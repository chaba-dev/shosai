//! Allocation-bounded inspection of raw ZIP directory records.

use std::io::{Read, Seek, SeekFrom};

use anyhow::{Context, Result, bail};

#[derive(Clone, Copy, Debug)]
pub(crate) struct ZipPreflight {
    pub(crate) entries: usize,
    pub(crate) declared_uncompressed_bytes: u64,
    pub(crate) central_directory_bytes: usize,
    pub(crate) copied_filename_ceiling: usize,
    pub(crate) has_epub_mimetype: bool,
    pub(crate) has_epub_container: bool,
    pub(crate) has_comic_image: bool,
}

pub(crate) fn preflight<R: Read + Seek>(
    mut reader: R,
    max_entries: usize,
    is_cancelled: Option<&dyn Fn() -> bool>,
) -> Result<ZipPreflight> {
    check_cancelled(is_cancelled)?;
    let archive_len = reader.seek(SeekFrom::End(0))?;
    let tail_len = usize::try_from(archive_len)
        .unwrap_or(usize::MAX)
        .min(65_557);
    let mut tail = vec![0; tail_len];
    reader.seek(SeekFrom::Start(archive_len - tail_len as u64))?;
    read_exact_cancellable(&mut reader, &mut tail, is_cancelled)?;
    let eocd = (0..tail.len().saturating_sub(21))
        .rev()
        .find(|&offset| {
            tail.get(offset..offset + 4) == Some(b"PK\x05\x06")
                && le16(&tail, offset + 20)
                    .and_then(|len| offset.checked_add(22 + usize::from(len)))
                    == Some(tail.len())
        })
        .context("ZIP end-of-central-directory record is missing")?;
    let eocd_position = archive_len - tail_len as u64 + eocd as u64;
    if has_earlier_zip_candidate(
        &mut reader,
        eocd_position,
        archive_len,
        max_entries,
        is_cancelled,
    )? {
        bail!("multiple ZIP end-of-central-directory records are not supported");
    }
    let disk = le16(&tail, eocd + 4).unwrap();
    let directory_disk = le16(&tail, eocd + 6).unwrap();
    let count_disk32 = le16(&tail, eocd + 8).unwrap();
    let count32 = le16(&tail, eocd + 10).unwrap();
    let size32 = le32(&tail, eocd + 12).unwrap();
    let offset32 = le32(&tail, eocd + 16).unwrap();
    // Match zip 8.4's ZIP64 selection exactly. A saturated files-on-disk or
    // directory-size field alone is still interpreted as ZIP32 by the dependency.
    let uses_zip64 = count32 == u16::MAX || offset32 == u32::MAX;
    let (entries, central_size, central_offset) = if uses_zip64 {
        let locator_position = eocd_position
            .checked_sub(20)
            .context("ZIP64 locator is missing")?;
        let mut locator = [0; 20];
        reader.seek(SeekFrom::Start(locator_position))?;
        read_exact_cancellable(&mut reader, &mut locator, is_cancelled)?;
        if &locator[..4] != b"PK\x06\x07"
            || le32(&locator, 4) != Some(0)
            || le32(&locator, 16) != Some(1)
        {
            bail!("invalid ZIP64 locator");
        }
        let record_position = le64(&locator, 8).unwrap();
        let mut record = [0; 56];
        reader.seek(SeekFrom::Start(record_position))?;
        read_exact_cancellable(&mut reader, &mut record, is_cancelled)?;
        if &record[..4] != b"PK\x06\x06"
            || le64(&record, 4) != Some(44)
            || record_position.checked_add(56) != Some(locator_position)
        {
            bail!("invalid ZIP64 end-of-central-directory record");
        }
        let count_disk64 = le64(&record, 24).unwrap();
        let count64 = le64(&record, 32).unwrap();
        if le32(&record, 16) != Some(0) || le32(&record, 20) != Some(0) || count_disk64 != count64 {
            bail!("multi-disk ZIP archives are not supported");
        }
        let size64 = le64(&record, 40).unwrap();
        let offset64 = le64(&record, 48).unwrap();
        // Every non-sentinel ZIP32 field must agree with its ZIP64 counterpart.
        if (count32 != u16::MAX && u64::from(count32) != count64)
            || (count_disk32 != u16::MAX && u64::from(count_disk32) != count_disk64)
            || (size32 != u32::MAX && u64::from(size32) != size64)
            || (offset32 != u32::MAX && u64::from(offset32) != offset64)
        {
            bail!("ZIP32 and ZIP64 directory declarations disagree");
        }
        (count64, size64, offset64)
    } else {
        if disk != 0 || directory_disk != 0 || count_disk32 != count32 {
            bail!("multi-disk ZIP archives are not supported");
        }
        (u64::from(count32), u64::from(size32), u64::from(offset32))
    };
    if entries > max_entries as u64 {
        crate::resource_limit!("ZIP archive has too many entries: {entries}");
    }
    let central_end = central_offset
        .checked_add(central_size)
        .context("ZIP central-directory extent overflowed")?;
    let expected_end = if uses_zip64 {
        eocd_position - 20 - 56
    } else {
        eocd_position
    };
    if central_end != expected_end || central_end > archive_len {
        bail!("ZIP central-directory extent does not match its footer");
    }
    reader.seek(SeekFrom::Start(central_offset))?;
    let mut declared = 0_u64;
    let mut copied_filename_ceiling = 0_usize;
    let mut has_epub_mimetype = false;
    let mut has_epub_container = false;
    let mut has_comic_image = false;
    let mut mimetype_entry = None;
    for _ in 0..entries {
        check_cancelled(is_cancelled)?;
        let mut header = [0; 46];
        read_exact_cancellable(&mut reader, &mut header, is_cancelled)?;
        if &header[..4] != b"PK\x01\x02" {
            bail!("malformed ZIP central-directory entry");
        }
        let name_len = usize::from(le16(&header, 28).unwrap());
        let extra_len = usize::from(le16(&header, 30).unwrap());
        // zip may replace the raw name with an Info-ZIP Unicode Path value
        // held in the extra fields. Otherwise lossy UTF-8 decoding expands
        // each invalid raw byte to at most three bytes.
        let copied_name = name_len.checked_mul(3).context("ZIP filename overflowed")?;
        copied_filename_ceiling = copied_filename_ceiling
            .checked_add(copied_name.max(extra_len))
            .context("ZIP filename byte total overflowed")?;
        let comment_len = usize::from(le16(&header, 32).unwrap());
        let variable_len = name_len
            .checked_add(extra_len)
            .and_then(|v| v.checked_add(comment_len))
            .context("ZIP entry metadata overflowed")?;
        let mut variable = vec![0; variable_len];
        read_exact_cancellable(&mut reader, &mut variable, is_cancelled)?;
        let raw_name = &variable[..name_len];
        let name = effective_name(raw_name, &variable[name_len..name_len + extra_len])?;
        let (uncompressed_size, compressed_size, local_offset) = effective_entry_sizes_and_offset(
            le32(&header, 24).unwrap(),
            le32(&header, 20).unwrap(),
            le32(&header, 42).unwrap(),
            &variable[name_len..name_len + extra_len],
        )?;
        if name == b"mimetype" {
            mimetype_entry = Some((
                le16(&header, 8).unwrap(),
                le16(&header, 10).unwrap(),
                compressed_size,
                uncompressed_size,
                local_offset,
            ));
        }
        has_epub_container |= name == b"META-INF/container.xml";
        has_comic_image |= comic_image_name(&name);
        declared = declared
            .checked_add(uncompressed_size)
            .context("ZIP declared size overflowed")?;
    }
    if reader.stream_position()? != central_end {
        bail!("ZIP central-directory size does not match its entries");
    }
    if let Some(entry) = mimetype_entry {
        has_epub_mimetype = epub_mimetype_matches(&mut reader, entry, is_cancelled)?;
    }
    Ok(ZipPreflight {
        entries: usize::try_from(entries).context("ZIP entry count cannot be represented")?,
        declared_uncompressed_bytes: declared,
        central_directory_bytes: usize::try_from(central_size)
            .context("ZIP central-directory size cannot be represented")?,
        copied_filename_ceiling,
        has_epub_mimetype,
        has_epub_container,
        has_comic_image,
    })
}

