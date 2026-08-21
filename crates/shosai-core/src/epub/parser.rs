//! EPUB parsing: ZIP extraction, container.xml, OPF, and content loading.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Cursor, Read, Seek};
use std::path::Path;

use anyhow::{Context, Result};
use zip::ZipArchive;

use super::limits::{
    resource_read_limit, validate_declared_resource_size, validate_resource, validate_xml_shape,
};
use super::presentation::EpubPresentation;
use super::types::*;
use super::{CanonicalEpubPath, EpubLimits};
use crate::document::DocumentMetadata;

const MAX_ARCHIVE_ENTRIES: usize = u16::MAX as usize;

/// A parsed EPUB document.
#[derive(Debug)]
pub struct EpubDoc {
    pub content: EpubContent,
    presentation: EpubPresentation,
}

impl EpubDoc {
    /// Open an EPUB file from disk.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_limits(path, EpubLimits::default())
    }

    /// Open an EPUB file with explicit resource admission limits.
    pub fn open_with_limits(path: impl AsRef<Path>, limits: EpubLimits) -> Result<Self> {
        let path = path.as_ref();
        let file =
            File::open(path).with_context(|| format!("failed to read {}", path.display()))?;
        let declared_bytes = file
            .metadata()
            .with_context(|| format!("failed to inspect {}", path.display()))?
            .len();
        validate_input_size(declared_bytes, &limits)?;
        let capacity = usize::try_from(declared_bytes)
            .unwrap_or(usize::MAX)
            .min(usize::try_from(limits.max_input_bytes).unwrap_or(usize::MAX));
        let mut data = Vec::with_capacity(capacity);
        file.take(limits.max_input_bytes.saturating_add(1))
            .read_to_end(&mut data)
            .with_context(|| format!("failed to read {}", path.display()))?;
        validate_input_size(data.len() as u64, &limits)?;
        Self::from_bytes_with_limits(data, limits)
    }

    /// Open an EPUB from raw bytes.
    pub fn from_bytes(data: Vec<u8>) -> Result<Self> {
        Self::from_bytes_with_limits(data, EpubLimits::default())
    }

    /// Open an EPUB from raw bytes with explicit resource admission limits.
    pub fn from_bytes_with_limits(data: Vec<u8>, limits: EpubLimits) -> Result<Self> {
        Self::from_bytes_inner(data, false, limits)
    }

    /// Open an EPUB while retaining non-spine content documents for the renderer spike.
    #[doc(hidden)]
    pub fn from_bytes_for_renderer_spike(data: Vec<u8>) -> Result<Self> {
        Self::from_bytes_inner(data, true, EpubLimits::default())
    }

    fn from_bytes_inner(
        data: Vec<u8>,
        include_non_spine_content: bool,
        limits: EpubLimits,
    ) -> Result<Self> {
        validate_input_size(data.len() as u64, &limits)?;
        let declared_entries = declared_archive_entry_count(&data, limits.max_archive_entries)?;
        let mut validation_archive = ZipArchive::new(Cursor::new(data.as_slice()))
            .context("failed to open EPUB as ZIP archive")?;
        validate_archive_entries(&mut validation_archive, declared_entries, &limits, &data)?;
        drop(validation_archive);
        let cursor = Cursor::new(data);
        let mut archive = ZipArchive::new(cursor).context("failed to open EPUB as ZIP archive")?;

        // 1. Parse container.xml to find the OPF path.
        let opf_path = parse_container(&mut archive, &limits)?;

        // The OPF directory is used as a base for resolving relative paths.
        let opf_dir = opf_path
            .rsplit_once('/')
            .map_or_else(String::new, |(directory, _)| directory.to_string());

        // 2. Parse the OPF file.
        let opf_xml = read_archive_entry(&mut archive, &opf_path, &limits)
            .with_context(|| format!("failed to read OPF file: {opf_path}"))?;
        let (metadata, manifest, spine_ids) = parse_opf(&opf_xml, &opf_dir)?;

        // 3. Try to parse the TOC (NCX or nav document).
        let toc = parse_toc(&mut archive, &manifest, &opf_dir, &limits)?;

        // 4. Load chapters (spine items) in reading order.
        let chapters = load_chapters(&mut archive, &spine_ids, &manifest, &toc, &limits)?;

        // 5. Load resources (images, CSS, fonts).
        let chapter_paths = chapters
            .iter()
            .map(|chapter| chapter.path.as_str())
            .collect::<HashSet<_>>();
        let resources = load_resources(
            &mut archive,
            &manifest,
            &chapter_paths,
            include_non_spine_content,
            &limits,
        )?;

        // 6. Parse CSS stylesheets into a class → style map.
        let css_sources: Vec<(&str, &str)> = manifest
            .values()
            .filter(|item| item.media_type == "text/css")
            .filter_map(|item| {
                resources
                    .get(item.href.as_str())
                    .and_then(|resource| std::str::from_utf8(&resource.bytes).ok())
                    .map(|css| (item.href.as_str(), css))
            })
            .collect();

        let styles =
            super::style::parse_epub_styles(css_sources.iter().map(|(path, css)| (*path, *css)));

        let presentation = EpubPresentation::parse(&chapters, &styles);

        Ok(Self {
            content: EpubContent {
                metadata,
                chapters,
                toc,
                manifest,
                resources,
                styles,
            },
            presentation,
        })
    }

    /// Number of chapters.
    pub fn chapter_count(&self) -> usize {
        self.content.chapters.len()
    }

    /// Get a chapter by index.
    pub fn chapter(&self, index: usize) -> Option<&Chapter> {
        self.content.chapters.get(index)
    }

    /// Parsed chapter content shared by rendering, pagination, and search.
    pub fn presentation(&self) -> &EpubPresentation {
        &self.presentation
    }

    /// Get document metadata in the common format.
    pub fn metadata(&self) -> DocumentMetadata {
        DocumentMetadata {
            title: self.content.metadata.title.clone(),
            author: self.content.metadata.author.clone(),
            subject: self.content.metadata.description.clone(),
            creator: None,
        }
    }

    /// Get a read-only resource by its canonical archive path.
    pub fn resource(&self, path: &str) -> Option<EpubResource<'_>> {
        let (path, resource) = self.content.resources.get_key_value(path)?;
        Some(EpubResource {
            path,
            media_type: &resource.media_type,
            bytes: &resource.bytes,
        })
    }

    /// Iterate over resources admitted from the EPUB manifest.
    pub fn resources(&self) -> impl Iterator<Item = EpubResource<'_>> {
        self.content
            .resources
            .iter()
            .map(|(path, resource)| EpubResource {
                path,
                media_type: &resource.media_type,
                bytes: &resource.bytes,
            })
    }

    /// Get the table of contents.
    pub fn toc(&self) -> &[TocEntry] {
        &self.content.toc
    }
}

