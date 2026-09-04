//! Owned, coarse-grained API suitable for a generated Dart/Rust bridge.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use thiserror::Error;

use crate::application::{DeviceFileLocator, OpenDocument, OpenDocumentError};
use crate::document::{Document, RenderedPage};
use crate::library::BookFormat;

pub const MAX_BRIDGE_BUFFER_BYTES: usize = 160 * 1024 * 1024;
pub const MAX_BRIDGE_RETAINED_BUFFER_BYTES: usize = 320 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct OpenRequest {
    pub book_id: Option<i64>,
    pub locator: DeviceFileLocator,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DocumentHandle(u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BufferHandle(u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentSummary {
    pub handle: DocumentHandle,
    pub book_id: Option<i64>,
    pub format: BookFormat,
    pub title: Option<String>,
    pub page_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RenderRequest {
    pub document: DocumentHandle,
    pub page: usize,
    pub scale: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderedBuffer {
    pub handle: BufferHandle,
    pub width: u32,
    pub height: u32,
    pub byte_len: usize,
}

#[derive(Debug, Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);

impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum BridgeError {
    #[error("operation was cancelled")]
    Cancelled,
    #[error("unknown or released document handle")]
    InvalidDocumentHandle,
    #[error("unknown or released buffer handle")]
    InvalidBufferHandle,
    #[error("operation is unsupported for {0}")]
    UnsupportedOperation(BookFormat),
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("document open failed: {0}")]
    Open(String),
    #[error("document render failed: {0}")]
    Render(String),
    #[error("bridge buffer exceeds {MAX_BRIDGE_BUFFER_BYTES} bytes")]
    BufferLimit,
    #[error("Rust operation panicked")]
    Panic,
    #[error("bridge worker stopped unexpectedly")]
    Worker,
}

#[derive(Debug, Default)]
struct Registry {
    documents: HashMap<DocumentHandle, (Option<i64>, OpenDocument)>,
    buffers: HashMap<BufferHandle, Vec<u8>>,
    retained_buffer_bytes: usize,
}

#[derive(Debug, Default, Clone)]
pub struct Bridge {
    next_handle: Arc<AtomicU64>,
    registry: Arc<Mutex<Registry>>,
}

impl Bridge {
    pub async fn open_document(
        &self,
        request: OpenRequest,
        cancellation: Cancellation,
    ) -> Result<DocumentSummary, BridgeError> {
        check_cancelled(&cancellation)?;
        let locator = request.locator.clone();
        let document = tokio::task::spawn_blocking(move || {
            guarded(|| OpenDocument::open(&locator).map_err(map_open_error))
        })
        .await
        .map_err(|_| BridgeError::Worker)??;
        check_cancelled(&cancellation)?;

        let handle = DocumentHandle(self.next_id());
        let summary = DocumentSummary {
            handle,
            book_id: request.book_id,
            format: document.format(),
            title: document.title(),
            page_count: document.page_count(),
        };
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .insert(handle, (request.book_id, document));
        Ok(summary)
    }

    pub async fn render_page(
        &self,
        request: RenderRequest,
        cancellation: Cancellation,
    ) -> Result<RenderedBuffer, BridgeError> {
        check_cancelled(&cancellation)?;
        if !request.scale.is_finite() || request.scale <= 0.0 {
            return Err(BridgeError::InvalidRequest(
                "render scale must be finite and positive".to_owned(),
            ));
        }
        let document = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .get(&request.document)
            .map(|(_, document)| document.clone())
            .ok_or(BridgeError::InvalidDocumentHandle)?;
        let rendered = tokio::task::spawn_blocking(move || {
            guarded(|| render(document, request.page, request.scale))
        })
        .await
        .map_err(|_| BridgeError::Worker)??;
        check_cancelled(&cancellation)?;
        self.store_buffer(rendered)
    }

    pub fn take_buffer(&self, handle: BufferHandle) -> Result<Vec<u8>, BridgeError> {
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let buffer = registry
            .buffers
            .remove(&handle)
            .ok_or(BridgeError::InvalidBufferHandle)?;
        registry.retained_buffer_bytes -= buffer.len();
        Ok(buffer)
    }

    pub fn release_document(&self, handle: DocumentHandle) -> bool {
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .remove(&handle)
            .is_some()
    }

    pub fn release_buffer(&self, handle: BufferHandle) -> bool {
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(buffer) = registry.buffers.remove(&handle) else {
            return false;
        };
        registry.retained_buffer_bytes -= buffer.len();
        true
    }

    fn next_id(&self) -> u64 {
        self.next_handle.fetch_add(1, Ordering::Relaxed) + 1
    }

    fn store_buffer(&self, rendered: RenderedPage) -> Result<RenderedBuffer, BridgeError> {
        self.store_buffer_with_limit(rendered, MAX_BRIDGE_RETAINED_BUFFER_BYTES)
    }

    fn store_buffer_with_limit(
        &self,
        rendered: RenderedPage,
        retained_limit: usize,
    ) -> Result<RenderedBuffer, BridgeError> {
        let pixels = rendered.pixels.to_vec();
        if pixels.len() > MAX_BRIDGE_BUFFER_BYTES {
            return Err(BridgeError::BufferLimit);
        }
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(retained_buffer_bytes) = registry.retained_buffer_bytes.checked_add(pixels.len())
        else {
            return Err(BridgeError::BufferLimit);
        };
        if retained_buffer_bytes > retained_limit {
            return Err(BridgeError::BufferLimit);
        }
        let handle = BufferHandle(self.next_id());
        let result = RenderedBuffer {
            handle,
            width: rendered.width,
            height: rendered.height,
            byte_len: pixels.len(),
        };
        registry.retained_buffer_bytes = retained_buffer_bytes;
        registry.buffers.insert(handle, pixels);
        Ok(result)
    }
}

fn guarded<T>(operation: impl FnOnce() -> Result<T, BridgeError>) -> Result<T, BridgeError> {
    catch_unwind(AssertUnwindSafe(operation)).map_err(|_| BridgeError::Panic)?
}

fn check_cancelled(cancellation: &Cancellation) -> Result<(), BridgeError> {
    if cancellation.is_cancelled() {
        Err(BridgeError::Cancelled)
    } else {
        Ok(())
    }
}

fn map_open_error(error: OpenDocumentError) -> BridgeError {
    BridgeError::Open(error.to_string())
}

fn render(document: OpenDocument, page: usize, scale: f32) -> Result<RenderedPage, BridgeError> {
    match document {
        OpenDocument::Pdf(document) => document
            .render_page(page, scale)
            .map_err(|error| BridgeError::Render(error.to_string())),
        OpenDocument::Cbz(document) => document
            .render_page(page, scale)
            .map_err(|error| BridgeError::Render(error.to_string())),
        OpenDocument::Epub(_) => Err(BridgeError::UnsupportedOperation(BookFormat::Epub)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cancellation_prevents_opening_and_allocating_handles() {
        let bridge = Bridge::default();
        let cancellation = Cancellation::default();
        cancellation.cancel();

        let error = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    locator: DeviceFileLocator::from_path("missing.cbz"),
                },
                cancellation,
            )
            .await
            .unwrap_err();

        assert_eq!(error, BridgeError::Cancelled);
        assert!(bridge.registry.lock().unwrap().documents.is_empty());
    }

    #[tokio::test]
    async fn owned_buffers_and_documents_are_released_deterministically() {
        let bridge = Bridge::default();
        let document = bridge
            .open_document(
                OpenRequest {
                    book_id: Some(7),
                    locator: DeviceFileLocator::from_path(concat!(
                        env!("CARGO_MANIFEST_DIR"),
                        "/tests/fixtures/sample.cbz"
                    )),
                },
                Cancellation::default(),
            )
            .await
            .unwrap();
        let rendered = bridge
            .render_page(
                RenderRequest {
                    document: document.handle,
                    page: 0,
                    scale: 1.0,
                },
                Cancellation::default(),
            )
            .await
            .unwrap();

        let bytes = bridge.take_buffer(rendered.handle).unwrap();
        assert_eq!(bytes.len(), rendered.byte_len);
        assert_eq!(
            bridge.take_buffer(rendered.handle),
            Err(BridgeError::InvalidBufferHandle)
        );
        assert!(bridge.release_document(document.handle));
        assert!(!bridge.release_document(document.handle));
    }

    #[test]
    fn retained_buffers_have_an_aggregate_limit_and_release_their_budget() {
        let bridge = Bridge::default();
        let rendered = || RenderedPage {
            width: 1,
            height: 1,
            pixels: vec![0; 4].into(),
        };

        let first = bridge.store_buffer_with_limit(rendered(), 4).unwrap();
        assert_eq!(
            bridge.store_buffer_with_limit(rendered(), 4),
            Err(BridgeError::BufferLimit)
        );
        assert!(bridge.release_buffer(first.handle));
        assert!(bridge.store_buffer_with_limit(rendered(), 4).is_ok());
    }
}
