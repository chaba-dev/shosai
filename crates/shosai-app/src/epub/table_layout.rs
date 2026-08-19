//! Gate 0 table-layout spike. XHTML table structure is normalized into an
//! explicit Taffy grid; this is component evidence, not a CSS table algorithm.

use cosmic_text::{Attrs, Buffer, Family, FontSystem, Metrics, Shaping, Wrap};
use roxmltree::Node;
use taffy::Point;
use taffy::prelude::*;

use super::text_shaping::font_system;

const XHTML: &str = include_str!("../../tests/fixtures/native-table-layout.xhtml");
const CELL_PADDING: f32 = 8.0;
const MIN_TABLE_WIDTH: f32 = 360.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RowGroup {
    Head,
    Body,
    Foot,
}

#[derive(Clone, Debug, PartialEq)]
struct IntrinsicImage {
    source: String,
    alt: String,
    width: f32,
    height: f32,
}

#[derive(Clone, Debug, PartialEq)]
struct TableCell {
    id: String,
    group: RowGroup,
    header: bool,
    row: usize,
    column: usize,
    row_span: u16,
    column_span: u16,
    text: String,
    links: Vec<String>,
    images: Vec<IntrinsicImage>,
}

#[derive(Clone, Debug, PartialEq)]
struct TableModel {
    caption: String,
    row_count: usize,
    column_count: usize,
    cells: Vec<TableCell>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct BoxGeometry {
    location: Point<f32>,
    size: Size<f32>,
}

#[derive(Clone, Debug, PartialEq)]
struct CellEvidence {
    cell: TableCell,
    geometry: BoxGeometry,
}

#[derive(Clone, Debug, PartialEq)]
struct TableEvidence {
    viewport_width: f32,
    caption: BoxGeometry,
    table: BoxGeometry,
    cells: Vec<CellEvidence>,
}

#[derive(Clone, Debug)]
enum LeafContext {
    Caption(String),
    Cell(TableCell),
}

fn normalized_text(node: Node<'_, '_>) -> String {
    node.descendants()
        .filter(Node::is_text)
        .filter_map(|descendant| descendant.text())
        .flat_map(str::split_whitespace)
        .collect::<Vec<_>>()
        .join(" ")
}

fn positive_span(node: Node<'_, '_>, name: &str) -> u16 {
    let value = node.attribute(name).unwrap_or("1");
    let span = value
        .parse::<u16>()
        .unwrap_or_else(|_| panic!("{name} must be a positive integer"));
    assert!(span > 0, "{name} must be a positive integer");
    span
}

fn row_group(row: Node<'_, '_>, table: Node<'_, '_>) -> RowGroup {
    let group = row
        .ancestors()
        .take_while(|ancestor| *ancestor != table)
        .find(|ancestor| matches!(ancestor.tag_name().name(), "thead" | "tbody" | "tfoot"))
        .expect("every fixture row must belong to an explicit row group");
    match group.tag_name().name() {
        "thead" => RowGroup::Head,
        "tbody" => RowGroup::Body,
        "tfoot" => RowGroup::Foot,
        _ => unreachable!(),
    }
}

fn parse_table(xhtml: &str) -> TableModel {
    let document = roxmltree::Document::parse(xhtml).expect("table fixture must be valid XHTML");
    let table = document
        .descendants()
        .find(|node| node.has_tag_name("table"))
        .expect("fixture must contain a table");
    let caption = table
        .children()
        .find(|node| node.has_tag_name("caption"))
        .map(normalized_text)
        .expect("fixture table must have a caption");
    let rows = table
        .descendants()
        .filter(|node| node.has_tag_name("tr"))
        .collect::<Vec<_>>();
    let mut occupied = vec![Vec::<bool>::new(); rows.len()];
    let mut cells = Vec::new();
    let mut column_count = 0;

    for (row_index, row) in rows.iter().copied().enumerate() {
        let group = row_group(row, table);
        let mut column = 0;
        for cell in row
            .children()
            .filter(|node| matches!(node.tag_name().name(), "th" | "td"))
        {
            while occupied[row_index].get(column).copied().unwrap_or(false) {
                column += 1;
            }
            let row_span = positive_span(cell, "rowspan");
            let column_span = positive_span(cell, "colspan");
            assert!(
                row_index + usize::from(row_span) <= rows.len(),
                "rowspan must remain inside the explicit row groups"
            );
            for occupied_row in occupied
                .iter_mut()
                .skip(row_index)
                .take(usize::from(row_span))
            {
                occupied_row.resize(column + usize::from(column_span), false);
                assert!(
                    occupied_row[column..column + usize::from(column_span)]
                        .iter()
                        .all(|slot| !slot),
                    "table cells must not overlap"
                );
                occupied_row[column..column + usize::from(column_span)].fill(true);
            }
            column_count = column_count.max(column + usize::from(column_span));
            let links = cell
                .descendants()
                .filter(|node| node.has_tag_name("a"))
                .filter_map(|node| node.attribute("href"))
                .map(str::to_owned)
                .collect();
            let images = cell
                .descendants()
                .filter(|node| node.has_tag_name("img"))
                .map(|image| IntrinsicImage {
                    source: image
                        .attribute("src")
                        .expect("fixture image must have a source")
                        .to_owned(),
                    alt: image
                        .attribute("alt")
                        .expect("fixture image must have fallback text")
                        .to_owned(),
                    width: image
                        .attribute("width")
                        .expect("fixture image must have an intrinsic width")
                        .parse()
                        .expect("fixture image width must be numeric"),
                    height: image
                        .attribute("height")
                        .expect("fixture image must have an intrinsic height")
                        .parse()
                        .expect("fixture image height must be numeric"),
                })
                .collect();
            cells.push(TableCell {
                id: cell
                    .attribute("id")
                    .expect("fixture cells must have stable IDs")
                    .to_owned(),
                group,
                header: cell.has_tag_name("th"),
                row: row_index,
                column,
                row_span,
                column_span,
                text: normalized_text(cell),
                links,
                images,
            });
            column += usize::from(column_span);
        }
    }

    TableModel {
        caption,
        row_count: rows.len(),
        column_count,
        cells,
    }
}

fn shaped_size(font_system: &mut FontSystem, text: &str, width: Option<f32>) -> Size<f32> {
    let metrics = Metrics::new(16.0, 22.0);
    let mut buffer = Buffer::new(font_system, metrics);
    buffer.set_wrap(font_system, Wrap::WordOrGlyph);
    buffer.set_size(font_system, width, None);
    buffer.set_text(
        font_system,
        text,
        &Attrs::new().family(Family::Name("Inter Variable")),
        Shaping::Advanced,
        None,
    );
    buffer.shape_until_scroll(font_system, false);
    let mut size = Size::ZERO;
    for run in buffer.layout_runs() {
        size.width = size.width.max(run.line_w);
        size.height = size.height.max(run.line_top + run.line_height);
    }
    size
}

fn intrinsic_text_width(font_system: &mut FontSystem, text: &str, minimum: bool) -> f32 {
    if minimum {
        text.split_whitespace()
            .map(|word| shaped_size(font_system, word, None).width)
            .fold(0.0, f32::max)
    } else {
        shaped_size(font_system, text, None).width
    }
}

fn measure_leaf(
    known: Size<Option<f32>>,
    available: Size<AvailableSpace>,
    context: &LeafContext,
    font_system: &mut FontSystem,
) -> Size<f32> {
    let (text, images) = match context {
        LeafContext::Caption(text) => (text.as_str(), &[][..]),
        LeafContext::Cell(cell) => (cell.text.as_str(), cell.images.as_slice()),
    };
    let image_width = images.iter().map(|image| image.width).fold(0.0, f32::max);
    let image_height = images.iter().map(|image| image.height).fold(0.0, f32::max);
    let horizontal_padding = 2.0 * CELL_PADDING;
    let requested_width = known.width.or_else(|| match available.width {
        AvailableSpace::Definite(width) => Some(width),
        AvailableSpace::MinContent => Some(
            intrinsic_text_width(font_system, text, true).max(image_width) + horizontal_padding,
        ),
        AvailableSpace::MaxContent => Some(
            intrinsic_text_width(font_system, text, false).max(image_width) + horizontal_padding,
        ),
    });
    let width = requested_width.expect("table leaf width must be bounded");
    let content_width = (width - horizontal_padding).max(1.0);
    let text_size = shaped_size(font_system, text, Some(content_width));
    Size {
        width,
        height: known
            .height
            .unwrap_or(text_size.height.max(image_height) + 2.0 * CELL_PADDING),
    }
}

fn layout_table(model: TableModel, viewport_width: f32) -> TableEvidence {
    let mut tree = TaffyTree::new();
    tree.disable_rounding();
    let caption = tree
        .new_leaf_with_context(
            Style::default(),
            LeafContext::Caption(model.caption.clone()),
        )
        .expect("caption leaf must be valid");
    let mut cell_nodes = Vec::new();
    for cell in model.cells.iter().cloned() {
        let node = tree
            .new_leaf_with_context(
                Style {
                    grid_row: Line {
                        start: line(cell.row as i16 + 1),
                        end: span(cell.row_span),
                    },
                    grid_column: Line {
                        start: line(cell.column as i16 + 1),
                        end: span(cell.column_span),
                    },
                    ..Style::default()
                },
                LeafContext::Cell(cell.clone()),
            )
            .expect("table cell must be valid");
        cell_nodes.push((node, cell));
    }
    let children = cell_nodes.iter().map(|(node, _)| *node).collect::<Vec<_>>();
    let grid = tree
        .new_with_children(
            Style {
                display: Display::Grid,
                size: Size {
                    width: percent(1.0),
                    height: auto(),
                },
                min_size: Size {
                    width: length(MIN_TABLE_WIDTH),
                    height: auto(),
                },
                grid_template_columns: (0..model.column_count)
                    .map(|_| minmax(length(0.0), fr(1.0)))
                    .collect(),
                grid_template_rows: (0..model.row_count).map(|_| auto()).collect(),
                ..Style::default()
            },
            &children,
        )
        .expect("table grid must be valid");
    let root = tree
        .new_with_children(
            Style {
                display: Display::Block,
                size: Size {
                    width: length(viewport_width),
                    height: auto(),
                },
                ..Style::default()
            },
            &[caption, grid],
        )
        .expect("table root must be valid");
    let mut fonts = font_system();
    tree.compute_layout_with_measure(
        root,
        Size {
            width: AvailableSpace::Definite(viewport_width),
            height: AvailableSpace::MaxContent,
        },
        |known, available, _, context, _| {
            context.map_or(Size::ZERO, |context| {
                measure_leaf(known, available, context, &mut fonts)
            })
        },
    )
    .expect("normalized table must lay out");

    let caption_layout = *tree.layout(caption).expect("caption layout must exist");
    let grid_layout = *tree.layout(grid).expect("grid layout must exist");
    let cells = cell_nodes
        .into_iter()
        .map(|(node, cell)| {
            let layout = *tree.layout(node).expect("cell layout must exist");
            CellEvidence {
                cell,
                geometry: BoxGeometry {
                    location: Point {
                        x: grid_layout.location.x + layout.location.x,
                        y: grid_layout.location.y + layout.location.y,
                    },
                    size: layout.size,
                },
            }
        })
        .collect();
    TableEvidence {
        viewport_width,
        caption: BoxGeometry {
            location: caption_layout.location,
            size: caption_layout.size,
        },
        table: BoxGeometry {
            location: grid_layout.location,
            size: grid_layout.size,
        },
        cells,
    }
}

fn cell<'a>(evidence: &'a TableEvidence, id: &str) -> &'a CellEvidence {
    evidence
        .cells
        .iter()
        .find(|cell| cell.cell.id == id)
        .unwrap_or_else(|| panic!("missing cell {id}"))
}

