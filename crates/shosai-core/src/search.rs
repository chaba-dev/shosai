//! In-document search for PDF and EPUB formats.
//!
//! Provides case-insensitive text search across document pages or chapters,
//! returning a list of [`SearchMatch`] values that the GUI can use to navigate
//! results and highlight matches.

use crate::epub::EpubDoc;
use crate::epub::render::{ContentNode, TextSpan};
use crate::pdf::PdfDoc;
use unicode_casefold::UnicodeCaseFold;

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
pub fn search_pdf(doc: &PdfDoc, query: &str) -> Vec<SearchMatch> {
    if query.is_empty() {
        return Vec::new();
    }

    let mut results = Vec::new();
    if let Ok(pages) = doc.page_texts() {
        find_matches_in_pages(&pages, query, &mut results);
    }
    results
}

/// Search all chapters of an EPUB document for the given query (case-insensitive).
///
/// Extracts plain text from the chapter content nodes and searches within them.
pub fn search_epub(doc: &EpubDoc, query: &str) -> Vec<SearchMatch> {
    if query.is_empty() {
        return Vec::new();
    }

    let mut results = Vec::new();
    let chapters = extract_epub_text(doc);
    find_matches_in_pages(&chapters, query, &mut results);
    results
}

/// Extract searchable plain text from every EPUB chapter.
pub fn extract_epub_text(doc: &EpubDoc) -> Vec<String> {
    doc.content
        .chapters
        .iter()
        .map(|chapter| {
            let base_path = chapter
                .path
                .rsplit_once('/')
                .map(|(dir, _)| dir)
                .unwrap_or("");
            let nodes = crate::epub::render::parse_chapter_xhtml(
                &chapter.content,
                base_path,
                &doc.content.styles,
            );
            extract_text_from_nodes(&nodes)
        })
        .collect()
}

/// Search pre-extracted page or chapter text.
pub fn search_pages(pages: &[String], query: &str) -> Vec<SearchMatch> {
    let mut results = Vec::new();
    find_matches_in_pages(pages, query, &mut results);
    results
}

fn find_matches_in_pages(pages: &[String], query: &str, results: &mut Vec<SearchMatch>) {
    for (page, text) in pages.iter().enumerate() {
        find_matches_in_text(text, query, page, results);
    }
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
        ContentNode::Heading { text, .. } => out.push_str(text),
        ContentNode::Paragraph(spans, _) => extract_spans_text(spans, out),
        ContentNode::BlockQuote { children, .. } => {
            for child in children {
                extract_node_text(child, out);
                out.push('\n');
            }
        }
        ContentNode::UnorderedList(items) | ContentNode::OrderedList(items) => {
            for item_spans in items {
                extract_spans_text(item_spans, out);
                out.push('\n');
            }
        }
        ContentNode::CodeBlock { code, .. } => out.push_str(code),
        ContentNode::InlineCode(code) => out.push_str(code),
        ContentNode::Image { alt, .. } => out.push_str(alt),
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
) {
    find_matches_in_text(text, query, page, results);
}

/// Find all occurrences of `query` in `text` (case-insensitive) and append
/// to `results`.
fn find_matches_in_text(text: &str, query: &str, page: usize, results: &mut Vec<SearchMatch>) {
    if query.is_empty() {
        return;
    }

    let query_folded: String = query.case_fold().collect();
    if query_folded.is_empty() {
        return;
    }

    let original: Vec<char> = text.chars().collect();
    let mut text_folded = String::new();
    let mut original_boundaries = vec![Some(0)];
    for (original_index, character) in original.iter().copied().enumerate() {
        let folded_start = text_folded.len();
        for folded in character.case_fold() {
            text_folded.push(folded);
        }
        original_boundaries.resize(text_folded.len() + 1, None);
        if text_folded.len() == folded_start {
            original_boundaries[folded_start] = Some(original_index + 1);
        } else {
            original_boundaries[text_folded.len()] = Some(original_index + 1);
        }
    }

    let mut start = 0;
    while let Some(pos) = text_folded[start..].find(&query_folded) {
        let absolute_pos = start + pos;
        let folded_end = absolute_pos + query_folded.len();
        match (
            original_boundaries[absolute_pos],
            original_boundaries[folded_end],
        ) {
            (Some(original_start), Some(original_end)) => {
                // Build a context snippet (up to 40 chars before and after).
                let ctx_start = original_start.saturating_sub(40);
                let ctx_end = (original_end + 40).min(original.len());
                let context: String = original[ctx_start..ctx_end].iter().collect();
                let context = context.trim().replace('\n', " ");

                results.push(SearchMatch {
                    page,
                    offset: original_start,
                    length: original_end - original_start,
                    context,
                });

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
}

#[cfg(test)]
mod tests {
    use super::*;

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
                text: "Chapter One".to_string(),
                style: Default::default(),
            },
            ContentNode::Paragraph(
                vec![
                    TextSpan {
                        text: "Hello ".to_string(),
                        bold: false,
                        italic: false,
                        monospace: false,
                        link: None,
                    },
                    TextSpan {
                        text: "world".to_string(),
                        bold: true,
                        italic: false,
                        monospace: false,
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
}
