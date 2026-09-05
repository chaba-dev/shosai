//! CBZ (Comic Book Zip) format support.
//!
//! Pages are indexed cheaply and decoded only when requested.

use std::io::{Cursor, Read, Seek};
use std::path::Path;
use std::sync::Mutex;

use anyhow::{Context, Result};
use image::ImageDecoder;
use zip::ZipArchive;

use crate::document::{DocumentMetadata, RenderedPage};

const IMAGE_EXTENSIONS: &[&str] = &["jpg", "jpeg", "png", "gif", "webp", "bmp"];
const MIB: u64 = 1024 * 1024;
pub(crate) const IMAGE_PROBE_METADATA_BYTES: usize = 1024 * 1024;

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
struct SharedBytes(std::sync::Arc<Vec<u8>>);

impl AsRef<[u8]> for SharedBytes {
    fn as_ref(&self) -> &[u8] {
        self.0.as_slice()
    }
}

#[derive(Debug)]
pub struct CbzDoc {
    page_paths: Vec<String>,
    page_byte_lengths: Vec<usize>,
    archive: Mutex<ZipArchive<Cursor<SharedBytes>>>,
    encoded_bytes: usize,
    title: Option<String>,
    limits: CbzLimits,
    dimensions: Mutex<Vec<Option<(u32, u32)>>>,
    native_bytes_per_pixel: Mutex<Vec<Option<usize>>>,
    archive_metadata_bytes: usize,
    _admission: Option<crate::document_admission::DocumentAdmission>,
}

