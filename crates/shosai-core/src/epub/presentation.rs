//! Parsed EPUB chapter content shared by search and reader presentation.

use super::EpubLimits;
use super::limits::svg_dimensions;
use super::render::{ContentNode, ImageKind, ImageSize, TextSpan};
use super::resource::CanonicalEpubPath;
use super::style::EpubStyles;
use super::types::{Chapter, StoredEpubResource};
use anyhow::Result;
use image::ImageReader;
use std::collections::HashMap;
use std::io::Cursor;

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
                if let Ok(format) = image::guess_format(&resource.bytes) {
                    let (width, height) =
                        ImageReader::with_format(Cursor::new(&resource.bytes), format)
                            .into_dimensions()
                            .ok()?;
                    Some((
                        path.as_str(),
                        (ImageSize { width, height }, ImageKind::Raster),
                    ))
                } else {
                    svg_intrinsic_size(&resource.bytes)
                        .map(|size| (path.as_str(), (size, ImageKind::Svg)))
                }
            })
            .collect::<HashMap<_, _>>();
        let mut presentations = Vec::with_capacity(chapters.len());
        let mut total_units = 0_usize;
        for chapter in chapters.iter() {
            let mut parsed = super::render::parse_chapter_content_at_path_with_limits(
                &chapter.content,
                &chapter.path,
                styles,
                fonts,
                limits,
            )?;
            total_units = total_units
                .checked_add(chapter_presentation_unit_count(
                    &parsed.nodes,
                    parsed.anchor_offsets.len(),
                ))
                .ok_or_else(|| {
                    crate::application::ResourceLimitError(
                        "EPUB aggregate presentation unit count overflowed".to_owned(),
                    )
                })?;
            if total_units > limits.max_total_presentation_nodes {
                crate::resource_limit!("EPUB exceeds aggregate presentation node limit");
            }
            populate_image_sizes(&mut parsed.nodes, &image_sizes);
            let search_text = crate::search::extract_text_from_nodes(&parsed.nodes);
            presentations.push(EpubChapterPresentation {
                nodes: parsed.nodes,
                search_text,
                anchor_offsets: parsed.anchor_offsets,
            });
        }
        Ok(Self {
            chapters: presentations,
        })
    }

    /// Parsed chapters in spine order.
    pub fn chapters(&self) -> &[EpubChapterPresentation] {
        &self.chapters
    }

    /// Get one parsed chapter by spine index.
    pub fn chapter(&self, index: usize) -> Option<&EpubChapterPresentation> {
        self.chapters.get(index)
    }

    pub(crate) fn retained_presentation_unit_count(&self) -> usize {
        self.chapters
            .iter()
            .map(|chapter| {
                chapter_presentation_unit_count(&chapter.nodes, chapter.anchor_offsets.len())
            })
            .sum()
    }
}

/// Count heap-backed presentation structures using the same unit that gates
/// aggregate admission and charges retained memory.
fn chapter_presentation_unit_count(nodes: &[ContentNode], anchor_count: usize) -> usize {
    // Charge the chapter presentation object itself as well as every retained
    // anchor-map entry, including anchors on elements that produce no nodes.
    1_usize
        .saturating_add(anchor_count)
        .saturating_add(presentation_unit_count(nodes))
}

fn presentation_unit_count(nodes: &[ContentNode]) -> usize {
    nodes.iter().fold(0_usize, |count, node| {
        let retained = match node {
            ContentNode::Heading { spans, .. } | ContentNode::Paragraph(spans, _) => {
                text_span_unit_count(spans)
            }
            ContentNode::BlockQuote { children, .. } | ContentNode::Figure { children, .. } => {
                presentation_unit_count(children)
            }
            ContentNode::Table {
                caption,
                row_groups,
                ..
            } => row_groups
                .iter()
                .fold(text_span_unit_count(caption), |total, group| {
                    group
                        .rows
                        .iter()
                        .fold(total.saturating_add(1), |total, row| {
                            row.cells
                                .iter()
                                .fold(total.saturating_add(1), |total, cell| {
                                    total
                                        .saturating_add(1)
                                        .saturating_add(cell.headers.len())
                                        .saturating_add(cell.block_starts.len())
                                        .saturating_add(presentation_unit_count(&cell.children))
                                })
                        })
                }),
            ContentNode::Math { content, .. } => math_content_unit_count(content),
            ContentNode::UnorderedList(items) => list_unit_count(items),
            ContentNode::OrderedList { items, .. } => list_unit_count(items),
            ContentNode::Image { caption, .. } => text_span_unit_count(caption),
            _ => 0,
        };
        count.saturating_add(1).saturating_add(retained)
    })
}

