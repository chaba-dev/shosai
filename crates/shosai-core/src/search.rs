//! In-document search for PDF and EPUB formats.
//!
//! Provides case-insensitive text search across document pages or chapters,
//! returning a list of [`SearchMatch`] values that the GUI can use to navigate
//! results and highlight matches.

use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::document::Document;
use crate::epub::EpubDoc;
use crate::epub::render::{ContentNode, TextSpan};
use crate::pdf::{BoundedPageTextError, PdfDoc};
use unicode_casefold::UnicodeCaseFold;

const MIB: usize = 1024 * 1024;

/// Resource limits for one in-document search.
#[derive(Debug, Clone, Copy)]
pub struct SearchLimits {
    pub max_query_bytes: usize,
    pub max_indexed_text_bytes: usize,
    pub max_matches: usize,
    pub max_result_bytes: usize,
}

impl Default for SearchLimits {
    fn default() -> Self {
        Self {
            max_query_bytes: 4 * 1024,
            max_indexed_text_bytes: 8 * MIB,
            max_matches: 10_000,
            max_result_bytes: 8 * MIB,
        }
    }
}

/// Cooperative cancellation shared with a background search worker.
#[derive(Debug, Clone, Default)]
pub struct SearchCancellation(Arc<AtomicBool>);

impl SearchCancellation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

/// A structural search failure rather than a silently truncated result set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchError {
    Cancelled,
    QueryLimit {
        actual: usize,
        limit: usize,
    },
    TextLimit {
        actual: usize,
        limit: usize,
    },
    MatchLimit {
        limit: usize,
    },
    ResultLimit {
        actual: usize,
        limit: usize,
    },
    InvalidLimit {
        name: &'static str,
        requested: usize,
        maximum: usize,
    },
    Document(String),
}

impl fmt::Display for SearchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Cancelled => formatter.write_str("document search was cancelled"),
            Self::QueryLimit { actual, limit } => {
                write!(
                    formatter,
                    "search query exceeds byte limit ({actual} > {limit})"
                )
            }
            Self::TextLimit { actual, limit } => {
                write!(
                    formatter,
                    "search text exceeds byte limit ({actual} > {limit})"
                )
            }
            Self::MatchLimit { limit } => {
                write!(formatter, "search result count exceeds limit ({limit})")
            }
            Self::ResultLimit { actual, limit } => {
                write!(
                    formatter,
                    "search results exceed byte limit ({actual} > {limit})"
                )
            }
            Self::InvalidLimit {
                name,
                requested,
                maximum,
            } => write!(
                formatter,
                "search {name} limit exceeds hard maximum ({requested} > {maximum})"
            ),
            Self::Document(error) => write!(formatter, "failed to extract document text: {error}"),
        }
    }
}

impl std::error::Error for SearchError {}

/// A single search match within a document.
#[derive(Debug, Clone, PartialEq)]
pub struct SearchMatch {
    /// Page index (PDF/CBZ) or chapter index (EPUB).
    pub page: usize,
    /// Character offset within the page/chapter text where the match starts.
    pub offset: usize,
    /// Length of the match in characters.
    pub length: usize,
    /// A short snippet of surrounding context text.
    pub context: String,
}

/// Search all pages of a PDF document for the given query (case-insensitive).
///
/// Returns matches across all pages. For large documents this may be slow;
/// callers should consider running this on a background thread.
pub fn search_pdf(doc: &PdfDoc, query: &str) -> Result<Vec<SearchMatch>, SearchError> {
    search_pdf_with(
        doc,
        query,
        SearchLimits::default(),
        &SearchCancellation::new(),
    )
}

pub fn search_pdf_with(
    doc: &PdfDoc,
    query: &str,
    limits: SearchLimits,
    cancellation: &SearchCancellation,
) -> Result<Vec<SearchMatch>, SearchError> {
    let mut search = Search::new(query, limits, cancellation)?;
    if search.query_folded.is_empty() {
        return Ok(Vec::new());
    }
    for page in 0..doc.page_count() {
        search.check_cancelled()?;
        let remaining = search
            .limits
            .max_indexed_text_bytes
            .saturating_sub(search.indexed_bytes);
        let text = doc
            .page_text_bounded(page, remaining, || cancellation.is_cancelled())
            .map_err(|error| match error {
                BoundedPageTextError::Cancelled => SearchError::Cancelled,
                BoundedPageTextError::Limit { actual } => SearchError::TextLimit {
                    actual: search.indexed_bytes.saturating_add(actual),
                    limit: search.limits.max_indexed_text_bytes,
                },
                BoundedPageTextError::Document(error) => SearchError::Document(error.to_string()),
            })?;
        search.add_text(&text, page)?;
    }
    Ok(search.results)
}