fn effective_name(raw_name: &[u8], extra: &[u8]) -> Result<Vec<u8>> {
    let mut name = raw_name.to_vec();
    let mut at = 0_usize;
    while at < extra.len() {
        let id = le16(extra, at).context("malformed ZIP extra field")?;
        let len = usize::from(le16(extra, at + 2).context("malformed ZIP extra field")?);
        let value = extra
            .get(
                at + 4
                    ..at.checked_add(4 + len)
                        .context("ZIP extra field overflowed")?,
            )
            .context("truncated ZIP extra field")?;
        if id == 0x7075 {
            let version = value.first().context("Unicode path field is empty")?;
            if *version != 1 || value.len() < 5 {
                bail!("invalid Unicode path field");
            }
            let expected = le32(value, 1).unwrap();
            if crc32fast::hash(&name) != expected {
                bail!("Unicode path checksum does not match its filename");
            }
            std::str::from_utf8(&value[5..]).context("Unicode path is not UTF-8")?;
            name = value[5..].to_vec();
        }
        at = at
            .checked_add(4 + len)
            .context("ZIP extra field overflowed")?;
    }
    Ok(name)
}

fn epub_mimetype_matches<R: Read + Seek>(
    reader: &mut R,
    (flags, method, compressed_size, uncompressed_size, offset): (u16, u16, u64, u64, u64),
    cancelled: Option<&dyn Fn() -> bool>,
) -> Result<bool> {
    const MIME: &[u8] = b"application/epub+zip";
    if flags & 1 != 0
        || method != 0
        || compressed_size != MIME.len() as u64
        || uncompressed_size != MIME.len() as u64
    {
        return Ok(false);
    }
    reader.seek(SeekFrom::Start(offset))?;
    let mut header = [0_u8; 30];
    read_exact_cancellable(reader, &mut header, cancelled)?;
    if &header[..4] != b"PK\x03\x04" || le16(&header, 8) != Some(0) {
        return Ok(false);
    }
    let variable = u64::from(le16(&header, 26).unwrap()) + u64::from(le16(&header, 28).unwrap());
    reader.seek(SeekFrom::Current(variable as i64))?;
    let mut value = [0_u8; MIME.len()];
    read_exact_cancellable(reader, &mut value, cancelled)?;
    Ok(value == MIME)
}

