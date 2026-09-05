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
#[derive(Debug)]
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

impl EpubContent {
    pub(crate) fn retained_byte_len(&self) -> Option<usize> {
        fn toc_bytes(entries: &[TocEntry], capacity: usize) -> Option<usize> {
            entries.iter().try_fold(
                capacity.checked_mul(std::mem::size_of::<TocEntry>())?,
                |total, entry| {
                    total
                        .checked_add(entry.title.capacity())?
                        .checked_add(entry.href.capacity())?
                        .checked_add(toc_bytes(&entry.children, entry.children.capacity())?)
                },
            )
        }

        let metadata = [
            &self.metadata.title,
            &self.metadata.author,
            &self.metadata.language,
            &self.metadata.publisher,
            &self.metadata.description,
            &self.metadata.cover_image_id,
        ]
        .into_iter()
        .flatten()
        .try_fold(0_usize, |total, value| total.checked_add(value.capacity()))?;
        let chapters = self.chapters.iter().try_fold(
            self.chapters
                .capacity()
                .checked_mul(std::mem::size_of::<Chapter>())?,
            |total, chapter| {
                total
                    .checked_add(chapter.title.as_ref().map_or(0, String::capacity))?
                    .checked_add(chapter.path.capacity())?
                    .checked_add(chapter.content.capacity())
            },
        )?;
        let manifest = self.manifest.iter().try_fold(
            self.manifest
                .capacity()
                .checked_mul(std::mem::size_of::<String>() + std::mem::size_of::<ManifestItem>())?,
            |total, (id, item)| {
                total
                    .checked_add(id.capacity())?
                    .checked_add(item.id.capacity())?
                    .checked_add(item.href.capacity())?
                    .checked_add(item.media_type.capacity())
            },
        )?;
        let resources = self.resources.iter().try_fold(
            self.resources.capacity().checked_mul(
                std::mem::size_of::<CanonicalEpubPath>()
                    + std::mem::size_of::<StoredEpubResource>(),
            )?,
            |total, (path, resource)| {
                total
                    .checked_add(path.as_str().len())?
                    .checked_add(resource.media_type.capacity())?
                    .checked_add(resource.bytes.capacity())
            },
        )?;
        metadata
            .checked_add(chapters)?
            .checked_add(toc_bytes(&self.toc, self.toc.capacity())?)?
            .checked_add(manifest)?
            .checked_add(resources)?
            .checked_add(self.styles.retained_byte_len()?)?
            .checked_add(std::mem::size_of::<Self>())
    }
}