/// Search all chapters of an EPUB document for the given query (case-insensitive).
///
/// Extracts plain text from the chapter content nodes and searches within them.
pub fn search_epub(doc: &EpubDoc, query: &str) -> Result<Vec<SearchMatch>, SearchError> {
    search_epub_with(
        doc,
        query,
        SearchLimits::default(),
        &SearchCancellation::new(),
    )
}

pub fn search_epub_with(
    doc: &EpubDoc,
    query: &str,
    limits: SearchLimits,
    cancellation: &SearchCancellation,
) -> Result<Vec<SearchMatch>, SearchError> {
    let mut search = Search::new(query, limits, cancellation)?;
    if search.query_folded.is_empty() {
        return Ok(Vec::new());
    }
    for (chapter, presentation) in doc.presentation().chapters().iter().enumerate() {
        search.add_text(presentation.search_text(), chapter)?;
    }
    Ok(search.results)
}

/// Extract searchable plain text from every EPUB chapter.
pub fn extract_epub_text(doc: &EpubDoc) -> Result<Vec<String>, SearchError> {
    let limits = SearchLimits::default();
    let mut bytes = 0_usize;
    let mut text = Vec::with_capacity(doc.presentation().chapters().len());
    for chapter in doc.presentation().chapters() {
        bytes = bytes.saturating_add(chapter.search_text().len());
        if bytes > limits.max_indexed_text_bytes {
            return Err(SearchError::TextLimit {
                actual: bytes,
                limit: limits.max_indexed_text_bytes,
            });
        }
        text.push(chapter.search_text().to_owned());
    }
    Ok(text)
}

/// Search pre-extracted page or chapter text.
pub fn search_pages(pages: &[String], query: &str) -> Result<Vec<SearchMatch>, SearchError> {
    search_pages_with(
        pages,
        query,
        SearchLimits::default(),
        &SearchCancellation::new(),
    )
}

pub fn search_pages_with(
    pages: &[String],
    query: &str,
    limits: SearchLimits,
    cancellation: &SearchCancellation,
) -> Result<Vec<SearchMatch>, SearchError> {
    let mut search = Search::new(query, limits, cancellation)?;
    if search.query_folded.is_empty() {
        return Ok(Vec::new());
    }
    for (page, text) in pages.iter().enumerate() {
        search.add_text(text, page)?;
    }
    Ok(search.results)
}

/// Extract plain text from a list of content nodes.
pub fn extract_text_from_nodes(nodes: &[ContentNode]) -> String {
    let mut text = String::new();
    for node in nodes {
        extract_node_text(node, &mut text);
        text.push('\n');
    }
    text
}

fn extract_node_text(node: &ContentNode, out: &mut String) {
    match node {
        ContentNode::Heading { spans, .. } => extract_spans_text(spans, out),
        ContentNode::Paragraph(spans, _) => extract_spans_text(spans, out),
        ContentNode::BlockQuote { children, .. } => {
            for child in children {
                extract_node_text(child, out);
                out.push('\n');
            }
        }
        ContentNode::Figure { children, .. } => {
            for (index, child) in children.iter().enumerate() {
                if index > 0 {
                    out.push('\n');
                }
                extract_node_text(child, out);
            }
        }
        ContentNode::Table {
            caption,
            row_groups,
            ..
        } => {
            extract_spans_text(caption, out);
            if !caption.is_empty() {
                out.push('\n');
            }
            for row in row_groups.iter().flat_map(|group| &group.rows) {
                for (index, cell) in row.cells.iter().enumerate() {
                    for (child_index, child) in cell.children.iter().enumerate() {
                        if cell.block_starts.contains(&child_index) {
                            out.push('\n');
                        }
                        extract_node_text(child, out);
                    }
                    if index + 1 < row.cells.len() {
                        out.push('\t');
                    }
                }
                out.push('\n');
            }
        }
        ContentNode::Math { content, .. } => out.push_str(&content.fallback),
        ContentNode::UnorderedList(items) | ContentNode::OrderedList { items, .. } => {
            for item_spans in items {
                extract_spans_text(item_spans, out);
                out.push('\n');
            }
        }
        ContentNode::CodeBlock { code, .. } => out.push_str(code),
        ContentNode::InlineCode(code) => out.push_str(code),
        ContentNode::Image { alt, caption, .. } => {
            out.push_str(alt);
            if !caption.is_empty() {
                out.push('\n');
                extract_spans_text(caption, out);
            }
        }
        ContentNode::HorizontalRule => {}
    }
}