// ---------------------------------------------------------------------------
// Internal parsing functions
// ---------------------------------------------------------------------------

/// Read a file from the ZIP archive as a UTF-8 string.
fn read_archive_entry(
    archive: &mut ZipArchive<Cursor<Vec<u8>>>,
    name: &str,
    limits: &EpubLimits,
) -> Result<String> {
    let bytes = read_archive_bytes_bounded(
        archive,
        name,
        limits.max_xml_bytes.min(limits.max_entry_bytes),
    )?;
    let text = String::from_utf8(bytes)
        .with_context(|| format!("archive entry is not UTF-8 XML: {name}"))?;
    validate_xml_shape(&text, name, limits)?;
    Ok(text)
}

/// Read a file from the ZIP archive as raw bytes.
fn read_archive_bytes_bounded(
    archive: &mut ZipArchive<Cursor<Vec<u8>>>,
    name: &str,
    max_bytes: u64,
) -> Result<Vec<u8>> {
    let file = archive
        .by_name(name)
        .with_context(|| format!("entry not found in archive: {name}"))?;
    if file.size() > max_bytes {
        anyhow::bail!(
            "EPUB archive entry exceeds byte limit: {name} ({} > {max_bytes})",
            file.size()
        );
    }
    let capacity = usize::try_from(file.size())
        .unwrap_or(usize::MAX)
        .min(usize::try_from(max_bytes).unwrap_or(usize::MAX));
    let mut buf = Vec::with_capacity(capacity);
    file.take(max_bytes.saturating_add(1))
        .read_to_end(&mut buf)
        .with_context(|| format!("failed to read archive entry: {name}"))?;
    if buf.len() as u64 > max_bytes {
        anyhow::bail!(
            "EPUB archive entry exceeds byte limit while reading: {name} ({} > {max_bytes})",
            buf.len()
        );
    }
    Ok(buf)
}

fn validate_input_size(bytes: u64, limits: &EpubLimits) -> Result<()> {
    if bytes > limits.max_input_bytes {
        anyhow::bail!(
            "EPUB input exceeds archive byte limit: {bytes} > {}",
            limits.max_input_bytes
        );
    }
    Ok(())
}

