//! Parsed EPUB chapter content shared by search and reader presentation.

use anyhow::Result;
use std::collections::HashMap;
use std::io::Cursor;

use image::ImageReader;

use super::EpubLimits;
use super::render::{ContentNode, ImageSize};
use super::resource::CanonicalEpubPath;
use super::style::EpubStyles;
use super::types::{Chapter, StoredEpubResource};

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
        resources: &HashMap<CanonicalEpubPath, StoredEpubResource>,
        limits: &EpubLimits,
    ) -> Result<Self> {
        let image_sizes = resources
            .iter()
            .filter_map(|(path, resource)| {
                let format = image::guess_format(&resource.bytes).ok()?;
                let (width, height) =
                    ImageReader::with_format(Cursor::new(&resource.bytes), format)
                        .into_dimensions()
                        .ok()?;
                Some((path.as_str(), ImageSize { width, height }))
            })
            .collect::<HashMap<_, _>>();
        let chapters = chapters
            .iter()
            .map(|chapter| -> Result<_> {
                let mut parsed = super::render::parse_chapter_content_at_path_with_limits(
                    &chapter.content,
                    &chapter.path,
                    styles,
                    fonts,
                    limits,
                )?;
                populate_image_sizes(&mut parsed.nodes, &image_sizes);
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

fn populate_image_sizes(nodes: &mut [ContentNode], image_sizes: &HashMap<&str, ImageSize>) {
    for node in nodes {
        match node {
            ContentNode::Image {
                src,
                intrinsic_size,
                ..
            } => {
                *intrinsic_size = image_sizes.get(src.as_str()).copied();
            }
            ContentNode::BlockQuote { children, .. } => {
                populate_image_sizes(children, image_sizes);
            }
            ContentNode::Table { row_groups, .. } => {
                for cell in row_groups
                    .iter_mut()
                    .flat_map(|group| &mut group.rows)
                    .flat_map(|row| &mut row.cells)
                {
                    populate_image_sizes(&mut cell.children, image_sizes);
                }
            }
            _ => {}
        }
    }
}