fn extract_spans_text(spans: &[TextSpan], out: &mut String) {
    for span in spans {
        out.push_str(&span.text);
    }
}

/// Find all case-insensitive occurrences of `query` in `text` and append to
/// `results`.
///
/// This is the public entry point for callers that already have extracted text
/// (e.g. the app layer extracting PDF text page-by-page via pdfium).
pub fn find_matches_in_text_pub(
    text: &str,
    query: &str,
    page: usize,
    results: &mut Vec<SearchMatch>,
) -> Result<(), SearchError> {
    let cancellation = SearchCancellation::new();
    let mut search = Search::new(query, SearchLimits::default(), &cancellation)?;
    let result_bytes = results
        .iter()
        .map(search_match_byte_len)
        .fold(0_usize, usize::saturating_add);
    if results.len() > search.limits.max_matches {
        return Err(SearchError::MatchLimit {
            limit: search.limits.max_matches,
        });
    }
    if result_bytes > search.limits.max_result_bytes {
        return Err(SearchError::ResultLimit {
            actual: result_bytes,
            limit: search.limits.max_result_bytes,
        });
    }
    search.results = std::mem::take(results);
    search.result_bytes = result_bytes;
    let result = search.add_text(text, page);
    *results = search.results;
    result
}

struct Search<'a> {
    query_folded: String,
    limits: SearchLimits,
    cancellation: &'a SearchCancellation,
    indexed_bytes: usize,
    result_bytes: usize,
    results: Vec<SearchMatch>,
}

impl<'a> Search<'a> {
    fn new(
        query: &str,
        limits: SearchLimits,
        cancellation: &'a SearchCancellation,
    ) -> Result<Self, SearchError> {
        let hard = SearchLimits::default();
        for (name, requested, maximum) in [
            ("query bytes", limits.max_query_bytes, hard.max_query_bytes),
            (
                "indexed text bytes",
                limits.max_indexed_text_bytes,
                hard.max_indexed_text_bytes,
            ),
            ("match count", limits.max_matches, hard.max_matches),
            (
                "result bytes",
                limits.max_result_bytes,
                hard.max_result_bytes,
            ),
        ] {
            if requested > maximum {
                return Err(SearchError::InvalidLimit {
                    name,
                    requested,
                    maximum,
                });
            }
        }
        if query.len() > limits.max_query_bytes {
            return Err(SearchError::QueryLimit {
                actual: query.len(),
                limit: limits.max_query_bytes,
            });
        }
        Ok(Self {
            query_folded: query.case_fold().collect(),
            limits,
            cancellation,
            indexed_bytes: 0,
            result_bytes: 0,
            results: Vec::new(),
        })
    }

    fn check_cancelled(&self) -> Result<(), SearchError> {
        if self.cancellation.is_cancelled() {
            Err(SearchError::Cancelled)
        } else {
            Ok(())
        }
    }

    fn add_text(&mut self, text: &str, page: usize) -> Result<(), SearchError> {
        self.check_cancelled()?;
        self.indexed_bytes = self.indexed_bytes.saturating_add(text.len());
        if self.indexed_bytes > self.limits.max_indexed_text_bytes {
            return Err(SearchError::TextLimit {
                actual: self.indexed_bytes,
                limit: self.limits.max_indexed_text_bytes,
            });
        }
        if self.query_folded.is_empty() {
            return Ok(());
        }

        let original: Vec<char> = text.chars().collect();
        let mut text_folded = String::new();
        let mut original_boundaries = vec![(0_u32, 0_u32)];
        for (original_index, character) in original.iter().copied().enumerate() {
            self.check_cancelled()?;
            let folded_start = text_folded.len();
            for folded in character.case_fold() {
                text_folded.push(folded);
            }
            let boundary = (
                u32::try_from(text_folded.len()).expect("bounded search text fits in u32"),
                u32::try_from(original_index + 1).expect("bounded search text fits in u32"),
            );
            if text_folded.len() == folded_start {
                *original_boundaries
                    .last_mut()
                    .expect("initial boundary exists") = boundary;
            } else {
                original_boundaries.push(boundary);
            }
        }

        let mut start = 0;
        while let Some(absolute_pos) = self.find_next(&text_folded, start)? {
            let folded_end = absolute_pos + self.query_folded.len();
            match (
                search_original_boundary(&original_boundaries, absolute_pos),
                search_original_boundary(&original_boundaries, folded_end),
            ) {
                (Some(original_start), Some(original_end)) => {
                    if self.results.len() >= self.limits.max_matches {
                        return Err(SearchError::MatchLimit {
                            limit: self.limits.max_matches,
                        });
                    }
                    let ctx_start = original_start.saturating_sub(40);
                    let ctx_end = (original_end + 40).min(original.len());
                    let context: String = original[ctx_start..ctx_end].iter().collect();
                    let context = context.trim().replace('\n', " ");
                    let result = SearchMatch {
                        page,
                        offset: original_start,
                        length: original_end - original_start,
                        context,
                    };
                    self.result_bytes = self
                        .result_bytes
                        .saturating_add(search_match_byte_len(&result));
                    if self.result_bytes > self.limits.max_result_bytes {
                        return Err(SearchError::ResultLimit {
                            actual: self.result_bytes,
                            limit: self.limits.max_result_bytes,
                        });
                    }
                    self.results.push(result);
                    start = folded_end;
                }
                _ => {
                    start = absolute_pos
                        + text_folded[absolute_pos..]
                            .chars()
                            .next()
                            .map(char::len_utf8)
                            .unwrap_or(1);
                }
            }
        }
        Ok(())
    }

