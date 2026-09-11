//! Renderer-independent text annotations and their SQLite persistence.

use std::collections::HashSet;
use std::future::Future;
use std::ops::Range;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use anyhow::{Context, Result, anyhow, bail};
use sqlx::sqlite::{SqliteConnection, SqlitePool, SqliteRow};
use sqlx::{Connection, Row, Sqlite, Transaction};
use thiserror::Error;
#[cfg(test)]
use tokio::sync::Semaphore;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

use crate::epub::CanonicalEpubPath;

pub const ANCHOR_VERSION: u32 = 1;
pub const QUOTE_PROFILE_V1: &str = "shosai-quote-v1";
pub const MAX_QUOTE_SCALARS: usize = 65_536;
pub const MAX_QUOTE_CONTEXT_INPUT_SCALARS: usize = 65_536;
pub const MAX_CONTEXT_SCALARS: usize = 32;
pub const MAX_PDF_RECTANGLES: usize = 16_384;
pub const MAX_ANNOTATIONS_PER_SNAPSHOT: usize = 1_024;
pub const MAX_PDF_RECTANGLES_PER_SNAPSHOT: usize = 65_536;
pub const MAX_ANNOTATION_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
pub const ANNOTATION_SNAPSHOT_BASE_BYTES: usize = 256;
pub const MAX_ANNOTATION_BODY_SCALARS: usize = 65_536;
const MAX_ANNOTATION_TIMESTAMP_BYTES: usize = 64;
pub const MAX_FINGERPRINT_BYTES: usize = 1_024;
pub const MAX_FINGERPRINT_ALGORITHM_BYTES: usize = 64;
pub const MAX_LOCAL_PATH_BYTES: usize = 32_768;
pub const MAX_EPUB_RESOURCE_PATH_BYTES: usize = 4_096;
pub const MAX_PROVENANCE_SYSTEM_BYTES: usize = 256;
pub const MAX_PROVENANCE_ID_BYTES: usize = 4_096;
pub const MAX_ANNOTATION_ASSOCIATION_SOURCES_PER_PAGE: usize = 100;
pub const MAX_ANNOTATION_DOCUMENT_VERSIONS: usize = 128;
pub(crate) const MAX_TEXT_ANCHOR_RESOLUTION_WORK: usize = 64 * 1024 * 1024;
const ANNOTATION_ASSOCIATION_PROGRESS_INTERVAL: usize = 1_000;
const MAX_ANNOTATION_ASSOCIATION_DISCOVERY_WORK: usize = 10_000_000;
const ANNOTATION_RECONCILIATION_PROGRESS_INTERVAL: usize = 1_000;
const MAX_ANNOTATION_RECONCILIATION_WORK: usize = 10_000_000;
const MAX_ANNOTATION_RECONCILIATION_ROWS: usize = 4_096;
const MAX_ANNOTATION_RECONCILIATION_CANDIDATES: usize = 4_096;
const MAX_ANNOTATION_RECONCILIATION_BEGIN_RETRIES: usize = 100;
const ANNOTATION_RECONCILIATION_BEGIN_RETRY_DELAY: std::time::Duration =
    std::time::Duration::from_millis(10);
const MAX_TEXT_ANCHOR_GRAPHEME_SCALARS: usize = 1_024;

#[derive(Debug, Error)]
#[error("annotation snapshot exceeds its aggregate retention limit")]
pub struct AnnotationSnapshotLimit;

#[derive(Debug, Error)]
#[error("annotation document exceeds its version limit")]
pub struct AnnotationDocumentVersionLimit;

#[derive(Debug, Error)]
#[error("annotation association source discovery was cancelled")]
pub struct AnnotationAssociationSourceCancelled;

#[derive(Debug, Error)]
#[error("annotation association source discovery exceeded its work limit")]
pub struct AnnotationAssociationSourceWorkLimit;

#[derive(Debug, Error)]
#[error("annotation reconciliation was cancelled")]
pub struct AnnotationReconciliationCancelled;

#[derive(Debug, Error)]
#[error("annotation reconciliation exceeded its work limit")]
pub struct AnnotationReconciliationWorkLimit;

#[derive(Debug, Error)]
#[error("invalid annotation association request: {0}")]
pub struct AnnotationAssociationInvalidRequest(pub String);

#[derive(Debug, Error)]
#[error("annotation association source was not found")]
pub struct AnnotationAssociationSourceNotFound;

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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AnnotationDocumentVersionId(Uuid);

impl std::fmt::Display for AnnotationDocumentVersionId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

impl FromStr for AnnotationDocumentVersionId {
    type Err = uuid::Error;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        Uuid::parse_str(value).map(Self)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnotationDocumentFormat {
    Epub,
    Pdf,
}

impl AnnotationDocumentFormat {
    fn as_str(self) -> &'static str {
        match self {
            Self::Epub => "epub",
            Self::Pdf => "pdf",
        }
    }

