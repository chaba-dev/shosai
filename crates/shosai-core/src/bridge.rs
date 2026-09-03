//! Owned, coarse-grained API suitable for a generated Dart/Rust bridge.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use thiserror::Error;
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};

use crate::application::{DeviceFileLocator, OpenDocument, OpenDocumentError};
use crate::document::{Document, RenderedPage};
use crate::library::BookFormat;

pub const MAX_BRIDGE_BUFFER_BYTES: usize = 160 * 1024 * 1024;
pub const MAX_BRIDGE_RETAINED_BUFFER_BYTES: usize = 320 * 1024 * 1024;
pub const MAX_BRIDGE_RENDER_WORKERS: usize = 2;

static NEXT_REGISTRY_ID: AtomicU64 = AtomicU64::new(1);

/// Fixed-field request that can be generated directly into a Dart value.
#[derive(Debug, Clone)]
pub struct OpenRequest {
    pub book_id: Option<i64>,
    pub local_id: String,
    pub path: String,
    pub format_hint: Option<BookFormat>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DocumentHandle {
    pub registry: u64,
    pub id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BufferHandle {
    pub registry: u64,
    pub id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogicalUnit {
    Page,
    Chapter,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentSummary {
    pub handle: DocumentHandle,
    pub book_id: Option<i64>,
    pub format: BookFormat,
    pub title: Option<String>,
    pub logical_unit: LogicalUnit,
    pub logical_unit_count: usize,
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

#[derive(Debug, Default)]
struct CancellationInner {
    cancelled: AtomicBool,
    notify: Notify,
    publication: Mutex<()>,
}

#[derive(Debug, Clone, Default)]
pub struct Cancellation(Arc<CancellationInner>);

impl Cancellation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        let _publication = self
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.0.cancelled.store(true, Ordering::Release);
        self.0.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Acquire)
    }

    async fn cancelled(&self) {
        loop {
            let notified = self.0.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeErrorKind {
    Cancelled,
    NotFound,
    Inaccessible,
    Malformed,
    LimitExceeded,
    BackendUnavailable,
    RenderFailed,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum BridgeError {
    #[error("operation was cancelled")]
    Cancelled,
    #[error("unknown, foreign, or released document handle")]
    InvalidDocumentHandle,
    #[error("unknown, foreign, or released buffer handle")]
    InvalidBufferHandle,
    #[error("document was not found")]
    DocumentNotFound,
    #[error("document is inaccessible")]
    DocumentInaccessible,
    #[error("operation is unsupported for {0}")]
    UnsupportedOperation(BookFormat),
    #[error("unsupported file format: .{0}")]
    UnsupportedFormat(String),
    #[error("invalid page {page}; document has {page_count} pages")]
    InvalidPage { page: usize, page_count: usize },
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("failed to open {format}: {detail}")]
    Open { format: BookFormat, detail: String },
    #[error("document render failed: {0}")]
    Render(String),
    #[error("bridge buffer exceeds its memory budget")]
    BufferLimit,
    #[error("Rust operation panicked")]
    Panic,
    #[error("bridge worker stopped unexpectedly")]
    Worker,
}

impl BridgeError {
    pub fn kind(&self) -> BridgeErrorKind {
        match self {
            Self::Cancelled => BridgeErrorKind::Cancelled,
            Self::InvalidDocumentHandle | Self::InvalidBufferHandle | Self::DocumentNotFound => {
                BridgeErrorKind::NotFound
            }
            Self::DocumentInaccessible => BridgeErrorKind::Inaccessible,
            Self::BufferLimit => BridgeErrorKind::LimitExceeded,
            Self::Panic | Self::Worker => BridgeErrorKind::BackendUnavailable,
            Self::Render(_) => BridgeErrorKind::RenderFailed,
            Self::Open { detail, .. } if is_limit_error(detail) => BridgeErrorKind::LimitExceeded,
            Self::Open { .. }
            | Self::UnsupportedOperation(_)
            | Self::UnsupportedFormat(_)
            | Self::InvalidPage { .. }
            | Self::InvalidRequest(_) => BridgeErrorKind::Malformed,
        }
    }
}

fn is_limit_error(detail: &str) -> bool {
    detail.to_ascii_lowercase().contains("limit")
}

#[derive(Debug)]
struct RetainedBuffer {
    pixels: Vec<u8>,
    transferred: bool,
    _bytes: OwnedSemaphorePermit,
}

#[derive(Debug, Default)]
struct Registry {
    documents: HashMap<DocumentHandle, (Option<i64>, OpenDocument)>,
    buffers: HashMap<BufferHandle, RetainedBuffer>,
}

#[derive(Debug, Clone)]
pub struct Bridge {
    registry_id: u64,
    next_handle: Arc<AtomicU64>,
    registry: Arc<Mutex<Registry>>,
    render_slots: Arc<Semaphore>,
    buffer_bytes: Arc<Semaphore>,
}

impl Default for Bridge {
    fn default() -> Self {
        Self::new()
    }
}

impl Bridge {
    pub fn new() -> Self {
        Self::with_limits(MAX_BRIDGE_RETAINED_BUFFER_BYTES, MAX_BRIDGE_RENDER_WORKERS)
    }

    fn with_limits(buffer_bytes: usize, render_workers: usize) -> Self {
        Self {
            registry_id: NEXT_REGISTRY_ID.fetch_add(1, Ordering::Relaxed),
            next_handle: Arc::new(AtomicU64::new(0)),
            registry: Arc::new(Mutex::new(Registry::default())),
            render_slots: Arc::new(Semaphore::new(render_workers)),
            buffer_bytes: Arc::new(Semaphore::new(buffer_bytes)),
        }
    }

    pub async fn open_document(
        &self,
        request: OpenRequest,
        cancellation: Cancellation,
    ) -> Result<DocumentSummary, BridgeError> {
        check_cancelled(&cancellation)?;
        let mut locator = DeviceFileLocator::new(request.local_id, request.path);
        if let Some(format) = request.format_hint {
            locator = locator.with_format_hint(format);
        }
        match std::fs::metadata(locator.path()) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(BridgeError::DocumentNotFound);
            }
            Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
                return Err(BridgeError::DocumentInaccessible);
            }
            Err(_) => return Err(BridgeError::Worker),
        }
        let document = tokio::task::spawn_blocking(move || {
            guarded(|| OpenDocument::open(&locator).map_err(map_open_error))
        })
        .await
        .map_err(|_| BridgeError::Worker)??;
        let _publication = cancellation
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        check_cancelled(&cancellation)?;

        let handle = self.document_handle();
        let format = document.format();
        let summary = DocumentSummary {
            handle,
            book_id: request.book_id,
            format,
            title: document.title(),
            logical_unit: if format == BookFormat::Epub {
                LogicalUnit::Chapter
            } else {
                LogicalUnit::Page
            },
            logical_unit_count: document.page_count(),
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
        let document = self.document(request.document)?;
        let byte_len = render_byte_len(&document, request.page, request.scale)?;
        if byte_len > MAX_BRIDGE_BUFFER_BYTES {
            return Err(BridgeError::BufferLimit);
        }
        let transfer_peak = byte_len.checked_mul(2).ok_or(BridgeError::BufferLimit)?;
        let byte_permits = u32::try_from(transfer_peak).map_err(|_| BridgeError::BufferLimit)?;
        let render_slot = acquire_permits(Arc::clone(&self.render_slots), 1, &cancellation).await?;
        let buffer_bytes =
            acquire_permits(Arc::clone(&self.buffer_bytes), byte_permits, &cancellation).await?;
        check_cancelled(&cancellation)?;
        let rendered = tokio::task::spawn_blocking(move || {
            let _render_slot = render_slot;
            guarded(|| render(document, request.page, request.scale))
        })
        .await
        .map_err(|_| BridgeError::Worker)??;
        let _publication = cancellation
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        check_cancelled(&cancellation)?;
        self.store_buffer(request.document, rendered, buffer_bytes)
    }

    /// Copy a retained raster into the bridge generator's `Uint8List` representation.
    /// The caller must release the handle after the Dart list is no longer retained.
    pub fn take_buffer(&self, handle: BufferHandle) -> Result<Vec<u8>, BridgeError> {
        self.ensure_buffer_handle(handle)?;
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let buffer = registry
            .buffers
            .get_mut(&handle)
            .ok_or(BridgeError::InvalidBufferHandle)?;
        if buffer.transferred {
            return Err(BridgeError::InvalidBufferHandle);
        }
        buffer.transferred = true;
        Ok(buffer.pixels.clone())
    }

    pub fn release_document(&self, handle: DocumentHandle) -> bool {
        if handle.registry != self.registry_id {
            return false;
        }
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .remove(&handle)
            .is_some()
    }

    pub fn release_buffer(&self, handle: BufferHandle) -> bool {
        if handle.registry != self.registry_id {
            return false;
        }
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .buffers
            .remove(&handle)
            .is_some()
    }

    fn document(&self, handle: DocumentHandle) -> Result<OpenDocument, BridgeError> {
        if handle.registry != self.registry_id {
            return Err(BridgeError::InvalidDocumentHandle);
        }
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .get(&handle)
            .map(|(_, document)| document.clone())
            .ok_or(BridgeError::InvalidDocumentHandle)
    }

    fn ensure_buffer_handle(&self, handle: BufferHandle) -> Result<(), BridgeError> {
        (handle.registry == self.registry_id)
            .then_some(())
            .ok_or(BridgeError::InvalidBufferHandle)
    }

    fn document_handle(&self) -> DocumentHandle {
        DocumentHandle {
            registry: self.registry_id,
            id: self.next_id(),
        }
    }

    fn buffer_handle(&self) -> BufferHandle {
        BufferHandle {
            registry: self.registry_id,
            id: self.next_id(),
        }
    }

    fn next_id(&self) -> u64 {
        self.next_handle.fetch_add(1, Ordering::Relaxed) + 1
    }

    fn store_buffer(
        &self,
        document: DocumentHandle,
        rendered: RenderedPage,
        bytes: OwnedSemaphorePermit,
    ) -> Result<RenderedBuffer, BridgeError> {
        let byte_len = rendered.pixels.len();
        if byte_len
            .checked_mul(2)
            .is_none_or(|peak| peak > bytes.num_permits())
            || rendered.pixels.len() > MAX_BRIDGE_BUFFER_BYTES
        {
            return Err(BridgeError::BufferLimit);
        }
        let pixels = rendered.pixels.to_vec();
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if document.registry != self.registry_id || !registry.documents.contains_key(&document) {
            return Err(BridgeError::InvalidDocumentHandle);
        }
        let handle = self.buffer_handle();
        let result = RenderedBuffer {
            handle,
            width: rendered.width,
            height: rendered.height,
            byte_len,
        };
        registry.buffers.insert(
            handle,
            RetainedBuffer {
                pixels,
                transferred: false,
                _bytes: bytes,
            },
        );
        Ok(result)
    }
}

async fn acquire_permits(
    semaphore: Arc<Semaphore>,
    permits: u32,
    cancellation: &Cancellation,
) -> Result<OwnedSemaphorePermit, BridgeError> {
    tokio::select! {
        permit = semaphore.acquire_many_owned(permits) => permit.map_err(|_| BridgeError::Worker),
        () = cancellation.cancelled() => Err(BridgeError::Cancelled),
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
    match error {
        OpenDocumentError::UnsupportedFormat(extension) => {
            BridgeError::UnsupportedFormat(extension)
        }
        OpenDocumentError::Open { format, detail } => BridgeError::Open { format, detail },
    }
}

fn render_byte_len(document: &OpenDocument, page: usize, scale: f32) -> Result<usize, BridgeError> {
    let page_count = document.page_count();
    if page >= page_count {
        return Err(BridgeError::InvalidPage { page, page_count });
    }
    match document {
        OpenDocument::Pdf(document) => document
            .rendered_byte_len(page, scale)
            .map_err(|error| BridgeError::InvalidRequest(error.to_string())),
        OpenDocument::Cbz(document) => {
            let (width, height) = document
                .page_size(page)
                .map_err(|error| BridgeError::InvalidRequest(error.to_string()))?;
            let width = (f64::from(width) * f64::from(scale)).ceil();
            let height = (f64::from(height) * f64::from(scale)).ceil();
            if !width.is_finite() || !height.is_finite() || width < 1.0 || height < 1.0 {
                return Err(BridgeError::InvalidRequest(
                    "render dimensions must be finite and positive".to_owned(),
                ));
            }
            (width as usize)
                .checked_mul(height as usize)
                .and_then(|pixels| pixels.checked_mul(4))
                .ok_or(BridgeError::BufferLimit)
        }
        OpenDocument::Epub(_) => Err(BridgeError::UnsupportedOperation(BookFormat::Epub)),
    }
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

    fn cbz_request() -> OpenRequest {
        OpenRequest {
            book_id: Some(7),
            local_id: "fixture".to_owned(),
            path: concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/sample.cbz").to_owned(),
            format_hint: Some(BookFormat::Cbz),
        }
    }

    #[test]
    fn bridge_errors_expose_stable_categories() {
        assert_eq!(
            BridgeError::InvalidDocumentHandle.kind(),
            BridgeErrorKind::NotFound
        );
        assert_eq!(
            BridgeError::DocumentInaccessible.kind(),
            BridgeErrorKind::Inaccessible
        );
        assert_eq!(
            BridgeError::InvalidRequest("bad scale".to_owned()).kind(),
            BridgeErrorKind::Malformed
        );
        assert_eq!(
            BridgeError::Open {
                format: BookFormat::Cbz,
                detail: "entry exceeds byte limit".to_owned(),
            }
            .kind(),
            BridgeErrorKind::LimitExceeded
        );
        assert_eq!(
            BridgeError::Worker.kind(),
            BridgeErrorKind::BackendUnavailable
        );
        assert_eq!(
            BridgeError::Render("backend error".to_owned()).kind(),
            BridgeErrorKind::RenderFailed
        );
    }

    #[tokio::test]
    async fn cancellation_prevents_opening_and_allocating_handles() {
        let bridge = Bridge::new();
        let cancellation = Cancellation::new();
        cancellation.cancel();

        let error = bridge
            .open_document(cbz_request(), cancellation)
            .await
            .unwrap_err();

        assert_eq!(error, BridgeError::Cancelled);
        assert!(bridge.registry.lock().unwrap().documents.is_empty());
    }

    #[tokio::test]
    async fn missing_documents_have_a_stable_not_found_category() {
        let bridge = Bridge::new();
        let mut request = cbz_request();
        request.path = "/definitely/missing/shosai-book.cbz".to_owned();

        let error = bridge
            .open_document(request, Cancellation::new())
            .await
            .unwrap_err();

        assert_eq!(error, BridgeError::DocumentNotFound);
        assert_eq!(error.kind(), BridgeErrorKind::NotFound);
    }

    #[test]
    fn cancellation_waits_for_the_publication_barrier() {
        let cancellation = Cancellation::new();
        let publication = cancellation.0.publication.lock().unwrap();
        let cancelling = cancellation.clone();
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            cancelling.cancel();
            finished_tx.send(()).unwrap();
        });

        assert!(
            finished_rx
                .recv_timeout(std::time::Duration::from_millis(20))
                .is_err()
        );
        drop(publication);
        finished_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        thread.join().unwrap();
        assert!(cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn owned_buffers_and_documents_are_released_deterministically() {
        let bridge = Bridge::new();
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        assert_eq!(document.logical_unit, LogicalUnit::Page);
        let rendered = bridge
            .render_page(
                RenderRequest {
                    document: document.handle,
                    page: 0,
                    scale: 1.0,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();

        let bytes = bridge.take_buffer(rendered.handle).unwrap();
        assert_eq!(bytes.len(), rendered.byte_len);
        assert_eq!(
            bridge.take_buffer(rendered.handle),
            Err(BridgeError::InvalidBufferHandle)
        );
        assert!(bridge.release_buffer(rendered.handle));
        assert!(bridge.release_document(document.handle));
        assert!(!bridge.release_document(document.handle));
    }

    #[tokio::test]
    async fn retained_and_in_flight_buffers_share_one_budget() {
        let bridge = Bridge::with_limits(8, 1);
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let permit = Arc::clone(&bridge.buffer_bytes)
            .acquire_many_owned(8)
            .await
            .unwrap();
        let buffer = bridge
            .store_buffer(
                document.handle,
                RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: vec![0; 4].into(),
                },
                permit,
            )
            .unwrap();
        assert_eq!(bridge.buffer_bytes.available_permits(), 0);
        let retained_pointer = bridge.registry.lock().unwrap().buffers[&buffer.handle]
            .pixels
            .as_ptr();
        let transferred = bridge.take_buffer(buffer.handle).unwrap();
        assert_ne!(transferred.as_ptr(), retained_pointer);
        assert_eq!(bridge.buffer_bytes.available_permits(), 0);
        assert!(bridge.release_buffer(buffer.handle));
        assert_eq!(bridge.buffer_bytes.available_permits(), 8);
    }

    #[tokio::test]
    async fn released_document_cannot_publish_an_in_flight_result() {
        let bridge = Bridge::with_limits(8, 1);
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let permit = Arc::clone(&bridge.buffer_bytes)
            .acquire_many_owned(8)
            .await
            .unwrap();
        assert!(bridge.release_document(document.handle));

        assert_eq!(
            bridge.store_buffer(
                document.handle,
                RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: vec![0; 4].into(),
                },
                permit,
            ),
            Err(BridgeError::InvalidDocumentHandle)
        );
        assert!(bridge.registry.lock().unwrap().buffers.is_empty());
    }

    #[tokio::test]
    async fn cancellation_interrupts_waiting_for_buffer_budget() {
        let bridge = Bridge::with_limits(4, 1);
        let _permit = Arc::clone(&bridge.buffer_bytes)
            .acquire_many_owned(4)
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let waiting = acquire_permits(Arc::clone(&bridge.buffer_bytes), 4, &cancellation);
        tokio::pin!(waiting);
        cancellation.cancel();

        assert_eq!(waiting.await.unwrap_err(), BridgeError::Cancelled);
    }

    #[tokio::test]
    async fn cancellation_cannot_be_lost_while_waiters_register() {
        for _ in 0..1_000 {
            let cancellation = Cancellation::new();
            let waiting = cancellation.cancelled();
            tokio::pin!(waiting);
            cancellation.cancel();
            tokio::time::timeout(std::time::Duration::from_millis(100), waiting)
                .await
                .expect("a cancellation notification must not be lost");
        }
    }

    #[tokio::test]
    async fn handles_cannot_be_used_with_another_bridge_registry() {
        let first = Bridge::new();
        let second = Bridge::new();
        let document = first
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();

        assert_eq!(
            second
                .render_page(
                    RenderRequest {
                        document: document.handle,
                        page: 0,
                        scale: 1.0,
                    },
                    Cancellation::new(),
                )
                .await,
            Err(BridgeError::InvalidDocumentHandle)
        );
    }

    #[tokio::test]
    async fn invalid_pages_and_oversized_scales_fail_before_rendering() {
        let bridge = Bridge::new();
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();

        assert!(matches!(
            bridge
                .render_page(
                    RenderRequest {
                        document: document.handle,
                        page: usize::MAX,
                        scale: 1.0,
                    },
                    Cancellation::new(),
                )
                .await,
            Err(BridgeError::InvalidPage { .. })
        ));
        assert_eq!(
            bridge
                .render_page(
                    RenderRequest {
                        document: document.handle,
                        page: 0,
                        scale: 100_000.0,
                    },
                    Cancellation::new(),
                )
                .await,
            Err(BridgeError::BufferLimit)
        );
    }
}
