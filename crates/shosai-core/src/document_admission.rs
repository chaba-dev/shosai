use std::sync::{Arc, Mutex, OnceLock};

use anyhow::{Result, bail};

use crate::application::ResourceLimitError;

#[cfg(not(any(test, feature = "test-unbounded-document-admission")))]
const MAX_DOCUMENTS: usize = 64;
#[cfg(any(test, feature = "test-unbounded-document-admission"))]
const MAX_DOCUMENTS: usize = 4096;
#[cfg(not(any(test, feature = "test-unbounded-document-admission")))]
const MAX_RETAINED_BYTES: usize = 3 * 1024 * 1024 * 1024;
#[cfg(any(test, feature = "test-unbounded-document-admission"))]
const MAX_RETAINED_BYTES: usize = usize::MAX / 4;
#[cfg(not(any(test, feature = "test-unbounded-document-admission")))]
const MAX_OPEN_WORKERS: usize = 64;
#[cfg(any(test, feature = "test-unbounded-document-admission"))]
const MAX_OPEN_WORKERS: usize = 4096;

#[derive(Debug, Default)]
struct AdmissionState {
    documents: usize,
    retained_bytes: usize,
    opening_bytes: usize,
    open_workers: usize,
}

#[derive(Debug)]
struct AdmissionController {
    state: Mutex<AdmissionState>,
    max_documents: usize,
    max_retained_bytes: usize,
    max_open_workers: usize,
}

impl AdmissionController {
    fn new(max_documents: usize, max_retained_bytes: usize, max_open_workers: usize) -> Self {
        Self {
            state: Mutex::new(AdmissionState::default()),
            max_documents,
            max_retained_bytes,
            max_open_workers,
        }
    }
}

fn controller() -> Arc<AdmissionController> {
    static CONTROLLER: OnceLock<Arc<AdmissionController>> = OnceLock::new();
    Arc::clone(CONTROLLER.get_or_init(|| {
        Arc::new(AdmissionController::new(
            MAX_DOCUMENTS,
            MAX_RETAINED_BYTES,
            MAX_OPEN_WORKERS,
        ))
    }))
}

#[derive(Debug)]
pub(crate) struct ProvisionalDocumentAdmission {
    controller: Arc<AdmissionController>,
    retained_bytes: usize,
    open_worker: bool,
}

impl ProvisionalDocumentAdmission {
    pub(crate) fn acquire(retained_bytes: usize) -> Result<Self> {
        Self::acquire_from(controller(), retained_bytes)
    }

    fn acquire_from(controller: Arc<AdmissionController>, retained_bytes: usize) -> Result<Self> {
        if retained_bytes > controller.max_retained_bytes {
            return Err(ResourceLimitError(
                "document exceeds the process retained-memory limit".to_owned(),
            )
            .into());
        }
        {
            let mut state = controller
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let admitted_bytes = state
                .retained_bytes
                .checked_add(state.opening_bytes)
                .and_then(|bytes| bytes.checked_add(retained_bytes));
            if state.documents >= controller.max_documents
                || state.open_workers >= controller.max_open_workers
                || admitted_bytes.is_none_or(|bytes| bytes > controller.max_retained_bytes)
            {
                return Err(ResourceLimitError(
                    "process document-opening capacity is exhausted".to_owned(),
                )
                .into());
            }
            state.documents += 1;
            state.opening_bytes += retained_bytes;
            state.open_workers += 1;
        }
        Ok(Self {
            controller,
            retained_bytes,
            open_worker: true,
        })
    }

    pub(crate) fn finish(mut self, actual_retained_bytes: usize) -> Result<DocumentAdmission> {
        if actual_retained_bytes > self.retained_bytes {
            bail!("document retained-memory estimate was exceeded");
        }
        {
            let mut state = self
                .controller
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state.opening_bytes -= self.retained_bytes;
            state.retained_bytes += actual_retained_bytes;
            state.open_workers -= 1;
        }
        self.retained_bytes = actual_retained_bytes;
        self.open_worker = false;
        Ok(DocumentAdmission { _lease: self })
    }
}

impl Drop for ProvisionalDocumentAdmission {
    fn drop(&mut self) {
        let mut state = self
            .controller
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.documents -= 1;
        if self.open_worker {
            state.opening_bytes -= self.retained_bytes;
            state.open_workers -= 1;
        } else {
            state.retained_bytes -= self.retained_bytes;
        }
    }
}

#[derive(Debug)]
pub(crate) struct DocumentAdmission {
    _lease: ProvisionalDocumentAdmission,
}

pub(crate) fn pdf_retained_ceiling(encoded_bytes: usize) -> Option<usize> {
    encoded_bytes.checked_add(16 * 1024 * 1024)
}

pub(crate) fn cbz_retained_ceiling(
    encoded_bytes: usize,
    max_entries: usize,
    archive_metadata_bytes: usize,
    copied_filename_ceiling: usize,
) -> Option<usize> {
    encoded_bytes
        .checked_add(archive_metadata_bytes)?
        .checked_add(copied_filename_ceiling)?
        .checked_add(max_entries.checked_mul(
            std::mem::size_of::<String>()
                + std::mem::size_of::<usize>()
                + std::mem::size_of::<Option<(u32, u32)>>()
                + std::mem::size_of::<Option<usize>>(),
        )?)?
        .checked_add(4 * 1024)
}

pub(crate) fn epub_retained_ceiling(
    encoded_bytes: usize,
    total_uncompressed_bytes: usize,
    decoded_font_bytes: usize,
    presentation_nodes: usize,
    central_directory_bytes: usize,
) -> Option<usize> {
    encoded_bytes
        .checked_add(total_uncompressed_bytes.checked_mul(4)?)?
        .checked_add(decoded_font_bytes)?
        .checked_add(presentation_nodes.checked_mul(256)?)?
        .checked_add(central_directory_bytes.checked_mul(16)?)?
        .checked_add(64 * 1024 * 1024)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composite_admission_releases_provisional_and_retained_capacity() {
        let controller = Arc::new(AdmissionController::new(2, 100, 2));
        let first = ProvisionalDocumentAdmission::acquire_from(Arc::clone(&controller), 60)
            .unwrap()
            .finish(20)
            .unwrap();
        let second = ProvisionalDocumentAdmission::acquire_from(Arc::clone(&controller), 70)
            .unwrap()
            .finish(30)
            .unwrap();

        assert!(ProvisionalDocumentAdmission::acquire_from(Arc::clone(&controller), 1).is_err());
        drop(first);
        let third =
            ProvisionalDocumentAdmission::acquire_from(Arc::clone(&controller), 50).unwrap();
        drop(third);
        drop(second);

        let state = controller.state.lock().unwrap();
        assert_eq!(state.documents, 0);
        assert_eq!(state.retained_bytes, 0);
        assert_eq!(state.opening_bytes, 0);
        assert_eq!(state.open_workers, 0);
    }

    #[test]
    fn composite_admission_is_atomic_on_failure() {
        let controller = Arc::new(AdmissionController::new(2, 100, 1));
        let first =
            ProvisionalDocumentAdmission::acquire_from(Arc::clone(&controller), 50).unwrap();
        assert!(ProvisionalDocumentAdmission::acquire_from(Arc::clone(&controller), 40).is_err());

        let state = controller.state.lock().unwrap();
        assert_eq!(state.documents, 1);
        assert_eq!(state.opening_bytes, 50);
        assert_eq!(state.open_workers, 1);
        drop(state);
        drop(first);
    }
}