fn assert_close(left: f32, right: f32) {
    assert!((left - right).abs() < 0.001, "{left} != {right}");
}

#[test]
fn normalized_table_preserves_groups_headers_spans_and_nested_content() {
    let model = parse_table(XHTML);
    assert_eq!(model.caption, "Native table evidence");
    assert_eq!((model.row_count, model.column_count), (4, 3));

    let layout = model.cells.iter().find(|cell| cell.id == "layout").unwrap();
    assert_eq!(layout.group, RowGroup::Body);
    assert!(layout.header);
    assert_eq!((layout.row, layout.column, layout.row_span), (1, 0, 2));
    let nested = model.cells.iter().find(|cell| cell.id == "nested").unwrap();
    assert_eq!((nested.row, nested.column, nested.column_span), (2, 1, 2));
    assert_eq!(
        nested.images,
        [IntrinsicImage {
            source: "diagram.png".into(),
            alt: "diagram".into(),
            width: 48.0,
            height: 24.0
        }]
    );
    assert_eq!(
        model
            .cells
            .iter()
            .find(|cell| cell.id == "verified")
            .unwrap()
            .links,
        ["#layout"]
    );
    assert!(
        model
            .cells
            .iter()
            .take(3)
            .all(|cell| cell.group == RowGroup::Head),
        "header row semantics must survive normalization"
    );
    assert_eq!(model.cells.last().unwrap().group, RowGroup::Foot);
}