fn text_span_unit_count(spans: &[TextSpan]) -> usize {
    spans.iter().fold(0, |total, span| {
        total
            .saturating_add(1)
            .saturating_add(span.math.as_ref().map_or(0, math_content_unit_count))
    })
}

fn list_unit_count(items: &[Vec<TextSpan>]) -> usize {
    items.iter().fold(0, |total, item| {
        total
            .saturating_add(1)
            .saturating_add(text_span_unit_count(item))
    })
}

fn math_content_unit_count(content: &super::MathContent) -> usize {
    content
        .expression
        .as_ref()
        .map_or(0, math_expression_unit_count)
}

fn math_expression_unit_count(expression: &super::MathExpression) -> usize {
    use super::MathExpression;

    let children = match expression {
        MathExpression::Row(children) | MathExpression::SquareRoot(children) => children
            .iter()
            .map(math_expression_unit_count)
            .fold(0_usize, usize::saturating_add),
        MathExpression::Fraction(left, right)
        | MathExpression::Root(left, right)
        | MathExpression::Subscript(left, right)
        | MathExpression::Superscript(left, right) => {
            math_expression_unit_count(left).saturating_add(math_expression_unit_count(right))
        }
        MathExpression::SubSuperscript {
            base,
            subscript,
            superscript,
        } => math_expression_unit_count(base)
            .saturating_add(math_expression_unit_count(subscript))
            .saturating_add(math_expression_unit_count(superscript)),
        MathExpression::Fenced { content, .. } => content
            .iter()
            .map(math_expression_unit_count)
            .fold(0_usize, usize::saturating_add),
        MathExpression::Table(rows) => rows.iter().fold(0_usize, |total, row| {
            row.iter()
                .map(math_expression_unit_count)
                .fold(total.saturating_add(1), usize::saturating_add)
        }),
        MathExpression::Token(_) => 0,
    };
    1_usize.saturating_add(children)
}

fn svg_intrinsic_size(bytes: &[u8]) -> Option<ImageSize> {
    let dimensions = svg_dimensions(bytes)?;
    Some(ImageSize {
        width: dimensions.0,
        height: dimensions.1,
    })
}

fn populate_image_sizes(
    nodes: &mut [ContentNode],
    image_sizes: &HashMap<&str, (ImageSize, ImageKind)>,
) {
    for node in nodes {
        match node {
            ContentNode::Image {
                src,
                intrinsic_size,
                kind,
                ..
            } => {
                if let Some((size, resource_kind)) = image_sizes.get(src.as_str()).copied() {
                    *intrinsic_size = Some(size);
                    *kind = Some(resource_kind);
                }
            }
            ContentNode::BlockQuote { children, .. } | ContentNode::Figure { children, .. } => {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn svg_intrinsic_dimensions_use_the_admitted_viewport_or_viewbox() {
        assert_eq!(
            svg_intrinsic_size(
                br#"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"/>"#
            ),
            Some(ImageSize {
                width: 120,
                height: 60
            })
        );
        assert_eq!(
            svg_intrinsic_size(
                br#"<svg xmlns="http://www.w3.org/2000/svg" width="1in" height=".5in"/>"#
            ),
            Some(ImageSize {
                width: 96,
                height: 48
            })
        );
        assert_eq!(
            svg_intrinsic_size(
                br#"<svg xmlns="http://www.w3.org/2000/svg" width="120" viewBox="0 0 240 80"/>"#
            ),
            Some(ImageSize {
                width: 120,
                height: 40
            })
        );
        assert_eq!(
            svg_intrinsic_size(
                br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 80"/>"#
            ),
            Some(ImageSize {
                width: 240,
                height: 80
            })
        );
    }
}