fn validate_archive_entries<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    declared_entries: usize,
    limits: &EpubLimits,
    encoded_archive: &[u8],
) -> Result<()> {
    if archive.len() != declared_entries {
        anyhow::bail!("duplicate EPUB archive entry");
    }
    let mut local_header_starts = Vec::with_capacity(archive.len());
    let mut central_directory_start = u64::MAX;
    for index in 0..archive.len() {
        let file = archive
            .by_index(index)
            .context("failed to inspect EPUB archive structure")?;
        local_header_starts.push(file.header_start());
        central_directory_start = central_directory_start.min(file.central_header_start());
    }
    local_header_starts.sort_unstable();
    if local_header_starts
        .windows(2)
        .any(|pair| pair[0] == pair[1])
    {
        anyhow::bail!("duplicate EPUB archive local header offset");
    }

    let mut paths = HashSet::new();
    let mut total_uncompressed = 0_u64;
    let mut size_mismatch = None;
    for index in 0..archive.len() {
        let mut file = archive
            .by_index(index)
            .context("failed to inspect EPUB archive entry")?;
        let is_directory = file.is_dir();
        let canonical_name = file.name().trim_end_matches('/');
        let path = CanonicalEpubPath::new(canonical_name)
            .with_context(|| format!("unsafe EPUB archive entry: {}", file.name()))?;
        if !paths.insert(path) {
            anyhow::bail!("duplicate EPUB archive entry: {}", file.name());
        }
        if file.size() > limits.max_entry_bytes {
            anyhow::bail!(
                "EPUB archive entry exceeds byte limit: {} ({} > {})",
                file.name(),
                file.size(),
                limits.max_entry_bytes
            );
        }
        if is_xml_archive_path(file.name()) && file.size() > limits.max_xml_bytes {
            anyhow::bail!(
                "EPUB XML entry exceeds byte limit: {} ({} > {})",
                file.name(),
                file.size(),
                limits.max_xml_bytes
            );
        }
        let name = file.name().to_string();
        let header_start = file.header_start();
        let data_start = file
            .data_start()
            .with_context(|| format!("EPUB archive entry has no data offset: {name}"))?;
        let declared_size = file.size();
        let compressed_size = file.compressed_size();
        let compression = file.compression();
        let next_boundary = local_header_starts
            .iter()
            .copied()
            .find(|&start| start > header_start)
            .unwrap_or(central_directory_start);
        let compressed_end = data_start
            .checked_add(compressed_size)
            .context("EPUB compressed entry extent overflowed")?;
        if data_start < header_start || compressed_end > next_boundary {
            anyhow::bail!(
                "EPUB archive entry compressed extent overlaps another ZIP record: {name} ({data_start}..{compressed_end}, boundary {next_boundary})"
            );
        }
        let mut actual_size = 0_u64;
        let mut buffer = [0_u8; 8192];
        loop {
            let read = file
                .read(&mut buffer)
                .with_context(|| format!("failed to validate EPUB archive entry: {name}"))?;
            if read == 0 {
                break;
            }
            actual_size = actual_size
                .checked_add(read as u64)
                .context("EPUB entry uncompressed byte count overflowed")?;
            if actual_size > limits.max_entry_bytes {
                anyhow::bail!(
                    "EPUB archive entry exceeds byte limit: {name} ({actual_size} > {})",
                    limits.max_entry_bytes
                );
            }
            if is_xml_archive_path(&name) && actual_size > limits.max_xml_bytes {
                anyhow::bail!(
                    "EPUB XML entry exceeds byte limit: {name} ({actual_size} > {})",
                    limits.max_xml_bytes
                );
            }
            total_uncompressed = total_uncompressed
                .checked_add(read as u64)
                .context("EPUB aggregate uncompressed byte count overflowed")?;
            if total_uncompressed > limits.max_total_uncompressed_bytes {
                anyhow::bail!(
                    "EPUB archive exceeds aggregate uncompressed byte limit: {total_uncompressed} > {}",
                    limits.max_total_uncompressed_bytes
                );
            }
            if actual_size >= limits.compression_ratio_min_bytes
                && (compressed_size == 0
                    || actual_size > compressed_size.saturating_mul(limits.max_compression_ratio))
            {
                anyhow::bail!(
                    "EPUB archive entry exceeds compression ratio limit: {name} ({compressed_size} compressed, {actual_size} uncompressed, max {}:1)",
                    limits.max_compression_ratio
                );
            }
        }
        if is_directory && actual_size != 0 {
            anyhow::bail!(
                "EPUB archive directory entry contains data: {name} ({actual_size} bytes)"
            );
        }
        if compression == zip::CompressionMethod::Deflated {
            let compressed_start =
                usize::try_from(data_start).context("EPUB compressed entry offset is too large")?;
            let compressed_end = usize::try_from(compressed_end)
                .context("EPUB compressed entry end is too large")?;
            let compressed = encoded_archive
                .get(compressed_start..compressed_end)
                .context("EPUB compressed entry extent is outside the archive")?;
            let mut decoder = flate2::bufread::DeflateDecoder::new(compressed);
            let decoded_size = std::io::copy(&mut decoder, &mut std::io::sink())
                .with_context(|| format!("failed to inspect EPUB deflate stream: {name}"))?;
            let consumed = decoder.total_in();
            if consumed != compressed_size || decoded_size != actual_size {
                anyhow::bail!(
                    "EPUB compressed size does not match deflate stream: {name} ({consumed} != {compressed_size})"
                );
            }
        }
        if actual_size != declared_size {
            size_mismatch.get_or_insert((name, actual_size, declared_size));
        }
    }
    if let Some((name, actual_size, declared_size)) = size_mismatch {
        anyhow::bail!(
            "EPUB archive entry size does not match central directory: {name} ({actual_size} != {declared_size})"
        );
    }
    Ok(())
}

