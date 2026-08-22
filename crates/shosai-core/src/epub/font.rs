//! Book-local admission of author supplied EPUB fonts.

use std::{
    collections::{HashMap, HashSet},
    fmt,
    io::Read,
    sync::Arc,
};

use anyhow::{Result, bail};
use fontdb::{Database, Source};
use lightningcss::{
    properties::font::FontFamily,
    rules::{
        CssRule,
        font_face::{FontFaceProperty, FontFormat as CssFormat, Source as CssSource},
    },
    stylesheet::{ParserOptions, StyleSheet},
    traits::ToCss,
};

use super::{CanonicalEpubPath, Chapter, EpubLimits, style::EpubStyles, types::StoredEpubResource};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EpubFontFormat {
    TrueType,
    OpenType,
    Woff,
    Woff2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EpubFontStyle {
    Normal,
    Italic,
    Oblique,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EpubFontAttempt {
    Rejected {
        source: String,
        reason: String,
    },
    Loaded {
        path: CanonicalEpubPath,
        format: EpubFontFormat,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EpubFontFace {
    pub family: String,
    pub style: EpubFontStyle,
    pub weight: u16,
    pub path: CanonicalEpubPath,
    pub format: EpubFontFormat,
    pub decoded_bytes: usize,
    pub attempts: Vec<EpubFontAttempt>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EpubRejectedFontFace {
    pub family: String,
    pub attempts: Vec<EpubFontAttempt>,
}

/// Fonts admitted for one EPUB. The backing database and its binary sources are
/// deliberately private, and are destroyed together with this value.
pub struct EpubFontBook {
    database: Database,
    registered_ids: Vec<fontdb::ID>,
    faces: Vec<EpubFontFace>,
    rejected_faces: Vec<EpubRejectedFontFace>,
    decoded_bytes: usize,
}

impl fmt::Debug for EpubFontBook {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EpubFontBook")
            .field("faces", &self.faces)
            .field("rejected_faces", &self.rejected_faces)
            .field("decoded_bytes", &self.decoded_bytes)
            .finish_non_exhaustive()
    }
}

impl EpubFontBook {
    pub fn is_empty(&self) -> bool {
        self.faces.is_empty()
    }
    pub fn len(&self) -> usize {
        self.faces.len()
    }
    pub fn faces(&self) -> &[EpubFontFace] {
        &self.faces
    }
    pub fn rejected_faces(&self) -> &[EpubRejectedFontFace] {
        &self.rejected_faces
    }
    pub fn registered_face_count(&self) -> usize {
        self.database.len()
    }
    /// Borrow one admitted decoded sfnt face without exposing the book-local database.
    pub fn with_face_data<T>(&self, index: usize, read: impl FnOnce(&[u8], u32) -> T) -> Option<T> {
        self.database
            .with_face_data(*self.registered_ids.get(index)?, read)
    }
    pub fn contains_family(&self, family: &str) -> bool {
        self.faces
            .iter()
            .any(|face| face.family.eq_ignore_ascii_case(family))
    }

    pub(crate) fn new(
        chapters: &[Chapter],
        styles: &EpubStyles,
        resources: &HashMap<CanonicalEpubPath, StoredEpubResource>,
        limits: &EpubLimits,
    ) -> Result<Self> {
        if limits.max_font_faces_per_book == 0
            || limits.max_decoded_font_bytes == 0
            || limits.max_total_decoded_font_bytes == 0
            || limits.max_font_tables == 0
        {
            bail!("EPUB font limits must be non-zero");
        }
        let mut book = Self {
            database: Database::new(),
            registered_ids: Vec::new(),
            faces: Vec::new(),
            rejected_faces: Vec::new(),
            decoded_bytes: 0,
        };
        let mut seen = HashSet::new();
        for chapter in chapters {
            let Ok(document) = roxmltree::Document::parse(&chapter.content) else {
                continue;
            };
            let base = chapter.path.rsplit_once('/').map_or("", |(dir, _)| dir);
            let css =
                styles.document_css_with_owner(&document, base, Some(&chapter.path), limits)?;
            for descriptor in parse_faces(&css) {
                if !seen.insert(descriptor.clone()) {
                    continue;
                }
                if seen.len() > limits.max_font_faces_per_book {
                    book.rejected_faces.push(EpubRejectedFontFace {
                        family: descriptor.family,
                        attempts: vec![EpubFontAttempt::Rejected {
                            source: "@font-face".into(),
                            reason: "per-book font face limit is exhausted".into(),
                        }],
                    });
                    continue;
                }
                book.load_descriptor(descriptor, resources, limits);
            }
        }
        Ok(book)
    }

    fn load_descriptor(
        &mut self,
        descriptor: Descriptor,
        resources: &HashMap<CanonicalEpubPath, StoredEpubResource>,
        limits: &EpubLimits,
    ) {
        let mut attempts = Vec::new();
        for source in &descriptor.sources {
            let SourceDescriptor::Url {
                reference,
                format,
                technology,
            } = source
            else {
                reject(&mut attempts, source.label(), "local fonts are disabled");
                continue;
            };
            if *technology {
                reject(
                    &mut attempts,
                    reference,
                    "font technology descriptor is unsupported",
                );
                continue;
            }
            let declared = match format {
                FormatHint::Absent => None,
                FormatHint::Supported(v) => Some(*v),
                FormatHint::Unsupported => {
                    reject(
                        &mut attempts,
                        reference,
                        "font format descriptor is unsupported",
                    );
                    continue;
                }
            };
            let reference_path = match CanonicalEpubPath::from_protocol_uri(reference) {
                Ok(value) if value.fragment.is_none() => value.path,
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
            let Some(resource) = resources.get(&reference_path) else {
                reject(
                    &mut attempts,
                    reference_path.as_str(),
                    "font resource is missing",
                );
                continue;
            };
            let (format, decoded) = match decode_font(&resource.bytes, declared, limits) {
                Ok(value) => value,
                Err(error) => {
                    reject(&mut attempts, reference_path.as_str(), error);
                    continue;
                }
            };
            if self
                .decoded_bytes
                .checked_add(decoded.len())
                .is_none_or(|n| n > limits.max_total_decoded_font_bytes)
            {
                reject(
                    &mut attempts,
                    reference_path.as_str(),
                    "per-book decoded font budget is exhausted",
                );
                continue;
            }
            let decoded_bytes = decoded.len();
            let ids = self
                .database
                .load_font_source(Source::Binary(Arc::new(decoded)));
            if ids.is_empty() {
                reject(
                    &mut attempts,
                    reference_path.as_str(),
                    "fontdb rejected the decoded font",
                );
                continue;
            }
            if ids.len() != 1 {
                for id in ids {
                    self.database.remove_face(id);
                }
                reject(
                    &mut attempts,
                    reference_path.as_str(),
                    "font collections are unsupported",
                );
                continue;
            }
            attempts.push(EpubFontAttempt::Loaded {
                path: reference_path.clone(),
                format,
            });
            self.decoded_bytes += decoded_bytes;
            self.registered_ids.push(ids[0]);
            self.faces.push(EpubFontFace {
                family: descriptor.family,
                style: descriptor.style,
                weight: descriptor.weight,
                path: reference_path,
                format,
                decoded_bytes,
                attempts,
            });
            return;
        }
        self.rejected_faces.push(EpubRejectedFontFace {
            family: descriptor.family,
            attempts,
        });
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Descriptor {
    family: String,
    style: EpubFontStyle,
    weight: u16,
    sources: Vec<SourceDescriptor>,
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum SourceDescriptor {
    Local(String),
    Url {
        reference: String,
        format: FormatHint,
        technology: bool,
    },
}
impl SourceDescriptor {
    fn label(&self) -> String {
        match self {
            Self::Local(v) => format!("local({v})"),
            Self::Url { reference, .. } => reference.clone(),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum FormatHint {
    Absent,
    Supported(EpubFontFormat),
    Unsupported,
}

fn text<T: ToCss>(value: &T) -> Option<String> {
    value.to_css_string(Default::default()).ok()
}
fn parse_faces(css: &str) -> Vec<Descriptor> {
    let Ok(sheet) = StyleSheet::parse(css, ParserOptions::default()) else {
        return Vec::new();
    };
    fn collect(rules: &[CssRule<'_>], faces: &mut Vec<Descriptor>) {
        for rule in rules {
            if let CssRule::Media(media) = rule {
                if super::computed_style::bounded_media_query(&media.query)
                    && super::computed_style::screen_media_matches(&media.query)
                {
                    collect(&media.rules.0, faces);
                }
                continue;
            }
            let CssRule::FontFace(rule) = rule else {
                continue;
            };
            let Some(descriptor) = (|| -> Option<Descriptor> {
                let (mut family, mut style, mut weight, mut sources) =
                    (None, EpubFontStyle::Normal, 400, Vec::new());
                for property in &rule.properties {
                    match property {
                        FontFaceProperty::FontFamily(FontFamily::FamilyName(v)) => {
                            family = text(v).map(|v| v.trim_matches(['\'', '"']).to_owned())
                        }
                        FontFaceProperty::FontStyle(v) => {
                            style = match text(v)?.to_ascii_lowercase().as_str() {
                                "italic" => EpubFontStyle::Italic,
                                v if v.starts_with("oblique") => EpubFontStyle::Oblique,
                                _ => EpubFontStyle::Normal,
                            }
                        }
                        FontFaceProperty::FontWeight(v) => {
                            let v = text(v)?;
                            weight = if v.eq_ignore_ascii_case("normal") {
                                400
                            } else if v.eq_ignore_ascii_case("bold") {
                                700
                            } else {
                                v.parse().ok()?
                            };
                        }
                        FontFaceProperty::Source(values) => {
                            sources.extend(values.iter().map(|source| match source {
                                CssSource::Local(v) => {
                                    SourceDescriptor::Local(text(v).unwrap_or_default())
                                }
                                CssSource::Url(v) => SourceDescriptor::Url {
                                    reference: v.url.url.to_string(),
                                    format: v.format.as_ref().map_or(
                                        FormatHint::Absent,
                                        |f| match f {
                                            CssFormat::TrueType => {
                                                FormatHint::Supported(EpubFontFormat::TrueType)
                                            }
                                            CssFormat::OpenType => {
                                                FormatHint::Supported(EpubFontFormat::OpenType)
                                            }
                                            CssFormat::WOFF => {
                                                FormatHint::Supported(EpubFontFormat::Woff)
                                            }
                                            CssFormat::WOFF2 => {
                                                FormatHint::Supported(EpubFontFormat::Woff2)
                                            }
                                            _ => FormatHint::Unsupported,
                                        },
                                    ),
                                    technology: !v.tech.is_empty(),
                                },
                            }))
                        }
                        _ => {}
                    }
                }
                let family = family?;
                Some(Descriptor {
                    family,
                    style,
                    weight,
                    sources,
                })
            })() else {
                continue;
            };
            faces.push(descriptor);
        }
    }
    let mut faces = Vec::new();
    collect(&sheet.rules.0, &mut faces);
    faces
}

fn reject(
    attempts: &mut Vec<EpubFontAttempt>,
    source: impl Into<String>,
    reason: impl Into<String>,
) {
    attempts.push(EpubFontAttempt::Rejected {
        source: source.into(),
        reason: reason.into(),
    });
}
fn read_u16(b: &[u8], o: usize) -> std::result::Result<usize, String> {
    b.get(o..o + 2)
        .map(|v| u16::from_be_bytes(v.try_into().unwrap()) as usize)
        .ok_or_else(|| "compressed font header is truncated".into())
}
fn read_u32(b: &[u8], o: usize) -> std::result::Result<usize, String> {
    b.get(o..o + 4)
        .map(|v| u32::from_be_bytes(v.try_into().unwrap()) as usize)
        .ok_or_else(|| "compressed font header is truncated".into())
}
fn aligned(v: usize) -> std::result::Result<usize, String> {
    v.checked_add(3)
        .map(|v| v & !3)
        .ok_or_else(|| "font size arithmetic overflowed".into())
}
fn header(bytes: &[u8], limits: &EpubLimits) -> std::result::Result<usize, String> {
    if bytes.get(4..8) == Some(b"ttcf") {
        return Err("font collections are unsupported".into());
    }
    let n = read_u16(bytes, 12)?;
    if n == 0 || n > limits.max_font_tables {
        return Err("font table count exceeds the limit".into());
    }
    if read_u32(bytes, 16)? > limits.max_decoded_font_bytes {
        return Err("font declares an oversized decoded payload".into());
    }
    Ok(n)
}
fn base_size(n: usize) -> std::result::Result<usize, String> {
    16usize
        .checked_mul(n)
        .and_then(|v| 12usize.checked_add(v))
        .ok_or_else(|| "font size arithmetic overflowed".into())
}
fn preflight_woff(bytes: &[u8], limits: &EpubLimits) -> std::result::Result<(), String> {
    let n = header(bytes, limits)?;
    if 20usize
        .checked_mul(n)
        .and_then(|directory| 44usize.checked_add(directory))
        .is_none_or(|v| v > bytes.len())
    {
        return Err("WOFF table directory is truncated".into());
    }
    let mut total = base_size(n)?;
    for i in 0..n {
        let e = 44 + i * 20;
        let o = read_u32(bytes, e + 4)?;
        let c = read_u32(bytes, e + 8)?;
        let raw = read_u32(bytes, e + 12)?;
        if o.checked_add(c).is_none_or(|v| v > bytes.len()) {
            return Err("WOFF table data is outside the input".into());
        }
        total = total
            .checked_add(aligned(if c < raw { raw } else { c })?)
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        if total > limits.max_decoded_font_bytes {
            return Err("WOFF table data exceeds the output limit".into());
        }
    }
    Ok(())
}
fn base128(b: &[u8], c: &mut usize) -> std::result::Result<usize, String> {
    let mut v = 0usize;
    for i in 0..5 {
        let x = *b
            .get(*c)
            .ok_or_else(|| "WOFF2 table directory is truncated".to_owned())?;
        *c += 1;
        if i == 0 && x == 128 {
            return Err("WOFF2 length is not canonical".into());
        }
        v = v
            .checked_mul(128)
            .and_then(|v| v.checked_add((x & 127) as usize))
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        if x & 128 == 0 {
            return Ok(v);
        }
    }
    Err("WOFF2 length is too large".into())
}
fn preflight_woff2(b: &[u8], l: &EpubLimits) -> std::result::Result<(), String> {
    let n = header(b, l)?;
    let (mut c, mut out, mut encoded) = (48, base_size(n)?, 0usize);
    for _ in 0..n {
        let flags = *b
            .get(c)
            .ok_or_else(|| "WOFF2 table directory is truncated".to_owned())?;
        c += 1;
        let tag = if flags & 63 == 63 {
            let t = b
                .get(c..c + 4)
                .ok_or_else(|| "WOFF2 table directory is truncated".to_owned())?;
            c += 4;
            Some(t)
        } else {
            None
        };
        let raw = base128(b, &mut c)?;
        let glyf = matches!(flags & 63, 10 | 11) || matches!(tag, Some(b"glyf") | Some(b"loca"));
        let transformed = if glyf {
            flags >> 6 == 0
        } else {
            flags >> 6 != 0
        };
        let enc = if transformed {
            base128(b, &mut c)?
        } else {
            raw
        };
        out = out
            .checked_add(aligned(raw)?)
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        encoded = encoded
            .checked_add(enc)
            .ok_or_else(|| "font size arithmetic overflowed".to_owned())?;
        if out > l.max_decoded_font_bytes || encoded > l.max_decoded_font_bytes {
            return Err("WOFF2 table data exceeds the output limit".into());
        }
    }
    Ok(())
}
fn bounded(
    reader: impl Read,
    expected: usize,
    limit: usize,
) -> std::result::Result<Vec<u8>, Box<dyn std::error::Error>> {
    if expected > limit {
        return Err("decoder output exceeds the limit".into());
    }
    let mut out = Vec::with_capacity(expected);
    reader.take(expected as u64 + 1).read_to_end(&mut out)?;
    if out.len() != expected {
        return Err("decoder output length does not match the table directory".into());
    }
    Ok(out)
}
fn sniff(b: &[u8]) -> std::result::Result<EpubFontFormat, String> {
    match b.get(..4) {
        Some([0, 1, 0, 0]) => Ok(EpubFontFormat::TrueType),
        Some(b"OTTO") => Ok(EpubFontFormat::OpenType),
        Some(b"wOFF") => Ok(EpubFontFormat::Woff),
        Some(b"wOF2") => Ok(EpubFontFormat::Woff2),
        _ => Err("unsupported font signature".into()),
    }
}
fn decode_font(
    b: &[u8],
    declared: Option<EpubFontFormat>,
    l: &EpubLimits,
) -> std::result::Result<(EpubFontFormat, Vec<u8>), String> {
    if b.len() > l.max_font_bytes as usize {
        return Err("encoded font exceeds the input limit".into());
    }
    let f = sniff(b)?;
    if declared.is_some_and(|d| d != f) {
        return Err("font signature does not match its format descriptor".into());
    }
    let out = match f {
        EpubFontFormat::TrueType | EpubFontFormat::OpenType => b.to_vec(),
        EpubFontFormat::Woff => {
            preflight_woff(b, l)?;
            wuff::decompress_woff1_with_custom_z(b, &mut |c, n| {
                bounded(
                    flate2::read::ZlibDecoder::new(c),
                    n,
                    l.max_decoded_font_bytes,
                )
            })
            .map_err(|_| "WOFF decoding failed".to_owned())?
        }
        EpubFontFormat::Woff2 => {
            preflight_woff2(b, l)?;
            wuff::decompress_woff2_with_custom_brotli(b, &mut |c, n| {
                bounded(
                    brotli_decompressor::Decompressor::new(c, 4096),
                    n,
                    l.max_decoded_font_bytes,
                )
            })
            .map_err(|_| "WOFF2 decoding failed".to_owned())?
        }
    };
    if out.len() > l.max_decoded_font_bytes {
        return Err("decoded font exceeds the output limit".into());
    }
    if !matches!(
        sniff(&out)?,
        EpubFontFormat::TrueType | EpubFontFormat::OpenType
    ) {
        return Err("decoder did not produce an sfnt font".into());
    }
    let tables = read_u16(&out, 4)?;
    if tables == 0 || tables > l.max_font_tables {
        return Err("font table count exceeds the limit".into());
    }
    Ok((f, out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::Digest;

    const BOOK_A_TTF: &[u8] = include_bytes!("../../../shosai-app/tests/fonts/epub/book-a.ttf");
    const BOOK_A_OTF: &[u8] = include_bytes!("../../../shosai-app/tests/fonts/epub/book-a.otf");
    const BOOK_A_WOFF: &[u8] = include_bytes!("../../../shosai-app/tests/fonts/epub/book-a.woff");
    const BOOK_A_WOFF2: &[u8] = include_bytes!("../../../shosai-app/tests/fonts/epub/book-a.woff2");
    const BOOK_B_TTF: &[u8] = include_bytes!("../../../shosai-app/tests/fonts/epub/book-b.ttf");
    const FAMILY: &str = "Shosai EPUB Fixture";

    fn font_book(
        css: &str,
        resources: &[(&str, &[u8])],
        limits: EpubLimits,
        chapters: usize,
    ) -> EpubFontBook {
        let styles = EpubStyles::parse([("OPS/styles/book.css", css)]);
        let chapters = (0..chapters)
            .map(|index| Chapter {
                index,
                title: None,
                path: format!("OPS/Text/chapter-{index}.xhtml"),
                content: r#"<html><head><link rel="stylesheet" href="../styles/book.css"/></head><body/></html>"#.into(),
            })
            .collect::<Vec<_>>();
        let resources = resources
            .iter()
            .map(|(path, bytes)| {
                (
                    CanonicalEpubPath::new(path).unwrap(),
                    StoredEpubResource {
                        media_type: "application/octet-stream".into(),
                        bytes: bytes.to_vec(),
                    },
                )
            })
            .collect();
        EpubFontBook::new(&chapters, &styles, &resources, &limits).unwrap()
    }

    fn one_face(path: &str, format: &str) -> String {
        format!(
            r#"@font-face {{ font-family: "{FAMILY}"; font-style: italic; font-weight: 700; src: url("../fonts/{path}") format("{format}"); }}"#
        )
    }

    #[test]
    fn ttf_otf_woff_and_woff2_are_admitted_into_book_local_databases() {
        for (path, format, bytes, expected) in [
            (
                "book-a.ttf",
                "truetype",
                BOOK_A_TTF,
                EpubFontFormat::TrueType,
            ),
            (
                "book-a.otf",
                "opentype",
                BOOK_A_OTF,
                EpubFontFormat::OpenType,
            ),
            ("book-a.woff", "woff", BOOK_A_WOFF, EpubFontFormat::Woff),
            ("book-a.woff2", "woff2", BOOK_A_WOFF2, EpubFontFormat::Woff2),
        ] {
            let resource_path = format!("OPS/fonts/{path}");
            let book = font_book(
                &one_face(path, format),
                &[(resource_path.as_str(), bytes)],
                EpubLimits::default(),
                1,
            );
            assert_eq!(book.len(), 1, "{path}: {:?}", book.rejected_faces());
            assert_eq!(book.registered_face_count(), 1, "{path}");
            assert_eq!(book.faces()[0].format, expected, "{path}");
            assert_eq!(book.faces()[0].style, EpubFontStyle::Italic, "{path}");
            assert_eq!(book.faces()[0].weight, 700, "{path}");
            assert!(book.with_face_data(0, |data, _| !data.is_empty()).unwrap());
        }
    }

    #[test]
    fn source_fallback_rejects_local_remote_missing_and_unsupported_sources() {
        let css = format!(
            r#"@font-face {{ font-family: "{FAMILY}"; src:
                local("System Font"),
                url("https://example.invalid/remote.ttf") format("truetype"),
                url("../fonts/missing.ttf") format("truetype"),
                url("../fonts/unsupported.ttf") format("svg"),
                url("../fonts/technology.ttf") format("truetype") tech(variations),
                url("../fonts/book-a.ttf") format("truetype"); }}"#
        );
        let book = font_book(
            &css,
            &[("OPS/fonts/book-a.ttf", BOOK_A_TTF)],
            EpubLimits::default(),
            1,
        );

        assert_eq!(book.len(), 1);
        assert_eq!(book.faces()[0].attempts.len(), 6);
        assert!(matches!(
            book.faces()[0].attempts.last(),
            Some(EpubFontAttempt::Loaded { path, .. }) if path.as_str() == "OPS/fonts/book-a.ttf"
        ));
    }

    #[test]
    fn malformed_mismatched_format_and_decoded_limits_fail_closed() {
        let mismatch = font_book(
            &one_face("book-a.ttf", "opentype"),
            &[("OPS/fonts/book-a.ttf", BOOK_A_TTF)],
            EpubLimits::default(),
            1,
        );
        assert!(mismatch.is_empty());
        assert!(mismatch.rejected_faces()[0].attempts.iter().any(|attempt| {
            matches!(attempt, EpubFontAttempt::Rejected { reason, .. } if reason.contains("signature does not match"))
        }));

        let alias = font_book(
            &one_face("book-a.ttf", "truetype"),
            &[("OPS/fonts/book-a.ttf", BOOK_A_TTF)],
            EpubLimits::default(),
            1,
        );
        assert_eq!(
            alias.len(),
            1,
            "@font-face family is an author-defined alias"
        );

        let bounded = font_book(
            &one_face("book-a.woff2", "woff2"),
            &[("OPS/fonts/book-a.woff2", BOOK_A_WOFF2)],
            EpubLimits {
                max_decoded_font_bytes: 1,
                ..EpubLimits::default()
            },
            1,
        );
        assert!(bounded.is_empty());
    }

    #[test]
    fn faces_are_deduplicated_bounded_and_isolated_per_book() {
        let css = one_face("book.ttf", "truetype");
        let first = font_book(
            &css,
            &[("OPS/fonts/book.ttf", BOOK_A_TTF)],
            EpubLimits::default(),
            2,
        );
        let second = font_book(
            &css,
            &[("OPS/fonts/book.ttf", BOOK_B_TTF)],
            EpubLimits::default(),
            2,
        );
        assert_eq!(first.len(), 1);
        assert_eq!(second.len(), 1);
        assert_eq!(first.registered_face_count(), 1);
        assert_eq!(second.registered_face_count(), 1);
        assert!(first.contains_family(FAMILY));
        assert!(second.contains_family(FAMILY));
        let first_hash = first
            .with_face_data(0, |bytes, _| sha2::Sha256::digest(bytes))
            .unwrap();
        let second_hash = second
            .with_face_data(0, |bytes, _| sha2::Sha256::digest(bytes))
            .unwrap();
        assert_ne!(first_hash, second_hash);

        let exhausted = font_book(
            &css,
            &[("OPS/fonts/book.ttf", BOOK_A_TTF)],
            EpubLimits {
                max_total_decoded_font_bytes: 1,
                ..EpubLimits::default()
            },
            1,
        );
        assert!(exhausted.is_empty());
        assert!(exhausted.rejected_faces()[0].attempts.iter().any(|attempt| {
            matches!(attempt, EpubFontAttempt::Rejected { reason, .. } if reason.contains("budget"))
        }));
    }

    #[test]
    fn native_spans_select_the_first_admitted_family_then_fall_back() {
        let css = format!(
            r#"{}
                p {{ font-family: "Missing Family", "{FAMILY}", serif; }}"#,
            one_face("book.ttf", "truetype")
        );
        let styles = EpubStyles::parse([("OPS/styles/book.css", css.as_str())]);
        let chapter = Chapter {
            index: 0,
            title: None,
            path: "OPS/Text/chapter.xhtml".into(),
            content: r#"<html><head><link rel="stylesheet" href="../styles/book.css"/></head><body><p>Embedded</p></body></html>"#.into(),
        };
        let resources = HashMap::from([(
            CanonicalEpubPath::new("OPS/fonts/book.ttf").unwrap(),
            StoredEpubResource {
                media_type: "font/ttf".into(),
                bytes: BOOK_A_TTF.to_vec(),
            },
        )]);
        let limits = EpubLimits::default();
        let fonts = EpubFontBook::new(std::slice::from_ref(&chapter), &styles, &resources, &limits)
            .unwrap();
        let nodes = super::super::render::parse_chapter_xhtml_at_path_with_limits(
            &chapter.content,
            &chapter.path,
            &styles,
            &fonts,
            &limits,
        )
        .unwrap();
        let super::super::render::ContentNode::Paragraph(spans, _) = &nodes[0] else {
            panic!("fixture paragraph must be retained");
        };
        assert_eq!(spans[0].font_family.as_deref(), Some(FAMILY));

        let no_fonts = EpubFontBook::new(
            std::slice::from_ref(&chapter),
            &styles,
            &HashMap::new(),
            &limits,
        )
        .unwrap();
        let fallback = super::super::render::parse_chapter_xhtml_at_path_with_limits(
            &chapter.content,
            &chapter.path,
            &styles,
            &no_fonts,
            &limits,
        )
        .unwrap();
        let super::super::render::ContentNode::Paragraph(spans, _) = &fallback[0] else {
            panic!("fixture paragraph must be retained");
        };
        assert_eq!(spans[0].font_family, None);
    }

    #[test]
    fn admitted_family_keeps_requested_bold_italic_for_native_synthesis() {
        let css = format!(
            r#"@font-face {{ font-family: "{FAMILY}"; font-style: normal; font-weight: 400; src: url("../fonts/book.ttf") format("truetype"); }}
                p {{ font-family: "{FAMILY}"; font-style: italic; font-weight: bold; }}"#
        );
        let styles = EpubStyles::parse([("OPS/styles/book.css", css.as_str())]);
        let chapter = Chapter {
            index: 0,
            title: None,
            path: "OPS/Text/chapter.xhtml".into(),
            content: r#"<html><head><link rel="stylesheet" href="../styles/book.css"/></head><body><p>Synthesized</p></body></html>"#.into(),
        };
        let resources = HashMap::from([(
            CanonicalEpubPath::new("OPS/fonts/book.ttf").unwrap(),
            StoredEpubResource {
                media_type: "font/ttf".into(),
                bytes: BOOK_A_TTF.to_vec(),
            },
        )]);
        let limits = EpubLimits::default();
        let fonts = EpubFontBook::new(std::slice::from_ref(&chapter), &styles, &resources, &limits)
            .unwrap();
        let nodes = super::super::render::parse_chapter_xhtml_at_path_with_limits(
            &chapter.content,
            &chapter.path,
            &styles,
            &fonts,
            &limits,
        )
        .unwrap();
        let super::super::render::ContentNode::Paragraph(spans, _) = &nodes[0] else {
            panic!("fixture paragraph must be retained");
        };
        assert_eq!(spans[0].font_family.as_deref(), Some(FAMILY));
        assert!(spans[0].bold);
        assert!(spans[0].italic);
    }
}
