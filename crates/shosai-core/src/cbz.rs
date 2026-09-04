//! CBZ (Comic Book Zip) format support.
//!
//! Pages are indexed cheaply and decoded only when requested.

use std::io::{Cursor, Read};
use std::path::Path;
use std::sync::Mutex;

use anyhow::{Context, Result};
use zip::ZipArchive;

use crate::document::{DocumentMetadata, RenderedPage};

const IMAGE_EXTENSIONS: &[&str] = &["jpg", "jpeg", "png", "gif", "webp", "bmp"];
const MIB: u64 = 1024 * 1024;

/// Resource limits applied while opening and reading a CBZ.
#[derive(Clone, Copy, Debug)]
pub struct CbzLimits {
    pub max_archive_bytes: u64,
    pub max_entries: usize,
    pub max_entry_bytes: u64,
    pub max_total_uncompressed_bytes: u64,
    pub max_compression_ratio: u64,
    pub max_image_width: u32,
    pub max_image_height: u32,
    pub max_image_pixels: u64,
    pub max_decoded_rgba_bytes: u64,
}

impl Default for CbzLimits {
    fn default() -> Self {
        Self {
            max_archive_bytes: 512 * 1024 * 1024,
            max_entries: 10_000,
            max_entry_bytes: 128 * 1024 * 1024,
            max_total_uncompressed_bytes: 2 * 1024 * 1024 * 1024,
            max_compression_ratio: 1_000,
            max_image_width: 16_384,
            max_image_height: 16_384,
            max_image_pixels: 40_000_000,
            max_decoded_rgba_bytes: 160 * MIB,
        }
    }
}

#[derive(Debug)]
pub struct CbzDoc {
    page_paths: Vec<String>,
    page_byte_lengths: Vec<usize>,
    data: Vec<u8>,
    title: Option<String>,
    limits: CbzLimits,
    dimensions: Mutex<Vec<Option<(u32, u32)>>>,
}