fn declared_archive_entry_count(data: &[u8], configured_max: usize) -> Result<usize> {
    const EOCD_SIGNATURE: &[u8] = b"PK\x05\x06";
    const ZIP64_LOCATOR_SIGNATURE: &[u8] = b"PK\x06\x07";
    const ZIP64_EOCD_SIGNATURE: &[u8] = b"PK\x06\x06";

    let search_start = data.len().saturating_sub(65_557);
    let eocd_offset = (search_start..data.len().saturating_sub(21))
        .rev()
        .find(|&offset| {
            get_bytes(data, offset, 4) == Some(EOCD_SIGNATURE)
                && offset
                    .checked_add(20)
                    .and_then(|comment_offset| read_u16(data, comment_offset))
                    .and_then(|length| offset.checked_add(22 + usize::from(length)))
                    .is_some_and(|end| end == data.len())
        })
        .context("EPUB ZIP end-of-central-directory record is missing")?;
    let entries_offset = eocd_offset
        .checked_add(10)
        .context("invalid EPUB ZIP footer")?;
    let entries = read_u16(data, entries_offset).context("invalid EPUB ZIP footer")?;
    if entries != u16::MAX {
        return bounded_archive_entry_count(u64::from(entries), configured_max);
    }

    let locator_offset = eocd_offset
        .checked_sub(20)
        .filter(|&offset| get_bytes(data, offset, 4) == Some(ZIP64_LOCATOR_SIGNATURE))
        .context("EPUB ZIP64 locator is missing")?;
    let zip64_pointer_offset = locator_offset
        .checked_add(8)
        .context("invalid EPUB ZIP64 locator")?;
    let zip64_offset = usize::try_from(
        read_u64(data, zip64_pointer_offset).context("invalid EPUB ZIP64 locator")?,
    )
    .context("EPUB ZIP64 directory offset is too large")?;
    if get_bytes(data, zip64_offset, 4) != Some(ZIP64_EOCD_SIGNATURE) {
        anyhow::bail!("EPUB ZIP64 end-of-central-directory record is missing");
    }
    let entry_count_offset = zip64_offset
        .checked_add(32)
        .context("invalid EPUB ZIP64 footer")?;
    bounded_archive_entry_count(
        read_u64(data, entry_count_offset).context("invalid EPUB ZIP64 footer")?,
        configured_max,
    )
}

fn bounded_archive_entry_count(entries: u64, configured_max: usize) -> Result<usize> {
    let max_entries = configured_max.min(MAX_ARCHIVE_ENTRIES);
    if entries > max_entries as u64 {
        anyhow::bail!("EPUB archive has too many entries: {entries}");
    }
    usize::try_from(entries).context("EPUB ZIP64 entry count is too large")
}

fn is_xml_archive_path(path: &str) -> bool {
    let extension = path.rsplit_once('.').map(|(_, extension)| extension);
    extension.is_some_and(|extension| {
        matches!(
            extension.to_ascii_lowercase().as_str(),
            "xml" | "opf" | "ncx" | "xhtml" | "html" | "svg"
        )
    })
}

fn read_u16(data: &[u8], offset: usize) -> Option<u16> {
    get_bytes(data, offset, 2)
        .and_then(|bytes| bytes.try_into().ok())
        .map(u16::from_le_bytes)
}

fn read_u64(data: &[u8], offset: usize) -> Option<u64> {
    get_bytes(data, offset, 8)
        .and_then(|bytes| bytes.try_into().ok())
        .map(u64::from_le_bytes)
}

fn get_bytes(data: &[u8], offset: usize, length: usize) -> Option<&[u8]> {
    data.get(offset..offset.checked_add(length)?)
}

/// Parse META-INF/container.xml to find the OPF file path.
fn parse_container(
    archive: &mut ZipArchive<Cursor<Vec<u8>>>,
    limits: &EpubLimits,
) -> Result<String> {
    let xml = read_archive_entry(archive, "META-INF/container.xml", limits)
        .context("EPUB missing META-INF/container.xml")?;

    let doc = roxmltree::Document::parse(&xml).context("failed to parse container.xml")?;

    // Find <rootfile full-path="..."/>
    let rootfile = doc
        .descendants()
        .find(|n| n.has_tag_name("rootfile"))
        .context("container.xml missing <rootfile> element")?;

    let full_path = rootfile
        .attribute("full-path")
        .context("rootfile missing full-path attribute")?;

    Ok(CanonicalEpubPath::resolve("", full_path)?
        .path
        .as_str()
        .to_string())
}

/// Parse the OPF file, returning metadata, manifest items, and spine item IDs.
fn parse_opf(
    xml: &str,
    opf_dir: &str,
) -> Result<(EpubMetadata, HashMap<String, ManifestItem>, Vec<String>)> {
    let doc = roxmltree::Document::parse(xml).context("failed to parse OPF file")?;

    // -- Metadata --
    let mut metadata = EpubMetadata::default();

    for node in doc.descendants() {
        if node.is_element() {
            match node.tag_name().name() {
                "title" => {
                    if metadata.title.is_none() {
                        metadata.title = node.text().map(|s| s.trim().to_string());
                    }
                }
                "creator" => {
                    if metadata.author.is_none() {
                        metadata.author = node.text().map(|s| s.trim().to_string());
                    }
                }
                "language" => {
                    if metadata.language.is_none() {
                        metadata.language = node.text().map(|s| s.trim().to_string());
                    }
                }
                "publisher" => {
                    if metadata.publisher.is_none() {
                        metadata.publisher = node.text().map(|s| s.trim().to_string());
                    }
                }
                "description" => {
                    if metadata.description.is_none() {
                        metadata.description = node.text().map(|s| s.trim().to_string());
                    }
                }
                "meta" => {
                    // <meta name="cover" content="cover-image-id"/>
                    if node.attribute("name") == Some("cover") {
                        metadata.cover_image_id = node.attribute("content").map(|s| s.to_string());
                    }
                }
                _ => {}
            }
        }
    }

    // -- Manifest --
    let mut manifest = HashMap::new();
    let mut manifest_paths = HashMap::new();

    for node in doc.descendants() {
        if node.is_element()
            && node.tag_name().name() == "item"
            && let (Some(id), Some(href), Some(media_type)) = (
                node.attribute("id"),
                node.attribute("href"),
                node.attribute("media-type"),
            )
        {
            let full_href = resolve_manifest_path(opf_dir, href)?;
            if let Some(existing_id) = manifest_paths.insert(full_href.clone(), id.to_string()) {
                anyhow::bail!(
                    "manifest items {existing_id} and {id} resolve to the same EPUB path: {full_href}"
                );
            }
            manifest.insert(
                id.to_string(),
                ManifestItem {
                    id: id.to_string(),
                    href: full_href,
                    media_type: media_type.to_string(),
                },
            );
        }
    }

    // -- Spine --
    let mut spine_ids = Vec::new();

    // Find the <spine> element
    if let Some(spine_el) = doc.descendants().find(|n| n.tag_name().name() == "spine") {
        for child in spine_el.children() {
            if child.is_element()
                && child.tag_name().name() == "itemref"
                && let Some(idref) = child.attribute("idref")
            {
                spine_ids.push(idref.to_string());
            }
        }
    }

    Ok((metadata, manifest, spine_ids))
}

