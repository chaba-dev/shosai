//! Renderer-independent text annotations and their SQLite persistence.

use std::ops::Range;
use std::str::FromStr;

use anyhow::{Context, Result, anyhow, bail};
use sqlx::Row;
use sqlx::sqlite::{SqlitePool, SqliteRow};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const ANCHOR_VERSION: u32 = 1;
pub const QUOTE_PROFILE_V1: &str = "shosai-quote-v1";
pub const MAX_QUOTE_SCALARS: usize = 65_536;
pub const MAX_CONTEXT_SCALARS: usize = 32;
pub const MAX_PDF_RECTANGLES: usize = 16_384;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AnnotationId(Uuid);

impl AnnotationId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for AnnotationId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for AnnotationId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

impl FromStr for AnnotationId {
    type Err = uuid::Error;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        Uuid::parse_str(value).map(Self)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HighlightColor {
    Yellow,
    Green,
    Blue,
    Pink,
    Purple,
}

impl HighlightColor {
    fn as_str(self) -> &'static str {
        match self {
            Self::Yellow => "yellow",
            Self::Green => "green",
            Self::Blue => "blue",
            Self::Pink => "pink",
            Self::Purple => "purple",
        }
    }

    fn from_db(value: &str) -> Result<Self> {
        match value {
            "yellow" => Ok(Self::Yellow),
            "green" => Ok(Self::Green),
            "blue" => Ok(Self::Blue),
            "pink" => Ok(Self::Pink),
            "purple" => Ok(Self::Purple),
            _ => bail!("unknown annotation color {value:?}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentFingerprint {
    pub algorithm: String,
    pub version: u32,
    pub bytes: Vec<u8>,
}

impl DocumentFingerprint {
    pub fn new(algorithm: impl Into<String>, version: u32, bytes: Vec<u8>) -> Result<Self> {
        let fingerprint = Self {
            algorithm: algorithm.into(),
            version,
            bytes,
        };
        fingerprint.validate()?;
        Ok(fingerprint)
    }

    fn validate(&self) -> Result<()> {
        if self.algorithm.trim().is_empty() || self.version == 0 || self.bytes.is_empty() {
            bail!("annotation fingerprint requires an algorithm, version, and bytes");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuoteSelector {
    pub original: Option<String>,
    pub exact: String,
    pub prefix: String,
    pub suffix: String,
}

impl QuoteSelector {
    /// Build a selector from the selected text and its unbounded surrounding text.
    pub fn new(selected: &str, before: &str, after: &str) -> Result<Self> {
        let exact = normalize_quote_v1(selected);
        if exact.is_empty() {
            bail!("annotation quote must not be empty");
        }
        if exact.chars().count() > MAX_QUOTE_SCALARS {
            bail!("annotation quote exceeds {MAX_QUOTE_SCALARS} Unicode scalars");
        }
        Ok(Self {
            original: Some(selected.to_owned()),
            exact,
            prefix: quote_context_v1(before, ContextDirection::Prefix),
            suffix: quote_context_v1(after, ContextDirection::Suffix),
        })
    }

    fn validate(&self) -> Result<()> {
        if self.exact.is_empty()
            || self.exact.chars().count() > MAX_QUOTE_SCALARS
            || self.prefix.chars().count() > MAX_CONTEXT_SCALARS
            || self.suffix.chars().count() > MAX_CONTEXT_SCALARS
        {
            bail!("annotation quote selector exceeds its scalar limit");
        }
        if self.original.as_ref().is_some_and(|quote| {
            quote.chars().count() > MAX_QUOTE_SCALARS || normalize_quote_v1(quote) != self.exact
        }) {
            bail!("annotation original and normalized quote do not match");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PageRect {
    pub left: f32,
    pub bottom: f32,
    pub right: f32,
    pub top: f32,
}

impl PageRect {
    pub fn new(left: f32, bottom: f32, right: f32, top: f32) -> Result<Self> {
        let rectangle = Self {
            left,
            bottom,
            right,
            top,
        };
        rectangle.validate()?;
        Ok(rectangle)
    }

    fn validate(&self) -> Result<()> {
        if ![self.left, self.bottom, self.right, self.top]
            .into_iter()
            .all(f32::is_finite)
            || self.left >= self.right
            || self.bottom >= self.top
        {
            bail!("PDF annotation rectangle must be finite and non-empty");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EpubAnchor {
    pub spine_occurrence: u32,
    pub resource_path: String,
    pub scalar_start: u32,
    pub scalar_end: u32,
}

impl EpubAnchor {
    pub fn new(
        spine_occurrence: u32,
        resource_path: impl Into<String>,
        scalar_start: u32,
        scalar_end: u32,
    ) -> Result<Self> {
        let anchor = Self {
            spine_occurrence,
            resource_path: resource_path.into(),
            scalar_start,
            scalar_end,
        };
        anchor.validate()?;
        Ok(anchor)
    }

    fn validate(&self) -> Result<()> {
        if self.resource_path.is_empty()
            || self.resource_path.contains('\\')
            || self.resource_path.split('/').any(|part| part == "..")
        {
            bail!("EPUB annotation requires a canonical resource path");
        }
        if self.scalar_start >= self.scalar_end {
            bail!("EPUB annotation range must be non-empty and half-open");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PdfAnchor {
    pub page: u32,
    pub character_range: Option<(u32, u32)>,
    pub rectangles: Vec<PageRect>,
}

impl PdfAnchor {
    pub fn new(
        page: u32,
        character_range: Option<(u32, u32)>,
        rectangles: Vec<PageRect>,
    ) -> Result<Self> {
        let anchor = Self {
            page,
            character_range,
            rectangles,
        };
        anchor.validate()?;
        Ok(anchor)
    }

    fn validate(&self) -> Result<()> {
        if self.rectangles.is_empty() || self.rectangles.len() > MAX_PDF_RECTANGLES {
            bail!("PDF annotation requires 1..={MAX_PDF_RECTANGLES} rectangles");
        }
        if self
            .character_range
            .is_some_and(|(start, end)| start >= end)
        {
            bail!("PDF annotation character range must be non-empty and half-open");
        }
        for rectangle in &self.rectangles {
            rectangle.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum AnnotationTarget {
    Epub(EpubAnchor),
    Pdf(PdfAnchor),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnotationResolution {
    Exact,
    Recovered,
    Ambiguous,
    Orphaned,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportProvenance {
    pub source_system: String,
    pub source_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NewAnnotation {
    pub id: AnnotationId,
    pub book_id: Option<i64>,
    pub local_path: Option<String>,
    pub fingerprint: DocumentFingerprint,
    pub quote: Option<QuoteSelector>,
    pub target: AnnotationTarget,
    pub color: HighlightColor,
    pub body: Option<String>,
    pub provenance: Option<ImportProvenance>,
}

impl NewAnnotation {
    fn validate(&self) -> Result<()> {
        self.fingerprint.validate()?;
        if let Some(quote) = &self.quote {
            quote.validate()?;
        }
        match &self.target {
            AnnotationTarget::Epub(anchor) => {
                anchor.validate()?;
                if self.quote.is_none() {
                    bail!("EPUB annotations require a quote selector");
                }
            }
            AnnotationTarget::Pdf(anchor) => {
                anchor.validate()?;
                if anchor.character_range.is_some() != self.quote.is_some() {
                    bail!(
                        "PDF text ranges require quote selectors; geometry-only anchors require none"
                    );
                }
            }
        }
        if self
            .provenance
            .as_ref()
            .is_some_and(|value| value.source_system.trim().is_empty())
        {
            bail!("annotation provenance requires a source system");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Annotation {
    pub id: AnnotationId,
    pub book_id: Option<i64>,
    pub local_path: Option<String>,
    pub fingerprint: DocumentFingerprint,
    pub quote: Option<QuoteSelector>,
    pub target: AnnotationTarget,
    pub color: HighlightColor,
    pub body: Option<String>,
    pub provenance: Option<ImportProvenance>,
    pub created_at: String,
    pub modified_at: String,
    pub deleted_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AnnotationStore {
    pool: SqlitePool,
}

impl AnnotationStore {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn create_async(&self, annotation: &NewAnnotation) -> Result<Annotation> {
        annotation.validate()?;
        let mut transaction = self
            .pool
            .begin()
            .await
            .context("failed to begin annotation insert")?;
        let (format, epub, pdf) = match &annotation.target {
            AnnotationTarget::Epub(anchor) => ("epub", Some(anchor), None),
            AnnotationTarget::Pdf(anchor) => ("pdf", None, Some(anchor)),
        };
        let (char_start, char_end) = pdf
            .and_then(|anchor| anchor.character_range)
            .map_or((None, None), |(start, end)| {
                (Some(i64::from(start)), Some(i64::from(end)))
            });
        let quote = annotation.quote.as_ref();
        let provenance = annotation.provenance.as_ref();
        sqlx::query(
            "INSERT INTO annotations (
                id, book_id, local_path, format, anchor_version,
                fingerprint_algorithm, fingerprint_version, fingerprint,
                original_quote, normalization_profile, normalized_exact,
                normalized_prefix, normalized_suffix, color, body,
                source_system, source_id, epub_spine_occurrence,
                epub_resource_path, epub_scalar_start, epub_scalar_end,
                pdf_page, pdf_char_start, pdf_char_end)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(annotation.id.to_string())
        .bind(annotation.book_id)
        .bind(&annotation.local_path)
        .bind(format)
        .bind(i64::from(ANCHOR_VERSION))
        .bind(&annotation.fingerprint.algorithm)
        .bind(i64::from(annotation.fingerprint.version))
        .bind(&annotation.fingerprint.bytes)
        .bind(quote.and_then(|value| value.original.as_deref()))
        .bind(quote.map(|_| QUOTE_PROFILE_V1))
        .bind(quote.map(|value| value.exact.as_str()))
        .bind(quote.map(|value| value.prefix.as_str()))
        .bind(quote.map(|value| value.suffix.as_str()))
        .bind(annotation.color.as_str())
        .bind(&annotation.body)
        .bind(provenance.map(|value| value.source_system.as_str()))
        .bind(provenance.and_then(|value| value.source_id.as_deref()))
        .bind(epub.map(|anchor| i64::from(anchor.spine_occurrence)))
        .bind(epub.map(|anchor| anchor.resource_path.as_str()))
        .bind(epub.map(|anchor| i64::from(anchor.scalar_start)))
        .bind(epub.map(|anchor| i64::from(anchor.scalar_end)))
        .bind(pdf.map(|anchor| i64::from(anchor.page)))
        .bind(char_start)
        .bind(char_end)
        .execute(&mut *transaction)
        .await
        .context("failed to insert annotation")?;

        if let Some(anchor) = pdf {
            for (index, rectangle) in anchor.rectangles.iter().enumerate() {
                sqlx::query(
                    "INSERT INTO annotation_pdf_rectangles
                        (annotation_id, rect_index, left, bottom, right, top)
                     VALUES (?, ?, ?, ?, ?, ?)",
                )
                .bind(annotation.id.to_string())
                .bind(i64::try_from(index).context("too many PDF rectangles")?)
                .bind(rectangle.left)
                .bind(rectangle.bottom)
                .bind(rectangle.right)
                .bind(rectangle.top)
                .execute(&mut *transaction)
                .await
                .context("failed to insert PDF annotation rectangle")?;
            }
        }
        transaction
            .commit()
            .await
            .context("failed to commit annotation")?;
        self.get_async(&annotation.id, true)
            .await?
            .context("annotation missing after insert")
    }

    pub async fn get_async(
        &self,
        id: &AnnotationId,
        include_deleted: bool,
    ) -> Result<Option<Annotation>> {
        let row =
            sqlx::query("SELECT * FROM annotations WHERE id = ? AND (? OR deleted_at IS NULL)")
                .bind(id.to_string())
                .bind(include_deleted)
                .fetch_optional(&self.pool)
                .await
                .context("failed to get annotation")?;
        match row {
            Some(row) => self.row_to_annotation(row).await.map(Some),
            None => Ok(None),
        }
    }

    pub async fn list_for_book_async(&self, book_id: i64) -> Result<Vec<Annotation>> {
        let ids = sqlx::query_scalar::<_, String>(
            "SELECT id FROM annotations
             WHERE book_id = ? AND deleted_at IS NULL
             ORDER BY created_at, id",
        )
        .bind(book_id)
        .fetch_all(&self.pool)
        .await
        .context("failed to list annotations for book")?;
        let mut annotations = Vec::with_capacity(ids.len());
        for id in ids {
            let id = AnnotationId::from_str(&id).context("invalid annotation ID in database")?;
            annotations.push(
                self.get_async(&id, false)
                    .await?
                    .context("listed annotation disappeared")?,
            );
        }
        Ok(annotations)
    }

    pub async fn update_async(
        &self,
        id: &AnnotationId,
        color: HighlightColor,
        body: Option<&str>,
    ) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE annotations
             SET color = ?, body = ?, modified_at =
                 CASE
                     WHEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now') > modified_at
                     THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                     ELSE strftime('%Y-%m-%dT%H:%M:%fZ', modified_at, '+0.001 seconds')
                 END
             WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(color.as_str())
        .bind(body)
        .bind(id.to_string())
        .execute(&self.pool)
        .await
        .context("failed to update annotation")?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn delete_async(&self, id: &AnnotationId) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE annotations
             SET deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                 modified_at =
                 CASE
                     WHEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now') > modified_at
                     THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                     ELSE strftime('%Y-%m-%dT%H:%M:%fZ', modified_at, '+0.001 seconds')
                 END
             WHERE id = ? AND deleted_at IS NULL",
        )
        .bind(id.to_string())
        .execute(&self.pool)
        .await
        .context("failed to delete annotation")?;
        Ok(result.rows_affected() == 1)
    }

    async fn row_to_annotation(&self, row: SqliteRow) -> Result<Annotation> {
        let id_text: String = row.try_get("id")?;
        let id = AnnotationId::from_str(&id_text).context("invalid annotation ID in database")?;
        let anchor_version: i64 = row.try_get("anchor_version")?;
        if anchor_version != i64::from(ANCHOR_VERSION) {
            bail!("unsupported annotation anchor version {anchor_version}");
        }
        let fingerprint_version =
            positive_u32(row.try_get("fingerprint_version")?, "fingerprint version")?;
        let fingerprint = DocumentFingerprint::new(
            row.try_get::<String, _>("fingerprint_algorithm")?,
            fingerprint_version,
            row.try_get("fingerprint")?,
        )?;
        let profile: Option<String> = row.try_get("normalization_profile")?;
        let quote = match profile.as_deref() {
            None => None,
            Some(QUOTE_PROFILE_V1) => Some(QuoteSelector {
                original: row.try_get("original_quote")?,
                exact: row.try_get("normalized_exact")?,
                prefix: row.try_get("normalized_prefix")?,
                suffix: row.try_get("normalized_suffix")?,
            }),
            Some(profile) => bail!("unsupported annotation quote profile {profile:?}"),
        };
        if let Some(quote) = &quote {
            quote.validate()?;
        }
        let target = match row.try_get::<String, _>("format")?.as_str() {
            "epub" => AnnotationTarget::Epub(EpubAnchor::new(
                nonnegative_u32(
                    row.try_get("epub_spine_occurrence")?,
                    "EPUB spine occurrence",
                )?,
                row.try_get::<String, _>("epub_resource_path")?,
                nonnegative_u32(row.try_get("epub_scalar_start")?, "EPUB scalar start")?,
                nonnegative_u32(row.try_get("epub_scalar_end")?, "EPUB scalar end")?,
            )?),
            "pdf" => {
                let start: Option<i64> = row.try_get("pdf_char_start")?;
                let end: Option<i64> = row.try_get("pdf_char_end")?;
                let character_range = match (start, end) {
                    (Some(start), Some(end)) => Some((
                        nonnegative_u32(start, "PDF character start")?,
                        nonnegative_u32(end, "PDF character end")?,
                    )),
                    (None, None) => None,
                    _ => bail!("incomplete PDF character range in database"),
                };
                let rectangle_rows = sqlx::query(
                    "SELECT left, bottom, right, top FROM annotation_pdf_rectangles
                     WHERE annotation_id = ? ORDER BY rect_index",
                )
                .bind(&id_text)
                .fetch_all(&self.pool)
                .await
                .context("failed to load PDF annotation rectangles")?;
                let rectangles = rectangle_rows
                    .into_iter()
                    .map(|rectangle| {
                        PageRect::new(
                            rectangle.try_get("left")?,
                            rectangle.try_get("bottom")?,
                            rectangle.try_get("right")?,
                            rectangle.try_get("top")?,
                        )
                    })
                    .collect::<Result<Vec<_>>>()?;
                AnnotationTarget::Pdf(PdfAnchor::new(
                    nonnegative_u32(row.try_get("pdf_page")?, "PDF page")?,
                    character_range,
                    rectangles,
                )?)
            }
            format => bail!("unknown annotation format {format:?}"),
        };
        let provenance = match row.try_get::<Option<String>, _>("source_system")? {
            Some(source_system) => Some(ImportProvenance {
                source_system,
                source_id: row.try_get("source_id")?,
            }),
            None => None,
        };
        let annotation = Annotation {
            id,
            book_id: row.try_get("book_id")?,
            local_path: row.try_get("local_path")?,
            fingerprint,
            quote,
            target,
            color: HighlightColor::from_db(&row.try_get::<String, _>("color")?)?,
            body: row.try_get("body")?,
            provenance,
            created_at: row.try_get("created_at")?,
            modified_at: row.try_get("modified_at")?,
            deleted_at: row.try_get("deleted_at")?,
        };
        NewAnnotation {
            id: annotation.id.clone(),
            book_id: annotation.book_id,
            local_path: annotation.local_path.clone(),
            fingerprint: annotation.fingerprint.clone(),
            quote: annotation.quote.clone(),
            target: annotation.target.clone(),
            color: annotation.color,
            body: annotation.body.clone(),
            provenance: annotation.provenance.clone(),
        }
        .validate()?;
        Ok(annotation)
    }
}

pub fn normalize_quote_v1(value: &str) -> String {
    let line_normalized = value.replace("\r\n", "\n").replace('\r', "\n");
    let normalized = line_normalized
        .chars()
        .filter(|character| *character != '\u{00ad}')
        .collect::<String>()
        .nfc()
        .collect::<String>();
    let mut result = String::new();
    let mut pending_space = false;
    for character in normalized.chars() {
        if quote_v1_whitespace(character) {
            pending_space = !result.is_empty();
        } else {
            if pending_space {
                result.push(' ');
                pending_space = false;
            }
            result.push(character);
        }
    }
    result
}

/// Convert a half-open Unicode-scalar range to the UTF-16 units required by EPUB CFI.
pub fn scalar_range_to_utf16(text: &str, range: Range<u32>) -> Result<Range<u32>> {
    if range.start > range.end {
        bail!("Unicode-scalar range is reversed");
    }
    let scalar_count = u32::try_from(text.chars().count()).context("text is too large")?;
    if range.end > scalar_count {
        bail!("Unicode-scalar range exceeds text length");
    }
    let mut utf16_start = None;
    let mut utf16_end = None;
    let mut utf16_offset = 0_u32;
    for (scalar_offset, character) in text.chars().enumerate() {
        let scalar_offset = u32::try_from(scalar_offset).context("text is too large")?;
        if scalar_offset == range.start {
            utf16_start = Some(utf16_offset);
        }
        if scalar_offset == range.end {
            utf16_end = Some(utf16_offset);
            break;
        }
        utf16_offset = utf16_offset
            .checked_add(character.len_utf16() as u32)
            .context("UTF-16 offset overflow")?;
    }
    if range.start == scalar_count {
        utf16_start = Some(utf16_offset);
    }
    if range.end == scalar_count {
        utf16_end = Some(utf16_offset);
    }
    Ok(utf16_start.context("missing UTF-16 range start")?
        ..utf16_end.context("missing UTF-16 range end")?)
}

#[derive(Clone, Copy)]
enum ContextDirection {
    Prefix,
    Suffix,
}

fn quote_context_v1(value: &str, direction: ContextDirection) -> String {
    let normalized = normalize_quote_v1(value);
    let graphemes = normalized.graphemes(true).collect::<Vec<_>>();
    match direction {
        ContextDirection::Prefix => {
            let mut scalars = 0;
            let start = graphemes
                .iter()
                .rposition(|grapheme| {
                    let next = scalars + grapheme.chars().count();
                    if next <= MAX_CONTEXT_SCALARS {
                        scalars = next;
                        false
                    } else {
                        true
                    }
                })
                .map_or(0, |index| index + 1);
            graphemes[start..].concat()
        }
        ContextDirection::Suffix => {
            let mut scalars = 0;
            let end = graphemes
                .iter()
                .position(|grapheme| {
                    let next = scalars + grapheme.chars().count();
                    if next <= MAX_CONTEXT_SCALARS {
                        scalars = next;
                        false
                    } else {
                        true
                    }
                })
                .unwrap_or(graphemes.len());
            graphemes[..end].concat()
        }
    }
}

fn quote_v1_whitespace(character: char) -> bool {
    matches!(
        character,
        '\u{0009}'..='\u{000d}'
            | '\u{0020}'
            | '\u{0085}'
            | '\u{00a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
    )
}

fn nonnegative_u32(value: i64, field: &str) -> Result<u32> {
    u32::try_from(value).map_err(|_| anyhow!("invalid {field} in annotation database"))
}

fn positive_u32(value: i64, field: &str) -> Result<u32> {
    let value = nonnegative_u32(value, field)?;
    if value == 0 {
        bail!("invalid {field} in annotation database");
    }
    Ok(value)
}