#[test]
fn table_measurement_distinguishes_minimum_and_maximum_content() {
    let model = parse_table(XHTML);
    let wrapping = model
        .cells
        .into_iter()
        .find(|cell| cell.id == "wrapping")
        .unwrap();
    let context = LeafContext::Cell(wrapping);
    let intrinsic = |available_width, fonts: &mut FontSystem| {
        measure_leaf(
            Size::NONE,
            Size {
                width: available_width,
                height: AvailableSpace::MaxContent,
            },
            &context,
            fonts,
        )
    };
    let mut fonts = font_system();
    let minimum = intrinsic(AvailableSpace::MinContent, &mut fonts);
    let maximum = intrinsic(AvailableSpace::MaxContent, &mut fonts);

    assert!(minimum.width > 2.0 * CELL_PADDING);
    assert!(minimum.width < maximum.width);
    assert!(minimum.height > maximum.height);
}

#[test]
fn intrinsic_images_contribute_to_table_cell_measurement() {
    let mut nested = parse_table(XHTML)
        .cells
        .into_iter()
        .find(|cell| cell.id == "nested")
        .unwrap();
    nested.text.clear();
    let context = LeafContext::Cell(nested);
    let measure = |known, available_width, fonts: &mut FontSystem| {
        measure_leaf(
            known,
            Size {
                width: available_width,
                height: AvailableSpace::MaxContent,
            },
            &context,
            fonts,
        )
    };
    let mut fonts = font_system();
    let minimum = measure(Size::NONE, AvailableSpace::MinContent, &mut fonts);
    let maximum = measure(Size::NONE, AvailableSpace::MaxContent, &mut fonts);
    let bounded = measure(
        Size {
            width: Some(32.0),
            height: None,
        },
        AvailableSpace::Definite(32.0),
        &mut fonts,
    );

    assert!(minimum.width >= 48.0 + 2.0 * CELL_PADDING);
    assert!(maximum.width >= 48.0 + 2.0 * CELL_PADDING);
    assert!(bounded.height >= 24.0 + 2.0 * CELL_PADDING);
}

