//! Parsed EPUB chapter content shared by search and reader presentation.

use anyhow::Result;
use std::collections::HashMap;

use super::EpubLimits;
use super::render::ContentNode;
use super::style::EpubStyles;
use super::types::Chapter;

/// Parsed content and searchable text for one spine chapter.
#[derive(Debug)]
pub struct EpubChapterPresentation {
    nodes: Vec<ContentNode>,
    search_text: String,
    anchor_offsets: HashMap<String, usize>,
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

    /// Character offset for a decoded XHTML element ID or legacy anchor name.
    pub fn anchor_offset(&self, anchor: &str) -> Option<usize> {
        self.anchor_offsets.get(anchor).copied()
    }
}

/// Immutable parsed presentation for every chapter in spine order.
#[derive(Debug)]
pub struct EpubPresentation {
    chapters: Vec<EpubChapterPresentation>,
}

impl EpubPresentation {
    pub(crate) fn parse(
        chapters: &[Chapter],
        styles: &EpubStyles,
        fonts: &super::font::EpubFontBook,
        limits: &EpubLimits,
    ) -> Result<Self> {
        let chapters = chapters
            .iter()
            .map(|chapter| -> Result<_> {
                let parsed = super::render::parse_chapter_content_at_path_with_limits(
                    &chapter.content,
                    &chapter.path,
                    styles,
                    fonts,
                    limits,
                )?;
                let search_text = crate::search::extract_text_from_nodes(&parsed.nodes);
                Ok(EpubChapterPresentation {
                    nodes: parsed.nodes,
                    search_text,
                    anchor_offsets: parsed.anchor_offsets,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self { chapters })
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
