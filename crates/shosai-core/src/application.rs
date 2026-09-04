//! Platform-neutral document admission and format capabilities.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::cbz::CbzDoc;
use crate::document::Document;
use crate::epub::pagination::content_node_text_len;
use crate::epub::{EpubDoc, EpubLimits};
use crate::library::BookFormat;
use crate::path_key::path_key;
use crate::pdf::PdfDoc;

const EPUB_RETAINED_SOURCE_COPIES: usize = 4;
const EPUB_PRESENTATION_UNIT_BYTES: usize = 256;
const EPUB_CONTAINER_OVERHEAD_BYTES: usize = 64 * 1024 * 1024;
const PDF_RETAINED_OVERHEAD_BYTES: usize = 16 * 1024 * 1024;

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

#[derive(Debug, Error)]
#[error("{0}")]
pub(crate) struct ResourceLimitError(pub(crate) String);

#[derive(Debug, Clone)]
pub enum OpenDocument {
    Pdf(Arc<PdfDoc>),
    Epub(Arc<EpubDoc>),
    Cbz(Arc<CbzDoc>),
}

#[derive(Debug)]
pub struct OpenDocumentPlan {
    format: BookFormat,
    file: std::fs::File,
    encoded_byte_len: usize,
    title_hint: Option<String>,
}

pub(crate) struct AdmittedDocumentBytes {
    pub(crate) format: BookFormat,
    pub(crate) data: Vec<u8>,
    pub(crate) title_hint: Option<String>,
    admission: crate::document_admission::ProvisionalDocumentAdmission,
}

impl OpenDocumentPlan {
    pub fn prepare(locator: &DeviceFileLocator) -> Result<Self, OpenDocumentError> {
        let format = locator.format()?;
        let file = std::fs::File::open(locator.path()).map_err(|error| match error.kind() {
            std::io::ErrorKind::NotFound => OpenDocumentError::NotFound,
            _ => OpenDocumentError::Inaccessible(error.to_string()),
        })?;
        let max_input_bytes = OpenDocument::max_input_bytes(format);
        let file_size = file
            .metadata()
            .map_err(|error| OpenDocumentError::Inaccessible(error.to_string()))?
            .len();
        if file_size > max_input_bytes {
            return Err(OpenDocumentError::LimitExceeded {
                format,
                detail: format!("input is larger than {max_input_bytes} bytes"),
            });
        }
        let encoded_byte_len =
            usize::try_from(file_size).map_err(|_| OpenDocumentError::LimitExceeded {
                format,
                detail: "input size cannot be represented".to_owned(),
            })?;
        Ok(Self {
            format,
            file,
            encoded_byte_len,
            title_hint: locator
                .path()
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned()),
        })
    }

    pub fn format(&self) -> BookFormat {
        self.format
    }

    pub fn retained_admission_byte_len(&self) -> Option<usize> {
        OpenDocument::retained_admission_byte_len(self.format, self.encoded_byte_len)
    }

    pub(crate) fn read_bytes(mut self) -> Result<AdmittedDocumentBytes, OpenDocumentError> {
        let retained_bytes =
            OpenDocument::maximum_retained_byte_len(self.format).ok_or_else(|| {
                OpenDocumentError::LimitExceeded {
                    format: self.format,
                    detail: "retained-memory admission cannot be represented".to_owned(),
                }
            })?;
        let admission =
            crate::document_admission::ProvisionalDocumentAdmission::acquire(retained_bytes)
                .map_err(|error| classify_open_error(self.format, error))?;
        let max_input_bytes = OpenDocument::max_input_bytes(self.format);
        let read_limit =
            max_input_bytes
                .checked_add(1)
                .ok_or_else(|| OpenDocumentError::LimitExceeded {
                    format: self.format,
                    detail: "input byte limit cannot be represented".to_owned(),
                })?;
        let mut data = Vec::with_capacity(self.encoded_byte_len);
        self.file
            .by_ref()
            .take(read_limit)
            .read_to_end(&mut data)
            .map_err(|error| classify_open_error(self.format, error.into()))?;
        if data.len() as u64 > max_input_bytes {
            return Err(OpenDocumentError::LimitExceeded {
                format: self.format,
                detail: format!("input is larger than {max_input_bytes} bytes"),
            });
        }
        Ok(AdmittedDocumentBytes {
            format: self.format,
            data,
            title_hint: self.title_hint,
            admission,
        })
    }

    pub fn open(self) -> Result<OpenDocument, OpenDocumentError> {
        OpenDocument::from_admitted_bytes(self.read_bytes()?)
    }

    #[doc(hidden)]
    pub fn open_with_content_hash(self) -> Result<(OpenDocument, String), OpenDocumentError> {
        let admitted = self.read_bytes()?;
        let content_hash = format!("{:x}", Sha256::digest(&admitted.data));
        let document = OpenDocument::from_admitted_bytes(admitted)?;
        Ok((document, content_hash))
    }
}

impl OpenDocument {
    /// Conservative charge that must be admitted before parsing this format.
    #[doc(hidden)]
    pub fn maximum_retained_byte_len(format: BookFormat) -> Option<usize> {
        let encoded_byte_len = usize::try_from(Self::max_input_bytes(format)).ok()?;
        Self::retained_admission_byte_len(format, encoded_byte_len)
    }