#[test]
fn explicit_grid_places_rowspan_colspan_caption_and_measured_cells() {
    let evidence = layout_table(parse_table(XHTML), 600.0);
    let layout = cell(&evidence, "layout");
    let wrapping = cell(&evidence, "wrapping");
    let nested = cell(&evidence, "nested");
    let verified = cell(&evidence, "verified");

    assert_eq!(evidence.caption.location.y, 0.0);
    assert!(evidence.table.location.y >= evidence.caption.size.height);
    assert_eq!(layout.geometry.location.y, wrapping.geometry.location.y);
    assert!(layout.geometry.size.height > wrapping.geometry.size.height);
    assert_eq!(nested.geometry.location.x, wrapping.geometry.location.x);
    assert!(nested.geometry.size.width > verified.geometry.size.width);
    assert!(wrapping.geometry.size.height > 2.0 * CELL_PADDING);
    assert_close(
        layout.geometry.location.y + layout.geometry.size.height,
        nested.geometry.location.y + nested.geometry.size.height,
    );
    assert_close(
        nested.geometry.location.x + nested.geometry.size.width,
        verified.geometry.location.x + verified.geometry.size.width,
    );
}

#[test]
fn narrow_tables_overflow_instead_of_flattening_or_discarding_cells() {
    let evidence = layout_table(parse_table(XHTML), 240.0);
    assert_eq!(evidence.viewport_width, 240.0);
    assert_eq!(evidence.table.size.width, MIN_TABLE_WIDTH);
    assert!(
        evidence
            .cells
            .iter()
            .all(|cell| cell.geometry.size.width > 0.0)
    );
    assert_eq!(
        cell(&evidence, "summary").geometry.size.width,
        MIN_TABLE_WIDTH
    );
}