/// Try to parse the table of contents (NCX or EPUB3 nav).
fn parse_toc(
    archive: &mut ZipArchive<Cursor<Vec<u8>>>,
    manifest: &HashMap<String, ManifestItem>,
    opf_dir: &str,
    limits: &EpubLimits,
) -> Result<Vec<TocEntry>> {
    // Try NCX first (EPUB 2).
    if let Some(ncx_item) = manifest
        .values()
        .find(|item| item.media_type == "application/x-dtbncx+xml")
    {
        let exists = archive.by_name(&ncx_item.href).is_ok();
        if exists {
            let xml = read_archive_entry(archive, &ncx_item.href, limits)?;
            if let Ok(entries) = parse_ncx_toc(&xml, opf_dir) {
                return Ok(entries);
            }
        }
    }

    // Try EPUB 3 nav document.
    if let Some(nav_item) = manifest
        .values()
        .find(|item| item.media_type == "application/xhtml+xml" && item.id.contains("nav"))
    {
        let exists = archive.by_name(&nav_item.href).is_ok();
        if exists {
            let xml = read_archive_entry(archive, &nav_item.href, limits)?;
            if let Ok(entries) = parse_nav_toc(&xml, opf_dir) {
                return Ok(entries);
            }
        }
    }

    Ok(Vec::new())
}

/// Parse an NCX (EPUB 2) table of contents.
fn parse_ncx_toc(xml: &str, opf_dir: &str) -> Result<Vec<TocEntry>> {
    let doc = roxmltree::Document::parse(xml).context("failed to parse NCX")?;

    fn parse_navpoints(parent: roxmltree::Node, opf_dir: &str) -> Result<Vec<TocEntry>> {
        let mut entries = Vec::new();
        for child in parent.children() {
            if child.is_element() && child.tag_name().name() == "navPoint" {
                let title = child
                    .descendants()
                    .find(|n| n.tag_name().name() == "text")
                    .and_then(|n| n.text())
                    .unwrap_or("")
                    .trim()
                    .to_string();

                let href = child
                    .descendants()
                    .find(|n| n.tag_name().name() == "content")
                    .and_then(|n| n.attribute("src"))
                    .map(|source| resolve_path(opf_dir, source))
                    .transpose()?
                    .unwrap_or_default();

                let children = parse_navpoints(child, opf_dir)?;

                entries.push(TocEntry {
                    title,
                    href,
                    children,
                });
            }
        }
        Ok(entries)
    }

    // Find <navMap>
    let nav_map = doc
        .descendants()
        .find(|n| n.tag_name().name() == "navMap")
        .context("NCX missing <navMap>")?;

    parse_navpoints(nav_map, opf_dir)
}

/// Parse an EPUB 3 nav document table of contents.
fn parse_nav_toc(xml: &str, opf_dir: &str) -> Result<Vec<TocEntry>> {
    let doc = roxmltree::Document::parse(xml).context("failed to parse nav document")?;

    // Find <nav epub:type="toc"> or just <nav>
    let nav = doc
        .descendants()
        .find(|n| n.tag_name().name() == "nav")
        .context("nav document missing <nav> element")?;

    // Find the <ol> inside
    let ol = nav
        .descendants()
        .find(|n| n.tag_name().name() == "ol")
        .context("nav missing <ol>")?;

    parse_nav_ol(ol, opf_dir)
}

fn parse_nav_ol(ol: roxmltree::Node, opf_dir: &str) -> Result<Vec<TocEntry>> {
    let mut entries = Vec::new();
    for li in ol.children() {
        if !li.is_element() || li.tag_name().name() != "li" {
            continue;
        }

        let (title, href) = if let Some(a) = li
            .children()
            .find(|n| n.is_element() && n.tag_name().name() == "a")
        {
            let title = a.text().unwrap_or("").trim().to_string();
            let href = a
                .attribute("href")
                .map(|source| resolve_path(opf_dir, source))
                .transpose()?
                .unwrap_or_default();
            (title, href)
        } else {
            continue;
        };

        let children = li
            .children()
            .find(|n| n.is_element() && n.tag_name().name() == "ol")
            .map(|ol| parse_nav_ol(ol, opf_dir))
            .transpose()?
            .unwrap_or_default();

        entries.push(TocEntry {
            title,
            href,
            children,
        });
    }
    Ok(entries)
}