    /// Conservative retained charge for a stable encoded input length.
    #[doc(hidden)]
    pub fn retained_admission_byte_len(
        format: BookFormat,
        encoded_byte_len: usize,
    ) -> Option<usize> {
        let expansion = match format {
            BookFormat::Epub => {
                let limits = EpubLimits::default();
                usize::try_from(limits.max_total_uncompressed_bytes)
                    .ok()?
                    .checked_mul(EPUB_RETAINED_SOURCE_COPIES)?
                    .checked_add(limits.max_total_decoded_font_bytes)?
                    .checked_add(
                        limits
                            .max_total_presentation_nodes
                            .checked_mul(EPUB_PRESENTATION_UNIT_BYTES)?,
                    )?
                    .checked_add(EPUB_CONTAINER_OVERHEAD_BYTES)?
            }
            BookFormat::Pdf => PDF_RETAINED_OVERHEAD_BYTES,
            BookFormat::Cbz => {
                let limits = crate::cbz::CbzLimits::default();
                encoded_byte_len
                    .checked_add(limits.max_entries.checked_mul(
                        std::mem::size_of::<String>()
                            + std::mem::size_of::<usize>()
                            + std::mem::size_of::<Option<(u32, u32)>>(),
                    )?)?
                    .checked_add(4 * 1024)?
            }
        };
        encoded_byte_len.checked_add(expansion)
    }

    /// Conservative byte charge for memory retained by this parsed document.
    #[doc(hidden)]
    pub fn retained_byte_len(&self) -> Option<usize> {
        match self {
            Self::Pdf(document) => document.retained_byte_len(),
            Self::Epub(document) => document.retained_byte_len(),
            Self::Cbz(document) => document.retained_byte_len(),
        }
    }

    pub fn open(locator: &DeviceFileLocator) -> Result<Self, OpenDocumentError> {
        OpenDocumentPlan::prepare(locator)?.open()
    }

    pub(crate) fn max_input_bytes(format: BookFormat) -> u64 {
        format.max_input_bytes()
    }

    #[cfg(test)]
    pub(crate) fn from_bytes(
        format: BookFormat,
        data: Vec<u8>,
        title_hint: Option<String>,
    ) -> Result<Self, OpenDocumentError> {
        match format {
            BookFormat::Pdf => PdfDoc::from_bytes(data)
                .map(|document| Self::Pdf(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
            BookFormat::Epub => EpubDoc::from_bytes(data)
                .map(|document| Self::Epub(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
            BookFormat::Cbz => CbzDoc::from_bytes_with_title_hint(data, title_hint)
                .map(|document| Self::Cbz(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
        }
    }

    pub(crate) fn from_admitted_bytes(
        admitted: AdmittedDocumentBytes,
    ) -> Result<Self, OpenDocumentError> {
        let AdmittedDocumentBytes {
            format,
            data,
            title_hint,
            admission,
        } = admitted;
        match format {
            BookFormat::Pdf => PdfDoc::from_bytes_admitted(data, admission)
                .map(|document| Self::Pdf(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
            BookFormat::Epub => EpubDoc::from_bytes_admitted(data, admission)
                .map(|document| Self::Epub(Arc::new(document)))
                .map_err(|error| classify_open_error(format, error)),
            BookFormat::Cbz => {
                CbzDoc::from_bytes_with_title_hint_admitted(data, title_hint, admission)
                    .map(|document| Self::Cbz(Arc::new(document)))
                    .map_err(|error| classify_open_error(format, error))
            }
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
    if error
        .chain()
        .any(|cause| cause.downcast_ref::<ResourceLimitError>().is_some())
    {
        return OpenDocumentError::LimitExceeded { format, detail };
    }
    if format == BookFormat::Pdf && crate::pdf::is_backend_unavailable(&error) {
        return OpenDocumentError::BackendUnavailable { format, detail };
    }
    if let Some(io_error) = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<std::io::Error>())
    {
        return match io_error.kind() {
            std::io::ErrorKind::NotFound => OpenDocumentError::NotFound,
            std::io::ErrorKind::PermissionDenied
            | std::io::ErrorKind::ReadOnlyFilesystem
            | std::io::ErrorKind::ResourceBusy => OpenDocumentError::Inaccessible(detail),
            _ => OpenDocumentError::Open { format, detail },
        };
    }
    OpenDocumentError::Open { format, detail }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cbz::CbzLimits;
    use crate::pdf::MAX_PDF_INPUT_BYTES;

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
    fn parser_limits_have_a_structural_limit_category() {
        let limits = CbzLimits {
            max_entries: 0,
            ..CbzLimits::default()
        };
        let error = CbzDoc::from_bytes_with_limits(
            include_bytes!("../tests/fixtures/sample.cbz").to_vec(),
            limits,
        )
        .unwrap_err();

        assert!(matches!(
            classify_open_error(BookFormat::Cbz, error),
            OpenDocumentError::LimitExceeded {
                format: BookFormat::Cbz,
                ..
            }
        ));
    }

    #[test]
    fn malformed_io_is_not_classified_as_inaccessible() {
        let error = anyhow::Error::new(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "malformed stream",
        ));

        assert!(matches!(
            classify_open_error(BookFormat::Epub, error),
            OpenDocumentError::Open {
                format: BookFormat::Epub,
                ..
            }
        ));
    }

    #[test]
    fn malformed_cbz_bytes_have_a_structural_open_category() {
        let error =
            OpenDocument::from_bytes(BookFormat::Cbz, b"not a zip".to_vec(), None).unwrap_err();

        assert!(matches!(
            error,
            OpenDocumentError::Open {
                format: BookFormat::Cbz,
                ..
            }
        ));
    }

    #[test]
    fn malformed_pdf_bytes_have_a_structural_open_category() {
        let error =
            OpenDocument::from_bytes(BookFormat::Pdf, b"not a pdf".to_vec(), None).unwrap_err();

        assert!(matches!(
            error,
            OpenDocumentError::Open {
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
