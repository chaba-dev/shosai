use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use pdfium_render::prelude::*;

use crate::document::{Document, DocumentMetadata, RenderedPage};

/// Create a short-lived Pdfium instance.
///
/// `pdfium-render`'s `thread_safe` feature serializes all PDFium access behind a
/// global mutex. The lock is acquired on `FPDF_InitLibrary` (when a `Pdfium` is
/// created) and released on `FPDF_DestroyLibrary` (when it is dropped). Creating
/// a `Pdfium`, doing work, and dropping it promptly is the intended usage pattern
/// — it keeps the lock held only as long as needed and allows other threads to
/// proceed in between.
fn create_pdfium() -> Result<Pdfium> {
    let bundled = std::env::current_exe()
        .ok()
        .and_then(|executable| bundled_pdfium_path(&executable))
        .filter(|path| path.is_file());

    let bindings = match bundled {
        Some(path) => Pdfium::bind_to_library(&path).with_context(|| {
            format!(
                "failed to load bundled PDFium library at {}",
                path.display()
            )
        }),
        None => Pdfium::bind_to_system_library().context("failed to load PDFium system library"),
    }
    .map_err(|e| {
        anyhow::anyhow!(
            "{e}. Install a Shosai package containing PDFium, or ensure \
             pdfium-binaries is available through the system library path"
        )
    })?;

    Ok(Pdfium::new(bindings))
}

fn bundled_pdfium_path(executable: &Path) -> Option<PathBuf> {
    let executable_dir = executable.parent()?;

    #[cfg(target_os = "macos")]
    {
        let contents_dir = executable_dir.parent()?;
        Some(contents_dir.join("Frameworks/libpdfium.dylib"))
    }

    #[cfg(not(target_os = "macos"))]
    {
        let package_dir = executable_dir.parent()?;
        Some(package_dir.join("lib/libpdfium.so"))
    }
}

#[cfg(test)]
mod tests {
    use super::bundled_pdfium_path;
    use std::path::{Path, PathBuf};

    #[test]
    fn bundled_pdfium_is_resolved_relative_to_executable() {
        #[cfg(target_os = "macos")]
        let expected =
            PathBuf::from("/Applications/Shosai.app/Contents/Frameworks/libpdfium.dylib");
        #[cfg(target_os = "macos")]
        let executable = Path::new("/Applications/Shosai.app/Contents/MacOS/Shosai");

        #[cfg(not(target_os = "macos"))]
        let expected = PathBuf::from("/opt/shosai/lib/libpdfium.so");
        #[cfg(not(target_os = "macos"))]
        let executable = Path::new("/opt/shosai/bin/shosai");

        assert_eq!(bundled_pdfium_path(executable), Some(expected));
    }
}

/// A PDF document backed by pdfium-render.
#[derive(Debug)]
pub struct PdfDoc {
    page_count: usize,
    page_sizes: Vec<(f32, f32)>,
    metadata: DocumentMetadata,
    /// Raw PDF bytes, kept for re-opening during render calls.
    data: Vec<u8>,
}

impl PdfDoc {
    /// Open a PDF file from disk.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let data =
            std::fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
        Self::from_bytes(data)
    }

    /// Open a PDF from raw bytes.
    pub fn from_bytes(data: Vec<u8>) -> Result<Self> {
        let pdfium = create_pdfium()?;
        let document = pdfium
            .load_pdf_from_byte_slice(&data, None)
            .map_err(|e| anyhow::anyhow!("failed to load PDF: {e}"))?;

        let page_count = document.pages().len() as usize;

        let mut page_sizes = Vec::with_capacity(page_count);
        for i in 0..page_count {
            let page = document
                .pages()
                .get(i as u16)
                .map_err(|e| anyhow::anyhow!("failed to get page {i}: {e}"))?;
            let w = page.width().value;
            let h = page.height().value;
            page_sizes.push((w, h));
        }

        let meta = document.metadata();
        let metadata = DocumentMetadata {
            title: meta
                .get(PdfDocumentMetadataTagType::Title)
                .map(|t| t.value().to_string()),
            author: meta
                .get(PdfDocumentMetadataTagType::Author)
                .map(|t| t.value().to_string()),
            subject: meta
                .get(PdfDocumentMetadataTagType::Subject)
                .map(|t| t.value().to_string()),
            creator: meta
                .get(PdfDocumentMetadataTagType::Creator)
                .map(|t| t.value().to_string()),
        };

        // Explicitly drop document and pdfium before moving `data` into the struct.
        // This releases the borrow on `data` and the global PDFium mutex lock.
        drop(document);
        drop(pdfium);

        Ok(Self {
            page_count,
            page_sizes,
            metadata,
            data,
        })
    }
}

