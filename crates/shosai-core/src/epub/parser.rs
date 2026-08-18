//! EPUB parsing: ZIP extraction, container.xml, OPF, and content loading.

use std::collections::{HashMap, HashSet};
use std::io::{Cursor, Read};
use std::path::Path;

use anyhow::{Context, Result};
use zip::ZipArchive;

use super::CanonicalEpubPath;
use super::types::*;
use crate::document::DocumentMetadata;

const MAX_ARCHIVE_ENTRIES: usize = u16::MAX as usize;

/// A parsed EPUB document.
#[derive(Debug)]
pub struct EpubDoc {
    pub content: EpubContent,
}

impl EpubDoc {
    /// Open an EPUB file from disk.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let data =
            std::fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
        Self::from_bytes(data)
    }

    /// Open an EPUB from raw bytes.
    pub fn from_bytes(data: Vec<u8>) -> Result<Self> {
        Self::from_bytes_inner(data, false)
    }

    /// Open an EPUB while retaining non-spine content documents for the renderer spike.
    #[doc(hidden)]
    pub fn from_bytes_for_renderer_spike(data: Vec<u8>) -> Result<Self> {
        Self::from_bytes_inner(data, true)
    }

    fn from_bytes_inner(data: Vec<u8>, include_non_spine_content: bool) -> Result<Self> {
        let declared_entries = declared_archive_entry_count(&data)?;
        let cursor = Cursor::new(data);
        let mut archive = ZipArchive::new(cursor).context("failed to open EPUB as ZIP archive")?;
        validate_archive_entries(&mut archive, declared_entries)?;

        // 1. Parse container.xml to find the OPF path.
        let opf_path = parse_container(&mut archive)?;

        // The OPF directory is used as a base for resolving relative paths.
        let opf_dir = opf_path
            .rsplit_once('/')
            .map_or_else(String::new, |(directory, _)| directory.to_string());

        // 2. Parse the OPF file.
        let opf_xml = read_archive_entry(&mut archive, &opf_path)
            .with_context(|| format!("failed to read OPF file: {opf_path}"))?;
        let (metadata, manifest, spine_ids) = parse_opf(&opf_xml, &opf_dir)?;

        // 3. Try to parse the TOC (NCX or nav document).
        let toc = parse_toc(&mut archive, &manifest, &opf_dir);

        // 4. Load chapters (spine items) in reading order.
        let chapters = load_chapters(&mut archive, &spine_ids, &manifest, &toc)?;

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
        )?;

        // 6. Parse CSS stylesheets into a class → style map.
        let css_sources: Vec<(&str, String)> = manifest
            .values()
            .filter(|item| item.media_type == "text/css")
            .filter_map(|item| {
                resources
                    .get(&item.href)
                    .and_then(|data| String::from_utf8(data.clone()).ok())
                    .map(|css| (item.href.as_str(), css))
            })
            .collect();

        let styles = super::style::parse_epub_styles(
            css_sources.iter().map(|(path, css)| (*path, css.as_str())),
        );

        Ok(Self {
            content: EpubContent {
                metadata,
                chapters,
                toc,
                manifest,
                resources,
                styles,
            },
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

    /// Get document metadata in the common format.
    pub fn metadata(&self) -> DocumentMetadata {
        DocumentMetadata {
            title: self.content.metadata.title.clone(),
            author: self.content.metadata.author.clone(),
            subject: self.content.metadata.description.clone(),
            creator: None,
        }
    }

    /// Get a resource (image, CSS, etc.) by its archive path.
    pub fn resource(&self, path: &str) -> Option<&[u8]> {
        self.content.resources.get(path).map(|v| v.as_slice())
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
fn read_archive_entry(archive: &mut ZipArchive<Cursor<Vec<u8>>>, name: &str) -> Result<String> {
    let mut file = archive
        .by_name(name)
        .with_context(|| format!("entry not found in archive: {name}"))?;
    let mut buf = String::new();
    file.read_to_string(&mut buf)
        .with_context(|| format!("failed to read archive entry: {name}"))?;
    Ok(buf)
}

/// Read a file from the ZIP archive as raw bytes.
fn read_archive_bytes(archive: &mut ZipArchive<Cursor<Vec<u8>>>, name: &str) -> Result<Vec<u8>> {
    let mut file = archive
        .by_name(name)
        .with_context(|| format!("entry not found in archive: {name}"))?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)
        .with_context(|| format!("failed to read archive entry: {name}"))?;
    Ok(buf)
}

fn validate_archive_entries(
    archive: &mut ZipArchive<Cursor<Vec<u8>>>,
    declared_entries: usize,
) -> Result<()> {
    if archive.len() != declared_entries {
        anyhow::bail!("duplicate EPUB archive entry");
    }
    let mut paths = HashSet::new();
    for index in 0..archive.len() {
        let file = archive
            .by_index(index)
            .context("failed to inspect EPUB archive entry")?;
        if file.is_dir() {
            continue;
        }
        let path = CanonicalEpubPath::new(file.name())
            .with_context(|| format!("unsafe EPUB archive entry: {}", file.name()))?;
        if !paths.insert(path) {
            anyhow::bail!("duplicate EPUB archive entry: {}", file.name());
        }
    }
    Ok(())
}

fn declared_archive_entry_count(data: &[u8]) -> Result<usize> {
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
        return bounded_archive_entry_count(u64::from(entries));
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
    )
}

fn bounded_archive_entry_count(entries: u64) -> Result<usize> {
    if entries > MAX_ARCHIVE_ENTRIES as u64 {
        anyhow::bail!("EPUB archive has too many entries: {entries}");
    }
    usize::try_from(entries).context("EPUB ZIP64 entry count is too large")
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
fn parse_container(archive: &mut ZipArchive<Cursor<Vec<u8>>>) -> Result<String> {
    let xml = read_archive_entry(archive, "META-INF/container.xml")
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
) -> Vec<TocEntry> {
    // Try NCX first (EPUB 2).
    if let Some(ncx_item) = manifest
        .values()
        .find(|item| item.media_type == "application/x-dtbncx+xml")
        && let Ok(xml) = read_archive_entry(archive, &ncx_item.href)
        && let Ok(entries) = parse_ncx_toc(&xml, opf_dir)
    {
        return entries;
    }

    // Try EPUB 3 nav document.
    if let Some(nav_item) = manifest
        .values()
        .find(|item| item.media_type == "application/xhtml+xml" && item.id.contains("nav"))
        && let Ok(xml) = read_archive_entry(archive, &nav_item.href)
        && let Ok(entries) = parse_nav_toc(&xml, opf_dir)
    {
        return entries;
    }

    Vec::new()
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

        let content = read_archive_entry(archive, &item.href)
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
) -> Result<HashMap<String, Vec<u8>>> {
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

        // Best effort: skip resources we can't read (e.g. missing from archive).
        if let Ok(data) = read_archive_bytes(archive, &item.href) {
            resources.insert(item.href.clone(), data);
        }
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

    use zip::ZipWriter;
    use zip::write::SimpleFileOptions;

    use super::EpubDoc;
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
        let error = declared_archive_entry_count(&zip64_footer(u64::from(u16::MAX) + 1))
            .expect_err("oversized ZIP64 entry count must fail before ZIP parsing");

        assert!(
            error.to_string().contains("too many entries"),
            "unexpected error: {error:#}"
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
                !epub.content.resources.contains_key(&item.href),
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
