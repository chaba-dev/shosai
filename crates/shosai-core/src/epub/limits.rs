//! EPUB archive and retained-resource admission limits.

use std::io::Cursor;

use anyhow::{Context, Result};
use quick_xml::Reader;
use quick_xml::events::Event;

/// Configurable limits applied before EPUB resources reach renderer backends.
#[derive(Debug, Clone, Copy)]
pub struct EpubLimits {
    /// Maximum encoded EPUB file size.
    pub max_input_bytes: u64,
    /// Maximum number of entries admitted from the ZIP central directory.
    pub max_archive_entries: usize,
    /// Maximum uncompressed-to-compressed ratio for entries above the ratio threshold.
    pub max_compression_ratio: u64,
    /// Minimum uncompressed entry size at which compression-ratio checks apply.
    pub compression_ratio_min_bytes: u64,
    /// Maximum uncompressed size of any ZIP entry.
    pub max_entry_bytes: u64,
    /// Maximum aggregate uncompressed size of all ZIP entries.
    pub max_total_uncompressed_bytes: u64,
    /// Maximum encoded size of an XML document.
    pub max_xml_bytes: u64,
    /// Maximum element nesting depth in an XML document.
    pub max_xml_depth: usize,
    /// Maximum aggregate encoded text and CDATA bytes in an XML document.
    pub max_xml_text_bytes: u64,
    /// Maximum encoded size of an individual font resource.
    pub max_font_bytes: u64,
    /// Maximum width or height reported by an admitted image.
    pub max_image_dimension: u32,
    /// Maximum pixel count reported by an admitted image.
    pub max_image_pixels: u64,
    /// Maximum estimated RGBA allocation for an admitted image.
    pub max_decoded_image_bytes: u64,
}

impl Default for EpubLimits {
    fn default() -> Self {
        const MIB: u64 = 1024 * 1024;

        Self {
            max_input_bytes: 512 * MIB,
            max_archive_entries: 10_000,
            max_compression_ratio: 100,
            compression_ratio_min_bytes: MIB,
            max_entry_bytes: 64 * MIB,
            max_total_uncompressed_bytes: 512 * MIB,
            max_xml_bytes: 8 * MIB,
            max_xml_depth: 128,
            max_xml_text_bytes: 4 * MIB,
            max_font_bytes: 16 * MIB,
            max_image_dimension: 16_384,
            max_image_pixels: 40_000_000,
            max_decoded_image_bytes: 160 * MIB,
        }
    }
}

pub(crate) fn validate_xml_shape(xml: &str, path: &str, limits: &EpubLimits) -> Result<()> {
    if xml.len() as u64 > limits.max_xml_bytes {
        anyhow::bail!(
            "EPUB XML entry exceeds byte limit: {path} ({} > {})",
            xml.len(),
            limits.max_xml_bytes
        );
    }

    let mut reader = Reader::from_str(xml);
    reader.config_mut().check_end_names = false;
    reader.config_mut().allow_unmatched_ends = true;
    let mut depth = 0_usize;
    let mut text_bytes = 0_u64;
    loop {
        match reader.read_event() {
            Ok(Event::Start(_)) => {
                depth = depth.checked_add(1).context("EPUB XML depth overflowed")?;
                if depth > limits.max_xml_depth {
                    anyhow::bail!(
                        "EPUB XML entry exceeds depth limit: {path} ({depth} > {})",
                        limits.max_xml_depth
                    );
                }
            }
            Ok(Event::Empty(_)) => {
                let empty_depth = depth.checked_add(1).context("EPUB XML depth overflowed")?;
                if empty_depth > limits.max_xml_depth {
                    anyhow::bail!(
                        "EPUB XML entry exceeds depth limit: {path} ({empty_depth} > {})",
                        limits.max_xml_depth
                    );
                }
            }
            Ok(Event::End(_)) => depth = depth.saturating_sub(1),
            Ok(Event::Text(text)) => {
                text_bytes = text_bytes
                    .checked_add(text.len() as u64)
                    .context("EPUB XML text byte count overflowed")?;
            }
            Ok(Event::CData(text)) => {
                text_bytes = text_bytes
                    .checked_add(text.len() as u64)
                    .context("EPUB XML text byte count overflowed")?;
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            // Structural mismatches remain available for renderer fallback through the tolerant
            // reader configuration. Lexically malformed XML is rejected because its unparsed
            // tail could otherwise conceal depth or text that must count toward admission.
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to inspect EPUB XML resource: {path}"));
            }
        }
        if text_bytes > limits.max_xml_text_bytes {
            anyhow::bail!(
                "EPUB XML entry exceeds text limit: {path} ({text_bytes} > {})",
                limits.max_xml_text_bytes
            );
        }
    }

    Ok(())
}

