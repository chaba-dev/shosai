//! Gate 0 EPUB font-loading spike. This is deliberately test-only and proves a
//! bounded archive-resource-to-cosmic-text path without changing production.

use std::{collections::HashMap, error::Error, io::Read, sync::Arc};

use cosmic_text::{
    Attrs, Buffer, Family, FontSystem, Metrics, Shaping,
    fontdb::{Database, Query, Source},
};
use lightningcss::{
    properties::font::FontFamily,
    rules::{
        CssRule,
        font_face::{FontFaceProperty, FontFormat as CssFontFormat, Source as CssFontSource},
    },
    stylesheet::{ParserOptions, StyleSheet},
    traits::ToCss,
};
use shosai_core::epub::CanonicalEpubPath;

const CSS: &str = include_str!("../../tests/fixtures/native-font-face.css");
const BOOK_A_TTF: &[u8] = include_bytes!("../../tests/fonts/epub/book-a.ttf");
const BOOK_A_OTF: &[u8] = include_bytes!("../../tests/fonts/epub/book-a.otf");
const BOOK_A_WOFF: &[u8] = include_bytes!("../../tests/fonts/epub/book-a.woff");
const BOOK_A_WOFF2: &[u8] = include_bytes!("../../tests/fonts/epub/book-a.woff2");
const BOOK_B_TTF: &[u8] = include_bytes!("../../tests/fonts/epub/book-b.ttf");
const OTHER_FAMILY_TTF: &[u8] = include_bytes!("../../tests/fonts/epub/other-family.ttf");
const FAMILY: &str = "Shosai EPUB Fixture";
const STYLESHEET_PATH: &str = "OPS/styles/book.css";
const MAX_COMPRESSED_FONT_BYTES: usize = 4 * 1024;
const MAX_DECODED_FONT_BYTES: usize = 8 * 1024;
const MAX_FACES_PER_BOOK: usize = 4;
const MAX_TABLES_PER_FONT: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FontFormat {
    TrueType,
    OpenType,
    Woff,
    Woff2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FormatHint {
    Absent,
    Supported(FontFormat),
    Unsupported,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum FontSource {
    Local(String),
    Url {
        reference: String,
        format: FormatHint,
        has_technology: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FontFace {
    family: String,
    style: String,
    weight: String,
    sources: Vec<FontSource>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Attempt {
    Rejected { source: String, reason: String },
    Loaded { path: String, format: FontFormat },
}

#[derive(Debug)]
struct LoadedFace {
    attempts: Vec<Attempt>,
    decoded_bytes: usize,
}

#[derive(Default)]
struct BookFonts {
    database: Database,
    decoded_bytes: usize,
    faces: usize,
}

fn css_text<T: ToCss>(value: &T) -> String {
    value
        .to_css_string(Default::default())
        .expect("fixture descriptor must serialize")
}

fn font_format(format: &CssFontFormat<'_>) -> FormatHint {
    match format {
        CssFontFormat::TrueType => FormatHint::Supported(FontFormat::TrueType),
        CssFontFormat::OpenType => FormatHint::Supported(FontFormat::OpenType),
        CssFontFormat::WOFF => FormatHint::Supported(FontFormat::Woff),
        CssFontFormat::WOFF2 => FormatHint::Supported(FontFormat::Woff2),
        _ => FormatHint::Unsupported,
    }
}

fn parse_font_faces(css: &str) -> Vec<FontFace> {
    let sheet = StyleSheet::parse(css, ParserOptions::default())
        .expect("font-face fixture must be valid CSS");
    sheet
        .rules
        .0
        .iter()
        .filter_map(|rule| match rule {
            CssRule::FontFace(rule) => Some(rule),
            _ => None,
        })
        .map(|rule| {
            let mut family = None;
            let mut style = "normal".to_owned();
            let mut weight = "normal".to_owned();
            let mut sources = Vec::new();
            for property in &rule.properties {
                match property {
                    FontFaceProperty::FontFamily(FontFamily::FamilyName(value)) => {
                        family = Some(css_text(value).trim_matches('"').to_owned());
                    }
                    FontFaceProperty::FontFamily(FontFamily::Generic(_)) => {
                        panic!("@font-face requires a custom family")
                    }
                    FontFaceProperty::FontStyle(value) => style = css_text(value),
                    FontFaceProperty::FontWeight(value) => weight = css_text(value),
                    FontFaceProperty::Source(values) => {
                        sources.extend(values.iter().map(|source| {
                            match source {
                                CssFontSource::Local(value) => FontSource::Local(css_text(value)),
                                CssFontSource::Url(value) => FontSource::Url {
                                    reference: value.url.url.to_string(),
                                    format: value
                                        .format
                                        .as_ref()
                                        .map_or(FormatHint::Absent, font_format),
                                    has_technology: !value.tech.is_empty(),
                                },
                            }
                        }));
                    }
                    _ => {}
                }
            }
            FontFace {
                family: family.expect("@font-face fixture requires font-family"),
                style,
                weight,
                sources,
            }
        })
        .collect()
}

fn sniff_format(bytes: &[u8]) -> Result<FontFormat, String> {
    match bytes.get(..4) {
        Some([0, 1, 0, 0]) => Ok(FontFormat::TrueType),
        Some(b"OTTO") => Ok(FontFormat::OpenType),
        Some(b"wOFF") => Ok(FontFormat::Woff),
        Some(b"wOF2") => Ok(FontFormat::Woff2),
        _ => Err("unsupported font signature".into()),
    }
}

fn read_u16(bytes: &[u8], offset: usize) -> Result<usize, String> {
    let value = bytes
        .get(offset..offset + 2)
        .ok_or_else(|| "compressed font header is truncated".to_owned())?;
    Ok(u16::from_be_bytes(value.try_into().unwrap()) as usize)
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<usize, String> {
    let value = bytes
        .get(offset..offset + 4)
        .ok_or_else(|| "compressed font header is truncated".to_owned())?;
    Ok(u32::from_be_bytes(value.try_into().unwrap()) as usize)
}

fn aligned(value: usize) -> Result<usize, String> {
    value
        .checked_add(3)
        .map(|value| value & !3)
        .ok_or_else(|| "font size arithmetic overflowed".to_owned())
}

fn initial_sfnt_size(table_count: usize) -> Result<usize, String> {
    16usize
        .checked_mul(table_count)
        .and_then(|directory| 12usize.checked_add(directory))
        .ok_or_else(|| "font size arithmetic overflowed".to_owned())
}

fn preflight_header(bytes: &[u8]) -> Result<usize, String> {
    if bytes.get(4..8) == Some(b"ttcf") {
        return Err("font collections are unsupported by the spike".into());
    }
    let table_count = read_u16(bytes, 12)?;
    if table_count == 0 || table_count > MAX_TABLES_PER_FONT {
        return Err("font table count exceeds the spike limit".into());
    }
    if read_u32(bytes, 16)? > MAX_DECODED_FONT_BYTES {
        return Err("font declares an oversized decoded payload".into());
    }
    Ok(table_count)
}

fn preflight_woff1(bytes: &[u8]) -> Result<(), String> {
    let table_count = preflight_header(bytes)?;
    let directory_end = 44usize
        .checked_add(
            20usize
                .checked_mul(table_count)
                .ok_or_else(|| "font size arithmetic overflowed".to_owned())?,
        )
        .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
    if directory_end > bytes.len() {
        return Err("WOFF table directory is truncated".into());
    }
    let mut reconstructed = initial_sfnt_size(table_count)?;
    for index in 0..table_count {
        let entry = 44 + index * 20;
        let offset = read_u32(bytes, entry + 4)?;
        let compressed = read_u32(bytes, entry + 8)?;
        let original = read_u32(bytes, entry + 12)?;
        if offset
            .checked_add(compressed)
            .is_none_or(|end| end > bytes.len())
        {
            return Err("WOFF table data is outside the input".into());
        }
        let emitted = if compressed < original {
            original
        } else {
            compressed
        };
        reconstructed = reconstructed
            .checked_add(aligned(emitted)?)
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        if reconstructed > MAX_DECODED_FONT_BYTES {
            return Err("WOFF table data exceeds the spike output limit".into());
        }
    }
    Ok(())
}

fn read_base128(bytes: &[u8], cursor: &mut usize) -> Result<usize, String> {
    let mut value = 0usize;
    for index in 0..5 {
        let byte = *bytes
            .get(*cursor)
            .ok_or_else(|| "WOFF2 table directory is truncated".to_owned())?;
        *cursor += 1;
        if index == 0 && byte == 0x80 {
            return Err("WOFF2 length is not canonical".into());
        }
        value = value
            .checked_mul(128)
            .and_then(|value| value.checked_add(usize::from(byte & 0x7f)))
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err("WOFF2 length is too large".into())
}

fn preflight_woff2(bytes: &[u8]) -> Result<(), String> {
    let table_count = preflight_header(bytes)?;
    let mut cursor = 48;
    let mut reconstructed = initial_sfnt_size(table_count)?;
    let mut transformed = 0usize;
    for _ in 0..table_count {
        let flags = *bytes
            .get(cursor)
            .ok_or_else(|| "WOFF2 table directory is truncated".to_owned())?;
        cursor += 1;
        let tag_index = flags & 0x3f;
        let custom_tag = if tag_index == 0x3f {
            let tag = bytes
                .get(cursor..cursor + 4)
                .ok_or_else(|| "WOFF2 table directory is truncated".to_owned())?;
            cursor += 4;
            Some(tag)
        } else {
            None
        };
        let original = read_base128(bytes, &mut cursor)?;
        let transform = flags >> 6;
        let glyf_or_loca =
            matches!(tag_index, 10 | 11) || matches!(custom_tag, Some(b"glyf") | Some(b"loca"));
        let is_transformed = if glyf_or_loca {
            transform == 0
        } else {
            transform != 0
        };
        let encoded = if is_transformed {
            read_base128(bytes, &mut cursor)?
        } else {
            original
        };
        reconstructed = reconstructed
            .checked_add(aligned(original)?)
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        transformed = transformed
            .checked_add(encoded)
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        if reconstructed > MAX_DECODED_FONT_BYTES || transformed > MAX_DECODED_FONT_BYTES {
            return Err("WOFF2 table data exceeds the spike output limit".into());
        }
    }
    Ok(())
}

fn bounded_read(reader: impl Read, expected: usize) -> Result<Vec<u8>, Box<dyn Error>> {
    if expected > MAX_DECODED_FONT_BYTES {
        return Err("decoder output exceeds the spike limit".into());
    }
    let mut output = Vec::with_capacity(expected);
    reader.take(expected as u64 + 1).read_to_end(&mut output)?;
    if output.len() != expected {
        return Err("decoder output length does not match the table directory".into());
    }
    Ok(output)
}

fn decode_woff1(bytes: &[u8]) -> Result<Vec<u8>, String> {
    preflight_woff1(bytes)?;
    wuff::decompress_woff1_with_custom_z(bytes, &mut |compressed, expected| {
        bounded_read(flate2::read::ZlibDecoder::new(compressed), expected)
    })
    .map_err(|_| "WOFF decoding failed".to_owned())
}

fn decode_woff2(bytes: &[u8]) -> Result<Vec<u8>, String> {
    preflight_woff2(bytes)?;
    wuff::decompress_woff2_with_custom_brotli(bytes, &mut |compressed, expected| {
        if expected > MAX_DECODED_FONT_BYTES {
            return Err("WOFF2 table data exceeds the spike output limit".into());
        }
        bounded_read(
            brotli_decompressor::Decompressor::new(compressed, 4096),
            expected,
        )
    })
    .map_err(|_| "WOFF2 decoding failed".to_owned())
}

fn decode_font(
    bytes: &[u8],
    declared: Option<FontFormat>,
) -> Result<(FontFormat, Vec<u8>), String> {
    if bytes.len() > MAX_COMPRESSED_FONT_BYTES {
        return Err("compressed font exceeds the spike input limit".into());
    }
    let format = sniff_format(bytes)?;
    if declared.is_some_and(|declared| declared != format) {
        return Err("font signature does not match its format descriptor".into());
    }
    let decoded = match format {
        FontFormat::TrueType | FontFormat::OpenType => bytes.to_vec(),
        FontFormat::Woff => decode_woff1(bytes)?,
        FontFormat::Woff2 => decode_woff2(bytes)?,
    };
    if decoded.len() > MAX_DECODED_FONT_BYTES {
        return Err("decoded font exceeds the spike output limit".into());
    }
    if !matches!(
        sniff_format(&decoded)?,
        FontFormat::TrueType | FontFormat::OpenType
    ) {
        return Err("decoder did not produce an sfnt font".into());
    }
    Ok((format, decoded))
}

fn stylesheet_directory(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(directory, _)| directory)
}

fn reject(attempts: &mut Vec<Attempt>, source: impl Into<String>, reason: impl Into<String>) {
    attempts.push(Attempt::Rejected {
        source: source.into(),
        reason: reason.into(),
    });
}

fn load_first_face(
    face: &FontFace,
    stylesheet_path: &str,
    resources: &HashMap<&str, &[u8]>,
    book: &mut BookFonts,
) -> Result<LoadedFace, Vec<Attempt>> {
    let mut attempts = Vec::new();
    for source in &face.sources {
        let (reference, declared) = match source {
            FontSource::Local(name) => {
                reject(
                    &mut attempts,
                    format!("local({name})"),
                    "local fonts are disabled",
                );
                continue;
            }
            FontSource::Url {
                reference,
                format,
                has_technology,
            } => {
                if *format == FormatHint::Unsupported {
                    reject(
                        &mut attempts,
                        reference,
                        "font format descriptor is unsupported",
                    );
                    continue;
                }
                if *has_technology {
                    reject(
                        &mut attempts,
                        reference,
                        "font technology descriptor is unsupported",
                    );
                    continue;
                }
                let declared = match format {
                    FormatHint::Absent => None,
                    FormatHint::Supported(format) => Some(*format),
                    FormatHint::Unsupported => unreachable!(),
                };
                (reference, declared)
            }
        };
        let resolved =
            match CanonicalEpubPath::resolve(stylesheet_directory(stylesheet_path), reference) {
                Ok(reference) if reference.fragment.is_none() => reference.path,
                Ok(_) => {
                    reject(
                        &mut attempts,
                        reference,
                        "font references cannot contain fragments",
                    );
                    continue;
                }
                Err(error) => {
                    reject(&mut attempts, reference, error.to_string());
                    continue;
                }
            };
        let path = resolved.as_str();
        let Some(bytes) = resources.get(path).copied() else {
            reject(&mut attempts, path, "font resource is missing");
            continue;
        };
        let (format, decoded) = match decode_font(bytes, declared) {
            Ok(decoded) => decoded,
            Err(error) => {
                reject(&mut attempts, path, error);
                continue;
            }
        };
        if book.faces >= MAX_FACES_PER_BOOK
            || book.decoded_bytes + decoded.len() > MAX_DECODED_FONT_BYTES
        {
            reject(&mut attempts, path, "per-book font budget is exhausted");
            continue;
        }
        let decoded_bytes = decoded.len();
        let ids = book
            .database
            .load_font_source(Source::Binary(Arc::new(decoded)));
        if ids.is_empty() {
            reject(&mut attempts, path, "fontdb rejected the decoded font");
            continue;
        }
        let matches_declared_family = ids.iter().any(|id| {
            book.database
                .face(*id)
                .is_some_and(|loaded| loaded.families.iter().any(|(name, _)| name == &face.family))
        });
        if !matches_declared_family {
            for id in ids {
                book.database.remove_face(id);
            }
            reject(
                &mut attempts,
                path,
                "font internal family does not match @font-face",
            );
            continue;
        }
        book.faces += ids.len();
        book.decoded_bytes += decoded_bytes;
        attempts.push(Attempt::Loaded {
            path: path.to_owned(),
            format,
        });
        return Ok(LoadedFace {
            attempts,
            decoded_bytes,
        });
    }
    Err(attempts)
}

fn one_source_face(path: &str, format: FontFormat) -> FontFace {
    FontFace {
        family: FAMILY.into(),
        style: "normal".into(),
        weight: "400".into(),
        sources: vec![FontSource::Url {
            reference: path.into(),
            format: FormatHint::Supported(format),
            has_technology: false,
        }],
    }
}

fn shaped_width(book: BookFonts) -> (f32, String) {
    let mut fonts = FontSystem::new_with_locale_and_db("en-US".into(), book.database);
    let mut buffer = Buffer::new(&mut fonts, Metrics::new(20.0, 28.0));
    buffer.set_size(&mut fonts, None, None);
    buffer.set_text(
        &mut fonts,
        "ABBA",
        &Attrs::new().family(Family::Name(FAMILY)),
        Shaping::Advanced,
        None,
    );
    buffer.shape_until_scroll(&mut fonts, false);
    let run = buffer
        .layout_runs()
        .next()
        .expect("fixture text must shape");
    let glyph = run
        .glyphs
        .first()
        .expect("fixture font must provide glyphs");
    let family = fonts
        .db()
        .face(glyph.font_id)
        .expect("glyph must reference the book database")
        .families[0]
        .0
        .clone();
    (run.line_w, family)
}

#[test]
fn font_face_descriptors_and_fallback_sources_are_preserved() {
    let faces = parse_font_faces(CSS);
    assert_eq!(faces.len(), 1);
    assert_eq!(faces[0].family, FAMILY);
    assert_eq!(faces[0].style, "normal");
    assert_eq!(faces[0].weight, "400");
    assert_eq!(
        faces[0].sources,
        [
            FontSource::Local("Forbidden system font".into()),
            FontSource::Url {
                reference: "https://example.invalid/remote.woff2".into(),
                format: FormatHint::Supported(FontFormat::Woff2),
                has_technology: false,
            },
            FontSource::Url {
                reference: "../fonts/missing.woff2".into(),
                format: FormatHint::Supported(FontFormat::Woff2),
                has_technology: false,
            },
            FontSource::Url {
                reference: "../fonts/book-a.woff2".into(),
                format: FormatHint::Supported(FontFormat::Woff2),
                has_technology: false,
            }
        ]
    );
}

#[test]
fn source_fallback_rejects_local_remote_and_missing_fonts_before_loading_archive_data() {
    let face = parse_font_faces(CSS).remove(0);
    let resources = HashMap::from([("OPS/fonts/book-a.woff2", BOOK_A_WOFF2)]);
    let loaded = load_first_face(
        &face,
        STYLESHEET_PATH,
        &resources,
        &mut BookFonts::default(),
    )
    .expect("final canonical archive source must load");

    assert_eq!(loaded.attempts.len(), 4);
    assert_eq!(
        loaded.attempts[0],
        Attempt::Rejected {
            source: "local(Forbidden system font)".into(),
            reason: "local fonts are disabled".into()
        }
    );
    assert_eq!(
        loaded.attempts[1],
        Attempt::Rejected {
            source: "https://example.invalid/remote.woff2".into(),
            reason: "resource reference has a foreign origin".into()
        }
    );
    assert_eq!(
        loaded.attempts[2],
        Attempt::Rejected {
            source: "OPS/fonts/missing.woff2".into(),
            reason: "font resource is missing".into()
        }
    );
    assert_eq!(
        loaded.attempts[3],
        Attempt::Loaded {
            path: "OPS/fonts/book-a.woff2".into(),
            format: FontFormat::Woff2
        }
    );
    assert!(loaded.decoded_bytes > BOOK_A_WOFF2.len());
}

#[test]
fn ttf_otf_woff_and_woff2_reach_fontdb_as_valid_sfnt_faces() {
    for (path, format, bytes) in [
        ("book-a.ttf", FontFormat::TrueType, BOOK_A_TTF),
        ("book-a.otf", FontFormat::OpenType, BOOK_A_OTF),
        ("book-a.woff", FontFormat::Woff, BOOK_A_WOFF),
        ("book-a.woff2", FontFormat::Woff2, BOOK_A_WOFF2),
    ] {
        let mut book = BookFonts::default();
        let resources = HashMap::from([(path, bytes)]);
        let loaded = load_first_face(
            &one_source_face(path, format),
            "book.css",
            &resources,
            &mut book,
        )
        .unwrap_or_else(|attempts| panic!("{path} failed: {attempts:?}"));
        assert_eq!(book.faces, 1, "{path}");
        assert!(loaded.decoded_bytes <= MAX_DECODED_FONT_BYTES, "{path}");
        assert_eq!(shaped_width(book).1, FAMILY, "{path}");
    }
}

#[test]
fn malformed_mismatched_and_oversized_fonts_fail_before_admission() {
    let mut oversized = BOOK_A_WOFF2.to_vec();
    oversized[16..20].copy_from_slice(&((MAX_DECODED_FONT_BYTES + 1) as u32).to_be_bytes());
    for (name, format, bytes, expected) in [
        (
            "corrupt.ttf",
            FontFormat::TrueType,
            &b"bad"[..],
            "unsupported font signature",
        ),
        (
            "mismatch.otf",
            FontFormat::OpenType,
            BOOK_A_TTF,
            "font signature does not match its format descriptor",
        ),
        (
            "oversized.woff2",
            FontFormat::Woff2,
            oversized.as_slice(),
            "font declares an oversized decoded payload",
        ),
    ] {
        let resources = HashMap::from([(name, bytes)]);
        let mut book = BookFonts::default();
        let attempts = load_first_face(
            &one_source_face(name, format),
            "book.css",
            &resources,
            &mut book,
        )
        .expect_err("invalid font must not load");
        assert_eq!(book.faces, 0);
        assert!(matches!(
            attempts.as_slice(),
            [Attempt::Rejected { reason, .. }] if reason == expected
        ));
    }
}

#[test]
fn oversized_table_directory_lengths_are_rejected_before_decoding() {
    let mut woff = BOOK_A_WOFF.to_vec();
    woff[16..20].copy_from_slice(&1u32.to_be_bytes());
    woff[56..60].copy_from_slice(&((MAX_DECODED_FONT_BYTES + 1) as u32).to_be_bytes());

    let mut woff2 = BOOK_A_WOFF2.to_vec();
    woff2[16..20].copy_from_slice(&1u32.to_be_bytes());
    woff2.splice(49..50, [0xc0, 0x01]);
    let woff2_length = woff2.len() as u32;
    woff2[8..12].copy_from_slice(&woff2_length.to_be_bytes());

    for (bytes, format, expected) in [
        (
            woff.as_slice(),
            FontFormat::Woff,
            "WOFF table data exceeds the spike output limit",
        ),
        (
            woff2.as_slice(),
            FontFormat::Woff2,
            "WOFF2 table data exceeds the spike output limit",
        ),
    ] {
        assert_eq!(decode_font(bytes, Some(format)).unwrap_err(), expected);
    }
}

#[test]
fn newly_loaded_face_must_itself_match_the_css_family() {
    let mut book = BookFonts::default();
    load_first_face(
        &one_source_face("matching.ttf", FontFormat::TrueType),
        "book.css",
        &HashMap::from([("matching.ttf", BOOK_A_TTF)]),
        &mut book,
    )
    .expect("matching fixture must load first");

    let attempts = load_first_face(
        &one_source_face("other.ttf", FontFormat::TrueType),
        "book.css",
        &HashMap::from([("other.ttf", OTHER_FAMILY_TTF)]),
        &mut book,
    )
    .expect_err("an existing matching face must not approve the new face");
    assert!(matches!(
        attempts.as_slice(),
        [Attempt::Rejected { reason, .. }]
            if reason == "font internal family does not match @font-face"
    ));
    assert_eq!(book.faces, 1);
    assert_eq!(book.database.len(), 1);
}

#[test]
fn unsupported_format_and_technology_sources_fall_back() {
    let css = format!(
        r#"@font-face {{
            font-family: "{FAMILY}";
            src:
                url("unsupported-format.ttf") format("svg"),
                url("unsupported-tech.ttf") format("truetype") tech(variations),
                url("supported.ttf") format("truetype");
        }}"#
    );
    let face = parse_font_faces(&css).remove(0);
    let resources = HashMap::from([
        ("unsupported-format.ttf", BOOK_A_TTF),
        ("unsupported-tech.ttf", BOOK_A_TTF),
        ("supported.ttf", BOOK_A_TTF),
    ]);
    let loaded = load_first_face(&face, "book.css", &resources, &mut BookFonts::default())
        .expect("supported fallback must load");

    assert!(matches!(
        loaded.attempts.as_slice(),
        [
            Attempt::Rejected { reason: format, .. },
            Attempt::Rejected { reason: technology, .. },
            Attempt::Loaded { path, .. }
        ] if format == "font format descriptor is unsupported"
            && technology == "font technology descriptor is unsupported"
            && path == "supported.ttf"
    ));
}

#[test]
fn identical_family_names_remain_isolated_per_book_font_system() {
    let load_book = |bytes| {
        let mut book = BookFonts::default();
        load_first_face(
            &one_source_face("font.ttf", FontFormat::TrueType),
            "book.css",
            &HashMap::from([("font.ttf", bytes)]),
            &mut book,
        )
        .expect("book fixture font must load");
        book
    };
    let (book_a_width, book_a_family) = shaped_width(load_book(BOOK_A_TTF));
    let (book_b_width, book_b_family) = shaped_width(load_book(BOOK_B_TTF));
    assert_eq!(book_a_family, FAMILY);
    assert_eq!(book_b_family, FAMILY);
    assert_ne!(book_a_width, book_b_width);

    let empty = Database::new();
    assert!(
        empty
            .query(&Query {
                families: &[cosmic_text::fontdb::Family::Name(FAMILY)],
                ..Query::default()
            })
            .is_none(),
        "per-book loading must not register the family globally"
    );
}
