//! Platform-neutral document admission and format capabilities.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use thiserror::Error;

use crate::cbz::CbzDoc;
use crate::document::Document;
use crate::epub::EpubDoc;
use crate::library::BookFormat;
use crate::pdf::PdfDoc;

/// A locator supplied by the current device.
///
/// `local_id` is meaningful only to the platform adapter that issued it. It is
/// deliberately separate from library identity and must not be synchronized.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceFileLocator {
    local_id: String,
    path: PathBuf,
}

impl DeviceFileLocator {
    pub fn new(local_id: impl Into<String>, path: impl Into<PathBuf>) -> Self {
        Self {
            local_id: local_id.into(),
            path: path.into(),
        }
    }

    pub fn from_path(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        Self::new(path.to_string_lossy(), path.clone())
    }

    pub fn local_id(&self) -> &str {
        &self.local_id
    }

    pub fn path(&self) -> &Path {
        &self.path
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
        let extension = locator
            .path()
            .extension()
            .map(|extension| extension.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let format = BookFormat::from_extension(&extension)
            .ok_or_else(|| OpenDocumentError::UnsupportedFormat(extension))?;

        match format {
            BookFormat::Pdf => PdfDoc::open(locator.path())
                .map(|document| Self::Pdf(Arc::new(document)))
                .map_err(|error| OpenDocumentError::Open {
                    format,
                    detail: error.to_string(),
                }),
            BookFormat::Epub => EpubDoc::open(locator.path())
                .map(|document| Self::Epub(Arc::new(document)))
                .map_err(|error| OpenDocumentError::Open {
                    format,
                    detail: format!("{error:#}"),
                }),
            BookFormat::Cbz => CbzDoc::open(locator.path())
                .map(|document| Self::Cbz(Arc::new(document)))
                .map_err(|error| OpenDocumentError::Open {
                    format,
                    detail: error.to_string(),
                }),
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
}