impl CbzDoc {
    pub(crate) fn retained_byte_len(&self) -> Option<usize> {
        let names = self
            .page_paths
            .iter()
            .try_fold(0_usize, |total, path| total.checked_add(path.capacity()))?;
        self.data
            .capacity()
            .checked_add(names)?
            .checked_add(
                self.page_paths
                    .capacity()
                    .checked_mul(std::mem::size_of::<String>())?,
            )?
            .checked_add(
                self.page_byte_lengths
                    .capacity()
                    .checked_mul(std::mem::size_of::<usize>())?,
            )?
            .checked_add(
                self.page_paths
                    .capacity()
                    .checked_mul(std::mem::size_of::<Option<(u32, u32)>>())?,
            )?
            .checked_add(self.title.as_ref().map_or(0, String::capacity))
            .and_then(|bytes| bytes.checked_add(std::mem::size_of::<Self>()))
    }

    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_limits(path, CbzLimits::default())
    }

    pub fn open_with_limits(path: impl AsRef<Path>, limits: CbzLimits) -> Result<Self> {
        let path = path.as_ref();
        let mut file = std::fs::File::open(path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let metadata = file
            .metadata()
            .with_context(|| format!("failed to inspect {}", path.display()))?;
        if metadata.len() > limits.max_archive_bytes {
            crate::resource_limit!("CBZ archive exceeds encoded byte limit");
        }
        let data = read_cbz_snapshot(&mut file, metadata.len(), limits.max_archive_bytes)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let title = path.file_stem().map(|s| s.to_string_lossy().to_string());
        Self::from_bytes_with_title(data, title, limits)
    }

    pub fn from_bytes(data: Vec<u8>) -> Result<Self> {
        Self::from_bytes_with_limits(data, CbzLimits::default())
    }

    pub fn from_bytes_with_limits(data: Vec<u8>, limits: CbzLimits) -> Result<Self> {
        Self::from_bytes_with_title(data, None, limits)
    }

    pub(crate) fn from_bytes_with_title_hint(data: Vec<u8>, title: Option<String>) -> Result<Self> {
        Self::from_bytes_with_title(data, title, CbzLimits::default())
    }

    fn from_bytes_with_title(
        data: Vec<u8>,
        title: Option<String>,
        limits: CbzLimits,
    ) -> Result<Self> {
        if u64::try_from(data.len()).unwrap_or(u64::MAX) > limits.max_archive_bytes {
            crate::resource_limit!("CBZ archive exceeds encoded byte limit");
        }
        let mut archive =
            ZipArchive::new(Cursor::new(&data)).context("failed to open CBZ as ZIP archive")?;
        if archive.len() > limits.max_entries {
            crate::resource_limit!("CBZ archive exceeds entry count limit");
        }

        let mut total = 0_u64;
        let mut page_paths = Vec::new();
        for i in 0..archive.len() {
            let file = archive.by_index(i).context("failed to inspect CBZ entry")?;
            let size = file.size();
            if size > limits.max_entry_bytes {
                crate::resource_limit!(
                    "CBZ entry exceeds uncompressed byte limit: {}",
                    file.name()
                );
            }
            total = total
                .checked_add(size)
                .context("CBZ declared size overflow")?;
            if total > limits.max_total_uncompressed_bytes {
                crate::resource_limit!("CBZ archive exceeds aggregate uncompressed byte limit");
            }
            let compressed = file.compressed_size();
            if size > 0
                && (compressed == 0
                    || size > compressed.saturating_mul(limits.max_compression_ratio))
            {
                crate::resource_limit!(
                    "CBZ entry exceeds compression ratio limit: {}",
                    file.name()
                );
            }
            let name = file.name();
            if name.ends_with('/') || name.contains("/__MACOSX") || name.contains("/.") {
                continue;
            }
            if name.rsplit('.').next().is_some_and(|ext| {
                IMAGE_EXTENSIONS
                    .iter()
                    .any(|known| ext.eq_ignore_ascii_case(known))
            }) {
                page_paths.push((name.to_owned(), usize::try_from(size).unwrap_or(usize::MAX)));
            }
        }
        page_paths.sort_by(|a, b| natord::compare(&a.0, &b.0));
        if page_paths.is_empty() {
            anyhow::bail!("CBZ archive contains no image files");
        }
        let dimensions = Mutex::new(vec![None; page_paths.len()]);
        let (page_paths, page_byte_lengths) = page_paths.into_iter().unzip();
        Ok(Self {
            page_paths,
            page_byte_lengths,
            data,
            title,
            limits,
            dimensions,
        })
    }

    pub fn page_count(&self) -> usize {
        self.page_paths.len()
    }

    pub fn page_source_byte_len(&self, index: usize) -> Option<usize> {
        self.page_byte_lengths.get(index).copied()
    }

    /// Worst-case source and decode admission used by non-rendering callers.
    pub fn render_admission_byte_len(&self, index: usize) -> Option<usize> {
        let source = self.page_source_byte_len(index)?;
        let decoded = usize::try_from(self.limits.max_decoded_rgba_bytes).ok()?;
        source.checked_add(decoded.checked_mul(2)?)
    }

    /// Compressed source plus conservative temporary decode/resize allocation.
    pub fn render_admission_byte_len_at_scale(&self, index: usize, scale: f32) -> Option<usize> {
        let source = self.page_source_byte_len(index)?;
        source.checked_add(self.render_transient_byte_len(index, scale)?)
    }

    fn image_bytes(&self, index: usize) -> Result<Vec<u8>> {
        let path = self
            .page_paths
            .get(index)
            .context("page index out of range")?;
        let mut archive =
            ZipArchive::new(Cursor::new(&self.data)).context("failed to reopen CBZ archive")?;
        let mut file = archive
            .by_name(path)
            .with_context(|| format!("image not found in archive: {path}"))?;
        let declared = file.size();
        if declared > self.limits.max_entry_bytes
            || declared > self.limits.max_total_uncompressed_bytes
        {
            crate::resource_limit!("CBZ entry exceeds streamed byte limit: {path}");
        }
        let capacity = usize::try_from(declared.min(self.limits.max_entry_bytes)).unwrap_or(0);
        let mut bytes = Vec::with_capacity(capacity);
        file.by_ref()
            .take(self.limits.max_entry_bytes.saturating_add(1))
            .read_to_end(&mut bytes)
            .with_context(|| format!("failed to read image: {path}"))?;
        let streamed = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        if streamed > self.limits.max_entry_bytes
            || streamed > self.limits.max_total_uncompressed_bytes
        {
            crate::resource_limit!("CBZ entry exceeds streamed byte limit: {path}");
        }
        if streamed != declared {
            anyhow::bail!("CBZ entry declared {declared} bytes but streamed {streamed}: {path}");
        }
        Ok(bytes)
    }

    fn dimensions(&self, index: usize) -> Result<(u32, u32)> {
        self.page_paths
            .get(index)
            .context("page index out of range")?;
        if let Some(dimensions) = self.cached_dimensions(index) {
            return Ok(dimensions);
        }
        let bytes = self.image_bytes(index)?;
        self.inspect_dimensions(index, &bytes)
    }

    fn cached_dimensions(&self, index: usize) -> Option<(u32, u32)> {
        self.dimensions.lock().expect("dimension cache poisoned")[index]
    }

    fn inspect_dimensions(&self, index: usize, bytes: &[u8]) -> Result<(u32, u32)> {
        let path = self
            .page_paths
            .get(index)
            .context("page index out of range")?;
        let reader = image::ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .with_context(|| format!("failed to identify image: {path}"))?;
        let (width, height) = reader
            .into_dimensions()
            .with_context(|| format!("failed to inspect image dimensions: {path}"))?;
        self.validate_dimensions(width, height)?;
        self.dimensions.lock().expect("dimension cache poisoned")[index] = Some((width, height));
        Ok((width, height))
    }

    fn validate_dimensions(&self, width: u32, height: u32) -> Result<()> {
        let pixels = u64::from(width)
            .checked_mul(u64::from(height))
            .context("image dimensions overflow")?;
        let rgba = pixels
            .checked_mul(4)
            .context("decoded image size overflow")?;
        if width > self.limits.max_image_width
            || height > self.limits.max_image_height
            || pixels > self.limits.max_image_pixels
            || rgba > self.limits.max_decoded_rgba_bytes
        {
            crate::resource_limit!("CBZ image exceeds decoded image limits");
        }
        Ok(())
    }

    pub fn render_page(&self, index: usize, scale: f32) -> Result<RenderedPage> {
        if !scale.is_finite() || scale <= 0.0 {
            anyhow::bail!("page scale must be finite and positive");
        }
        let path = self
            .page_paths
            .get(index)
            .context("page index out of range")?;
        let bytes = self.image_bytes(index)?;
        let (width, height) = self
            .cached_dimensions(index)
            .map(Ok)
            .unwrap_or_else(|| self.inspect_dimensions(index, &bytes))?;
        let (new_width, new_height) = scaled_dimensions(width, height, scale)
            .context("scaled image dimensions must be finite, positive, and in range")?;
        self.validate_dimensions(new_width, new_height)?;
        let mut reader = image::ImageReader::new(Cursor::new(&bytes))
            .with_guessed_format()
            .with_context(|| format!("failed to identify image: {path}"))?;
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(self.limits.max_image_width);
        limits.max_image_height = Some(self.limits.max_image_height);
        limits.max_alloc = Some(self.limits.max_decoded_rgba_bytes);
        reader.limits(limits);
        let img = reader
            .decode()
            .with_context(|| format!("failed to decode image: {path}"))?;
        let img = if (scale - 1.0).abs() > f32::EPSILON {
            img.resize_exact(new_width, new_height, image::imageops::FilterType::Lanczos3)
        } else {
            img
        };
        let rgba = img.to_rgba8();
        let (width, height) = rgba.dimensions();
        Ok(RenderedPage {
            width,
            height,
            pixels: bytes::Bytes::from(rgba.into_raw()),
        })
    }

    pub fn page_size(&self, index: usize) -> Result<(f32, f32)> {
        let (width, height) = self.dimensions(index)?;
        Ok((width as f32, height as f32))
    }

    /// Exact byte length of the final RGBA render buffer.
    pub fn rendered_byte_len(&self, index: usize, scale: f32) -> Result<usize> {
        let (width, height) = self.dimensions(index)?;
        let (width, height) = scaled_dimensions(width, height, scale)
            .context("scaled image dimensions must be finite, positive, and in range")?;
        self.validate_dimensions(width, height)?;
        usize::try_from(width)
            .ok()
            .and_then(|width| width.checked_mul(usize::try_from(height).ok()?))
            .and_then(|pixels| pixels.checked_mul(4))
            .context("rendered image byte length overflow")
    }

    /// Conservative temporary allocation charge for decoding and resizing a page.
    /// The final RGBA output is accounted separately by the caller.
    pub fn render_transient_byte_len(&self, index: usize, scale: f32) -> Option<usize> {
        if !scale.is_finite() || scale <= 0.0 {
            return None;
        }
        let (width, height) = self.cached_dimensions(index)?;
        let (target_width, target_height) = scaled_dimensions(width, height, scale)?;
        let decoded = usize::try_from(width)
            .ok()?
            .checked_mul(usize::try_from(height).ok()?)?
            .checked_mul(4)?;
        let resized = usize::try_from(target_width)
            .ok()?
            .checked_mul(usize::try_from(target_height).ok()?)?
            .checked_mul(4)?;
        decoded.checked_add(resized)
    }

    /// Return dimensions already discovered by a prior size query or render.
    ///
    /// Unlike [`Self::page_size`], this never reads or decompresses archive data.
    pub fn cached_page_size(&self, index: usize) -> Option<(f32, f32)> {
        let (width, height) = self
            .dimensions
            .lock()
            .expect("dimension cache poisoned")
            .get(index)
            .copied()
            .flatten()?;
        Some((width as f32, height as f32))
    }

    pub fn metadata(&self) -> DocumentMetadata {
        DocumentMetadata {
            title: self.title.clone(),
            author: None,
            subject: None,
            creator: None,
        }
    }

    pub fn page_image_bytes(&self, index: usize) -> Result<Vec<u8>> {
        let bytes = self.image_bytes(index)?;
        if self.cached_dimensions(index).is_none() {
            self.inspect_dimensions(index, &bytes)?;
        }
        Ok(bytes)
    }
}