    fn from_db(value: &str) -> Result<Self> {
        match value {
            "epub" => Ok(Self::Epub),
            "pdf" => Ok(Self::Pdf),
            _ => bail!("unknown annotation document format {value:?}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnnotationAssociationSource {
    pub version_id: AnnotationDocumentVersionId,
    pub format: AnnotationDocumentFormat,
    pub local_path: String,
    pub fingerprint: DocumentFingerprint,
    pub live_annotations: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnnotationAssociationSourcePage {
    pub sources: Vec<AnnotationAssociationSource>,
    pub next_cursor: Option<AnnotationDocumentVersionId>,
    pub previous_cursor: Option<AnnotationDocumentVersionId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnotationAssociationOutcome {
    Associated,
    AlreadyAssociated,
}

#[derive(Debug, Error)]
#[error("document version already belongs to another annotation collection")]
pub struct AnnotationAssociationConflict;

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
        if self.algorithm.trim().is_empty()
            || self.algorithm.len() > MAX_FINGERPRINT_ALGORITHM_BYTES
            || self.version == 0
            || self.bytes.is_empty()
            || self.bytes.len() > MAX_FINGERPRINT_BYTES
        {
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
    /// Build a selector from the selected text and its bounded surrounding text.
    pub fn new(selected: &str, before: &str, after: &str) -> Result<Self> {
        ensure_scalar_limit(selected, MAX_QUOTE_SCALARS, "annotation quote")?;
        ensure_scalar_limit(
            before,
            MAX_QUOTE_CONTEXT_INPUT_SCALARS,
            "annotation prefix input",
        )?;
        ensure_scalar_limit(
            after,
            MAX_QUOTE_CONTEXT_INPUT_SCALARS,
            "annotation suffix input",
        )?;
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
            || normalize_quote_v1(&self.exact) != self.exact
            || normalize_quote_v1(&self.prefix) != self.prefix
            || normalize_quote_v1(&self.suffix) != self.suffix
        {
            bail!("annotation quote selector is not normalized or exceeds its scalar limit");
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
    pub resource_path: CanonicalEpubPath,
    pub scalar_start: u32,
    pub scalar_end: u32,
}

impl EpubAnchor {
    pub fn new(
        spine_occurrence: u32,
        resource_path: impl AsRef<str>,
        scalar_start: u32,
        scalar_end: u32,
    ) -> Result<Self> {
        if resource_path.as_ref().len() > MAX_EPUB_RESOURCE_PATH_BYTES {
            bail!("EPUB annotation resource path exceeds {MAX_EPUB_RESOURCE_PATH_BYTES} bytes");
        }
        let anchor = Self {
            spine_occurrence,
            resource_path: CanonicalEpubPath::new(resource_path.as_ref())
                .context("EPUB annotation requires a canonical resource path")?,
            scalar_start,
            scalar_end,
        };
        anchor.validate()?;
        Ok(anchor)
    }

    fn validate(&self) -> Result<()> {
        if self.resource_path.as_str().len() > MAX_EPUB_RESOURCE_PATH_BYTES {
            bail!("EPUB annotation resource path exceeds {MAX_EPUB_RESOURCE_PATH_BYTES} bytes");
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
pub struct ResolvedTextAnchor {
    pub resolution: AnnotationResolution,
    pub range: Option<Range<usize>>,
}

#[derive(Debug, Error)]
pub enum TextAnchorResolutionError {
    #[error("text anchor selector is invalid")]
    InvalidSelector,
    #[error("text anchor resolution was cancelled")]
    Cancelled,
    #[error("text anchor resolution exceeded its work limit")]
    WorkLimit,
}

pub(crate) struct TextScalarIndex<'a> {
    text: &'a str,
    scalar_bytes: Vec<usize>,
}

impl<'a> TextScalarIndex<'a> {
    pub(crate) fn new(
        text: &'a str,
        remaining_work: &mut usize,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<Self, TextAnchorResolutionError> {
        let mut scalar_bytes = Vec::with_capacity(text.len().saturating_add(1));
        for (index, (byte, _)) in text.char_indices().enumerate() {
            if index % 1024 == 0 && is_cancelled() {
                return Err(TextAnchorResolutionError::Cancelled);
            }
            consume_resolution_work(remaining_work, 1)?;
            scalar_bytes.push(byte);
        }
        scalar_bytes.push(text.len());
        Ok(Self { text, scalar_bytes })
    }

    pub(crate) fn resolve_exact(
        &self,
        stored_range: Range<usize>,
        quote: &QuoteSelector,
        remaining_work: &mut usize,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<Option<ResolvedTextAnchor>, TextAnchorResolutionError> {
        quote
            .validate()
            .map_err(|_| TextAnchorResolutionError::InvalidSelector)?;
        if stored_range.start >= stored_range.end || stored_range.end >= self.scalar_bytes.len() {
            return Ok(None);
        }
        exact_text_anchor(
            &self.text[self.scalar_bytes[stored_range.start]..self.scalar_bytes[stored_range.end]],
            stored_range,
            quote,
            remaining_work,
            is_cancelled,
        )
    }
}

pub(crate) struct TextAnchorResolver<'a> {
    index: TextScalarIndex<'a>,
    normalized: MappedNormalizedText,
}

impl<'a> TextAnchorResolver<'a> {
    #[cfg(test)]
    pub(crate) fn new(
        text: &'a str,
        remaining_work: &mut usize,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<Self, TextAnchorResolutionError> {
        let index = TextScalarIndex::new(text, remaining_work, is_cancelled)?;
        Self::from_index(index, remaining_work, is_cancelled)
    }

    pub(crate) fn from_index(
        index: TextScalarIndex<'a>,
        remaining_work: &mut usize,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<Self, TextAnchorResolutionError> {
        let normalized = mapped_normalized_quote_text(index.text, remaining_work, is_cancelled)?;
        Ok(Self { index, normalized })
    }

    pub(crate) fn resolve(
        &self,
        stored_range: Range<usize>,
        quote: &QuoteSelector,
        remaining_work: &mut usize,
        is_cancelled: &dyn Fn() -> bool,
    ) -> Result<ResolvedTextAnchor, TextAnchorResolutionError> {
        if is_cancelled() {
            return Err(TextAnchorResolutionError::Cancelled);
        }
        if let Some(exact) =
            self.index
                .resolve_exact(stored_range.clone(), quote, remaining_work, is_cancelled)?
        {
            return Ok(exact);
        }

        let pattern = quote.exact.as_bytes();
        consume_resolution_work(remaining_work, pattern.len())?;
        let mut prefix_table = vec![0; pattern.len()];
        let mut matched = 0;
        let mut fallback_steps = 0;
        for index in 1..pattern.len() {
            if index % 1024 == 0 && is_cancelled() {
                return Err(TextAnchorResolutionError::Cancelled);
            }
            while matched > 0 && pattern[index] != pattern[matched] {
                if fallback_steps % 1024 == 0 && is_cancelled() {
                    return Err(TextAnchorResolutionError::Cancelled);
                }
                fallback_steps += 1;
                consume_resolution_work(remaining_work, 1)?;
                matched = prefix_table[matched - 1];
            }
            consume_resolution_work(remaining_work, 1)?;
            if pattern[index] == pattern[matched] {
                matched += 1;
                prefix_table[index] = matched;
            }
        }

        let mut candidate_count = 0;
        let mut only_candidate = None;
        let mut last_candidate = None;
        let mut contextual_candidate = None;
        let mut contextual_count = 0;
        let mut start_scalar = 0;
        let mut end_scalar = 0;
        let mut mapping_steps = 0;
        matched = 0;
        for (byte_index, byte) in self.normalized.text.bytes().enumerate() {
            if byte_index % 1024 == 0 && is_cancelled() {
                return Err(TextAnchorResolutionError::Cancelled);
            }
            while matched > 0 && byte != pattern[matched] {
                if fallback_steps % 1024 == 0 && is_cancelled() {
                    return Err(TextAnchorResolutionError::Cancelled);
                }
                fallback_steps += 1;
                consume_resolution_work(remaining_work, 1)?;
                matched = prefix_table[matched - 1];
            }
            consume_resolution_work(remaining_work, 1)?;
            if byte == pattern[matched] {
                matched += 1;
            }
            if matched != pattern.len() {
                continue;
            }
            let end_byte = byte_index + 1;
            let start_byte = end_byte - pattern.len();
            matched = prefix_table[matched - 1];
            while self.normalized.byte_offsets[start_scalar] < start_byte {
                if mapping_steps % 1024 == 0 && is_cancelled() {
                    return Err(TextAnchorResolutionError::Cancelled);
                }
                mapping_steps += 1;
                consume_resolution_work(remaining_work, 1)?;
                start_scalar += 1;
            }
            if self.normalized.byte_offsets[start_scalar] != start_byte {
                continue;
            }
            if end_scalar < start_scalar {
                end_scalar = start_scalar;
            }
            while self.normalized.byte_offsets[end_scalar] < end_byte {
                if mapping_steps % 1024 == 0 && is_cancelled() {
                    return Err(TextAnchorResolutionError::Cancelled);
                }
                mapping_steps += 1;
                consume_resolution_work(remaining_work, 1)?;
                end_scalar += 1;
            }
            if self.normalized.byte_offsets[end_scalar] != end_byte {
                continue;
            }
            let start = start_scalar;
            let end = end_scalar;
            if start >= end || !self.has_legal_profile_boundaries(start, end, remaining_work)? {
                continue;
            }
            let source_range = self.normalized.source_ranges[start].start
                ..self.normalized.source_ranges[end - 1].end;
            if last_candidate.as_ref() == Some(&source_range) {
                continue;
            }
            last_candidate = Some(source_range.clone());
            candidate_count += 1;
            if candidate_count == 1 {
                only_candidate = Some(source_range.clone());
            }
            if is_cancelled() {
                return Err(TextAnchorResolutionError::Cancelled);
            }
            consume_resolution_work(
                remaining_work,
                quote.prefix.len().saturating_add(quote.suffix.len()),
            )?;
            let matches_context = (quote.prefix.is_empty()
                || self.normalized.text[..start_byte]
                    .trim_end_matches(' ')
                    .ends_with(&quote.prefix))
                && (quote.suffix.is_empty()
                    || self.normalized.text[end_byte..]
                        .trim_start_matches(' ')
                        .starts_with(&quote.suffix));
            if matches_context {
                contextual_count += 1;
                if contextual_count == 1 {
                    contextual_candidate = Some(source_range);
                } else {
                    return Ok(ResolvedTextAnchor {
                        resolution: AnnotationResolution::Ambiguous,
                        range: None,
                    });
                }
            }
        }
        if candidate_count == 0 {
            return Ok(ResolvedTextAnchor {
                resolution: AnnotationResolution::Orphaned,
                range: None,
            });
        }

        let recovered = match contextual_count {
            1 => contextual_candidate,
            0 if candidate_count == 1 => only_candidate,
            _ => None,
        };
        Ok(ResolvedTextAnchor {
            resolution: if recovered.is_some() {
                AnnotationResolution::Recovered
            } else {
                AnnotationResolution::Ambiguous
            },
            range: recovered,
        })
    }

    fn has_legal_profile_boundaries(
        &self,
        start: usize,
        end: usize,
        remaining_work: &mut usize,
    ) -> Result<bool, TextAnchorResolutionError> {
        let start_range = &self.normalized.source_ranges[start];
        let mut omitted = start;
        while omitted > 0 && self.normalized.source_ranges[omitted - 1] == *start_range {
            consume_resolution_work(remaining_work, 1)?;
            omitted -= 1;
            let byte = self.normalized.byte_offsets[omitted];
            let next = self.normalized.byte_offsets[omitted + 1];
            if &self.normalized.text[byte..next] != " " {
                return Ok(false);
            }
        }
        let end_range = &self.normalized.source_ranges[end - 1];
        let mut omitted = end;
        while omitted < self.normalized.source_ranges.len()
            && self.normalized.source_ranges[omitted] == *end_range
        {
            consume_resolution_work(remaining_work, 1)?;
            let byte = self.normalized.byte_offsets[omitted];
            let next = self.normalized.byte_offsets[omitted + 1];
            if &self.normalized.text[byte..next] != " " {
                return Ok(false);
            }
            omitted += 1;
        }
        Ok(true)
    }
}

/// Resolve a persisted quote against the document's current Unicode-scalar
/// text. Stored offsets win when their normalized quote still matches; bounded
/// quote/context matching recovers a unique moved range without guessing when
/// repeated text remains ambiguous.
pub fn resolve_text_anchor(
    text: &str,
    stored_range: Range<usize>,
    quote: &QuoteSelector,
) -> Result<ResolvedTextAnchor, TextAnchorResolutionError> {
    quote
        .validate()
        .map_err(|_| TextAnchorResolutionError::InvalidSelector)?;
    let mut remaining_work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
    let index = TextScalarIndex::new(text, &mut remaining_work, &|| false)?;
    if let Some(exact) =
        index.resolve_exact(stored_range.clone(), quote, &mut remaining_work, &|| false)?
    {
        return Ok(exact);
    }
    TextAnchorResolver::from_index(index, &mut remaining_work, &|| false)
        .and_then(|resolver| resolver.resolve(stored_range, quote, &mut remaining_work, &|| false))
}

fn exact_text_anchor(
    selected: &str,
    stored_range: Range<usize>,
    quote: &QuoteSelector,
    remaining_work: &mut usize,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<Option<ResolvedTextAnchor>, TextAnchorResolutionError> {
    if let Some(original) = &quote.original
        && original.len() == selected.len()
    {
        let mut identical = true;
        for (selected, original) in selected
            .as_bytes()
            .chunks(1024)
            .zip(original.as_bytes().chunks(1024))
        {
            if is_cancelled() {
                return Err(TextAnchorResolutionError::Cancelled);
            }
            consume_resolution_work(remaining_work, selected.len())?;
            if selected != original {
                identical = false;
                break;
            }
        }
        if identical {
            return Ok(Some(ResolvedTextAnchor {
                resolution: AnnotationResolution::Exact,
                range: Some(stored_range),
            }));
        }
    }
    if bounded_normalize_quote_v1(selected, remaining_work, is_cancelled)? == quote.exact {
        Ok(Some(ResolvedTextAnchor {
            resolution: AnnotationResolution::Exact,
            range: Some(stored_range),
        }))
    } else {
        Ok(None)
    }
}

fn consume_resolution_work(
    remaining_work: &mut usize,
    amount: usize,
) -> Result<(), TextAnchorResolutionError> {
    *remaining_work = remaining_work
        .checked_sub(amount)
        .ok_or(TextAnchorResolutionError::WorkLimit)?;
    Ok(())
}

fn bounded_normalize_quote_v1(
    value: &str,
    remaining_work: &mut usize,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<String, TextAnchorResolutionError> {
    let mut source = value.chars().peekable();
    let mut profile_input = String::new();
    let mut since_cancel_check = 0;
    while let Some(character) = source.next() {
        if since_cancel_check >= 1024 {
            if is_cancelled() {
                return Err(TextAnchorResolutionError::Cancelled);
            }
            since_cancel_check = 0;
        }
        since_cancel_check += 1;
        consume_resolution_work(remaining_work, 1)?;
        if character == '\u{00ad}' {
            continue;
        }
        if character == '\r' {
            if source.peek().is_some_and(|next| *next == '\n') {
                source.next();
                since_cancel_check += 1;
                consume_resolution_work(remaining_work, 1)?;
            }
            profile_input.push('\n');
        } else {
            profile_input.push(character);
        }
    }
    let mut normalized_text = String::new();
    let mut pending_space = false;
    for_each_bounded_grapheme(
        &profile_input,
        remaining_work,
        is_cancelled,
        |grapheme, remaining_work| {
            let normalized = grapheme.nfc().collect::<String>();
            for (index, character) in normalized.chars().enumerate() {
                if index % 1024 == 0 && is_cancelled() {
                    return Err(TextAnchorResolutionError::Cancelled);
                }
                consume_resolution_work(remaining_work, 1)?;
                if quote_v1_whitespace(character) {
                    pending_space = !normalized_text.is_empty();
                } else {
                    if pending_space {
                        normalized_text.push(' ');
                        pending_space = false;
                    }
                    normalized_text.push(character);
                }
            }
            Ok(())
        },
    )?;
    Ok(normalized_text)
}

fn for_each_bounded_grapheme(
    value: &str,
    remaining_work: &mut usize,
    is_cancelled: &dyn Fn() -> bool,
    mut visit: impl FnMut(&str, &mut usize) -> Result<(), TextAnchorResolutionError>,
) -> Result<(), TextAnchorResolutionError> {
    if value.is_empty() {
        return Ok(());
    }
    // Keep the final grapheme pending until the next bounded window. This
    // preserves the context needed by ZWJ sequences and regional indicators
    // without allowing one adversarial cluster to monopolize cancellation.
    let mut pending_start = 0;
    let mut loaded_end = 0;
    loop {
        if is_cancelled() {
            return Err(TextAnchorResolutionError::Cancelled);
        }
        let mut added = 0;
        for character in value[loaded_end..]
            .chars()
            .take(MAX_TEXT_ANCHOR_GRAPHEME_SCALARS)
        {
            loaded_end += character.len_utf8();
            added += 1;
        }
        consume_resolution_work(remaining_work, added)?;

        let at_end = loaded_end == value.len();
        let window_start = pending_start;
        let mut graphemes = value[window_start..loaded_end]
            .grapheme_indices(true)
            .peekable();
        while let Some((offset, grapheme)) = graphemes.next() {
            if graphemes.peek().is_none() && !at_end {
                pending_start = window_start + offset;
                if grapheme.chars().count() > MAX_TEXT_ANCHOR_GRAPHEME_SCALARS {
                    return Err(TextAnchorResolutionError::WorkLimit);
                }
                break;
            }
            let grapheme_scalars = grapheme.chars().count();
            if grapheme_scalars > MAX_TEXT_ANCHOR_GRAPHEME_SCALARS {
                return Err(TextAnchorResolutionError::WorkLimit);
            }
            consume_resolution_work(remaining_work, grapheme_scalars)?;
            visit(grapheme, remaining_work)?;
            pending_start = window_start + offset + grapheme.len();
        }
        if at_end {
            return Ok(());
        }
    }
}

struct MappedNormalizedText {
    text: String,
    byte_offsets: Vec<usize>,
    source_ranges: Vec<Range<usize>>,
}

fn mapped_normalized_quote_text(
    value: &str,
    remaining_work: &mut usize,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<MappedNormalizedText, TextAnchorResolutionError> {
    let mut source = value.chars().enumerate().peekable();
    let mut profile_input = String::with_capacity(value.len());
    let mut input_ranges = Vec::with_capacity(value.len());
    let mut since_cancel_check = 0;
    while let Some((index, character)) = source.next() {
        if since_cancel_check >= 1024 {
            if is_cancelled() {
                return Err(TextAnchorResolutionError::Cancelled);
            }
            since_cancel_check = 0;
        }
        since_cancel_check += 1;
        consume_resolution_work(remaining_work, 1)?;
        if character == '\u{00ad}' {
            continue;
        }
        if character == '\r' {
            let end = if source.peek().is_some_and(|(_, next)| *next == '\n') {
                source.next();
                since_cancel_check += 1;
                consume_resolution_work(remaining_work, 1)?;
                index + 2
            } else {
                index + 1
            };
            profile_input.push('\n');
            input_ranges.push(index..end);
        } else {
            profile_input.push(character);
            input_ranges.push(index..index + 1);
        }
    }
    let mut text = String::with_capacity(profile_input.len());
    let mut source_ranges = Vec::with_capacity(profile_input.len());
    let mut pending_space: Option<Range<usize>> = None;
    let mut input_scalar_start = 0;
    for_each_bounded_grapheme(
        &profile_input,
        remaining_work,
        is_cancelled,
        |grapheme, remaining_work| {
            let grapheme_scalars = grapheme.chars().count();
            let start = input_scalar_start;
            let end = start + grapheme_scalars;
            let source_range = input_ranges[start].start..input_ranges[end - 1].end;
            let normalized = grapheme.nfc().collect::<String>();
            for (index, character) in normalized.chars().enumerate() {
                if index % 1024 == 0 && is_cancelled() {
                    return Err(TextAnchorResolutionError::Cancelled);
                }
                consume_resolution_work(remaining_work, 1)?;
                if quote_v1_whitespace(character) {
                    if !text.is_empty() {
                        pending_space = Some(match pending_space.take() {
                            Some(pending) => pending.start..source_range.end,
                            None => source_range.clone(),
                        });
                    }
                } else {
                    if let Some(pending) = pending_space.take() {
                        text.push(' ');
                        source_ranges.push(pending);
                    }
                    text.push(character);
                    source_ranges.push(source_range.clone());
                }
            }
            input_scalar_start = end;
            Ok(())
        },
    )?;
    drop(profile_input);
    drop(input_ranges);
    let mut byte_offsets = Vec::with_capacity(text.len().saturating_add(1));
    for (index, (byte, _)) in text.char_indices().enumerate() {
        if index % 1024 == 0 && is_cancelled() {
            return Err(TextAnchorResolutionError::Cancelled);
        }
        consume_resolution_work(remaining_work, 1)?;
        byte_offsets.push(byte);
    }
    byte_offsets.push(text.len());
    Ok(MappedNormalizedText {
        text,
        byte_offsets,
        source_ranges,
    })
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
        if self
            .local_path
            .as_ref()
            .is_some_and(|path| path.is_empty() || path.len() > MAX_LOCAL_PATH_BYTES)
        {
            bail!("annotation local path is empty or exceeds {MAX_LOCAL_PATH_BYTES} bytes");
        }
        if let Some(body) = &self.body {
            ensure_scalar_limit(body, MAX_ANNOTATION_BODY_SCALARS, "annotation body")?;
        }
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
        if let Some(provenance) = &self.provenance
            && (provenance.source_system.trim().is_empty()
                || provenance.source_system.len() > MAX_PROVENANCE_SYSTEM_BYTES
                || provenance
                    .source_id
                    .as_ref()
                    .is_some_and(|id| id.is_empty() || id.len() > MAX_PROVENANCE_ID_BYTES))
        {
            bail!("annotation provenance is empty or exceeds its byte limit");
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
    #[cfg(test)]
    persistence_gate: Option<Arc<AnnotationPersistenceTestGate>>,
    #[cfg(test)]
    list_gate: Option<Arc<AnnotationPersistenceTestGate>>,
    #[cfg(test)]
    fail_create_response: bool,
}

#[cfg(test)]
#[derive(Debug)]
pub(crate) struct AnnotationPersistenceTestGate {
    entered: Semaphore,
    release: Semaphore,
}

#[cfg(test)]
impl AnnotationPersistenceTestGate {
    pub(crate) fn new() -> Self {
        Self {
            entered: Semaphore::new(0),
            release: Semaphore::new(0),
        }
    }

    pub(crate) async fn wait_until_entered(&self) {
        self.entered.acquire().await.unwrap().forget();
    }

    pub(crate) fn release(&self) {
        self.release.add_permits(1);
    }
}

impl AnnotationStore {
    pub fn new(pool: SqlitePool) -> Self {
        Self {
            pool,
            #[cfg(test)]
            persistence_gate: None,
            #[cfg(test)]
            list_gate: None,
            #[cfg(test)]
            fail_create_response: false,
        }
    }

    #[cfg(test)]
    pub(crate) fn new_with_test_gates(
        pool: SqlitePool,
        persistence_gate: Option<Arc<AnnotationPersistenceTestGate>>,
        list_gate: Option<Arc<AnnotationPersistenceTestGate>>,
        fail_create_response: bool,
    ) -> Self {
        Self {
            pool,
            persistence_gate,
            list_gate,
            fail_create_response,
        }
    }

    #[cfg(test)]
    pub(crate) async fn execute_test_sql(&self, sql: &str) -> Result<()> {
        sqlx::query(sql).execute(&self.pool).await?;
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn test_pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub async fn create_async(&self, annotation: &NewAnnotation) -> Result<Annotation> {
        annotation.validate()?;
        let mut transaction = self
            .pool
            .begin()
            .await
            .context("failed to begin annotation insert")?;
        #[cfg(test)]
        if let Some(gate) = &self.persistence_gate {
            gate.entered.add_permits(1);
            gate.release.acquire().await.unwrap().forget();
        }
        let (format, epub, pdf) = match &annotation.target {
            AnnotationTarget::Epub(anchor) => ("epub", Some(anchor), None),
            AnnotationTarget::Pdf(anchor) => ("pdf", None, Some(anchor)),
        };
        let annotation_document_id = match &annotation.local_path {
            Some(local_path) => Some(
                ensure_annotation_document_version(
                    &mut transaction,
                    format,
                    local_path,
                    &annotation.fingerprint,
                )
                .await?,
            ),
            None => None,
        };
        let existing_ownership = if let Some(document_id) = annotation_document_id.as_ref() {
            let (owner, owner_count): (Option<i64>, i64) = sqlx::query_as(
                "SELECT MIN(book_id), COUNT(DISTINCT book_id)
                 FROM annotations
                 WHERE annotation_document_id = ? AND book_id IS NOT NULL",
            )
            .bind(document_id)
            .fetch_one(&mut *transaction)
            .await?;
            if owner_count > 1 {
                return Err(AnnotationAssociationConflict.into());
            }
            owner
        } else {
            None
        };
        if existing_ownership.is_some()
            && annotation.book_id.is_some()
            && existing_ownership != annotation.book_id
        {
            return Err(AnnotationAssociationConflict.into());
        }
        let book_id = if existing_ownership.is_some() {
            existing_ownership
        } else if annotation.book_id.is_some() {
            annotation.book_id
        } else if let Some(document_id) = annotation_document_id.as_ref() {
            sqlx::query_scalar::<_, i64>(
                "SELECT b.id
                 FROM annotation_document_versions v
                 JOIN books b
                   ON b.file_path = v.local_path
                  AND b.content_hash = CAST(v.fingerprint AS TEXT)
                 WHERE v.document_id = ?
                   AND v.fingerprint_algorithm = 'sha256-hex'
                 ORDER BY b.id LIMIT 1",
            )
            .bind(document_id)
            .fetch_optional(&mut *transaction)
            .await?
        } else {
            None
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
                id, book_id, local_path, annotation_document_id, format, anchor_version,
                fingerprint_algorithm, fingerprint_version, fingerprint,
                original_quote, normalization_profile, normalized_exact,
                normalized_prefix, normalized_suffix, color, body,
                source_system, source_id, epub_spine_occurrence,
                epub_resource_path, epub_scalar_start, epub_scalar_end,
                pdf_page, pdf_char_start, pdf_char_end)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(annotation.id.to_string())
        .bind(book_id)
        .bind(&annotation.local_path)
        .bind(annotation_document_id)
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
        ensure_annotation_snapshot_within_limits(&mut transaction, &annotation.id).await?;
        #[cfg(test)]
        if self.fail_create_response {
            bail!("injected annotation response preparation failure");
        }
        let id = annotation.id.to_string();
        let row = sqlx::query("SELECT * FROM annotations WHERE id = ?")
            .bind(&id)
            .fetch_optional(&mut *transaction)
            .await
            .context("failed to prepare inserted annotation")?
            .context("annotation missing after insert")?;
        let rectangle_rows = sqlx::query(
            "SELECT left, bottom, right, top FROM annotation_pdf_rectangles
             WHERE annotation_id = ? ORDER BY rect_index LIMIT ?",
        )
        .bind(id)
        .bind(i64::try_from(MAX_PDF_RECTANGLES + 1).expect("rectangle limit fits in i64"))
        .fetch_all(&mut *transaction)
        .await
        .context("failed to prepare inserted annotation rectangles")?;
        let created = row_to_annotation(row, rows_to_rectangles(rectangle_rows)?)?;
        transaction
            .commit()
            .await
            .context("failed to commit annotation")?;
        Ok(created)
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
        let Some(row) = row else {
            return Ok(None);
        };
        let rectangles = self
            .load_pdf_rectangles(&row.try_get::<String, _>("id")?)
            .await?;
        row_to_annotation(row, rectangles).map(Some)
    }

    pub async fn list_for_book_async(&self, book_id: i64) -> Result<Vec<Annotation>> {
        let mut transaction = self
            .pool
            .begin()
            .await
            .context("failed to begin annotation list snapshot")?;
        ensure_book_annotation_snapshot(&mut transaction, book_id).await?;
        let limit = i64::try_from(MAX_ANNOTATIONS_PER_SNAPSHOT + 1)
            .expect("annotation snapshot limit fits in i64");
        let rows = sqlx::query(
            "SELECT * FROM annotations
             WHERE book_id = ? AND deleted_at IS NULL
             ORDER BY created_at, id LIMIT ?",
        )
        .bind(book_id)
        .bind(limit)
        .fetch_all(&mut *transaction)
        .await
        .context("failed to list annotations for book")?;
        if rows.len() > MAX_ANNOTATIONS_PER_SNAPSHOT {
            return Err(AnnotationSnapshotLimit.into());
        }
        let mut annotations = Vec::with_capacity(rows.len());
        let mut rectangle_count = 0usize;
        for row in rows {
            let id: String = row.try_get("id")?;
            let rectangle_rows = sqlx::query(
                "SELECT left, bottom, right, top FROM annotation_pdf_rectangles
                 WHERE annotation_id = ? ORDER BY rect_index LIMIT ?",
            )
            .bind(id)
            .bind(i64::try_from(MAX_PDF_RECTANGLES + 1).expect("rectangle limit fits in i64"))
            .fetch_all(&mut *transaction)
            .await
            .context("failed to load PDF annotation rectangles")?;
            rectangle_count = rectangle_count
                .checked_add(rectangle_rows.len())
                .ok_or(AnnotationSnapshotLimit)?;
            if rectangle_count > MAX_PDF_RECTANGLES_PER_SNAPSHOT {
                return Err(AnnotationSnapshotLimit.into());
            }
            annotations.push(row_to_annotation(row, rows_to_rectangles(rectangle_rows)?)?);
        }
        transaction
            .commit()
            .await
            .context("failed to finish annotation list snapshot")?;
        Ok(annotations)
    }

    /// List live annotations associated with an untracked device-local path.
    pub async fn list_for_local_path_async(&self, local_path: &str) -> Result<Vec<Annotation>> {
        self.list_for_local_document_async(local_path, AnnotationDocumentFormat::Epub, None)
            .await
    }

    pub(crate) async fn list_for_local_document_async(
        &self,
        local_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: Option<&DocumentFingerprint>,
    ) -> Result<Vec<Annotation>> {
        let mut transaction = self
            .pool
            .begin()
            .await
            .context("failed to begin annotation list snapshot")?;
        #[cfg(test)]
        if let Some(gate) = &self.list_gate {
            gate.entered.add_permits(1);
            gate.release.acquire().await.unwrap().forget();
        }
        let limit = i64::try_from(MAX_ANNOTATIONS_PER_SNAPSHOT + 1)
            .expect("annotation snapshot limit fits in i64");
        if let Some(fingerprint) = fingerprint {
            if let Some(representative) = sqlx::query_scalar::<_, String>(
                "SELECT a.id FROM annotations a
                 JOIN annotation_document_versions v
                   ON v.document_id = a.annotation_document_id
                 WHERE v.local_path = ? AND v.format = ?
                   AND v.fingerprint_algorithm = ? AND v.fingerprint_version = ?
                   AND v.fingerprint = ? AND a.deleted_at IS NULL LIMIT 1",
            )
            .bind(local_path)
            .bind(format.as_str())
            .bind(&fingerprint.algorithm)
            .bind(i64::from(fingerprint.version))
            .bind(&fingerprint.bytes)
            .fetch_optional(&mut *transaction)
            .await?
            {
                ensure_annotation_snapshot_within_limits(
                    &mut transaction,
                    &AnnotationId::from_str(&representative)?,
                )
                .await?;
            }
        } else {
            ensure_local_path_snapshot_within_limits(&mut transaction, local_path).await?;
        }
        let rows = if let Some(fingerprint) = fingerprint {
            sqlx::query(
                "SELECT a.* FROM annotations a
                 JOIN annotation_document_versions v
                   ON v.document_id = a.annotation_document_id
                 WHERE v.local_path = ?
                   AND v.format = ?
                   AND v.fingerprint_algorithm = ?
                   AND v.fingerprint_version = ?
                   AND v.fingerprint = ?
                   AND a.deleted_at IS NULL
                 ORDER BY a.created_at, a.id LIMIT ?",
            )
            .bind(local_path)
            .bind(format.as_str())
            .bind(&fingerprint.algorithm)
            .bind(i64::from(fingerprint.version))
            .bind(&fingerprint.bytes)
            .bind(limit)
            .fetch_all(&mut *transaction)
            .await
        } else {
            sqlx::query(
                "SELECT * FROM annotations
                 WHERE book_id IS NULL AND local_path = ? AND deleted_at IS NULL
                 ORDER BY created_at, id LIMIT ?",
            )
            .bind(local_path)
            .bind(limit)
            .fetch_all(&mut *transaction)
            .await
        }
        .context("failed to list annotations for local path")?;
        if rows.len() > MAX_ANNOTATIONS_PER_SNAPSHOT {
            return Err(AnnotationSnapshotLimit.into());
        }
        let mut annotations = Vec::with_capacity(rows.len());
        let mut rectangle_count = 0usize;
        for row in rows {
            let id: String = row.try_get("id")?;
            let rectangle_rows = sqlx::query(
                "SELECT left, bottom, right, top FROM annotation_pdf_rectangles WHERE annotation_id = ? ORDER BY rect_index LIMIT ?",
            )
            .bind(id)
            .bind(i64::try_from(MAX_PDF_RECTANGLES + 1).expect("rectangle limit fits in i64"))
            .fetch_all(&mut *transaction)
            .await
            .context("failed to load PDF annotation rectangles")?;
            rectangle_count = rectangle_count
                .checked_add(rectangle_rows.len())
                .ok_or(AnnotationSnapshotLimit)?;
            if rectangle_count > MAX_PDF_RECTANGLES_PER_SNAPSHOT {
                return Err(AnnotationSnapshotLimit.into());
            }
            annotations.push(row_to_annotation(row, rows_to_rectangles(rectangle_rows)?)?);
        }
        transaction
            .commit()
            .await
            .context("failed to finish annotation list snapshot")?;
        Ok(annotations)
    }

    pub async fn list_association_sources_async(
        &self,
        format: AnnotationDocumentFormat,
        target_local_path: &str,
        target_fingerprint: &DocumentFingerprint,
        cursor: Option<&AnnotationDocumentVersionId>,
        limit: usize,
    ) -> Result<AnnotationAssociationSourcePage> {
        self.list_association_sources_cancellable_async(
            format,
            target_local_path,
            target_fingerprint,
            cursor,
            limit,
            (|| false, std::future::pending()),
        )
        .await
    }

    pub async fn list_association_sources_cancellable_async<F, C>(
        &self,
        format: AnnotationDocumentFormat,
        target_local_path: &str,
        target_fingerprint: &DocumentFingerprint,
        cursor: Option<&AnnotationDocumentVersionId>,
        limit: usize,
        cancellation: (F, C),
    ) -> Result<AnnotationAssociationSourcePage>
    where
        F: Fn() -> bool + Send + Sync + 'static,
        C: Future<Output = ()> + Send,
    {
        let (is_cancelled, cancelled) = cancellation;
        let is_cancelled = Arc::new(is_cancelled);
        tokio::pin!(cancelled);
        if limit == 0 || limit > MAX_ANNOTATION_ASSOCIATION_SOURCES_PER_PAGE {
            return Err(AnnotationAssociationInvalidRequest(format!(
                "source limit must be between 1 and {MAX_ANNOTATION_ASSOCIATION_SOURCES_PER_PAGE}"
            ))
            .into());
        }
        if is_cancelled() {
            return Err(AnnotationAssociationSourceCancelled.into());
        }
        let mut connection = tokio::select! {
            connection = self.pool.acquire() => connection
                .context("failed to acquire annotation association source connection")?,
            () = &mut cancelled => return Err(AnnotationAssociationSourceCancelled.into()),
        };
        connection.close_on_drop();
        if is_cancelled() {
            return Err(AnnotationAssociationSourceCancelled.into());
        }
        let query_cancelled = Arc::new(AtomicBool::new(false));
        let work_exhausted = Arc::new(AtomicBool::new(false));
        let completed_work = Arc::new(AtomicUsize::new(0));
        {
            let query_cancelled = Arc::clone(&query_cancelled);
            let work_exhausted = Arc::clone(&work_exhausted);
            let completed_work = Arc::clone(&completed_work);
            let query_is_cancelled = Arc::clone(&is_cancelled);
            let mut handle = tokio::select! {
                handle = connection.lock_handle() => handle
                    .context("failed to configure annotation association source query")?,
                () = &mut cancelled => {
                    return Err(AnnotationAssociationSourceCancelled.into());
                }
            };
            handle.set_progress_handler(
                i32::try_from(ANNOTATION_ASSOCIATION_PROGRESS_INTERVAL)
                    .expect("SQLite progress interval fits in i32"),
                move || {
                    if query_is_cancelled() {
                        query_cancelled.store(true, Ordering::Release);
                        return false;
                    }
                    let work = completed_work
                        .fetch_add(ANNOTATION_ASSOCIATION_PROGRESS_INTERVAL, Ordering::Relaxed)
                        + ANNOTATION_ASSOCIATION_PROGRESS_INTERVAL;
                    if work >= MAX_ANNOTATION_ASSOCIATION_DISCOVERY_WORK {
                        work_exhausted.store(true, Ordering::Release);
                        return false;
                    }
                    true
                },
            );
        }
        if is_cancelled() {
            return Err(AnnotationAssociationSourceCancelled.into());
        }
        let result: Result<AnnotationAssociationSourcePage> = tokio::select! {
            result = async {
                let rows = sqlx::query(
                "WITH candidates AS MATERIALIZED (
               SELECT v.id, v.document_id, v.format, v.local_path,
                      v.fingerprint_algorithm, v.fingerprint_version, v.fingerprint
               FROM annotation_document_versions v
               WHERE v.format = ?
                 AND v.document_id != COALESCE((
                   SELECT target.document_id FROM annotation_document_versions target
                   WHERE target.local_path = ? AND target.format = ?
                     AND target.fingerprint_algorithm = ?
                     AND target.fingerprint_version = ? AND target.fingerprint = ?
                 ), '')
                 AND v.id > ?
                 AND EXISTS (
                   SELECT 1 FROM annotations a
                   WHERE a.annotation_document_id = v.document_id
                     AND a.deleted_at IS NULL
                 )
               ORDER BY v.id
               LIMIT ?
             )
             SELECT c.id, c.format, c.local_path, c.fingerprint_algorithm,
                    c.fingerprint_version, c.fingerprint,
                    (SELECT COUNT(*) FROM annotations a
                     WHERE a.annotation_document_id = c.document_id
                       AND a.deleted_at IS NULL) AS live_annotations
             FROM candidates c ORDER BY c.id",
            )
            .bind(format.as_str())
            .bind(target_local_path)
            .bind(format.as_str())
            .bind(&target_fingerprint.algorithm)
            .bind(i64::from(target_fingerprint.version))
            .bind(&target_fingerprint.bytes)
            .bind(cursor.map(ToString::to_string).unwrap_or_default())
            .bind(i64::try_from(limit + 1).expect("bounded source page limit fits in i64"))
            .fetch_all(&mut *connection)
            .await
            .context("failed to list annotation association sources")?;
            let has_more = rows.len() > limit;
            let mut sources = Vec::with_capacity(rows.len().min(limit));
            for row in rows.into_iter().take(limit) {
                let version_id =
                    AnnotationDocumentVersionId::from_str(&row.try_get::<String, _>("id")?)
                        .context("invalid annotation document version ID in database")?;
                sources.push(AnnotationAssociationSource {
                    version_id,
                    format: AnnotationDocumentFormat::from_db(
                        &row.try_get::<String, _>("format")?,
                    )?,
                    local_path: row.try_get("local_path")?,
                    fingerprint: DocumentFingerprint::new(
                        row.try_get::<String, _>("fingerprint_algorithm")?,
                        positive_u32(row.try_get("fingerprint_version")?, "fingerprint version")?,
                        row.try_get("fingerprint")?,
                    )?,
                    live_annotations: usize::try_from(row.try_get::<i64, _>("live_annotations")?)
                        .context("invalid live annotation count in database")?,
                });
            }
            let next_cursor = has_more
                .then(|| sources.last().map(|source| source.version_id.clone()))
                .flatten();
            let previous_cursor = if let Some(cursor) = cursor {
                let previous = sqlx::query_scalar::<_, String>(
                    "SELECT v.id FROM annotation_document_versions v
                 WHERE v.format = ?
                   AND v.document_id != COALESCE((
                     SELECT target.document_id FROM annotation_document_versions target
                     WHERE target.local_path = ? AND target.format = ?
                       AND target.fingerprint_algorithm = ?
                       AND target.fingerprint_version = ? AND target.fingerprint = ?
                   ), '')
                   AND v.id <= ?
                   AND EXISTS (
                     SELECT 1 FROM annotations a
                     WHERE a.annotation_document_id = v.document_id
                       AND a.deleted_at IS NULL
                   )
                 ORDER BY v.id DESC LIMIT ?",
                )
                .bind(format.as_str())
                .bind(target_local_path)
                .bind(format.as_str())
                .bind(&target_fingerprint.algorithm)
                .bind(i64::from(target_fingerprint.version))
                .bind(&target_fingerprint.bytes)
                .bind(cursor.to_string())
                .bind(i64::try_from(limit + 1).expect("bounded source page limit fits in i64"))
                .fetch_all(&mut *connection)
                .await
                .context("failed to locate previous annotation association source page")?;
                if previous.len() > limit {
                    Some(
                        AnnotationDocumentVersionId::from_str(&previous[limit])
                            .context("invalid previous annotation version cursor in database")?,
                    )
                } else {
                    None
                }
            } else {
                None
            };
                Ok(AnnotationAssociationSourcePage {
                    sources,
                    next_cursor,
                    previous_cursor,
                })
            } => result,
            () = &mut cancelled => {
                return Err(AnnotationAssociationSourceCancelled.into());
            }
        };
        tokio::select! {
            handle = connection.lock_handle() => handle
                .context("failed to clear annotation association source query budget")?
                .remove_progress_handler(),
            () = &mut cancelled => {
                return Err(AnnotationAssociationSourceCancelled.into());
            }
        }
        if query_cancelled.load(Ordering::Acquire) {
            Err(AnnotationAssociationSourceCancelled.into())
        } else if work_exhausted.load(Ordering::Acquire) {
            Err(AnnotationAssociationSourceWorkLimit.into())
        } else {
            result
        }
    }

    pub async fn associate_document_version_async(
        &self,
        source: &AnnotationDocumentVersionId,
        target_format: AnnotationDocumentFormat,
        target_local_path: &str,
        target_fingerprint: &DocumentFingerprint,
    ) -> Result<AnnotationAssociationOutcome> {
        self.associate_document_version_for_book_async(
            source,
            target_format,
            target_local_path,
            target_fingerprint,
            None,
        )
        .await
    }

    pub(crate) async fn associate_document_version_for_book_async(
        &self,
        source: &AnnotationDocumentVersionId,
        target_format: AnnotationDocumentFormat,
        target_local_path: &str,
        target_fingerprint: &DocumentFingerprint,
        book_id: Option<i64>,
    ) -> Result<AnnotationAssociationOutcome> {
        if target_local_path.is_empty() || target_local_path.len() > MAX_LOCAL_PATH_BYTES {
            bail!("annotation local path is empty or exceeds {MAX_LOCAL_PATH_BYTES} bytes");
        }
        target_fingerprint.validate()?;
        let mut transaction = self
            .pool
            .begin()
            .await
            .context("failed to begin annotation document association")?;
        #[cfg(test)]
        if let Some(gate) = &self.persistence_gate {
            gate.entered.add_permits(1);
            gate.release.acquire().await.unwrap().forget();
        }
        let source_id = source.to_string();
        let locked = sqlx::query(
            "UPDATE annotation_documents SET format = format
             WHERE id = (SELECT document_id FROM annotation_document_versions WHERE id = ?)",
        )
        .bind(&source_id)
        .execute(&mut *transaction)
        .await
        .context("failed to lock annotation document association")?;
        if locked.rows_affected() != 1 {
            return Err(AnnotationAssociationSourceNotFound.into());
        }
        let (document_id, source_format): (String, String) = sqlx::query_as(
            "SELECT v.document_id, d.format
             FROM annotation_document_versions v
             JOIN annotation_documents d ON d.id = v.document_id
             WHERE v.id = ?",
        )
        .bind(&source_id)
        .fetch_one(&mut *transaction)
        .await
        .context("failed to load annotation association source")?;
        if source_format != target_format.as_str() {
            return Err(AnnotationAssociationInvalidRequest(
                "selected source has a different document format".into(),
            )
            .into());
        }
        let existing = sqlx::query_scalar::<_, String>(
            "SELECT document_id FROM annotation_document_versions
             WHERE local_path = ? AND format = ? AND fingerprint_algorithm = ?
               AND fingerprint_version = ? AND fingerprint = ?",
        )
        .bind(target_local_path)
        .bind(target_format.as_str())
        .bind(&target_fingerprint.algorithm)
        .bind(i64::from(target_fingerprint.version))
        .bind(&target_fingerprint.bytes)
        .fetch_optional(&mut *transaction)
        .await
        .context("failed to resolve target annotation document version")?;
        if let Some(existing) = existing {
            if existing != document_id {
                let Some(book_id) = book_id else {
                    return Err(AnnotationAssociationConflict.into());
                };
                ensure_annotation_document_version_capacity(
                    &mut transaction,
                    &existing,
                    Some(&document_id),
                    0,
                )
                .await?;
                sqlx::query(
                    "UPDATE annotations
                     SET book_id = ?, local_path = ?, annotation_document_id = ?
                     WHERE book_id = ? OR annotation_document_id = ?
                        OR annotation_document_id = ?",
                )
                .bind(book_id)
                .bind(target_local_path)
                .bind(&existing)
                .bind(book_id)
                .bind(&existing)
                .bind(&document_id)
                .execute(&mut *transaction)
                .await?;
                sqlx::query(
                    "UPDATE annotation_document_versions SET document_id = ? WHERE document_id = ?",
                )
                .bind(&existing)
                .bind(&document_id)
                .execute(&mut *transaction)
                .await?;
                sqlx::query("DELETE FROM annotation_documents WHERE id = ?")
                    .bind(&document_id)
                    .execute(&mut *transaction)
                    .await?;
                if let Some(representative) = sqlx::query_scalar::<_, String>(
                    "SELECT id FROM annotations WHERE book_id = ? LIMIT 1",
                )
                .bind(book_id)
                .fetch_optional(&mut *transaction)
                .await?
                {
                    ensure_annotation_snapshot_within_limits(
                        &mut transaction,
                        &AnnotationId::from_str(&representative)?,
                    )
                    .await?;
                }
                transaction.commit().await?;
                return Ok(AnnotationAssociationOutcome::Associated);
            }
            if let Some(book_id) = book_id {
                sqlx::query(
                    "UPDATE annotations SET book_id = ?, local_path = ?
                     WHERE annotation_document_id = ?",
                )
                .bind(book_id)
                .bind(target_local_path)
                .bind(&document_id)
                .execute(&mut *transaction)
                .await?;
                ensure_book_annotation_snapshot(&mut transaction, book_id).await?;
            }
            transaction
                .commit()
                .await
                .context("failed to finish existing annotation association")?;
            return Ok(AnnotationAssociationOutcome::AlreadyAssociated);
        }
        let version_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM annotation_document_versions WHERE document_id = ?",
        )
        .bind(&document_id)
        .fetch_one(&mut *transaction)
        .await
        .context("failed to count annotation document versions")?;
        if usize::try_from(version_count).unwrap_or(usize::MAX) >= MAX_ANNOTATION_DOCUMENT_VERSIONS
        {
            return Err(AnnotationDocumentVersionLimit.into());
        }
        sqlx::query(
            "INSERT INTO annotation_document_versions (
                id, document_id, format, local_path, fingerprint_algorithm,
                fingerprint_version, fingerprint, associated_from_version_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(&document_id)
        .bind(target_format.as_str())
        .bind(target_local_path)
        .bind(&target_fingerprint.algorithm)
        .bind(i64::from(target_fingerprint.version))
        .bind(&target_fingerprint.bytes)
        .bind(source_id)
        .execute(&mut *transaction)
        .await
        .context("failed to associate annotation document version")?;
        if let Some(book_id) = book_id {
            sqlx::query(
                "UPDATE annotations SET book_id = ?, local_path = ?
                 WHERE annotation_document_id = ?",
            )
            .bind(book_id)
            .bind(target_local_path)
            .bind(&document_id)
            .execute(&mut *transaction)
            .await?;
            ensure_book_annotation_snapshot(&mut transaction, book_id).await?;
        }
        transaction
            .commit()
            .await
            .context("failed to commit annotation document association")?;
        Ok(AnnotationAssociationOutcome::Associated)
    }

    pub async fn update_async(
        &self,
        id: &AnnotationId,
        color: HighlightColor,
        body: Option<&str>,
    ) -> Result<bool> {
        if let Some(body) = body {
            ensure_scalar_limit(body, MAX_ANNOTATION_BODY_SCALARS, "annotation body")?;
        }
        let mut transaction = self
            .pool
            .begin()
            .await
            .context("failed to begin annotation update")?;
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
        .execute(&mut *transaction)
        .await
        .context("failed to update annotation")?;
        if result.rows_affected() == 1 {
            ensure_annotation_snapshot_within_limits(&mut transaction, id).await?;
        }
        transaction
            .commit()
            .await
            .context("failed to commit annotation update")?;
        Ok(result.rows_affected() == 1)
    }

    pub(crate) async fn update_for_local_document_async(
        &self,
        id: &AnnotationId,
        local_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
        color: HighlightColor,
        body: Option<&str>,
    ) -> Result<bool> {
        if let Some(body) = body {
            ensure_scalar_limit(body, MAX_ANNOTATION_BODY_SCALARS, "annotation body")?;
        }
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            "UPDATE annotations
             SET color = ?, body = ?, modified_at =
                 CASE
                     WHEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now') > modified_at
                     THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                     ELSE strftime('%Y-%m-%dT%H:%M:%fZ', modified_at, '+0.001 seconds')
                 END
             WHERE id = ? AND deleted_at IS NULL
               AND annotation_document_id = (
                 SELECT document_id FROM annotation_document_versions
                 WHERE local_path = ? AND format = ? AND fingerprint_algorithm = ?
                   AND fingerprint_version = ? AND fingerprint = ?
               )",
        )
        .bind(color.as_str())
        .bind(body)
        .bind(id.to_string())
        .bind(local_path)
        .bind(format.as_str())
        .bind(&fingerprint.algorithm)
        .bind(i64::from(fingerprint.version))
        .bind(&fingerprint.bytes)
        .execute(&mut *transaction)
        .await?;
        if result.rows_affected() == 1 {
            ensure_annotation_snapshot_within_limits(&mut transaction, id).await?;
        }
        transaction.commit().await?;
        Ok(result.rows_affected() == 1)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn update_for_book_document_async(
        &self,
        id: &AnnotationId,
        book_id: i64,
        local_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
        color: HighlightColor,
        body: Option<&str>,
    ) -> Result<bool> {
        if let Some(body) = body {
            ensure_scalar_limit(body, MAX_ANNOTATION_BODY_SCALARS, "annotation body")?;
        }
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            "UPDATE annotations
             SET color = ?, body = ?, modified_at =
                 CASE
                     WHEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now') > modified_at
                     THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                     ELSE strftime('%Y-%m-%dT%H:%M:%fZ', modified_at, '+0.001 seconds')
                 END
             WHERE id = ? AND deleted_at IS NULL AND (
               book_id = ? OR annotation_document_id = (
                 SELECT document_id FROM annotation_document_versions
                 WHERE local_path = ? AND format = ? AND fingerprint_algorithm = ?
                   AND fingerprint_version = ? AND fingerprint = ?
               )
             )",
        )
        .bind(color.as_str())
        .bind(body)
        .bind(id.to_string())
        .bind(book_id)
        .bind(local_path)
        .bind(format.as_str())
        .bind(&fingerprint.algorithm)
        .bind(i64::from(fingerprint.version))
        .bind(&fingerprint.bytes)
        .execute(&mut *transaction)
        .await?;
        if result.rows_affected() == 1 {
            ensure_annotation_snapshot_within_limits(&mut transaction, id).await?;
        }
        transaction.commit().await?;
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

    pub(crate) async fn reconcile_book_document(
        transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        book_id: i64,
        old_path: &str,
        new_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
    ) -> Result<()> {
        Self::reconcile_book_document_inner(
            transaction,
            book_id,
            old_path,
            new_path,
            format,
            fingerprint,
            false,
            false,
            Arc::new(AtomicBool::new(false)),
            #[cfg(test)]
            None,
            #[cfg(test)]
            None,
            #[cfg(test)]
            None,
        )
        .await
    }

    pub(crate) async fn reconcile_book_document_before_detach(
        transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        book_id: i64,
        old_path: &str,
        new_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
    ) -> Result<()> {
        Self::reconcile_book_document_inner(
            transaction,
            book_id,
            old_path,
            new_path,
            format,
            fingerprint,
            true,
            false,
            Arc::new(AtomicBool::new(false)),
            #[cfg(test)]
            None,
            #[cfg(test)]
            None,
            #[cfg(test)]
            None,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn reconcile_book_document_inner(
        transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        book_id: i64,
        old_path: &str,
        new_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
        ignore_foreign_exact_versions: bool,
        use_progress_budget: bool,
        cancelled: Arc<AtomicBool>,
        #[cfg(test)] progress_barrier: Option<Arc<std::sync::Barrier>>,
        #[cfg(test)] work_limit: Option<usize>,
        #[cfg(test)] persistence_gate: Option<&Arc<AnnotationPersistenceTestGate>>,
    ) -> Result<()> {
        if cancelled.load(Ordering::Acquire) {
            return Err(AnnotationReconciliationCancelled.into());
        }
        if !use_progress_budget {
            return Self::reconcile_book_document_work(
                transaction,
                book_id,
                old_path,
                new_path,
                format,
                fingerprint,
                ignore_foreign_exact_versions,
                None,
                #[cfg(test)]
                persistence_gate,
            )
            .await;
        }
        let work_exhausted = Arc::new(AtomicBool::new(false));
        let completed_work = Arc::new(AtomicUsize::new(0));
        let handler_active = Arc::new(AtomicBool::new(true));
        let budget_enabled = Arc::new(AtomicBool::new(true));
        #[cfg(test)]
        let progress_interval = if progress_barrier.is_some() || work_limit.is_some() {
            1
        } else {
            ANNOTATION_RECONCILIATION_PROGRESS_INTERVAL
        };
        #[cfg(not(test))]
        let progress_interval = ANNOTATION_RECONCILIATION_PROGRESS_INTERVAL;
        #[cfg(test)]
        let work_limit = work_limit.unwrap_or(MAX_ANNOTATION_RECONCILIATION_WORK);
        #[cfg(not(test))]
        let work_limit = MAX_ANNOTATION_RECONCILIATION_WORK;
        {
            let cancelled = Arc::clone(&cancelled);
            let work_exhausted = Arc::clone(&work_exhausted);
            let completed_work = Arc::clone(&completed_work);
            let handler_active = Arc::clone(&handler_active);
            let callback_budget_enabled = Arc::clone(&budget_enabled);
            #[cfg(test)]
            let mut progress_barrier = progress_barrier;
            let mut handle = transaction.as_mut().lock_handle().await?;
            handle.set_progress_handler(
                i32::try_from(progress_interval).expect("SQLite progress interval fits in i32"),
                move || {
                    if !handler_active.load(Ordering::Acquire) {
                        return true;
                    }
                    #[cfg(test)]
                    if let Some(barrier) = progress_barrier.take() {
                        barrier.wait();
                        barrier.wait();
                    }
                    if cancelled.load(Ordering::Acquire) {
                        handler_active.store(false, Ordering::Release);
                        return false;
                    }
                    if !callback_budget_enabled.load(Ordering::Acquire) {
                        return true;
                    }
                    let work = completed_work.fetch_add(progress_interval, Ordering::Relaxed)
                        + progress_interval;
                    if work >= work_limit {
                        work_exhausted.store(true, Ordering::Release);
                        handler_active.store(false, Ordering::Release);
                        return false;
                    }
                    true
                },
            );
        }
        let result = Self::reconcile_book_document_work(
            transaction,
            book_id,
            old_path,
            new_path,
            format,
            fingerprint,
            ignore_foreign_exact_versions,
            Some(budget_enabled),
            #[cfg(test)]
            persistence_gate,
        )
        .await;
        transaction
            .as_mut()
            .lock_handle()
            .await?
            .remove_progress_handler();
        if cancelled.load(Ordering::Acquire) {
            Err(AnnotationReconciliationCancelled.into())
        } else if work_exhausted.load(Ordering::Acquire) {
            Err(AnnotationReconciliationWorkLimit.into())
        } else {
            result
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn reconcile_book_document_work(
        transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        book_id: i64,
        old_path: &str,
        new_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
        ignore_foreign_exact_versions: bool,
        work_budget: Option<Arc<AtomicBool>>,
        #[cfg(test)] persistence_gate: Option<&Arc<AnnotationPersistenceTestGate>>,
    ) -> Result<()> {
        let current_versions = sqlx::query_as::<_, (String, String, i64)>(
            "SELECT document_id, local_path,
                    (SELECT COUNT(*) FROM (
                       SELECT 1 FROM annotation_document_versions candidate_version
                       WHERE candidate_version.document_id = annotation_document_versions.document_id
                       LIMIT ?
                     )) AS document_version_count
             FROM annotation_document_versions
             WHERE (local_path = ? OR local_path = ?)
               AND format = ? AND fingerprint_algorithm = ?
               AND fingerprint_version = ? AND fingerprint = ?
             ORDER BY (local_path = ?) DESC
             LIMIT 2",
        )
        .bind(i64::try_from(MAX_ANNOTATION_DOCUMENT_VERSIONS + 1).unwrap())
        .bind(new_path)
        .bind(old_path)
        .bind(format.as_str())
        .bind(&fingerprint.algorithm)
        .bind(i64::from(fingerprint.version))
        .bind(&fingerprint.bytes)
        .bind(new_path)
        .fetch_all(&mut **transaction)
        .await?;
        let mut rows = Vec::new();
        let mut considered_documents = HashSet::new();
        for (document_id, local_path, version_count) in current_versions {
            if considered_documents.insert(document_id.clone())
                && reconciliation_candidate_is_eligible(transaction, &document_id, book_id).await?
            {
                rows.push((document_id, local_path, version_count));
            }
        }
        let mut inspected_candidates = 0usize;
        let mut cursor: Option<(String, String)> = None;
        loop {
            let remaining = MAX_ANNOTATION_RECONCILIATION_CANDIDATES
                .saturating_sub(inspected_candidates)
                .saturating_add(1);
            let page_limit = remaining.min(MAX_ANNOTATION_DOCUMENT_VERSIONS + 1);
            let candidates = sqlx::query_as::<_, (String, String, String, String, i64)>(
                "SELECT document_id, local_path, associated_at, id,
                        (SELECT COUNT(*) FROM (
                           SELECT 1 FROM annotation_document_versions candidate_version
                           WHERE candidate_version.document_id = annotation_document_versions.document_id
                           LIMIT ?
                         )) AS document_version_count
                 FROM annotation_document_versions
                 WHERE local_path != ? AND local_path != ?
                   AND format = ? AND fingerprint_algorithm = ?
                   AND fingerprint_version = ? AND fingerprint = ?
                   AND (associated_at, id) > (?, ?)
                 ORDER BY associated_at, id
                 LIMIT ?",
            )
            .bind(i64::try_from(MAX_ANNOTATION_DOCUMENT_VERSIONS + 1).unwrap())
            .bind(new_path)
            .bind(old_path)
            .bind(format.as_str())
            .bind(&fingerprint.algorithm)
            .bind(i64::from(fingerprint.version))
            .bind(&fingerprint.bytes)
            .bind(
                cursor
                    .as_ref()
                    .map_or("", |(associated_at, _)| associated_at),
            )
            .bind(cursor.as_ref().map_or("", |(_, id)| id))
            .bind(i64::try_from(page_limit).unwrap())
            .fetch_all(&mut **transaction)
            .await?;
            if candidates.is_empty() {
                break;
            }
            inspected_candidates = inspected_candidates.saturating_add(candidates.len());
            if inspected_candidates > MAX_ANNOTATION_RECONCILIATION_CANDIDATES {
                return Err(AnnotationReconciliationWorkLimit.into());
            }
            let candidate_count = candidates.len();
            for (document_id, local_path, associated_at, id, version_count) in candidates {
                cursor = Some((associated_at, id));
                if considered_documents.insert(document_id.clone())
                    && reconciliation_candidate_is_eligible(transaction, &document_id, book_id)
                        .await?
                {
                    rows.push((document_id, local_path, version_count));
                }
            }
            if candidate_count < page_limit {
                break;
            }
        }
        #[cfg(test)]
        if let Some(gate) = persistence_gate {
            gate.entered.add_permits(1);
            gate.release.acquire().await.unwrap().forget();
        }
        if rows.len() > MAX_ANNOTATION_DOCUMENT_VERSIONS {
            return Err(AnnotationDocumentVersionLimit.into());
        }
        let candidate_documents = rows
            .iter()
            .map(|(document_id, _, _)| document_id.clone())
            .collect::<HashSet<_>>();
        let existing_old =
            annotation_document_for_version(transaction, old_path, format.as_str(), fingerprint)
                .await?;
        let existing_new = if old_path == new_path {
            existing_old.clone()
        } else {
            annotation_document_for_version(transaction, new_path, format.as_str(), fingerprint)
                .await?
        };
        if existing_old
            .as_ref()
            .is_some_and(|document| !candidate_documents.contains(document))
            || existing_new
                .as_ref()
                .is_some_and(|document| !candidate_documents.contains(document))
        {
            if ignore_foreign_exact_versions {
                let has_current_annotations: bool = sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM annotations WHERE book_id = ?)",
                )
                .bind(book_id)
                .fetch_one(&mut **transaction)
                .await?;
                if !has_current_annotations {
                    return Ok(());
                }
            }
            return Err(AnnotationAssociationConflict.into());
        }
        let mut has_old = existing_old.is_some();
        let mut has_new = existing_new.is_some();
        let mut version_count = 0usize;
        for candidate in &candidate_documents {
            let count = rows
                .iter()
                .find_map(|(document_id, _, count)| (document_id == candidate).then_some(*count))
                .unwrap_or(0);
            version_count = version_count
                .checked_add(usize::try_from(count).unwrap_or(usize::MAX))
                .ok_or(AnnotationDocumentVersionLimit)?;
        }
        let mut rewrite_rows = usize::try_from(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM (
                   SELECT 1 FROM annotations WHERE book_id = ? LIMIT ?
                 )",
            )
            .bind(book_id)
            .bind(i64::try_from(MAX_ANNOTATION_RECONCILIATION_ROWS + 1).unwrap())
            .fetch_one(&mut **transaction)
            .await?,
        )
        .unwrap_or(usize::MAX);
        if rewrite_rows > MAX_ANNOTATION_RECONCILIATION_ROWS {
            return Err(AnnotationReconciliationWorkLimit.into());
        }
        for candidate in &candidate_documents {
            let remaining = MAX_ANNOTATION_RECONCILIATION_ROWS - rewrite_rows;
            let additional = usize::try_from(
                sqlx::query_scalar::<_, i64>(
                    "SELECT COUNT(*) FROM (
                       SELECT 1 FROM annotations
                       WHERE annotation_document_id = ?
                         AND (book_id IS NULL OR book_id != ?)
                       LIMIT ?
                     )",
                )
                .bind(candidate)
                .bind(book_id)
                .bind(i64::try_from(remaining + 1).unwrap())
                .fetch_one(&mut **transaction)
                .await?,
            )
            .unwrap_or(usize::MAX);
            if additional > remaining {
                return Err(AnnotationReconciliationWorkLimit.into());
            }
            rewrite_rows += additional;
        }
        if let Some(work_budget) = work_budget {
            work_budget.store(false, Ordering::Release);
        }
        let document_id = if let Some((document_id, _, _)) = rows.first() {
            document_id.clone()
        } else {
            has_new = true;
            version_count = 1;
            ensure_annotation_document_version(transaction, format.as_str(), new_path, fingerprint)
                .await?
        };
        let additional_versions =
            usize::from(old_path != new_path && !has_old) + usize::from(!has_new);
        if version_count.saturating_add(additional_versions) > MAX_ANNOTATION_DOCUMENT_VERSIONS {
            return Err(AnnotationDocumentVersionLimit.into());
        }
        if old_path != new_path && !has_old {
            sqlx::query(
                "INSERT INTO annotation_document_versions (
                   id, document_id, format, local_path, fingerprint_algorithm,
                   fingerprint_version, fingerprint)
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(Uuid::new_v4().to_string())
            .bind(&document_id)
            .bind(format.as_str())
            .bind(old_path)
            .bind(&fingerprint.algorithm)
            .bind(i64::from(fingerprint.version))
            .bind(&fingerprint.bytes)
            .execute(&mut **transaction)
            .await?;
            has_old = true;
        }
        if !has_new {
            sqlx::query(
                "INSERT INTO annotation_document_versions (
                   id, document_id, format, local_path, fingerprint_algorithm,
                   fingerprint_version, fingerprint)
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(Uuid::new_v4().to_string())
            .bind(&document_id)
            .bind(format.as_str())
            .bind(new_path)
            .bind(&fingerprint.algorithm)
            .bind(i64::from(fingerprint.version))
            .bind(&fingerprint.bytes)
            .execute(&mut **transaction)
            .await?;
            has_new = true;
        }
        debug_assert!(has_old || old_path == new_path);
        debug_assert!(has_new);
        let merged_documents = rows
            .iter()
            .map(|(candidate, _, _)| candidate)
            .filter(|candidate| **candidate != document_id)
            .cloned()
            .collect::<HashSet<_>>();
        for merged in &merged_documents {
            sqlx::query(
                "UPDATE annotation_document_versions SET document_id = ? WHERE document_id = ?",
            )
            .bind(&document_id)
            .bind(merged)
            .execute(&mut **transaction)
            .await?;
        }
        sqlx::query(
            "UPDATE annotations
             SET book_id = ?, local_path = ?, annotation_document_id = ?
             WHERE book_id = ? OR annotation_document_id = ?",
        )
        .bind(book_id)
        .bind(new_path)
        .bind(&document_id)
        .bind(book_id)
        .bind(&document_id)
        .execute(&mut **transaction)
        .await?;
        for merged in &merged_documents {
            sqlx::query(
                "UPDATE annotations
                 SET book_id = ?, local_path = ?, annotation_document_id = ?
                 WHERE annotation_document_id = ?",
            )
            .bind(book_id)
            .bind(new_path)
            .bind(&document_id)
            .bind(merged)
            .execute(&mut **transaction)
            .await?;
        }
        for merged in merged_documents {
            sqlx::query("DELETE FROM annotation_documents WHERE id = ?")
                .bind(merged)
                .execute(&mut **transaction)
                .await?;
        }
        ensure_book_annotation_snapshot_within_limits(transaction, book_id).await?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn reconcile_opened_book_cancellable_async(
        &self,
        book_id: i64,
        local_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
        cancelled: Arc<AtomicBool>,
        cancellation_notifier: Arc<tokio::sync::Notify>,
        #[cfg(test)] progress_barrier: Option<Arc<std::sync::Barrier>>,
        #[cfg(test)] work_limit: Option<usize>,
        accept_commit: impl FnOnce() -> bool,
    ) -> Result<()> {
        let cancellation_notification = cancellation_notifier.notified();
        tokio::pin!(cancellation_notification);
        cancellation_notification.as_mut().enable();
        if cancelled.load(Ordering::Acquire) {
            return Err(AnnotationReconciliationCancelled.into());
        }
        let mut connection = tokio::select! {
            connection = self.pool.acquire() => connection
                .context("failed to acquire annotation reconciliation connection")?,
            () = &mut cancellation_notification => {
                return Err(AnnotationReconciliationCancelled.into());
            }
        };
        connection.close_on_drop();
        sqlx::query("PRAGMA busy_timeout = 0")
            .execute(&mut *connection)
            .await?;
        let mut attempts = 0usize;
        let mut transaction = loop {
            if cancelled.load(Ordering::Acquire) {
                return Err(AnnotationReconciliationCancelled.into());
            }
            match connection.begin_with("BEGIN IMMEDIATE").await {
                Ok(transaction) => break transaction,
                Err(error) if sqlite_is_busy(&error) => {
                    attempts += 1;
                    if attempts >= MAX_ANNOTATION_RECONCILIATION_BEGIN_RETRIES {
                        return Err(AnnotationReconciliationWorkLimit.into());
                    }
                    let cancellation_notification = cancellation_notifier.notified();
                    tokio::pin!(cancellation_notification);
                    cancellation_notification.as_mut().enable();
                    if cancelled.load(Ordering::Acquire) {
                        return Err(AnnotationReconciliationCancelled.into());
                    }
                    tokio::select! {
                        () = tokio::time::sleep(ANNOTATION_RECONCILIATION_BEGIN_RETRY_DELAY) => {}
                        () = &mut cancellation_notification => {
                            return Err(AnnotationReconciliationCancelled.into());
                        }
                    }
                }
                Err(error) => {
                    return Err(error.into());
                }
            }
        };
        let result = Self::reconcile_book_document_inner(
            &mut transaction,
            book_id,
            local_path,
            local_path,
            format,
            fingerprint,
            false,
            true,
            Arc::clone(&cancelled),
            #[cfg(test)]
            progress_barrier,
            #[cfg(test)]
            work_limit,
            #[cfg(test)]
            self.persistence_gate.as_ref(),
        )
        .await;
        if result.is_ok() && !accept_commit() {
            let _ = transaction.rollback().await;
            let _ = connection.close().await;
            return Err(AnnotationReconciliationCancelled.into());
        }
        match result {
            Ok(()) => transaction.commit().await?,
            Err(error) => {
                let _ = transaction.rollback().await;
                let _ = connection.close().await;
                return Err(error);
            }
        }
        let _ = connection.close().await;
        Ok(())
    }

    pub(crate) async fn bind_book_annotations_before_detach(
        transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        book_id: i64,
    ) -> Result<()> {
        let versions = sqlx::query(
            "SELECT DISTINCT format, local_path, fingerprint_algorithm,
                    fingerprint_version, fingerprint
             FROM annotations
             WHERE book_id = ? AND local_path IS NOT NULL
               AND annotation_document_id IS NULL",
        )
        .bind(book_id)
        .fetch_all(&mut **transaction)
        .await
        .context("failed to list book annotation document versions")?;
        for version in versions {
            let format: String = version.try_get("format")?;
            AnnotationDocumentFormat::from_db(&format)?;
            let local_path: String = version.try_get("local_path")?;
            let fingerprint = DocumentFingerprint::new(
                version.try_get::<String, _>("fingerprint_algorithm")?,
                positive_u32(
                    version.try_get("fingerprint_version")?,
                    "fingerprint version",
                )?,
                version.try_get("fingerprint")?,
            )?;
            let document_id =
                ensure_annotation_document_version(transaction, &format, &local_path, &fingerprint)
                    .await?;
            let foreign_owner = sqlx::query_scalar::<_, i64>(
                "SELECT book_id FROM annotations
                 WHERE annotation_document_id = ? AND book_id IS NOT NULL AND book_id != ?
                 LIMIT 1",
            )
            .bind(&document_id)
            .bind(book_id)
            .fetch_optional(&mut **transaction)
            .await?;
            if foreign_owner.is_some() {
                return Err(AnnotationAssociationConflict.into());
            }
            sqlx::query(
                "UPDATE annotations SET annotation_document_id = ?
                 WHERE book_id = ? AND annotation_document_id IS NULL
                   AND local_path = ? AND format = ?
                   AND fingerprint_algorithm = ? AND fingerprint_version = ?
                   AND fingerprint = ?",
            )
            .bind(document_id)
            .bind(book_id)
            .bind(local_path)
            .bind(format)
            .bind(&fingerprint.algorithm)
            .bind(i64::from(fingerprint.version))
            .bind(&fingerprint.bytes)
            .execute(&mut **transaction)
            .await
            .context("failed to bind detached book annotations")?;
        }
        let representatives = sqlx::query_scalar::<_, String>(
            "SELECT MIN(id) FROM annotations
             WHERE book_id = ? AND annotation_document_id IS NOT NULL
             GROUP BY annotation_document_id",
        )
        .bind(book_id)
        .fetch_all(&mut **transaction)
        .await
        .context("failed to identify detached annotation collections")?;
        sqlx::query(
            "UPDATE annotations SET book_id = NULL
             WHERE book_id = ? AND annotation_document_id IS NOT NULL",
        )
        .bind(book_id)
        .execute(&mut **transaction)
        .await
        .context("failed to detach bound book annotations")?;
        for representative in representatives {
            let annotation_id = AnnotationId::from_str(&representative)
                .context("invalid detached annotation ID in database")?;
            ensure_annotation_snapshot_within_limits(transaction, &annotation_id).await?;
        }
        Ok(())
    }

    pub(crate) async fn delete_for_local_document_async(
        &self,
        id: &AnnotationId,
        local_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
    ) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE annotations
             SET deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                 modified_at =
                 CASE
                     WHEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now') > modified_at
                     THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                     ELSE strftime('%Y-%m-%dT%H:%M:%fZ', modified_at, '+0.001 seconds')
                 END
             WHERE id = ? AND deleted_at IS NULL
               AND annotation_document_id = (
                 SELECT document_id FROM annotation_document_versions
                 WHERE local_path = ? AND format = ? AND fingerprint_algorithm = ?
                   AND fingerprint_version = ? AND fingerprint = ?
               )",
        )
        .bind(id.to_string())
        .bind(local_path)
        .bind(format.as_str())
        .bind(&fingerprint.algorithm)
        .bind(i64::from(fingerprint.version))
        .bind(&fingerprint.bytes)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub(crate) async fn delete_for_book_document_async(
        &self,
        id: &AnnotationId,
        book_id: i64,
        local_path: &str,
        format: AnnotationDocumentFormat,
        fingerprint: &DocumentFingerprint,
    ) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE annotations
             SET deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                 modified_at =
                 CASE
                     WHEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now') > modified_at
                     THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                     ELSE strftime('%Y-%m-%dT%H:%M:%fZ', modified_at, '+0.001 seconds')
                 END
             WHERE id = ? AND deleted_at IS NULL AND (
               book_id = ? OR annotation_document_id = (
                 SELECT document_id FROM annotation_document_versions
                 WHERE local_path = ? AND format = ? AND fingerprint_algorithm = ?
                   AND fingerprint_version = ? AND fingerprint = ?
               )
             )",
        )
        .bind(id.to_string())
        .bind(book_id)
        .bind(local_path)
        .bind(format.as_str())
        .bind(&fingerprint.algorithm)
        .bind(i64::from(fingerprint.version))
        .bind(&fingerprint.bytes)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    async fn load_pdf_rectangles(&self, annotation_id: &str) -> Result<Vec<PageRect>> {
        let rows = sqlx::query(
            "SELECT left, bottom, right, top FROM annotation_pdf_rectangles
             WHERE annotation_id = ? ORDER BY rect_index LIMIT ?",
        )
        .bind(annotation_id)
        .bind(i64::try_from(MAX_PDF_RECTANGLES + 1).expect("rectangle limit fits in i64"))
        .fetch_all(&self.pool)
        .await
        .context("failed to load PDF annotation rectangles")?;
        rows_to_rectangles(rows)
    }
}

async fn ensure_annotation_document_version_capacity(
    transaction: &mut Transaction<'_, Sqlite>,
    document_id: &str,
    merged_document_id: Option<&str>,
    additional_versions: usize,
) -> Result<()> {
    let version_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM annotation_document_versions
         WHERE document_id = ? OR (? IS NOT NULL AND document_id = ?)",
    )
    .bind(document_id)
    .bind(merged_document_id)
    .bind(merged_document_id)
    .fetch_one(&mut **transaction)
    .await?;
    let resulting_count = usize::try_from(version_count)
        .unwrap_or(usize::MAX)
        .saturating_add(additional_versions);
    if resulting_count > MAX_ANNOTATION_DOCUMENT_VERSIONS {
        return Err(AnnotationDocumentVersionLimit.into());
    }
    Ok(())
}

async fn reconciliation_candidate_is_eligible(
    transaction: &mut Transaction<'_, Sqlite>,
    document_id: &str,
    book_id: i64,
) -> Result<bool> {
    let (has_current_owner, has_lower_owner, has_higher_owner, has_other_path_owner): (
        bool,
        bool,
        bool,
        bool,
    ) = sqlx::query_as(
        "SELECT
           EXISTS(SELECT 1 FROM annotations
                  WHERE annotation_document_id = ? AND book_id = ?),
           EXISTS(SELECT 1 FROM annotations
                  WHERE annotation_document_id = ? AND book_id < ?),
           EXISTS(SELECT 1 FROM annotations
                  WHERE annotation_document_id = ? AND book_id > ?),
           EXISTS(
             SELECT 1
             FROM annotation_document_versions owned_version
             JOIN books b
               ON b.file_path = owned_version.local_path
                 OR b.original_path = owned_version.local_path
             WHERE owned_version.document_id = ? AND b.id != ?
               AND owned_version.fingerprint_algorithm = 'sha256-hex'
               AND owned_version.fingerprint_version = 1
               AND b.content_hash = CAST(owned_version.fingerprint AS TEXT)
           )",
    )
    .bind(document_id)
    .bind(book_id)
    .bind(document_id)
    .bind(book_id)
    .bind(document_id)
    .bind(book_id)
    .bind(document_id)
    .bind(book_id)
    .fetch_one(&mut **transaction)
    .await?;
    Ok(!has_lower_owner && !has_higher_owner && (has_current_owner || !has_other_path_owner))
}

async fn annotation_document_for_version(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    local_path: &str,
    format: &str,
    fingerprint: &DocumentFingerprint,
) -> Result<Option<String>> {
    sqlx::query_scalar(
        "SELECT document_id FROM annotation_document_versions
         WHERE local_path = ? AND format = ? AND fingerprint_algorithm = ?
           AND fingerprint_version = ? AND fingerprint = ?",
    )
    .bind(local_path)
    .bind(format)
    .bind(&fingerprint.algorithm)
    .bind(i64::from(fingerprint.version))
    .bind(&fingerprint.bytes)
    .fetch_optional(&mut **transaction)
    .await
    .context("failed to resolve annotation document version")
}

async fn ensure_annotation_document_version(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    format: &str,
    local_path: &str,
    fingerprint: &DocumentFingerprint,
) -> Result<String> {
    // Acquire SQLite's write lock before checking the binding so two first
    // annotations cannot both observe an absent version and deadlock while
    // upgrading deferred transactions.
    let document_id = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO annotation_documents (id, format) VALUES (?, ?)")
        .bind(&document_id)
        .bind(format)
        .execute(&mut **transaction)
        .await
        .context("failed to reserve annotation document")?;
    if let Some(retained_document_id) = sqlx::query_scalar::<_, String>(
        "SELECT document_id FROM annotation_document_versions
         WHERE local_path = ? AND format = ? AND fingerprint_algorithm = ?
           AND fingerprint_version = ? AND fingerprint = ?",
    )
    .bind(local_path)
    .bind(format)
    .bind(&fingerprint.algorithm)
    .bind(i64::from(fingerprint.version))
    .bind(&fingerprint.bytes)
    .fetch_optional(&mut **transaction)
    .await
    .context("failed to resolve annotation document version")?
    {
        sqlx::query("DELETE FROM annotation_documents WHERE id = ?")
            .bind(&document_id)
            .execute(&mut **transaction)
            .await
            .context("failed to remove unused annotation document")?;
        return Ok(retained_document_id);
    }

    let version_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO annotation_document_versions (
            id, document_id, format, local_path, fingerprint_algorithm,
            fingerprint_version, fingerprint)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(local_path, format, fingerprint_algorithm, fingerprint_version, fingerprint)
         DO NOTHING",
    )
    .bind(version_id)
    .bind(&document_id)
    .bind(format)
    .bind(local_path)
    .bind(&fingerprint.algorithm)
    .bind(i64::from(fingerprint.version))
    .bind(&fingerprint.bytes)
    .execute(&mut **transaction)
    .await
    .context("failed to create annotation document version")?;
    Ok(document_id)
}

async fn ensure_book_annotation_snapshot_within_limits(
    connection: &mut SqliteConnection,
    book_id: i64,
) -> Result<()> {
    let usage = sqlx::query(
        "SELECT COUNT(*) AS annotation_count,
                COALESCE(SUM(
                  LENGTH(CAST(a.id AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.local_path, '') AS BLOB)) +
                  LENGTH(CAST(a.fingerprint_algorithm AS BLOB)) +
                  LENGTH(CAST(a.fingerprint AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.body, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.original_quote, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalization_profile, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_exact, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_prefix, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_suffix, '') AS BLOB)) +
                  LENGTH(CAST(a.color AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.source_system, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.source_id, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.epub_resource_path, '') AS BLOB)) +
                  LENGTH(CAST(a.created_at AS BLOB)) +
                  LENGTH(CAST(a.modified_at AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.deleted_at, '') AS BLOB))
                ), 0) AS string_bytes,
                MAX(MAX(MAX(LENGTH(CAST(a.created_at AS BLOB)),
                            LENGTH(CAST(a.modified_at AS BLOB))),
                        LENGTH(CAST(COALESCE(a.deleted_at, '') AS BLOB)))) AS timestamp_bytes
         FROM annotations a
         WHERE a.book_id = ? AND a.deleted_at IS NULL",
    )
    .bind(book_id)
    .fetch_one(&mut *connection)
    .await
    .context("failed to measure book annotation snapshot")?;
    let annotation_count = usize::try_from(usage.try_get::<i64, _>("annotation_count")?)
        .map_err(|_| AnnotationSnapshotLimit)?;
    let string_bytes = usize::try_from(usage.try_get::<i64, _>("string_bytes")?)
        .map_err(|_| AnnotationSnapshotLimit)?;
    let timestamp_bytes = usage
        .try_get::<Option<i64>, _>("timestamp_bytes")?
        .unwrap_or(0);
    if usize::try_from(timestamp_bytes).unwrap_or(usize::MAX) > MAX_ANNOTATION_TIMESTAMP_BYTES {
        return Err(AnnotationSnapshotLimit.into());
    }
    let rectangle_count = usize::try_from(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*)
             FROM annotations a
             JOIN annotation_pdf_rectangles r ON r.annotation_id = a.id
             WHERE a.book_id = ? AND a.deleted_at IS NULL",
        )
        .bind(book_id)
        .fetch_one(&mut *connection)
        .await
        .context("failed to measure book annotation rectangles")?,
    )
    .map_err(|_| AnnotationSnapshotLimit)?;
    let retained_bytes = annotation_count
        .checked_mul(ANNOTATION_SNAPSHOT_BASE_BYTES)
        .and_then(|base| base.checked_add(string_bytes))
        .and_then(|bytes| {
            rectangle_count
                .checked_mul(std::mem::size_of::<PageRect>())
                .and_then(|rectangles| bytes.checked_add(rectangles))
        })
        .ok_or(AnnotationSnapshotLimit)?;
    ensure_annotation_snapshot_usage(annotation_count, retained_bytes, rectangle_count)
}

async fn ensure_annotation_snapshot_within_limits(
    connection: &mut SqliteConnection,
    annotation_id: &AnnotationId,
) -> Result<()> {
    let usage = sqlx::query(
        "WITH target AS (
           SELECT book_id, annotation_document_id, local_path,
                  fingerprint_algorithm, fingerprint_version, fingerprint
           FROM annotations WHERE id = ?
         )
         SELECT COUNT(*) AS annotation_count,
                COALESCE(SUM(
                  LENGTH(CAST(a.id AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.local_path, '') AS BLOB)) +
                  LENGTH(CAST(a.fingerprint_algorithm AS BLOB)) +
                  LENGTH(CAST(a.fingerprint AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.body, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.original_quote, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalization_profile, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_exact, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_prefix, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_suffix, '') AS BLOB)) +
                  LENGTH(CAST(a.color AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.source_system, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.source_id, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.epub_resource_path, '') AS BLOB)) +
                  LENGTH(CAST(a.created_at AS BLOB)) +
                  LENGTH(CAST(a.modified_at AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.deleted_at, '') AS BLOB))
                ), 0) AS string_bytes,
                MAX(MAX(MAX(LENGTH(CAST(a.created_at AS BLOB)),
                            LENGTH(CAST(a.modified_at AS BLOB))),
                        LENGTH(CAST(COALESCE(a.deleted_at, '') AS BLOB)))) AS timestamp_bytes
         FROM annotations a, target t
         WHERE a.deleted_at IS NULL AND (
           (t.book_id IS NOT NULL AND
            (a.book_id = t.book_id OR
             (t.annotation_document_id IS NOT NULL AND
              a.annotation_document_id = t.annotation_document_id))) OR
           (t.book_id IS NULL AND t.annotation_document_id IS NOT NULL AND
            a.annotation_document_id = t.annotation_document_id) OR
           (t.book_id IS NULL AND t.annotation_document_id IS NULL AND
            a.book_id IS NULL AND
            a.local_path = t.local_path AND
            a.fingerprint_algorithm = t.fingerprint_algorithm AND
            a.fingerprint_version = t.fingerprint_version AND
            a.fingerprint = t.fingerprint)
         )",
    )
    .bind(annotation_id.to_string())
    .fetch_one(&mut *connection)
    .await
    .context("failed to measure annotation snapshot")?;
    let annotation_count = usize::try_from(usage.try_get::<i64, _>("annotation_count")?)
        .map_err(|_| AnnotationSnapshotLimit)?;
    let string_bytes = usize::try_from(usage.try_get::<i64, _>("string_bytes")?)
        .map_err(|_| AnnotationSnapshotLimit)?;
    let timestamp_bytes = usage
        .try_get::<Option<i64>, _>("timestamp_bytes")?
        .unwrap_or(0);
    if usize::try_from(timestamp_bytes).unwrap_or(usize::MAX) > MAX_ANNOTATION_TIMESTAMP_BYTES {
        return Err(AnnotationSnapshotLimit.into());
    }
    let rectangle_count = usize::try_from(
        sqlx::query_scalar::<_, i64>(
            "WITH target AS (
               SELECT book_id, annotation_document_id, local_path,
                      fingerprint_algorithm, fingerprint_version, fingerprint
               FROM annotations WHERE id = ?
             )
             SELECT COUNT(*)
             FROM annotation_pdf_rectangles r
             JOIN annotations a ON a.id = r.annotation_id
             JOIN target t
             WHERE a.deleted_at IS NULL AND (
               (t.book_id IS NOT NULL AND
                (a.book_id = t.book_id OR
                 (t.annotation_document_id IS NOT NULL AND
                  a.annotation_document_id = t.annotation_document_id))) OR
               (t.book_id IS NULL AND t.annotation_document_id IS NOT NULL AND
                a.annotation_document_id = t.annotation_document_id) OR
               (t.book_id IS NULL AND t.annotation_document_id IS NULL AND
                a.book_id IS NULL AND
                a.local_path = t.local_path AND
                a.fingerprint_algorithm = t.fingerprint_algorithm AND
                a.fingerprint_version = t.fingerprint_version AND
                a.fingerprint = t.fingerprint)
             )",
        )
        .bind(annotation_id.to_string())
        .fetch_one(&mut *connection)
        .await
        .context("failed to measure annotation rectangles")?,
    )
    .map_err(|_| AnnotationSnapshotLimit)?;
    let retained_bytes = annotation_count
        .checked_mul(ANNOTATION_SNAPSHOT_BASE_BYTES)
        .and_then(|base| base.checked_add(string_bytes))
        .and_then(|bytes| {
            rectangle_count
                .checked_mul(std::mem::size_of::<PageRect>())
                .and_then(|rectangles| bytes.checked_add(rectangles))
        })
        .ok_or(AnnotationSnapshotLimit)?;

    ensure_annotation_snapshot_usage(annotation_count, retained_bytes, rectangle_count)
}

async fn ensure_local_path_snapshot_within_limits(
    connection: &mut SqliteConnection,
    local_path: &str,
) -> Result<()> {
    let usage = sqlx::query(
        "SELECT COUNT(*) AS annotation_count,
                COALESCE(SUM(
                  LENGTH(CAST(a.id AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.local_path, '') AS BLOB)) +
                  LENGTH(CAST(a.fingerprint_algorithm AS BLOB)) +
                  LENGTH(CAST(a.fingerprint AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.body, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.original_quote, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalization_profile, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_exact, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_prefix, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.normalized_suffix, '') AS BLOB)) +
                  LENGTH(CAST(a.color AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.source_system, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.source_id, '') AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.epub_resource_path, '') AS BLOB)) +
                  LENGTH(CAST(a.created_at AS BLOB)) +
                  LENGTH(CAST(a.modified_at AS BLOB)) +
                  LENGTH(CAST(COALESCE(a.deleted_at, '') AS BLOB))
                ), 0) AS string_bytes,
                MAX(MAX(MAX(LENGTH(CAST(a.created_at AS BLOB)),
                            LENGTH(CAST(a.modified_at AS BLOB))),
                        LENGTH(CAST(COALESCE(a.deleted_at, '') AS BLOB)))) AS timestamp_bytes
         FROM annotations a
         WHERE a.book_id IS NULL AND a.local_path = ? AND a.deleted_at IS NULL",
    )
    .bind(local_path)
    .fetch_one(&mut *connection)
    .await
    .context("failed to measure local-path annotation snapshot")?;
    let annotation_count = usize::try_from(usage.try_get::<i64, _>("annotation_count")?)
        .map_err(|_| AnnotationSnapshotLimit)?;
    let string_bytes = usize::try_from(usage.try_get::<i64, _>("string_bytes")?)
        .map_err(|_| AnnotationSnapshotLimit)?;
    let timestamp_bytes = usage
        .try_get::<Option<i64>, _>("timestamp_bytes")?
        .unwrap_or(0);
    if usize::try_from(timestamp_bytes).unwrap_or(usize::MAX) > MAX_ANNOTATION_TIMESTAMP_BYTES {
        return Err(AnnotationSnapshotLimit.into());
    }
    let rectangle_count = usize::try_from(
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM annotation_pdf_rectangles r
             JOIN annotations a ON a.id = r.annotation_id
             WHERE a.book_id IS NULL AND a.local_path = ? AND a.deleted_at IS NULL",
        )
        .bind(local_path)
        .fetch_one(&mut *connection)
        .await
        .context("failed to measure local-path annotation rectangles")?,
    )
    .map_err(|_| AnnotationSnapshotLimit)?;
    let retained_bytes = annotation_count
        .checked_mul(ANNOTATION_SNAPSHOT_BASE_BYTES)
        .and_then(|base| base.checked_add(string_bytes))
        .and_then(|bytes| {
            rectangle_count
                .checked_mul(std::mem::size_of::<PageRect>())
                .and_then(|rectangles| bytes.checked_add(rectangles))
        })
        .ok_or(AnnotationSnapshotLimit)?;
    ensure_annotation_snapshot_usage(annotation_count, retained_bytes, rectangle_count)
}