/// Load chapters in spine order, assigning titles from the TOC where possible.
fn load_chapters(
    archive: &mut ZipArchive<Cursor<Vec<u8>>>,
    spine_ids: &[String],
    manifest: &HashMap<String, ManifestItem>,
    toc: &[TocEntry],
    limits: &EpubLimits,
) -> Result<Vec<Chapter>> {
    // Build a map from (path without fragment) -> TOC title for quick lookup.
    let mut toc_titles: HashMap<String, String> = HashMap::new();
    fn collect_titles(entries: &[TocEntry], map: &mut HashMap<String, String>) {
        for entry in entries {
            let path = entry.href.split('#').next().unwrap_or("").to_string();
            if !path.is_empty() {
                map.entry(path).or_insert_with(|| entry.title.clone());
            }
            collect_titles(&entry.children, map);
        }
    }
    collect_titles(toc, &mut toc_titles);

    let mut chapters = Vec::new();

    for (index, id) in spine_ids.iter().enumerate() {
        let item = manifest
            .get(id)
            .with_context(|| format!("spine references unknown manifest id: {id}"))?;

        // Only load XHTML content documents.
        if item.media_type != "application/xhtml+xml" {
            continue;
        }

        let content = read_archive_entry(archive, &item.href, limits)
            .with_context(|| format!("failed to read chapter: {}", item.href))?;

        let title = toc_titles.get(&item.href).cloned();

        chapters.push(Chapter {
            index,
            title,
            path: item.href.clone(),
            content,
        });
    }

    Ok(chapters)
}

/// Load binary resources, plus non-spine content documents requested by a spike.
fn load_resources(
    archive: &mut ZipArchive<Cursor<Vec<u8>>>,
    manifest: &HashMap<String, ManifestItem>,
    chapter_paths: &HashSet<&str>,
    include_non_spine_content: bool,
    limits: &EpubLimits,
) -> Result<HashMap<CanonicalEpubPath, StoredEpubResource>> {
    let mut resources = HashMap::new();

    for item in manifest.values() {
        let is_content_document = matches!(
            item.media_type.as_str(),
            "application/xhtml+xml" | "application/x-dtbncx+xml"
        );
        if is_content_document
            && (!include_non_spine_content || chapter_paths.contains(item.href.as_str()))
        {
            continue;
        }

        // Missing resources retain the existing deterministic fallback. Present resources that
        // violate admission limits fail with their canonical path before backend allocation.
        let declared_size = match archive.by_name(&item.href) {
            Ok(file) => file.size(),
            Err(_) => continue,
        };
        validate_declared_resource_size(&item.href, &item.media_type, declared_size, limits)?;
        let data = read_archive_bytes_bounded(
            archive,
            &item.href,
            resource_read_limit(&item.media_type, limits),
        )?;
        validate_resource(&item.href, &item.media_type, &data, limits)?;
        resources.insert(
            CanonicalEpubPath::new(&item.href)?,
            StoredEpubResource {
                media_type: item.media_type.clone(),
                bytes: data,
            },
        );
    }

    Ok(resources)
}

/// Resolve a relative path against the OPF directory.
fn resolve_path(opf_dir: &str, href: &str) -> Result<String> {
    let reference = CanonicalEpubPath::resolve(opf_dir, href)?;
    let mut resolved = reference.path.as_str().to_string();
    if let Some(fragment) = reference.fragment {
        resolved.push('#');
        resolved.push_str(&fragment);
    }
    Ok(resolved)
}