impl PdfDoc {
    /// Extract all text from a single page.
    pub fn page_text(&self, index: usize) -> Result<String> {
        if index >= self.page_count {
            anyhow::bail!(
                "page index {index} out of range (total: {})",
                self.page_count
            );
        }

        let pdfium = create_pdfium()?;
        let document = pdfium
            .load_pdf_from_byte_slice(&self.data, None)
            .map_err(|e| anyhow::anyhow!("failed to load PDF for text extraction: {e}"))?;

        let page = document
            .pages()
            .get(index as u16)
            .map_err(|e| anyhow::anyhow!("failed to get page {index}: {e}"))?;

        let text = page
            .text()
            .map_err(|e| anyhow::anyhow!("failed to load text for page {index}: {e}"))?;

        Ok(searchable_page_text(&page, &text))
    }

    /// Extract text from every page while loading the PDF only once.
    pub fn page_texts(&self) -> Result<Vec<String>> {
        let pdfium = create_pdfium()?;
        let document = pdfium
            .load_pdf_from_byte_slice(&self.data, None)
            .map_err(|e| anyhow::anyhow!("failed to load PDF for text extraction: {e}"))?;

        let mut pages = Vec::with_capacity(self.page_count);
        for index in 0..self.page_count {
            let text = match document.pages().get(index as u16) {
                Ok(page) => page
                    .text()
                    .map(|text| searchable_page_text(&page, &text))
                    .unwrap_or_default(),
                Err(_) => String::new(),
            };
            pages.push(text);
        }

        Ok(pages)
    }

    /// Render a page and tint the text ranges used by in-document search.
    ///
    /// Each tuple contains a character offset, character count, and whether
    /// the range is the currently selected search result.
    pub fn render_page_with_highlights(
        &self,
        index: usize,
        scale: f32,
        highlights: &[(usize, usize, bool)],
    ) -> Result<RenderedPage> {
        self.render_page_impl(index, scale, highlights)
    }

    fn render_page_impl(
        &self,
        index: usize,
        scale: f32,
        highlights: &[(usize, usize, bool)],
    ) -> Result<RenderedPage> {
        if index >= self.page_count {
            anyhow::bail!(
                "page index {index} out of range (total: {})",
                self.page_count
            );
        }

        let pdfium = create_pdfium()?;
        let document = pdfium
            .load_pdf_from_byte_slice(&self.data, None)
            .map_err(|e| anyhow::anyhow!("failed to load PDF for rendering: {e}"))?;
        let page = document
            .pages()
            .get(index as u16)
            .map_err(|e| anyhow::anyhow!("failed to get page {index}: {e}"))?;

        let (pt_w, pt_h) = self.page_sizes[index];
        let pixel_w = (pt_w * scale) as i32;
        let pixel_h = (pt_h * scale) as i32;
        let config = PdfRenderConfig::new()
            .set_target_width(pixel_w)
            .set_maximum_height(pixel_h);
        let bitmap = page
            .render_with_config(&config)
            .map_err(|e| anyhow::anyhow!("failed to render page {index}: {e}"))?;

        let width = bitmap.width() as u32;
        let height = bitmap.height() as u32;
        let mut pixels = bitmap.as_rgba_bytes();

        if !highlights.is_empty()
            && let Ok(text) = page.text()
        {
            let chars = text.chars();

            for &(offset, length, current) in highlights {
                let end = offset.saturating_add(length).min(chars.len());
                for char_index in offset..end {
                    let Ok(character) = chars.get(char_index) else {
                        continue;
                    };
                    let Ok(bounds) = character.loose_bounds() else {
                        continue;
                    };
                    if let Some(bounds) = rect_to_pixels(&page, bounds, &config) {
                        tint_rectangle(&mut pixels, width, height, bounds, current);
                    }
                }
            }
        }

        Ok(RenderedPage {
            width,
            height,
            pixels: bytes::Bytes::from(pixels),
        })
    }
}