    fn find_next(&self, text: &str, start: usize) -> Result<Option<usize>, SearchError> {
        const CANCELLATION_CHUNK_BYTES: usize = 64 * 1024;

        let mut cursor = start;
        while cursor < text.len() {
            self.check_cancelled()?;
            let mut primary_end = cursor
                .saturating_add(CANCELLATION_CHUNK_BYTES)
                .min(text.len());
            while primary_end > cursor && !text.is_char_boundary(primary_end) {
                primary_end -= 1;
            }
            let mut search_end = primary_end
                .saturating_add(self.query_folded.len())
                .saturating_add(4)
                .min(text.len());
            while search_end > primary_end && !text.is_char_boundary(search_end) {
                search_end -= 1;
            }
            if let Some(position) = text[cursor..search_end].find(&self.query_folded) {
                return Ok(Some(cursor + position));
            }
            cursor = primary_end;
        }
        Ok(None)
    }
}

fn search_original_boundary(boundaries: &[(u32, u32)], folded: usize) -> Option<usize> {
    let folded = u32::try_from(folded).ok()?;
    boundaries
        .binary_search_by_key(&folded, |(boundary, _)| *boundary)
        .ok()
        .map(|index| boundaries[index].1 as usize)
}

fn search_match_byte_len(result: &SearchMatch) -> usize {
    std::mem::size_of::<SearchMatch>().saturating_add(result.context.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find_matches_in_text(text: &str, query: &str, page: usize, results: &mut Vec<SearchMatch>) {
        find_matches_in_text_pub(text, query, page, results).unwrap();
    }

    #[test]
    fn test_find_matches_basic() {
        let mut results = Vec::new();
        find_matches_in_text("Hello World hello", "hello", 0, &mut results);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].page, 0);
        assert_eq!(results[0].offset, 0);
        assert_eq!(results[1].offset, 12);
    }

    #[test]
    fn test_find_matches_empty_query() {
        let mut results = Vec::new();
        find_matches_in_text("Hello World", "", 0, &mut results);
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn test_find_matches_no_match() {
        let mut results = Vec::new();
        find_matches_in_text("Hello World", "xyz", 0, &mut results);
        assert!(results.is_empty());
    }

    #[test]
    fn test_find_matches_case_insensitive() {
        let mut results = Vec::new();
        find_matches_in_text("Rust Programming in RUST", "rust", 0, &mut results);
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_find_matches_unicode_case_insensitive() {
        let mut results = Vec::new();
        find_matches_in_text("Σ", "ς", 0, &mut results);
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn test_match_range_and_context_refer_to_original_unicode_text() {
        let text = format!("{}target", "K".repeat(50));
        let mut results = Vec::new();
        find_matches_in_text(&text, "target", 0, &mut results);

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].offset, 50);
        assert_eq!(results[0].length, 6);
        assert!(results[0].context.contains("target"));
    }

    #[test]
    fn test_full_case_fold_expansion_maps_to_complete_original_characters() {
        let mut results = Vec::new();
        find_matches_in_text("Straße ﬁnd", "STRASSE", 0, &mut results);
        find_matches_in_text("Straße ﬁnd", "FIND", 0, &mut results);

        assert_eq!(results.len(), 2);
        assert_eq!((results[0].offset, results[0].length), (0, 6));
        assert_eq!((results[1].offset, results[1].length), (7, 3));
    }

    #[test]
    fn test_partial_case_fold_expansions_do_not_match() {
        let mut results = Vec::new();
        find_matches_in_text("aßb", "s", 0, &mut results);
        find_matches_in_text("aßb", "as", 0, &mut results);
        find_matches_in_text("aßb", "sb", 0, &mut results);

        assert!(results.is_empty());
    }

    #[test]
    fn test_extract_text_from_nodes() {
        let nodes = vec![
            ContentNode::Heading {
                level: 1,
                spans: vec![TextSpan {
                    text: "Chapter One".to_string(),
                    math: None,
                    font_family: None,
                    bold: true,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
                    preserve_whitespace: false,
                    link: None,
                }],
                style: Default::default(),
            },
            ContentNode::Paragraph(
                vec![
                    TextSpan {
                        text: "Hello ".to_string(),
                        math: None,
                        font_family: None,
                        bold: false,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
                        preserve_whitespace: false,
                        link: None,
                    },
                    TextSpan {
                        text: "world".to_string(),
                        math: None,
                        font_family: None,
                        bold: true,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
                        preserve_whitespace: false,
                        link: None,
                    },
                ],
                Default::default(),
            ),
        ];
        let text = extract_text_from_nodes(&nodes);
        assert!(text.contains("Chapter One"));
        assert!(text.contains("Hello world"));
    }

    #[test]
    fn test_context_snippet() {
        let mut results = Vec::new();
        let text = "This is a longer text with the word target somewhere in the middle of it";
        find_matches_in_text(text, "target", 0, &mut results);
        assert_eq!(results.len(), 1);
        assert!(results[0].context.contains("target"));
    }

    #[test]
    fn bounded_search_reports_query_text_match_and_result_limits() {
        let cancellation = SearchCancellation::new();
        let base = SearchLimits {
            max_query_bytes: 2,
            max_indexed_text_bytes: 5,
            max_matches: 1,
            max_result_bytes: SearchLimits::default().max_result_bytes,
        };

        assert_eq!(
            search_pages_with(&["a".to_owned()], "abc", base, &cancellation),
            Err(SearchError::QueryLimit {
                actual: 3,
                limit: 2
            })
        );
        assert_eq!(
            search_pages_with(
                &["aaa".to_owned(), "aaa".to_owned()],
                "z",
                base,
                &cancellation
            ),
            Err(SearchError::TextLimit {
                actual: 6,
                limit: 5
            })
        );
        assert_eq!(
            search_pages_with(&["a a".to_owned()], "a", base, &cancellation),
            Err(SearchError::MatchLimit { limit: 1 })
        );

        let result_limit = SearchLimits {
            max_query_bytes: 1,
            max_indexed_text_bytes: 1,
            max_matches: 1,
            max_result_bytes: std::mem::size_of::<SearchMatch>(),
        };
        assert!(matches!(
            search_pages_with(&["a".to_owned()], "a", result_limit, &cancellation),
            Err(SearchError::ResultLimit { .. })
        ));
    }

    #[test]
    fn bounded_search_observes_cancellation_before_indexing() {
        let cancellation = SearchCancellation::new();
        cancellation.cancel();

        assert_eq!(
            search_pages_with(
                &["searchable".repeat(1024)],
                "missing",
                SearchLimits::default(),
                &cancellation,
            ),
            Err(SearchError::Cancelled)
        );
    }

    #[test]
    fn configurable_limits_cannot_exceed_hard_maxima() {
        let limits = SearchLimits {
            max_indexed_text_bytes: usize::MAX,
            ..SearchLimits::default()
        };

        assert!(matches!(
            search_pages_with(
                &["text".to_owned()],
                "t",
                limits,
                &SearchCancellation::new()
            ),
            Err(SearchError::InvalidLimit {
                name: "indexed text bytes",
                ..
            })
        ));
    }

    #[test]
    fn public_accumulator_rejects_oversized_seed_without_mutating_it() {
        let seed = SearchMatch {
            page: 0,
            offset: 0,
            length: 1,
            context: String::new(),
        };
        let mut results = vec![seed; SearchLimits::default().max_matches + 1];
        let original = results.clone();

        assert_eq!(
            find_matches_in_text_pub("a", "a", 0, &mut results),
            Err(SearchError::MatchLimit {
                limit: SearchLimits::default().max_matches,
            })
        );
        assert_eq!(results, original);
    }

    #[test]
    fn chunked_search_finds_matches_across_cancellation_boundaries() {
        let mut text = "x".repeat(64 * 1024 - 2);
        text.push_str("target");

        let results = search_pages(&[text], "target").unwrap();

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].offset, 64 * 1024 - 2);
    }
}