pub(crate) fn validate_resource(
    path: &str,
    media_type: &str,
    bytes: &[u8],
    limits: &EpubLimits,
) -> Result<()> {
    if is_font(media_type) && bytes.len() as u64 > limits.max_font_bytes {
        anyhow::bail!(
            "EPUB font resource exceeds byte limit: {path} ({} > {})",
            bytes.len(),
            limits.max_font_bytes
        );
    }

    if is_xml(media_type) {
        let text = std::str::from_utf8(bytes)
            .with_context(|| format!("EPUB XML resource is not UTF-8: {path}"))?;
        validate_xml_shape(text, path, limits)?;
    }

    if media_type == "image/svg+xml" {
        if let Some((width, height)) = svg_dimensions(bytes) {
            validate_image_dimensions(path, width, height, limits)?;
        }
    } else if media_type.starts_with("image/") {
        let reader = image::ImageReader::new(Cursor::new(bytes)).with_guessed_format();
        if let Ok(reader) = reader
            && let Ok((width, height)) = reader.into_dimensions()
        {
            validate_image_dimensions(path, width, height, limits)?;
        }
    }

    Ok(())
}

pub(crate) fn validate_declared_resource_size(
    path: &str,
    media_type: &str,
    bytes: u64,
    limits: &EpubLimits,
) -> Result<()> {
    if is_font(media_type) && bytes > limits.max_font_bytes {
        anyhow::bail!(
            "EPUB font resource exceeds byte limit: {path} ({bytes} > {})",
            limits.max_font_bytes
        );
    }
    if is_xml(media_type) && bytes > limits.max_xml_bytes {
        anyhow::bail!(
            "EPUB XML resource exceeds byte limit: {path} ({bytes} > {})",
            limits.max_xml_bytes
        );
    }
    Ok(())
}

pub(crate) fn resource_read_limit(media_type: &str, limits: &EpubLimits) -> u64 {
    if is_xml(media_type) {
        limits.max_xml_bytes.min(limits.max_entry_bytes)
    } else if is_font(media_type) {
        limits.max_font_bytes.min(limits.max_entry_bytes)
    } else {
        limits.max_entry_bytes
    }
}

fn validate_image_dimensions(
    path: &str,
    width: u32,
    height: u32,
    limits: &EpubLimits,
) -> Result<()> {
    if width > limits.max_image_dimension || height > limits.max_image_dimension {
        anyhow::bail!(
            "EPUB image resource exceeds dimension limit: {path} ({width}x{height}, max {})",
            limits.max_image_dimension
        );
    }
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .context("EPUB image pixel count overflowed")?;
    if pixels > limits.max_image_pixels {
        anyhow::bail!(
            "EPUB image resource exceeds pixel limit: {path} ({pixels} > {})",
            limits.max_image_pixels
        );
    }
    let decoded_bytes = pixels
        .checked_mul(4)
        .context("EPUB decoded image byte count overflowed")?;
    if decoded_bytes > limits.max_decoded_image_bytes {
        anyhow::bail!(
            "EPUB image resource exceeds decoded byte limit: {path} ({decoded_bytes} > {})",
            limits.max_decoded_image_bytes
        );
    }
    Ok(())
}

fn svg_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let xml = std::str::from_utf8(bytes).ok()?;
    let document = roxmltree::Document::parse(xml).ok()?;
    let root = document.root_element();
    let width = svg_length(root.attribute("width")?)?;
    let height = svg_length(root.attribute("height")?)?;
    Some((width, height))
}

fn svg_length(value: &str) -> Option<u32> {
    value
        .strip_suffix("px")
        .unwrap_or(value)
        .parse::<u32>()
        .ok()
}

fn is_xml(media_type: &str) -> bool {
    matches!(
        media_type,
        "application/xhtml+xml"
            | "application/x-dtbncx+xml"
            | "application/xml"
            | "text/xml"
            | "image/svg+xml"
    ) || media_type.ends_with("+xml")
}

fn is_font(media_type: &str) -> bool {
    media_type.starts_with("font/")
        || matches!(
            media_type,
            "application/font-sfnt"
                | "application/font-woff"
                | "application/vnd.ms-opentype"
                | "application/x-font-otf"
                | "application/x-font-truetype"
        )
}

#[cfg(test)]
mod tests {
    use super::{EpubLimits, validate_xml_shape};

    #[test]
    fn empty_xml_elements_count_toward_depth() {
        let limits = EpubLimits {
            max_xml_depth: 1,
            ..EpubLimits::default()
        };

        let error = validate_xml_shape("<root><leaf/></root>", "chapter.xhtml", &limits)
            .expect_err("empty child must count as a nested element");

        assert!(error.to_string().contains("depth limit"));
    }

    #[test]
    fn lexical_xml_errors_cannot_hide_uninspected_content() {
        let error = validate_xml_shape(
            "<root attribute=\"unterminated><child/></root>",
            "chapter.xhtml",
            &EpubLimits::default(),
        )
        .expect_err("lexically malformed XML must not bypass shape admission");

        assert!(
            error
                .to_string()
                .contains("failed to inspect EPUB XML resource")
        );
    }
}