fn searchable_page_text(page: &PdfPage<'_>, text: &PdfPageText<'_>) -> String {
    let page_bounds = page
        .boundaries()
        .bounding()
        .ok()
        .map(|boundary| boundary.bounds);
    let mut result = String::with_capacity(text.chars().len());

    for character in text.chars().iter() {
        // Generated whitespace and line breaks must remain to preserve PDFium
        // character indexes even though they often have no visible bounds.
        let visible = character.is_generated().unwrap_or(false)
            || character.loose_bounds().is_ok_and(|bounds| {
                page_bounds.is_some_and(|page_bounds| bounds.does_overlap(&page_bounds))
            });
        result.push(if visible {
            character
                .unicode_char()
                .filter(|character| *character != '\0')
                .unwrap_or('\u{FFFD}')
        } else {
            '\u{FFFD}'
        });
    }

    result
}

fn rect_to_pixels(
    page: &PdfPage<'_>,
    bounds: PdfRect,
    config: &PdfRenderConfig,
) -> Option<(i32, i32, i32, i32)> {
    let corners = [
        page.points_to_pixels(bounds.left(), bounds.bottom(), config)
            .ok()?,
        page.points_to_pixels(bounds.left(), bounds.top(), config)
            .ok()?,
        page.points_to_pixels(bounds.right(), bounds.bottom(), config)
            .ok()?,
        page.points_to_pixels(bounds.right(), bounds.top(), config)
            .ok()?,
    ];
    Some((
        corners.iter().map(|(x, _)| *x).min()?,
        corners.iter().map(|(_, y)| *y).min()?,
        corners.iter().map(|(x, _)| *x).max()?,
        corners.iter().map(|(_, y)| *y).max()?,
    ))
}

fn tint_rectangle(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    bounds: (i32, i32, i32, i32),
    current: bool,
) {
    let (left, top, right, bottom) = bounds;
    let left = left.clamp(0, width as i32) as u32;
    let right = right.clamp(0, width as i32) as u32;
    let top = top.clamp(0, height as i32) as u32;
    let bottom = bottom.clamp(0, height as i32) as u32;
    let color = if current {
        [255_u16, 160_u16, 60_u16]
    } else {
        [255_u16, 225_u16, 70_u16]
    };
    let alpha = if current { 120_u16 } else { 95_u16 };

    for y in top..bottom {
        for x in left..right {
            let pixel = ((y * width + x) * 4) as usize;
            for channel in 0..3 {
                pixels[pixel + channel] = ((pixels[pixel + channel] as u16 * (255 - alpha)
                    + color[channel] * alpha)
                    / 255) as u8;
            }
        }
    }
}

impl Document for PdfDoc {
    fn page_count(&self) -> usize {
        self.page_count
    }

    fn page_size(&self, index: usize) -> Result<(f32, f32)> {
        self.page_sizes
            .get(index)
            .copied()
            .ok_or_else(|| anyhow::anyhow!("page index {index} out of range"))
    }

    fn render_page(&self, index: usize, scale: f32) -> Result<RenderedPage> {
        self.render_page_impl(index, scale, &[])
    }

    fn metadata(&self) -> DocumentMetadata {
        self.metadata.clone()
    }
}
