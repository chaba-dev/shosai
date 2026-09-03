//! Platform-neutral document admission and format capabilities.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use thiserror::Error;

use crate::cbz::{CbzDoc, CbzLimits};
use crate::document::Document;
use crate::epub::pagination::content_node_text_len;
use crate::epub::{EpubDoc, EpubLimits};
use crate::library::BookFormat;
use crate::path_key::path_key;
use crate::pdf::{MAX_PDF_INPUT_BYTES, PdfDoc};

/// A locator supplied by the current device.
///
/// `local_id` is meaningful only to the platform adapter that issued it. It is
/// deliberately separate from library identity and must not be synchronized.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceFileLocator {
    local_id: String,
    path: PathBuf,
    format_hint: Option<BookFormat>,
}

impl DeviceFileLocator {
    pub fn new(local_id: impl Into<String>, path: impl Into<PathBuf>) -> Self {
        Self {
            local_id: local_id.into(),
            path: path.into(),
            format_hint: None,
        }
    }

    pub fn with_format_hint(mut self, format: BookFormat) -> Self {
        self.format_hint = Some(format);
        self
    }

    pub fn from_path(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        Self::new(path_key(&path), path)
    }

    pub fn local_id(&self) -> &str {
        &self.local_id
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn format_hint(&self) -> Option<BookFormat> {
        self.format_hint
    }

    pub fn format(&self) -> Result<BookFormat, OpenDocumentError> {
        let extension = self
            .path()
            .extension()
            .map(|extension| extension.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        self.format_hint()
            .or_else(|| BookFormat::from_extension(&extension))
            .ok_or(OpenDocumentError::UnsupportedFormat(extension))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FormatCapabilities {
    pub paginated: bool,
    pub continuous: bool,
    pub reflowable: bool,
    pub searchable: bool,
    pub selectable: bool,
}

pub fn format_capabilities(format: BookFormat) -> FormatCapabilities {
    match format {
        BookFormat::Pdf => FormatCapabilities {
            paginated: true,
            continuous: true,
            reflowable: false,
            searchable: true,
            selectable: true,
        },
        BookFormat::Epub => FormatCapabilities {
            paginated: true,
            continuous: true,
            reflowable: true,
            searchable: true,
            selectable: true,
        },
        BookFormat::Cbz => FormatCapabilities {
            paginated: true,
            continuous: true,
            reflowable: false,
            searchable: false,
            selectable: false,
        },
    }
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum OpenDocumentError {
    #[error("unsupported file format: .{0}")]
    UnsupportedFormat(String),
    #[error("document was not found")]
    NotFound,
    #[error("document is inaccessible: {0}")]
    Inaccessible(String),
    #[error("{format} exceeds an opening resource limit: {detail}")]
    LimitExceeded { format: BookFormat, detail: String },
    #[error("{format} backend is unavailable: {detail}")]
    BackendUnavailable { format: BookFormat, detail: String },
    #[error("failed to open {format}: {detail}")]
    Open { format: BookFormat, detail: String },
}

#[derive(Debug, Clone)]
pub enum OpenDocument {
    Pdf(Arc<PdfDoc>),
    Epub(Arc<EpubDoc>),
    Cbz(Arc<CbzDoc>),
}

impl OpenDocument {
    pub fn open(locator: &DeviceFileLocator) -> Result<Self, OpenDocumentError> {
        let format = locator.format()?;
        let metadata = std::fs::metadata(locator.path()).map_err(|error| match error.kind() {
            std::io::ErrorKind::NotFound => OpenDocumentError::NotFound,
            _ => OpenDocumentError::Inaccessible(error.to_string()),
        })?;
        let max_input_bytes = match format {
            BookFormat::Pdf => MAX_PDF_INPUT_BYTES,
            BookFormat::Epub => EpubLimits::default().max_input_bytes,
            BookFormat::Cbz => CbzLimits::default().max_archive_bytes,
        };
        if metadata.len() > max_input_bytes {
            return Err(OpenDocumentError::LimitExceeded {
                format,
                detail: format!("input is larger than {max_input_bytes} bytes"),
            });
        }

        match format {
            BookFormat::Pdf => PdfDoc::open(locator.path())
                .map(|document| Self::Pdf(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
            BookFormat::Epub => EpubDoc::open(locator.path())
                .map(|document| Self::Epub(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
            BookFormat::Cbz => CbzDoc::open(locator.path())
                .map(|document| Self::Cbz(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
        }
    }

    pub fn format(&self) -> BookFormat {
        match self {
            Self::Pdf(_) => BookFormat::Pdf,
            Self::Epub(_) => BookFormat::Epub,
            Self::Cbz(_) => BookFormat::Cbz,
        }
    }

    pub fn capabilities(&self) -> FormatCapabilities {
        format_capabilities(self.format())
    }

    pub fn page_count(&self) -> usize {
        match self {
            Self::Pdf(document) => document.page_count(),
            Self::Epub(document) => document.chapter_count(),
            Self::Cbz(document) => document.page_count(),
        }
    }

    pub fn title(&self) -> Option<String> {
        match self {
            Self::Pdf(document) => document.title(),
            Self::Epub(document) => document.metadata().title,
            Self::Cbz(document) => document.metadata().title,
        }
    }

    pub fn max_location_offset(&self, page: usize) -> Option<usize> {
        let Self::Epub(document) = self else {
            return None;
        };
        document.presentation().chapter(page).map(|chapter| {
            chapter.nodes().iter().fold(0usize, |offset, node| {
                offset.saturating_add(content_node_text_len(node).saturating_add(1))
            })
        })
    }
}

fn classify_open_error(format: BookFormat, error: anyhow::Error) -> OpenDocumentError {
    let detail = format!("{error:#}");
    if format == BookFormat::Pdf && crate::pdf::is_backend_unavailable(&error) {
        return OpenDocumentError::BackendUnavailable { format, detail };
    }
    if let Some(io_error) = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<std::io::Error>())
    {
        return match io_error.kind() {
            std::io::ErrorKind::NotFound => OpenDocumentError::NotFound,
            _ => OpenDocumentError::Inaccessible(detail),
        };
    }
    OpenDocumentError::Open { format, detail }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locator_identity_is_device_local_and_does_not_rewrite_the_path() {
        let locator = DeviceFileLocator::new("android:42", "content/books/example.epub");

        assert_eq!(locator.local_id(), "android:42");
        assert_eq!(locator.path(), Path::new("content/books/example.epub"));
    }

    #[test]
    fn format_capabilities_are_centralized() {
        assert!(format_capabilities(BookFormat::Epub).reflowable);
        assert!(format_capabilities(BookFormat::Pdf).selectable);
        assert!(!format_capabilities(BookFormat::Cbz).searchable);
    }

    #[test]
    fn unsupported_extensions_fail_before_document_io() {
        let error = OpenDocument::open(&DeviceFileLocator::from_path("missing.txt")).unwrap_err();

        assert_eq!(
            error,
            OpenDocumentError::UnsupportedFormat("txt".to_owned())
        );
    }

    #[test]
    fn platform_format_hint_is_checked_before_document_io() {
        let locator = DeviceFileLocator::new("content:42", "missing-provider-file")
            .with_format_hint(BookFormat::Epub);
        let error = OpenDocument::open(&locator).unwrap_err();

        assert_eq!(error, OpenDocumentError::NotFound);
    }

    #[test]
    fn oversized_inputs_have_a_structural_limit_category() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("oversized.pdf");
        std::fs::File::create(&path)
            .unwrap()
            .set_len(MAX_PDF_INPUT_BYTES + 1)
            .unwrap();

        let error = OpenDocument::open(&DeviceFileLocator::from_path(path)).unwrap_err();

        assert!(matches!(
            error,
            OpenDocumentError::LimitExceeded {
                format: BookFormat::Pdf,
                ..
            }
        ));
    }

    #[test]
    fn pdf_backend_failures_have_a_structural_category() {
        let error = anyhow::Error::new(crate::pdf::PdfBackendUnavailable(
            "missing PDFium".to_owned(),
        ));

        assert!(matches!(
            classify_open_error(BookFormat::Pdf, error),
            OpenDocumentError::BackendUnavailable {
                format: BookFormat::Pdf,
                ..
            }
        ));
    }

    #[cfg(unix)]
    #[test]
    fn path_locators_keep_non_unicode_paths_distinct() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;

        let first = DeviceFileLocator::from_path(Path::new(OsStr::from_bytes(b"book-\x80.epub")));
        let second = DeviceFileLocator::from_path(Path::new(OsStr::from_bytes(b"book-\x81.epub")));

        assert_ne!(first.local_id(), second.local_id());
        assert_eq!(first.path().as_os_str().as_bytes(), b"book-\x80.epub");
    }
}