fn comic_image_name(name: &[u8]) -> bool {
    [
        b".jpg".as_slice(),
        b".jpeg",
        b".png",
        b".gif",
        b".webp",
        b".bmp",
    ]
    .iter()
    .any(|extension| {
        name.len() >= extension.len()
            && name[name.len() - extension.len()..].eq_ignore_ascii_case(extension)
    })
}

pub(crate) fn metadata_allocation_ceiling(preflight: ZipPreflight) -> Option<usize> {
    preflight
        .central_directory_bytes
        .checked_mul(16)?
        .checked_add(preflight.entries.checked_mul(512)?)?
        .checked_add(64 * 1024)
}

fn has_earlier_zip_candidate<R: Read + Seek>(
    reader: &mut R,
    selected: u64,
    archive_len: u64,
    max_entries: usize,
    cancelled: Option<&dyn Fn() -> bool>,
) -> Result<bool> {
    reader.seek(SeekFrom::Start(0))?;
    let mut consumed = 0_u64;
    let mut window = 0_u32;
    let mut seen = 0_usize;
    let mut buffer = [0_u8; 64 * 1024];
    while consumed < archive_len {
        check_cancelled(cancelled)?;
        let read_len = usize::try_from(archive_len - consumed)
            .unwrap_or(usize::MAX)
            .min(buffer.len());
        let read = reader.read(&mut buffer[..read_len])?;
        if read == 0 {
            break;
        }
        let resume = reader.stream_position()?;
        for (index, byte) in buffer[..read].iter().enumerate() {
            window = (window << 8) | u32::from(*byte);
            seen += 1;
            if seen < 4 {
                continue;
            }
            let position = consumed + index as u64 - 3;
            if window == u32::from_be_bytes(*b"PK\x05\x06") && position != selected {
                reader.seek(SeekFrom::Start(position))?;
                let mut header = [0_u8; 22];
                let read = reader.read_exact(&mut header);
                reader.seek(SeekFrom::Start(resume))?;
                let entries = usize::from(le16(&header, 10).unwrap());
                let files_on_disk = usize::from(le16(&header, 8).unwrap());
                let directory_end = u64::from(le32(&header, 16).unwrap())
                    .checked_add(u64::from(le32(&header, 12).unwrap()));
                let candidate_fits = read.is_ok()
                    && position
                        .checked_add(22 + u64::from(le16(&header, 20).unwrap()))
                        .is_some_and(|candidate_end| candidate_end <= archive_len);
                // zip 8.4 allocates from this field before rejecting a
                // disagreeing alternate candidate and falling back.
                if candidate_fits && files_on_disk > max_entries {
                    crate::resource_limit!(
                        "ZIP alternate footer has too many entries: {files_on_disk}"
                    );
                }
                if read.is_ok()
                    && le16(&header, 4) == Some(0)
                    && le16(&header, 6) == Some(0)
                    && le16(&header, 8) == Some(entries as u16)
                    && directory_end == Some(position)
                    && candidate_fits
                {
                    return Ok(true);
                }
            }
        }
        consumed += read as u64;
    }
    Ok(false)
}