impl CbzDoc {
    pub(crate) fn retained_byte_len(&self) -> Option<usize> {
        let names = self
            .page_paths
            .iter()
            .try_fold(0_usize, |total, path| total.checked_add(path.capacity()))?;
        self.encoded_bytes
            .checked_add(names)?
            .checked_add(self.archive_metadata_bytes)?
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
            .checked_add(
                self.page_paths
                    .capacity()
                    .checked_mul(std::mem::size_of::<Option<usize>>())?,
            )?
            .checked_add(self.title.as_ref().map_or(0, String::capacity))
            .and_then(|bytes| bytes.checked_add(std::mem::size_of::<Self>()))
    }

    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_limits(path, CbzLimits::default())
    }

    pub fn open_with_limits(path: impl AsRef<Path>, limits: CbzLimits) -> Result<Self> {
        Self::open_with_limits_inner(path.as_ref(), limits, None)
    }

    pub(crate) fn open_with_limits_cancellable(
        path: &Path,
        limits: CbzLimits,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<Self> {
        Self::open_with_limits_inner(path, limits, Some(is_cancelled))
    }

    fn open_with_limits_inner(
        path: &Path,
        limits: CbzLimits,
        is_cancelled: Option<&dyn Fn() -> bool>,
    ) -> Result<Self> {
        let mut file = std::fs::File::open(path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let metadata = file
            .metadata()
            .with_context(|| format!("failed to inspect {}", path.display()))?;
        if metadata.len() > limits.max_archive_bytes {
            crate::resource_limit!("CBZ archive exceeds encoded byte limit");
        }
        let preflight =
            crate::zip_preflight::preflight(&mut file, limits.max_entries, is_cancelled)
                .context("failed to preflight CBZ ZIP archive")?;
        file.rewind()?;
        let archive_metadata_bytes = crate::zip_preflight::metadata_allocation_ceiling(preflight)
            .context("CBZ metadata admission overflowed")?;
        let retained_ceiling = crate::document_admission::cbz_retained_ceiling(
            usize::try_from(metadata.len()).unwrap_or(usize::MAX),
            limits.max_entries,
            archive_metadata_bytes,
            preflight.copied_filename_ceiling,
        )
        .context("CBZ retained-memory admission overflowed")?;
        let admission =
            crate::document_admission::ProvisionalDocumentAdmission::acquire(retained_ceiling)?;
        let data = read_cbz_snapshot_cancellable(
            &mut file,
            metadata.len(),
            limits.max_archive_bytes,
            is_cancelled,
        )
        .with_context(|| format!("failed to read {}", path.display()))?;
        let snapshot_preflight = crate::zip_preflight::preflight(
            Cursor::new(data.as_slice()),
            limits.max_entries,
            is_cancelled,
        )
        .context("failed to preflight CBZ snapshot")?;
        let snapshot_metadata =
            crate::zip_preflight::metadata_allocation_ceiling(snapshot_preflight)
                .context("CBZ snapshot metadata admission overflowed")?;
        let required = crate::document_admission::cbz_retained_ceiling(
            data.capacity(),
            limits.max_entries,
            snapshot_metadata,
            snapshot_preflight.copied_filename_ceiling,
        )
        .context("CBZ snapshot admission overflowed")?;
        if required > retained_ceiling {
            crate::resource_limit!("CBZ changed after retained-memory admission");
        }
        let title = path.file_stem().map(|s| s.to_string_lossy().to_string());
        Self::from_bytes_with_title_cancellable_admitted(
            data,
            title,
            limits,
            is_cancelled,
            admission,
        )
    }

    pub fn from_bytes(data: Vec<u8>) -> Result<Self> {
        Self::from_bytes_with_limits(data, CbzLimits::default())
    }

    pub fn from_bytes_with_limits(data: Vec<u8>, limits: CbzLimits) -> Result<Self> {
        Self::from_bytes_with_title(data, None, limits)
    }

    #[cfg(test)]
    pub(crate) fn from_bytes_with_title_hint(data: Vec<u8>, title: Option<String>) -> Result<Self> {
        Self::from_bytes_with_title(data, title, CbzLimits::default())
    }

    pub(crate) fn from_bytes_with_title_hint_admitted_cancellable(
        data: Vec<u8>,
        title: Option<String>,
        admission: crate::document_admission::ProvisionalDocumentAdmission,
        is_cancelled: Option<&dyn Fn() -> bool>,
    ) -> Result<Self> {
        Self::from_bytes_with_title_cancellable_admitted(
            data,
            title,
            CbzLimits::default(),
            is_cancelled,
            admission,
        )
    }

    fn from_bytes_with_title(
        data: Vec<u8>,
        title: Option<String>,
        limits: CbzLimits,
    ) -> Result<Self> {
        Self::from_bytes_with_title_cancellable(data, title, limits, None)
    }

    fn from_bytes_with_title_cancellable(
        data: Vec<u8>,
        title: Option<String>,
        limits: CbzLimits,
        is_cancelled: Option<&dyn Fn() -> bool>,
    ) -> Result<Self> {
        let preflight = crate::zip_preflight::preflight(
            Cursor::new(data.as_slice()),
            limits.max_entries,
            is_cancelled,
        )
        .context("failed to preflight CBZ ZIP archive")?;
        let archive_metadata_bytes = crate::zip_preflight::metadata_allocation_ceiling(preflight)
            .context("CBZ metadata admission overflowed")?;
        let retained_ceiling = crate::document_admission::cbz_retained_ceiling(
            data.capacity(),
            limits.max_entries,
            archive_metadata_bytes,
            preflight.copied_filename_ceiling,
        )
        .context("CBZ retained-memory admission overflowed")?;
        let admission =
            crate::document_admission::ProvisionalDocumentAdmission::acquire(retained_ceiling)?;
        Self::from_bytes_with_title_cancellable_admitted(
            data,
            title,
            limits,
            is_cancelled,
            admission,
        )
    }

    fn from_bytes_with_title_cancellable_admitted(
        data: Vec<u8>,
        title: Option<String>,
        limits: CbzLimits,
        is_cancelled: Option<&dyn Fn() -> bool>,
        admission: crate::document_admission::ProvisionalDocumentAdmission,
    ) -> Result<Self> {
        check_cancelled(is_cancelled)?;
        if u64::try_from(data.len()).unwrap_or(u64::MAX) > limits.max_archive_bytes {
            crate::resource_limit!("CBZ archive exceeds encoded byte limit");
        }
        let preflight = crate::zip_preflight::preflight(
            Cursor::new(data.as_slice()),
            limits.max_entries,
            is_cancelled,
        )
        .context("failed to preflight CBZ ZIP archive")?;
        let encoded_bytes = data.capacity();
        let mut archive = ZipArchive::new(Cursor::new(SharedBytes(std::sync::Arc::new(data))))
            .context("failed to open CBZ as ZIP archive")?;

        let mut total = 0_u64;
        let mut page_paths = Vec::new();
        for i in 0..archive.len() {
            check_cancelled(is_cancelled)?;
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
        let native_bytes_per_pixel = Mutex::new(vec![None; page_paths.len()]);
        let (page_paths, page_byte_lengths) = page_paths.into_iter().unzip();
        let mut parsed = Self {
            page_paths,
            page_byte_lengths,
            archive: Mutex::new(archive),
            encoded_bytes,
            title,
            limits,
            dimensions,
            native_bytes_per_pixel,
            archive_metadata_bytes: crate::zip_preflight::metadata_allocation_ceiling(preflight)
                .context("CBZ archive metadata charge overflowed")?,
            _admission: None,
        };
        let retained_bytes = parsed
            .retained_byte_len()
            .context("CBZ retained-memory charge overflowed")?;
        parsed._admission = Some(admission.finish(retained_bytes)?);
        Ok(parsed)
    }

    pub fn page_count(&self) -> usize {
        self.page_paths.len()
    }

    pub fn page_source_byte_len(&self, index: usize) -> Option<usize> {
        self.page_byte_lengths.get(index).copied()
    }

    pub fn page_probe_admission_byte_len(&self, index: usize) -> Option<usize> {
        self.page_source_byte_len(index)?
            .checked_mul(2)?
            .checked_add(IMAGE_PROBE_METADATA_BYTES)
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
        self.image_bytes_cancellable(index, None)
    }

    fn image_bytes_cancellable(
        &self,
        index: usize,
        is_cancelled: Option<&dyn Fn() -> bool>,
    ) -> Result<Vec<u8>> {
        let path = self
            .page_paths
            .get(index)
            .context("page index out of range")?;
        let mut archive = self.archive.lock().expect("CBZ archive mutex poisoned");
        let mut file = archive
            .by_name(path)
            .with_context(|| format!("image not found in archive: {path}"))?;
        let declared = file.size();
        if declared > self.limits.max_entry_bytes
            || declared > self.limits.max_total_uncompressed_bytes
        {
            crate::resource_limit!("CBZ entry exceeds streamed byte limit: {path}");
        }
        let capacity = usize::try_from(declared).context("CBZ entry size cannot be represented")?;
        let mut bytes = Vec::with_capacity(capacity);
        let mut buffer = [0_u8; 64 * 1024];
        while bytes.len() < capacity {
            check_cancelled(is_cancelled)?;
            let remaining = capacity - bytes.len();
            let chunk = remaining.min(buffer.len());
            let read = file
                .by_ref()
                .read(&mut buffer[..chunk])
                .with_context(|| format!("failed to read image: {path}"))?;
            if read == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..read]);
        }
        check_cancelled(is_cancelled)?;
        let mut extra = [0_u8; 1];
        let extra = file
            .read(&mut extra)
            .with_context(|| format!("failed to finish reading image: {path}"))?;
        let streamed = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        if extra != 0 {
            crate::resource_limit!("CBZ entry exceeds declared streamed byte limit: {path}");
        }
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

    fn cached_dimensions(&self, index: usize) -> Option<(u32, u32)> {
        self.dimensions
            .lock()
            .expect("dimension cache poisoned")
            .get(index)
            .copied()
            .flatten()
    }

    fn inspect_dimensions(&self, index: usize, bytes: &[u8]) -> Result<(u32, u32)> {
        let path = self
            .page_paths
            .get(index)
            .context("page index out of range")?;
        let mut reader = image::ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .with_context(|| format!("failed to identify image: {path}"))?;
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(self.limits.max_image_width);
        limits.max_image_height = Some(self.limits.max_image_height);
        limits.max_alloc = Some(IMAGE_PROBE_METADATA_BYTES as u64);
        reader.limits(limits);
        let decoder = reader
            .into_decoder()
            .with_context(|| format!("failed to inspect image dimensions: {path}"))?;
        let (width, height) = decoder.dimensions();
        let native_bytes_per_pixel = usize::from(decoder.color_type().bytes_per_pixel());
        self.validate_dimensions(width, height)?;
        self.native_bytes_per_pixel
            .lock()
            .expect("image byte-depth cache poisoned")[index] = Some(native_bytes_per_pixel);
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
        self.render_page_cancellable_inner(index, scale, None)
    }

    #[doc(hidden)]
    pub fn render_page_cancellable(
        &self,
        index: usize,
        scale: f32,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<RenderedPage> {
        self.render_page_cancellable_inner(index, scale, Some(is_cancelled))
    }

    fn render_page_cancellable_inner(
        &self,
        index: usize,
        scale: f32,
        is_cancelled: Option<&dyn Fn() -> bool>,
    ) -> Result<RenderedPage> {
        check_cancelled(is_cancelled)?;
        if !scale.is_finite() || scale <= 0.0 {
            anyhow::bail!("page scale must be finite and positive");
        }
        let path = self
            .page_paths
            .get(index)
            .context("page index out of range")?;
        let bytes = self.image_bytes_cancellable(index, is_cancelled)?;
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
        check_cancelled(is_cancelled)?;
        let img = if (scale - 1.0).abs() > f32::EPSILON {
            img.resize_exact(new_width, new_height, image::imageops::FilterType::Lanczos3)
        } else {
            img
        };
        check_cancelled(is_cancelled)?;
        let rgba = img.to_rgba8();
        let (width, height) = rgba.dimensions();
        Ok(RenderedPage {
            width,
            height,
            pixels: bytes::Bytes::from(rgba.into_raw()),
        })
    }

    pub fn page_size(&self, index: usize) -> Result<(f32, f32)> {
        self.page_size_cancellable_inner(index, None)
    }

    #[doc(hidden)]
    pub fn page_size_cancellable(
        &self,
        index: usize,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<(f32, f32)> {
        self.page_size_cancellable_inner(index, Some(is_cancelled))
    }

    fn page_size_cancellable_inner(
        &self,
        index: usize,
        is_cancelled: Option<&dyn Fn() -> bool>,
    ) -> Result<(f32, f32)> {
        check_cancelled(is_cancelled)?;
        let dimensions = if let Some(dimensions) = self.cached_dimensions(index) {
            dimensions
        } else {
            let bytes = self.image_bytes_cancellable(index, is_cancelled)?;
            check_cancelled(is_cancelled)?;
            self.inspect_dimensions(index, &bytes)?
        };
        check_cancelled(is_cancelled)?;
        let (width, height) = dimensions;
        Ok((width as f32, height as f32))
    }

    /// Exact byte length of the final RGBA render buffer.
    pub fn rendered_byte_len(&self, index: usize, scale: f32) -> Result<usize> {
        self.rendered_byte_len_inner(index, scale, None)
    }

    #[doc(hidden)]
    pub fn rendered_byte_len_cancellable(
        &self,
        index: usize,
        scale: f32,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<usize> {
        self.rendered_byte_len_inner(index, scale, Some(is_cancelled))
    }

    fn rendered_byte_len_inner(
        &self,
        index: usize,
        scale: f32,
        is_cancelled: Option<&dyn Fn() -> bool>,
    ) -> Result<usize> {
        check_cancelled(is_cancelled)?;
        let (width, height) = if let Some(dimensions) = self.cached_dimensions(index) {
            dimensions
        } else {
            let bytes = self.image_bytes_cancellable(index, is_cancelled)?;
            check_cancelled(is_cancelled)?;
            self.inspect_dimensions(index, &bytes)?
        };
        let (width, height) = scaled_dimensions(width, height, scale)
            .context("scaled image dimensions must be finite, positive, and in range")?;
        self.validate_dimensions(width, height)?;
        let byte_len = usize::try_from(width)
            .ok()
            .and_then(|width| width.checked_mul(usize::try_from(height).ok()?))
            .and_then(|pixels| pixels.checked_mul(4))
            .context("rendered image byte length overflow")?;
        check_cancelled(is_cancelled)?;
        Ok(byte_len)
    }

    /// Conservative temporary allocation charge for decoding and resizing a page.
    /// The final RGBA output is accounted separately by the caller.
    pub fn render_transient_byte_len(&self, index: usize, scale: f32) -> Option<usize> {
        if !scale.is_finite() || scale <= 0.0 {
            return None;
        }
        let source = self.page_source_byte_len(index)?;
        let (width, height) = self.cached_dimensions(index)?;
        let native_bytes_per_pixel = self
            .native_bytes_per_pixel
            .lock()
            .expect("image byte-depth cache poisoned")
            .get(index)
            .copied()
            .flatten()?;
        let (target_width, target_height) = scaled_dimensions(width, height, scale)?;
        let decoded = usize::try_from(width)
            .ok()?
            .checked_mul(usize::try_from(height).ok()?)?
            .checked_mul(native_bytes_per_pixel)?;
        let decoder = decoded.max(usize::try_from(self.limits.max_decoded_rgba_bytes).ok()?);
        let resized = usize::try_from(target_width)
            .ok()?
            .checked_mul(usize::try_from(target_height).ok()?)?
            .checked_mul(native_bytes_per_pixel)?;
        // image 0.25's Lanczos path resizes vertically first through an
        // Rgba32F buffer spanning the source width and target height.
        let resize_intermediate = if (scale - 1.0).abs() > f32::EPSILON {
            usize::try_from(width)
                .ok()?
                .checked_mul(usize::try_from(target_height).ok()?)?
                .checked_mul(std::mem::size_of::<image::Rgba<f32>>())?
        } else {
            0
        };
        decoder
            .checked_add(source)?
            .checked_add(resized)?
            .checked_add(resize_intermediate)
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

    pub(crate) fn page_image_bytes_cancellable(
        &self,
        index: usize,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<Vec<u8>> {
        let bytes = self.image_bytes_cancellable(index, Some(is_cancelled))?;
        check_cancelled(Some(is_cancelled))?;
        if self.cached_dimensions(index).is_none() {
            self.inspect_dimensions(index, &bytes)?;
        }
        check_cancelled(Some(is_cancelled))?;
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

#[cfg(test)]
fn read_cbz_snapshot(
    reader: impl Read,
    expected_bytes: u64,
    max_archive_bytes: u64,
) -> Result<Vec<u8>> {
    read_cbz_snapshot_cancellable(reader, expected_bytes, max_archive_bytes, None)
}

fn read_cbz_snapshot_cancellable(
    mut reader: impl Read,
    expected_bytes: u64,
    max_archive_bytes: u64,
    is_cancelled: Option<&dyn Fn() -> bool>,
) -> Result<Vec<u8>> {
    if expected_bytes > max_archive_bytes {
        crate::resource_limit!("CBZ archive exceeds encoded byte limit");
    }
    let mut data = Vec::with_capacity(usize::try_from(expected_bytes).unwrap_or_default());
    let mut buffer = [0_u8; 64 * 1024];
    while (data.len() as u64) < expected_bytes {
        check_cancelled(is_cancelled)?;
        let remaining = usize::try_from(expected_bytes - data.len() as u64)
            .unwrap_or(usize::MAX)
            .min(buffer.len());
        let read = reader.read(&mut buffer[..remaining])?;
        if read == 0 {
            break;
        }
        data.extend_from_slice(&buffer[..read]);
    }
    let mut extra = [0_u8; 1];
    let grew = reader.read(&mut extra)? != 0;
    let actual_bytes = u64::try_from(data.len()).unwrap_or(u64::MAX);
    if grew && expected_bytes == max_archive_bytes {
        crate::resource_limit!("CBZ archive exceeds encoded byte limit");
    }
    if actual_bytes != expected_bytes || grew {
        anyhow::bail!(
            "CBZ changed while reading (expected {expected_bytes} bytes, read {actual_bytes}, grew={grew})"
        );
    }
    Ok(data)
}

fn check_cancelled(is_cancelled: Option<&dyn Fn() -> bool>) -> Result<()> {
    if is_cancelled.is_some_and(|is_cancelled| is_cancelled()) {
        anyhow::bail!("import cancelled");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::ZipWriter;
    use zip::write::SimpleFileOptions;

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

    #[test]
    fn raw_duplicate_names_count_toward_the_entry_limit() {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        for name in ["page1.png", "page2.png"] {
            writer
                .start_file(name, SimpleFileOptions::default())
                .unwrap();
            writer.write_all(b"not decoded").unwrap();
        }
        let mut bytes = writer.finish().unwrap().into_inner();
        for offset in bytes
            .windows(b"page2.png".len())
            .enumerate()
            .filter_map(|(offset, value)| (value == b"page2.png").then_some(offset))
            .collect::<Vec<_>>()
        {
            bytes[offset..offset + b"page1.png".len()].copy_from_slice(b"page1.png");
        }
        let error = CbzDoc::from_bytes_with_limits(
            bytes,
            CbzLimits {
                max_entries: 1,
                ..CbzLimits::default()
            },
        )
        .unwrap_err();
        assert!(format!("{error:#}").contains("too many entries"));
    }

    #[test]
    fn retained_ceiling_includes_long_copied_page_names() {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        let name = format!("{}.png", "a".repeat(6_000));
        writer
            .start_file(&name, SimpleFileOptions::default())
            .unwrap();
        writer.write_all(b"not decoded").unwrap();
        let bytes = writer.finish().unwrap().into_inner();

        let document = CbzDoc::from_bytes_with_limits(
            bytes,
            CbzLimits {
                max_entries: 1,
                ..CbzLimits::default()
            },
        )
        .unwrap();

        assert_eq!(document.page_count(), 1);
        assert!(document.page_paths[0].capacity() >= name.len());
    }

    #[test]
    fn retained_document_charges_zip_metadata_without_recharging_page_work() {
        let document =
            CbzDoc::from_bytes(include_bytes!("../tests/fixtures/sample.cbz").to_vec()).unwrap();
        let without_metadata = document.page_source_byte_len(0).unwrap()
            + usize::try_from(document.limits.max_decoded_rgba_bytes).unwrap() * 2;
        assert_eq!(
            document.render_admission_byte_len(0).unwrap(),
            without_metadata
        );
        assert!(document.archive_metadata_bytes > 0);
        assert!(
            document.retained_byte_len().unwrap()
                >= document.encoded_bytes + document.archive_metadata_bytes
        );
    }

    #[test]
    fn image_probe_charges_source_and_decoder_owned_encoded_copy() {
        let document =
            CbzDoc::from_bytes(include_bytes!("../tests/fixtures/sample.cbz").to_vec()).unwrap();
        let source = document.page_source_byte_len(0).unwrap();

        assert_eq!(
            document.page_probe_admission_byte_len(0),
            Some(source * 2 + IMAGE_PROBE_METADATA_BYTES)
        );
    }

    #[test]
    fn page_work_honors_preexisting_cancellation() {
        let document =
            CbzDoc::from_bytes(include_bytes!("../tests/fixtures/sample.cbz").to_vec()).unwrap();

        assert!(
            document
                .page_size_cancellable(0, &|| true)
                .unwrap_err()
                .to_string()
                .contains("cancelled")
        );
        assert!(
            document
                .render_page_cancellable(0, 1.0, &|| true)
                .unwrap_err()
                .to_string()
                .contains("cancelled")
        );
        assert!(
            document
                .rendered_byte_len_cancellable(0, 1.0, &|| true)
                .unwrap_err()
                .to_string()
                .contains("cancelled")
        );
    }

    #[test]
    fn invalid_page_indexes_return_errors_without_poisoning_dimension_cache() {
        let document =
            CbzDoc::from_bytes(include_bytes!("../tests/fixtures/sample.cbz").to_vec()).unwrap();

        assert!(document.page_size(usize::MAX).is_err());
        assert!(document.rendered_byte_len(usize::MAX, 1.0).is_err());
        assert!(document.page_size(0).is_ok());
    }

    #[test]
    fn high_bit_depth_pages_charge_native_decode_and_resize_buffers() {
        let image = image::ImageBuffer::<image::Rgba<u16>, Vec<u16>>::new(2, 2);
        let mut encoded = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba16(image)
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
        archive
            .start_file("page.png", SimpleFileOptions::default())
            .unwrap();
        archive.write_all(encoded.get_ref()).unwrap();
        let bytes = archive.finish().unwrap().into_inner();
        let document = CbzDoc::from_bytes(bytes).unwrap();

        document.page_size(0).unwrap();

        assert_eq!(
            document.render_transient_byte_len(0, 2.0),
            Some(
                usize::try_from(document.limits.max_decoded_rgba_bytes).unwrap()
                    + document.page_source_byte_len(0).unwrap()
                    + 256
            )
        );
    }
}