fn resolve_manifest_path(opf_dir: &str, href: &str) -> Result<String> {
    let reference = CanonicalEpubPath::resolve(opf_dir, href)?;
    if reference.fragment.is_some() {
        anyhow::bail!("EPUB manifest href must not contain a fragment: {href}");
    }
    Ok(reference.path.as_str().to_string())
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};

    use zip::CompressionMethod;
    use zip::ZipWriter;
    use zip::write::SimpleFileOptions;

    use super::EpubDoc;
    use super::EpubLimits;
    use super::declared_archive_entry_count;
    use super::parse_opf;

    fn archive_with_entries(names: &[&str]) -> Vec<u8> {
        let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
        for name in names {
            archive
                .start_file(name, SimpleFileOptions::default())
                .unwrap();
            archive.write_all(b"content").unwrap();
        }
        archive.finish().unwrap().into_inner()
    }

    fn archive_with_payloads(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        for (name, bytes) in entries {
            archive.start_file(*name, options).unwrap();
            archive.write_all(bytes).unwrap();
        }
        archive.finish().unwrap().into_inner()
    }

    fn forge_declared_uncompressed_size(archive: &mut [u8], forged_size: u32) {
        for (signature, size_offset) in [(b"PK\x03\x04".as_slice(), 22), (b"PK\x01\x02", 24)] {
            let offsets = archive
                .windows(signature.len())
                .enumerate()
                .filter_map(|(offset, bytes)| (bytes == signature).then_some(offset + size_offset))
                .collect::<Vec<_>>();
            assert!(!offsets.is_empty(), "ZIP record signature is missing");
            for offset in offsets {
                archive[offset..offset + 4].copy_from_slice(&forged_size.to_le_bytes());
            }
        }
    }

    fn forge_declared_compressed_size(archive: &mut [u8], forged_size: u32) {
        for (signature, size_offset) in [(b"PK\x03\x04".as_slice(), 18), (b"PK\x01\x02", 20)] {
            let offsets = archive
                .windows(signature.len())
                .enumerate()
                .filter_map(|(offset, bytes)| (bytes == signature).then_some(offset + size_offset))
                .collect::<Vec<_>>();
            assert!(!offsets.is_empty(), "ZIP record signature is missing");
            for offset in offsets {
                archive[offset..offset + 4].copy_from_slice(&forged_size.to_le_bytes());
            }
        }
    }

    fn pad_deflate_stream_before_central_directory(archive: &mut Vec<u8>, padding: usize) {
        let central_offset = archive
            .windows(4)
            .position(|bytes| bytes == b"PK\x01\x02")
            .expect("central directory is missing");
        let compressed_size = u32::from_le_bytes(
            archive[central_offset + 20..central_offset + 24]
                .try_into()
                .unwrap(),
        );
        archive.splice(
            central_offset..central_offset,
            std::iter::repeat_n(0, padding),
        );
        let new_central_offset = central_offset + padding;
        let eocd_offset = archive
            .windows(4)
            .rposition(|bytes| bytes == b"PK\x05\x06")
            .expect("end of central directory is missing");
        archive[eocd_offset + 16..eocd_offset + 20]
            .copy_from_slice(&(new_central_offset as u32).to_le_bytes());
        forge_declared_compressed_size(archive, compressed_size + padding as u32);
    }

    fn zip64_footer(entry_count: u64) -> Vec<u8> {
        let mut archive = Vec::new();
        archive.extend_from_slice(b"PK\x06\x06");
        archive.extend_from_slice(&44_u64.to_le_bytes());
        archive.extend_from_slice(&45_u16.to_le_bytes());
        archive.extend_from_slice(&45_u16.to_le_bytes());
        archive.extend_from_slice(&0_u32.to_le_bytes());
        archive.extend_from_slice(&0_u32.to_le_bytes());
        archive.extend_from_slice(&entry_count.to_le_bytes());
        archive.extend_from_slice(&entry_count.to_le_bytes());
        archive.extend_from_slice(&0_u64.to_le_bytes());
        archive.extend_from_slice(&0_u64.to_le_bytes());
        archive.extend_from_slice(b"PK\x06\x07");
        archive.extend_from_slice(&0_u32.to_le_bytes());
        archive.extend_from_slice(&0_u64.to_le_bytes());
        archive.extend_from_slice(&1_u32.to_le_bytes());
        archive.extend_from_slice(b"PK\x05\x06");
        archive.extend_from_slice(&0_u16.to_le_bytes());
        archive.extend_from_slice(&0_u16.to_le_bytes());
        archive.extend_from_slice(&u16::MAX.to_le_bytes());
        archive.extend_from_slice(&u16::MAX.to_le_bytes());
        archive.extend_from_slice(&u32::MAX.to_le_bytes());
        archive.extend_from_slice(&u32::MAX.to_le_bytes());
        archive.extend_from_slice(&0_u16.to_le_bytes());
        archive
    }

    #[test]
    fn epub_rejects_zip64_entry_counts_above_the_archive_limit() {
        let error =
            declared_archive_entry_count(&zip64_footer(u64::from(u16::MAX) + 1), usize::MAX)
                .expect_err("oversized ZIP64 entry count must fail before ZIP parsing");

        assert!(
            error.to_string().contains("too many entries"),
            "unexpected error: {error:#}"
        );
    }

    #[test]
    fn actual_zip_output_enforces_entry_aggregate_and_ratio_limits() {
        let payload = vec![b'a'; 4096];

        for (entries, limits, expected) in [
            (
                vec![("payload.bin", payload.as_slice())],
                EpubLimits {
                    max_entry_bytes: 1024,
                    compression_ratio_min_bytes: u64::MAX,
                    ..EpubLimits::default()
                },
                "entry exceeds byte limit",
            ),
            (
                vec![
                    ("first.bin", payload[..800].as_ref()),
                    ("second.bin", payload[..800].as_ref()),
                ],
                EpubLimits {
                    max_entry_bytes: 1024,
                    max_total_uncompressed_bytes: 1200,
                    compression_ratio_min_bytes: u64::MAX,
                    ..EpubLimits::default()
                },
                "aggregate uncompressed byte limit",
            ),
            (
                vec![("payload.bin", payload.as_slice())],
                EpubLimits {
                    max_compression_ratio: 2,
                    compression_ratio_min_bytes: 100,
                    ..EpubLimits::default()
                },
                "compression ratio limit",
            ),
        ] {
            let mut archive = archive_with_payloads(&entries);
            forge_declared_uncompressed_size(&mut archive, 1);

            let error = EpubDoc::from_bytes_with_limits(archive, limits)
                .expect_err("actual decompressed output must enforce archive limits");

            assert!(
                error.to_string().contains(expected),
                "expected {expected:?}, got {error:#}"
            );
        }
    }

    #[test]
    fn directory_payloads_and_forged_compressed_extents_cannot_bypass_limits() {
        let payload = vec![b'a'; 4096];
        let limits = EpubLimits {
            max_entry_bytes: 1024,
            compression_ratio_min_bytes: u64::MAX,
            ..EpubLimits::default()
        };
        let mut directory = archive_with_payloads(&[("bomb/", payload.as_slice())]);
        forge_declared_uncompressed_size(&mut directory, 1);
        let error = EpubDoc::from_bytes_with_limits(directory, limits)
            .expect_err("directory-named payload must enforce actual output limits");
        assert!(
            error.to_string().contains("entry exceeds byte limit"),
            "unexpected directory payload error: {error:#}"
        );

        let mut forged = archive_with_payloads(&[("payload.bin", payload.as_slice())]);
        pad_deflate_stream_before_central_directory(&mut forged, 2048);
        let ratio_limits = EpubLimits {
            max_compression_ratio: 2,
            compression_ratio_min_bytes: 100,
            ..EpubLimits::default()
        };
        let error = EpubDoc::from_bytes_with_limits(forged, ratio_limits)
            .expect_err("compressed size cannot include padding after the deflate stream");
        assert!(
            error
                .to_string()
                .contains("compressed size does not match deflate stream"),
            "unexpected compressed extent error: {error:#}"
        );
    }

    #[test]
    fn production_resources_do_not_duplicate_content_documents() {
        let epub = EpubDoc::from_bytes(include_bytes!("../../tests/fixtures/sample.epub").to_vec())
            .unwrap();

        for item in epub.content.manifest.values().filter(|item| {
            matches!(
                item.media_type.as_str(),
                "application/xhtml+xml" | "application/x-dtbncx+xml"
            )
        }) {
            assert!(
                !epub.content.resources.contains_key(item.href.as_str()),
                "content document duplicated in resources: {}",
                item.href
            );
        }
    }

    #[test]
    fn epub_rejects_noncanonical_archive_entries_before_lookup() {
        let error = EpubDoc::from_bytes(archive_with_entries(&[
            "META-INF/container.xml",
            "OEBPS/../chapter.xhtml",
        ]))
        .unwrap_err();

        assert!(error.to_string().contains("unsafe EPUB archive entry"));
    }

    #[test]
    fn epub_rejects_duplicate_archive_entries_before_lookup() {
        let mut archive = archive_with_entries(&[
            "META-INF/container.xml",
            "OEBPS/chapter1.xhtml",
            "OEBPS/chapter2.xhtml",
        ]);
        let old_name = b"OEBPS/chapter2.xhtml";
        let new_name = b"OEBPS/chapter1.xhtml";
        let offsets = archive
            .windows(old_name.len())
            .enumerate()
            .filter_map(|(offset, bytes)| (bytes == old_name).then_some(offset))
            .collect::<Vec<_>>();
        assert_eq!(offsets.len(), 2, "expected local and central ZIP names");
        for offset in offsets {
            archive[offset..offset + new_name.len()].copy_from_slice(new_name);
        }

        let error = EpubDoc::from_bytes(archive).unwrap_err();

        assert!(
            error.to_string().contains("duplicate EPUB archive entry"),
            "unexpected error: {error:#}"
        );
    }

    #[test]
    fn epub_rejects_fragment_aliases_in_the_manifest() {
        let opf = r#"<package xmlns="http://www.idpf.org/2007/opf">
            <manifest>
                <item id="one" href="chapter.xhtml#one" media-type="application/xhtml+xml"/>
                <item id="two" href="./chapter.xhtml#two" media-type="application/xhtml+xml"/>
            </manifest>
            <spine/>
        </package>"#;

        let error = parse_opf(opf, "OEBPS").unwrap_err();

        assert!(
            error.to_string().contains("must not contain a fragment"),
            "unexpected error: {error:#}"
        );
    }

    #[test]
    fn epub_rejects_overflowing_zip64_offsets_without_panicking() {
        let mut archive = Vec::new();
        archive.extend_from_slice(b"PK\x06\x07");
        archive.extend_from_slice(&0_u32.to_le_bytes());
        archive.extend_from_slice(&u64::MAX.to_le_bytes());
        archive.extend_from_slice(&1_u32.to_le_bytes());
        archive.extend_from_slice(b"PK\x05\x06");
        archive.extend_from_slice(&0_u16.to_le_bytes());
        archive.extend_from_slice(&0_u16.to_le_bytes());
        archive.extend_from_slice(&u16::MAX.to_le_bytes());
        archive.extend_from_slice(&u16::MAX.to_le_bytes());
        archive.extend_from_slice(&0_u32.to_le_bytes());
        archive.extend_from_slice(&0_u32.to_le_bytes());
        archive.extend_from_slice(&0_u16.to_le_bytes());

        assert!(EpubDoc::from_bytes(archive).is_err());
    }
}