fn read_exact_cancellable(
    reader: &mut impl Read,
    mut bytes: &mut [u8],
    cancelled: Option<&dyn Fn() -> bool>,
) -> Result<()> {
    while !bytes.is_empty() {
        check_cancelled(cancelled)?;
        let length = bytes.len().min(64 * 1024);
        let read = reader.read(&mut bytes[..length])?;
        if read == 0 {
            bail!("unexpected end of ZIP archive");
        }
        bytes = &mut bytes[read..];
    }
    Ok(())
}

fn check_cancelled(cancelled: Option<&dyn Fn() -> bool>) -> Result<()> {
    if cancelled.is_some_and(|f| f()) {
        bail!("document open cancelled");
    }
    Ok(())
}
fn le16(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?))
}
fn le32(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}
fn le64(data: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_le_bytes(data.get(at..at + 8)?.try_into().ok()?))
}
fn effective_entry_sizes_and_offset(
    uncompressed32: u32,
    compressed32: u32,
    offset32: u32,
    extra: &[u8],
) -> Result<(u64, u64, u64)> {
    let mut at = 0_usize;
    let mut values = (
        u64::from(uncompressed32),
        u64::from(compressed32),
        u64::from(offset32),
    );
    let mut saw_zip64 = false;
    while at.checked_add(4).is_some_and(|end| end <= extra.len()) {
        let id = le16(extra, at).context("malformed ZIP extra field")?;
        let len = usize::from(le16(extra, at + 2).context("malformed ZIP extra field")?);
        let value = extra
            .get(
                at + 4
                    ..at.checked_add(4 + len)
                        .context("ZIP extra field overflowed")?,
            )
            .context("truncated ZIP extra field")?;
        if id == 1 {
            if saw_zip64 {
                bail!("duplicate ZIP64 extended-information field");
            }
            saw_zip64 = true;
            let mut cursor = 0;
            for (declared, effective, label) in [
                (uncompressed32, &mut values.0, "uncompressed size"),
                (compressed32, &mut values.1, "compressed size"),
                (offset32, &mut values.2, "local-header offset"),
            ] {
                if len >= 24 || declared == u32::MAX {
                    let replacement =
                        le64(value, cursor).with_context(|| format!("ZIP64 {label} is missing"))?;
                    if declared != u32::MAX && replacement != u64::from(declared) {
                        bail!("ZIP32 and ZIP64 {label} disagree");
                    }
                    *effective = replacement;
                    cursor += 8;
                }
            }
        }
        at = at
            .checked_add(4 + len)
            .context("ZIP extra field overflowed")?;
    }
    if at != extra.len() {
        bail!("malformed ZIP extra field");
    }
    for (declared, label) in [
        (uncompressed32, "uncompressed size"),
        (compressed32, "compressed size"),
        (offset32, "local-header offset"),
    ] {
        if declared == u32::MAX && !saw_zip64 {
            bail!("ZIP64 {label} is missing");
        }
    }
    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::io::{Cursor, Write};
    use zip::write::SimpleFileOptions;

    fn archive(payload: &[u8]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        writer
            .start_file("page.bin", SimpleFileOptions::default())
            .unwrap();
        writer.write_all(payload).unwrap();
        writer.finish().unwrap().into_inner()
    }

    fn named_archive(names: &[&str]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for name in names {
            writer
                .start_file(*name, SimpleFileOptions::default())
                .unwrap();
            writer.write_all(b"data").unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    fn zip64_mimetype_archive(extra_values: &[u64], raw: (u32, u32, u32)) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let stored =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        writer.start_file("mimetype", stored).unwrap();
        writer.write_all(b"application/epub+zip").unwrap();
        writer.start_file("META-INF/container.xml", stored).unwrap();
        writer.write_all(b"container").unwrap();
        let mut bytes = writer.finish().unwrap().into_inner();
        let central = bytes
            .windows(4)
            .position(|window| window == b"PK\x01\x02")
            .unwrap();
        bytes[central + 20..central + 24].copy_from_slice(&raw.0.to_le_bytes());
        bytes[central + 24..central + 28].copy_from_slice(&raw.1.to_le_bytes());
        bytes[central + 42..central + 46].copy_from_slice(&raw.2.to_le_bytes());
        let name_len = usize::from(le16(&bytes, central + 28).unwrap());
        let extra = central + 46 + name_len;
        let mut field = Vec::new();
        field.extend_from_slice(&1_u16.to_le_bytes());
        field.extend_from_slice(&(extra_values.len() as u16 * 8).to_le_bytes());
        for (index, value) in extra_values.iter().enumerate() {
            debug_assert_eq!(index * 8 + 4, field.len());
            field.extend_from_slice(&value.to_le_bytes());
        }
        bytes.splice(extra..extra, field.iter().copied());
        bytes[central + 30..central + 32]
            .copy_from_slice(&((extra_values.len() * 8 + 4) as u16).to_le_bytes());
        let eocd = bytes.len() - 22;
        let central_size = le32(&bytes, eocd + 12).unwrap() + extra_values.len() as u32 * 8 + 4;
        bytes[eocd + 12..eocd + 16].copy_from_slice(&central_size.to_le_bytes());
        bytes
    }

    #[test]
    fn preflight_is_cancellable_before_directory_work() {
        let error = preflight(Cursor::new(archive(b"page")), 10, Some(&|| true)).unwrap_err();
        assert!(error.to_string().contains("cancelled"));
    }

    #[test]
    fn preflight_observes_cancellation_after_inspection_starts() {
        let checks = Cell::new(0);
        let cancelled = || {
            checks.set(checks.get() + 1);
            checks.get() > 3
        };

        let error = preflight(
            Cursor::new(named_archive(&["one", "two", "three"])),
            10,
            Some(&cancelled),
        )
        .unwrap_err();

        assert!(checks.get() > 3);
        assert!(error.to_string().contains("cancelled"));
    }

    #[test]
    fn preflight_requires_the_epub_mimetype_value_and_classifies_comic_names() {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let stored =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        writer.start_file("mimetype", stored).unwrap();
        writer.write_all(b"application/not-epub").unwrap();
        writer.start_file("META-INF/container.xml", stored).unwrap();
        writer.write_all(b"data").unwrap();
        let epub = preflight(Cursor::new(writer.finish().unwrap().into_inner()), 10, None).unwrap();
        assert!(!epub.has_epub_mimetype);
        assert!(epub.has_epub_container);
        assert!(!epub.has_comic_image);

        let comic = preflight(Cursor::new(named_archive(&["pages/001.BMP"])), 10, None).unwrap();
        assert!(comic.has_comic_image);
        assert!(!comic.has_epub_mimetype);
    }

    #[test]
    fn unicode_path_fields_use_the_consumers_effective_name() {
        let raw = b"page";
        let unicode = b"pages/001.jpg";
        let mut extra = Vec::new();
        extra.extend_from_slice(&0x7075_u16.to_le_bytes());
        extra.extend_from_slice(&(5_u16 + unicode.len() as u16).to_le_bytes());
        extra.push(1);
        extra.extend_from_slice(&crc32fast::hash(raw).to_le_bytes());
        extra.extend_from_slice(unicode);

        assert_eq!(effective_name(raw, &extra).unwrap(), unicode);
        assert!(comic_image_name(&effective_name(raw, &extra).unwrap()));
    }

    #[test]
    fn payload_eocd_false_candidates_do_not_trigger_prefix_rescans() {
        let mut false_footer = [0_u8; 22];
        false_footer[..4].copy_from_slice(b"PK\x05\x06");
        false_footer[4..6].copy_from_slice(&1_u16.to_le_bytes());
        let payload = false_footer.repeat(100_000);
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        writer
            .start_file(
                "page.bin",
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored),
            )
            .unwrap();
        writer.write_all(&payload).unwrap();
        let bytes = writer.finish().unwrap().into_inner();
        let byte_len = bytes.len();
        struct CountingReader {
            inner: Cursor<Vec<u8>>,
            read: usize,
        }
        impl Read for CountingReader {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                let read = self.inner.read(buffer)?;
                self.read += read;
                Ok(read)
            }
        }
        impl Seek for CountingReader {
            fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
                self.inner.seek(position)
            }
        }
        let mut reader = CountingReader {
            inner: Cursor::new(bytes),
            read: 0,
        };
        preflight(&mut reader, 10, None).unwrap();
        assert!(
            reader.read < byte_len * 2 + 200_000,
            "preflight read {} bytes from a {byte_len}-byte archive",
            reader.read,
        );
    }

    #[test]
    fn zip32_and_zip64_sentinel_mismatches_are_rejected() {
        let mut zip32 = archive(b"page");
        let eocd = zip32.len() - 22;
        zip32[eocd + 8..eocd + 10].copy_from_slice(&0_u16.to_le_bytes());
        assert!(preflight(Cursor::new(zip32), 10, None).is_err());

        let mut zip64 = vec![0_u8; 56 + 20 + 22];
        zip64[..4].copy_from_slice(b"PK\x06\x06");
        zip64[4..12].copy_from_slice(&44_u64.to_le_bytes());
        zip64[40..48].copy_from_slice(&1_u64.to_le_bytes());
        zip64[56..60].copy_from_slice(b"PK\x06\x07");
        zip64[72..76].copy_from_slice(&1_u32.to_le_bytes());
        zip64[76..80].copy_from_slice(b"PK\x05\x06");
        zip64[84..86].copy_from_slice(&u16::MAX.to_le_bytes());
        zip64[86..88].copy_from_slice(&u16::MAX.to_le_bytes());
        let error = preflight(Cursor::new(zip64), 10, None).unwrap_err();
        assert!(error.to_string().contains("disagree"));
    }

    #[test]
    fn alternate_eocd_candidates_are_rejected() {
        let mut bytes = archive(b"page");
        bytes.extend_from_slice(&[
            b'P', b'K', 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]);

        let error = preflight(Cursor::new(bytes), 10, None).unwrap_err();

        assert!(error.to_string().contains("multiple ZIP"));
    }

    #[test]
    fn alternate_comment_candidate_bounds_files_on_disk_before_fallback() {
        let mut bytes = archive(b"page");
        bytes.truncate(bytes.len() - 22);
        let mut candidate = [0_u8; 22];
        candidate[..4].copy_from_slice(b"PK\x05\x06");
        candidate[8..10].copy_from_slice(&u16::MAX.to_le_bytes());
        candidate[10..12].copy_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&candidate);
        bytes.extend_from_slice(&[0; 22]);
        let selected = bytes.len() - 22;
        bytes[selected..selected + 4].copy_from_slice(b"PK\x05\x06");

        let error = preflight(Cursor::new(bytes), 10, None).unwrap_err();

        assert!(error.to_string().contains("too many entries"));
    }

    #[test]
    fn zip64_entry_sizes_cannot_override_zip32_or_repeat() {
        let mut conflicting = Vec::new();
        conflicting.extend_from_slice(&1_u16.to_le_bytes());
        conflicting.extend_from_slice(&24_u16.to_le_bytes());
        conflicting.extend_from_slice(&9_u64.to_le_bytes());
        conflicting.extend_from_slice(&[0; 16]);
        assert!(effective_entry_sizes_and_offset(7, 0, 0, &conflicting).is_err());

        let mut duplicate = conflicting;
        duplicate[4..12].copy_from_slice(&7_u64.to_le_bytes());
        duplicate.extend_from_slice(&1_u16.to_le_bytes());
        duplicate.extend_from_slice(&8_u16.to_le_bytes());
        duplicate.extend_from_slice(&7_u64.to_le_bytes());
        assert!(effective_entry_sizes_and_offset(7, 0, 0, &duplicate).is_err());
    }

    #[test]
    fn zip64_entry_fields_resolve_sentinels_and_reject_decoy_offsets() {
        let mut sentinel = Vec::new();
        sentinel.extend_from_slice(&1_u16.to_le_bytes());
        sentinel.extend_from_slice(&24_u16.to_le_bytes());
        sentinel.extend_from_slice(&20_u64.to_le_bytes());
        sentinel.extend_from_slice(&20_u64.to_le_bytes());
        sentinel.extend_from_slice(&42_u64.to_le_bytes());
        assert_eq!(
            effective_entry_sizes_and_offset(u32::MAX, u32::MAX, u32::MAX, &sentinel).unwrap(),
            (20, 20, 42),
        );

        assert!(effective_entry_sizes_and_offset(20, 20, 41, &sentinel).is_err());
    }

    #[test]
    fn preflight_and_zip_consumer_agree_on_zip64_mimetype_entries() {
        let sentinel = zip64_mimetype_archive(&[20, 20, 0], (u32::MAX, u32::MAX, u32::MAX));
        let admitted = preflight(Cursor::new(&sentinel), 10, None).unwrap();
        assert!(admitted.has_epub_mimetype);
        let mut archive = zip::ZipArchive::new(Cursor::new(&sentinel)).unwrap();
        let mut value = String::new();
        archive
            .by_name("mimetype")
            .unwrap()
            .read_to_string(&mut value)
            .unwrap();
        assert_eq!(value, "application/epub+zip");

        let short = zip64_mimetype_archive(&[20], (20, u32::MAX, 0));
        assert!(
            preflight(Cursor::new(short), 10, None)
                .unwrap()
                .has_epub_mimetype
        );
    }

    #[test]
    fn preflight_rejects_a_zip64_offset_that_overrides_a_zip32_decoy() {
        let decoy = zip64_mimetype_archive(&[20, 20, 0], (20, 20, 1));
        assert!(preflight(Cursor::new(decoy), 10, None).is_err());
    }
}
