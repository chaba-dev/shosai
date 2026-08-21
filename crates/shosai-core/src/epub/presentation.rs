//! Parsed EPUB chapter content shared by search and reader presentation.

use super::render::{ContentNode, parse_chapter_xhtml};
use super::style::StyleMap;
use super::types::Chapter;

/// Parsed content and searchable text for one spine chapter.
#[derive(Debug)]
pub struct EpubChapterPresentation {
    nodes: Vec<ContentNode>,
    search_text: String,
}

impl EpubChapterPresentation {
    /// Native content nodes parsed from the chapter XHTML.
    pub fn nodes(&self) -> &[ContentNode] {
        &self.nodes
    }

    /// Searchable text extracted from the same parsed content nodes.
    pub fn search_text(&self) -> &str {
        &self.search_text
    }
}

/// Immutable parsed presentation for every chapter in spine order.
#[derive(Debug)]
pub struct EpubPresentation {
    chapters: Vec<EpubChapterPresentation>,
}

impl EpubPresentation {
    pub(crate) fn parse(chapters: &[Chapter], styles: &StyleMap) -> Self {
        let chapters = chapters
            .iter()
            .map(|chapter| {
                let base_path = chapter
                    .path
                    .rsplit_once('/')
                    .map(|(directory, _)| directory)
                    .unwrap_or("");
                let nodes = parse_chapter_xhtml(&chapter.content, base_path, styles);
                let search_text = crate::search::extract_text_from_nodes(&nodes);
                EpubChapterPresentation { nodes, search_text }
            })
            .collect();
        Self { chapters }
    }

    /// Parsed chapters in spine order.
    pub fn chapters(&self) -> &[EpubChapterPresentation] {
        &self.chapters
    }

    /// Get one parsed chapter by spine index.
    pub fn chapter(&self, index: usize) -> Option<&EpubChapterPresentation> {
        self.chapters.get(index)
    }
}