async fn ensure_book_annotation_snapshot(
    transaction: &mut Transaction<'_, Sqlite>,
    book_id: i64,
) -> Result<()> {
    if let Some(representative) =
        sqlx::query_scalar::<_, String>("SELECT id FROM annotations WHERE book_id = ? LIMIT 1")
            .bind(book_id)
            .fetch_optional(&mut **transaction)
            .await?
    {
        ensure_annotation_snapshot_within_limits(
            transaction,
            &AnnotationId::from_str(&representative)?,
        )
        .await?;
    }
    Ok(())
}

fn ensure_annotation_snapshot_usage(
    annotation_count: usize,
    retained_bytes: usize,
    rectangle_count: usize,
) -> Result<()> {
    if annotation_count > MAX_ANNOTATIONS_PER_SNAPSHOT
        || retained_bytes > MAX_ANNOTATION_SNAPSHOT_BYTES
        || rectangle_count > MAX_PDF_RECTANGLES_PER_SNAPSHOT
    {
        return Err(AnnotationSnapshotLimit.into());
    }
    Ok(())
}

fn row_to_annotation(row: SqliteRow, rectangles: Vec<PageRect>) -> Result<Annotation> {
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

fn rows_to_rectangles(rows: Vec<SqliteRow>) -> Result<Vec<PageRect>> {
    if rows.len() > MAX_PDF_RECTANGLES {
        bail!("PDF annotation exceeds {MAX_PDF_RECTANGLES} rectangles");
    }
    rows.into_iter()
        .map(|rectangle| {
            PageRect::new(
                rectangle.try_get("left")?,
                rectangle.try_get("bottom")?,
                rectangle.try_get("right")?,
                rectangle.try_get("top")?,
            )
        })
        .collect()
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
            graphemes[start..].concat().trim_start().to_owned()
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
            graphemes[..end].concat().trim_end().to_owned()
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

fn sqlite_is_busy(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .and_then(|code| code.parse::<i32>().ok())
        .is_some_and(|code| matches!(code & 0xff, 5 | 6))
}

fn ensure_scalar_limit(value: &str, limit: usize, field: &str) -> Result<()> {
    if value.chars().take(limit + 1).count() > limit {
        bail!("{field} exceeds {limit} Unicode scalars");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_anchor_resolution_distinguishes_exact_and_unique_recovery() {
        let original = "lead Cafe\u{301}\ttext tail";
        let quote = QuoteSelector::new("Cafe\u{301}\ttext", "lead ", " tail").unwrap();
        assert_eq!(
            resolve_text_anchor(original, 5..15, &quote).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Exact,
                range: Some(5..15),
            }
        );

        let changed = "inserted lead Café text tail";
        assert_eq!(
            resolve_text_anchor(changed, 5..15, &quote).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Recovered,
                range: Some(14..23),
            }
        );
    }

    #[test]
    fn text_anchor_resolution_uses_context_without_guessing_repeated_quotes() {
        let contextual = QuoteSelector::new("target", "alpha ", " omega").unwrap();
        assert_eq!(
            resolve_text_anchor("target noise alpha target omega", 1..7, &contextual).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Recovered,
                range: Some(19..25),
            }
        );

        let ambiguous = QuoteSelector::new("target", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor("target target", 1..7, &ambiguous).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Ambiguous,
                range: None,
            }
        );
        let overlapping = QuoteSelector::new("aa", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor("aaa", 1..2, &overlapping)
                .unwrap()
                .resolution,
            AnnotationResolution::Ambiguous,
        );
    }

    #[test]
    fn text_anchor_resolution_reports_missing_quotes_as_orphaned() {
        let quote = QuoteSelector::new("missing", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor("other text", 0..7, &quote).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Orphaned,
                range: None,
            }
        );
    }

    #[test]
    fn text_anchor_resolution_preserves_the_normalization_profile_at_source_boundaries() {
        let composed = QuoteSelector::new("é", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor("xe\u{00ad}\u{0301}", 0..1, &composed).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Recovered,
                range: Some(1..4),
            }
        );

        let partial_cluster = QuoteSelector::new("👩", "", "").unwrap();
        let resolved = resolve_text_anchor("x👩‍💻", 0..1, &partial_cluster).unwrap();
        assert_eq!(resolved.resolution, AnnotationResolution::Orphaned);
        assert!(resolved.range.is_none());

        let whitespace_cluster = QuoteSelector::new(" \u{0301}", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor("x \u{0301}", 0..1, &whitespace_cluster).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Recovered,
                range: Some(1..3),
            }
        );
    }

    #[test]
    fn text_anchor_resolution_observes_cancellation_and_work_limits() {
        let checks = std::cell::Cell::new(0);
        let text = "x".repeat(2_048);
        let mut work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
        assert!(matches!(
            TextAnchorResolver::new(&text, &mut work, &|| {
                checks.set(checks.get() + 1);
                checks.get() > 1
            }),
            Err(TextAnchorResolutionError::Cancelled)
        ));

        let mut work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
        let resolver = TextAnchorResolver::new("different", &mut work, &|| false).unwrap();
        let quote = QuoteSelector::new("missing", "", "").unwrap();
        assert!(matches!(
            resolver.resolve(0..1, &quote, &mut 0, &|| false),
            Err(TextAnchorResolutionError::WorkLimit)
        ));
    }

    #[test]
    fn text_anchor_resolution_bounds_adversarial_prefixes_and_graphemes() {
        let text = "a".repeat(32_768);
        let quote = QuoteSelector::new(&"a".repeat(16_384), "z", "").unwrap();
        let mut work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
        let resolver = TextAnchorResolver::new(&text, &mut work, &|| false).unwrap();
        assert_eq!(
            resolver
                .resolve(0..1, &quote, &mut work, &|| false)
                .unwrap()
                .resolution,
            AnnotationResolution::Ambiguous,
        );

        let combining = format!("e{}", "\u{0301}".repeat(1_025));
        let mut work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
        assert!(matches!(
            TextAnchorResolver::new(&combining, &mut work, &|| false),
            Err(TextAnchorResolutionError::WorkLimit)
        ));

        let mut work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
        let resolver = TextAnchorResolver::new(&text, &mut work, &|| false).unwrap();
        let checks = std::cell::Cell::new(0);
        assert!(matches!(
            resolver.resolve(0..1, &quote, &mut work, &|| {
                checks.set(checks.get() + 1);
                checks.get() > 1
            }),
            Err(TextAnchorResolutionError::Cancelled)
        ));
    }

    #[test]
    fn text_anchor_resolution_handles_unicode_across_workspace_chunks() {
        for selected in ["😀", "👩‍💻", "🇷🇸", "क्‍ष"] {
            let prefix = "a".repeat(1_023 + usize::from(selected == "😀"));
            let text = format!("{prefix}{selected}");
            let start = prefix.chars().count();
            let end = start + selected.chars().count();
            let quote = QuoteSelector::new(selected, "", "").unwrap();
            assert_eq!(
                resolve_text_anchor(&text, 0..1, &quote).unwrap(),
                ResolvedTextAnchor {
                    resolution: AnnotationResolution::Recovered,
                    range: Some(start..end),
                },
                "failed at a workspace boundary for {selected:?}",
            );
        }

        let split_zwj = format!("{}👩‍💻", "a".repeat(1_023));
        let laptop = QuoteSelector::new("💻", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor(&split_zwj, 0..1, &laptop)
                .unwrap()
                .resolution,
            AnnotationResolution::Orphaned,
        );

        let split_indicators = format!("{}🇷🇸🇮", "a".repeat(1_023));
        let flag = QuoteSelector::new("🇷🇸", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor(&split_indicators, 0..1, &flag).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Recovered,
                range: Some(1_023..1_025),
            }
        );
    }

    #[test]
    fn text_anchor_resolution_rejects_mutated_empty_selectors() {
        let mut quote = QuoteSelector::new("quote", "", "").unwrap();
        quote.exact.clear();
        assert!(matches!(
            resolve_text_anchor("quote", 0..5, &quote),
            Err(TextAnchorResolutionError::InvalidSelector)
        ));
    }

    #[test]
    fn text_anchor_resolution_handles_large_mismatching_stored_ranges() {
        let text = "a".repeat(131_072);
        let quote = QuoteSelector::new("missing", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor(&text, 0..text.len(), &quote)
                .unwrap()
                .resolution,
            AnnotationResolution::Orphaned,
        );
    }

    #[test]
    fn exact_text_anchor_does_not_scan_unrelated_graphemes() {
        let text = format!("ordinary e{}", "\u{301}".repeat(1_025));
        let quote = QuoteSelector::new("ordinary", "", "").unwrap();
        assert_eq!(
            resolve_text_anchor(&text, 0..8, &quote).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Exact,
                range: Some(0..8),
            }
        );

        let oversized = format!("e{}", "\u{301}".repeat(1_025));
        let quote = QuoteSelector::new(&oversized, "", "").unwrap();
        assert_eq!(
            resolve_text_anchor(&text, 9..1_035, &quote).unwrap(),
            ResolvedTextAnchor {
                resolution: AnnotationResolution::Exact,
                range: Some(9..1_035),
            }
        );
    }

    #[test]
    fn text_anchor_resolution_checks_cancellation_through_crlf_preprocessing() {
        let text = "x\r\n".repeat(2_048);
        let mut work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
        let checks = std::cell::Cell::new(0);
        assert!(matches!(
            mapped_normalized_quote_text(&text, &mut work, &|| {
                checks.set(checks.get() + 1);
                checks.get() > 1
            }),
            Err(TextAnchorResolutionError::Cancelled)
        ));
    }

    #[test]
    fn aggregate_snapshot_usage_enforces_each_limit() {
        assert!(
            ensure_annotation_snapshot_usage(
                MAX_ANNOTATIONS_PER_SNAPSHOT,
                MAX_ANNOTATION_SNAPSHOT_BYTES,
                MAX_PDF_RECTANGLES_PER_SNAPSHOT,
            )
            .is_ok()
        );
        for usage in [
            (
                MAX_ANNOTATIONS_PER_SNAPSHOT + 1,
                MAX_ANNOTATION_SNAPSHOT_BYTES,
                MAX_PDF_RECTANGLES_PER_SNAPSHOT,
            ),
            (
                MAX_ANNOTATIONS_PER_SNAPSHOT,
                MAX_ANNOTATION_SNAPSHOT_BYTES + 1,
                MAX_PDF_RECTANGLES_PER_SNAPSHOT,
            ),
            (
                MAX_ANNOTATIONS_PER_SNAPSHOT,
                MAX_ANNOTATION_SNAPSHOT_BYTES,
                MAX_PDF_RECTANGLES_PER_SNAPSHOT + 1,
            ),
        ] {
            let error = ensure_annotation_snapshot_usage(usage.0, usage.1, usage.2).unwrap_err();
            assert!(error.is::<AnnotationSnapshotLimit>());
        }
    }
}