fn scaled_dimensions(width: u32, height: u32, scale: f32) -> Option<(u32, u32)> {
    if !scale.is_finite() || scale <= 0.0 {
        return None;
    }
    if (scale - 1.0).abs() <= f32::EPSILON {
        return Some((width, height));
    }
    let width = (f64::from(width) * f64::from(scale)).floor();
    let height = (f64::from(height) * f64::from(scale)).floor();
    if !width.is_finite()
        || !height.is_finite()
        || width < 1.0
        || height < 1.0
        || width > f64::from(u32::MAX)
        || height > f64::from(u32::MAX)
    {
        return None;
    }
    Some((width as u32, height as u32))
}

fn read_cbz_snapshot(
    reader: impl Read,
    expected_bytes: u64,
    max_archive_bytes: u64,
) -> Result<Vec<u8>> {
    let mut data = Vec::with_capacity(
        usize::try_from(expected_bytes.min(max_archive_bytes)).unwrap_or_default(),
    );
    reader
        .take(max_archive_bytes.saturating_add(1))
        .read_to_end(&mut data)?;
    let actual_bytes = u64::try_from(data.len()).unwrap_or(u64::MAX);
    if actual_bytes > max_archive_bytes {
        crate::resource_limit!("CBZ archive exceeds encoded byte limit");
    }
    if actual_bytes != expected_bytes {
        anyhow::bail!(
            "CBZ changed while reading (expected {expected_bytes} bytes, read {actual_bytes})"
        );
    }
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cbz_snapshot_rejects_growth_and_truncation() {
        let growth = read_cbz_snapshot(&b"four"[..], 3, 3).unwrap_err();
        assert!(
            growth
                .downcast_ref::<crate::application::ResourceLimitError>()
                .is_some()
        );

        let truncation = read_cbz_snapshot(&b"two"[..], 4, 4).unwrap_err();
        assert!(truncation.to_string().contains("changed while reading"));
    }

    #[test]
    fn test_image_extensions() {
        assert!(IMAGE_EXTENSIONS.contains(&"jpg"));
        assert!(IMAGE_EXTENSIONS.contains(&"png"));
        assert!(!IMAGE_EXTENSIONS.contains(&"txt"));
    }
}
