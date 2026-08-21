//! Types representing the structure of an EPUB document.

use std::collections::HashMap;

use super::CanonicalEpubPath;
use super::style::EpubStyles;

/// Metadata extracted from the OPF `<metadata>` element.
#[derive(Debug, Clone, Default)]
pub struct EpubMetadata {
    pub title: Option<String>,
    pub author: Option<String>,
    pub language: Option<String>,
    pub publisher: Option<String>,
    pub description: Option<String>,
    /// Manifest ID of the cover image (from `<meta name="cover" content="..."/>`).
    pub cover_image_id: Option<String>,
}

/// An entry in the OPF manifest.
#[derive(Debug, Clone)]
pub struct ManifestItem {
    /// Manifest item ID (e.g. "chapter1").
    pub id: String,
    /// Path relative to the OPF file (e.g. "Text/chapter1.xhtml").
    pub href: String,
    /// MIME type (e.g. "application/xhtml+xml").
    pub media_type: String,
}

/// A chapter (spine item) with its content loaded.
#[derive(Debug, Clone)]
pub struct Chapter {
    /// Index in the spine (reading order).
    pub index: usize,
    /// Title from the TOC, if available.
    pub title: Option<String>,
    /// Path within the EPUB archive.
    pub path: String,
    /// Raw XHTML content of this chapter.
    pub content: String,
}

/// Table of contents entry.
#[derive(Debug, Clone)]
pub struct TocEntry {
    /// Display title.
    pub title: String,
    /// Path within the EPUB archive (may include fragment #id).
    pub href: String,
    /// Nested children.
    pub children: Vec<TocEntry>,
}

/// A read-only manifest resource admitted through the EPUB resource policy.
#[derive(Debug, Clone, Copy)]
pub struct EpubResource<'a> {
    pub(crate) path: &'a CanonicalEpubPath,
    pub(crate) media_type: &'a str,
    pub(crate) bytes: &'a [u8],
}

impl<'a> EpubResource<'a> {
    /// Canonical path within the EPUB archive.
    pub fn path(self) -> &'a CanonicalEpubPath {
        self.path
    }

    /// Media type declared by the OPF manifest.
    pub fn media_type(self) -> &'a str {
        self.media_type
    }

    /// Resource bytes retained by the parsed document.
    pub fn bytes(self) -> &'a [u8] {
        self.bytes
    }
}

#[derive(Debug, Clone)]
pub(crate) struct StoredEpubResource {
    pub media_type: String,
    pub bytes: Vec<u8>,
}

/// Complete parsed EPUB structure.
#[derive(Debug, Clone)]
pub struct EpubContent {
    /// Document metadata.
    pub metadata: EpubMetadata,
    /// Chapters in reading order.
    pub chapters: Vec<Chapter>,
    /// Table of contents.
    pub toc: Vec<TocEntry>,
    /// All manifest items by ID.
    pub manifest: HashMap<String, ManifestItem>,
    /// Resources admitted by the parser, keyed by canonical archive path.
    pub(crate) resources: HashMap<CanonicalEpubPath, StoredEpubResource>,
    /// Admitted author stylesheets used by the native computed-style engine.
    pub styles: EpubStyles,
}
