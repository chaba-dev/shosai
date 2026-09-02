//! Executable Phase 0 proofs for RFD 6. Production integration follows in Phases 2 and 3.

use std::ops::Range;

#[derive(Clone, Copy, Debug, PartialEq)]
struct Point {
    x: f32,
    y: f32,
}

#[derive(Clone, Copy, Debug)]
struct Rect {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}

impl Rect {
    fn contains(self, point: Point) -> bool {
        point.x >= self.x
            && point.x < self.x + self.width
            && point.y >= self.y
            && point.y < self.y + self.height
    }
}

/// Owned geometry is the contract between asynchronous extraction/layout and pointer handling.
/// Neither hit testing nor range coordination calls PDFium, Iced layout, or SQLite.
struct SelectableSurface {
    rows: Vec<Row>,
}

struct Row {
    bounds: Rect,
    endpoints: Vec<EndpointRect>,
}

struct EndpointRect {
    bounds: Rect,
    endpoint: usize,
}

impl SelectableSurface {
    fn hit_test(&self, point: Point) -> Option<usize> {
        self.rows
            .iter()
            .find(|row| row.bounds.contains(point))?
            .endpoints
            .iter()
            .find(|endpoint| endpoint.bounds.contains(point))
            .map(|endpoint| endpoint.endpoint)
    }
}

/// Maps a point in an Iced image widget to the rendered PDF bitmap. PDFium then converts the
/// bitmap point through its crop/rotation-aware transform while building the owned snapshot.
fn widget_to_bitmap(point: Point, widget: Rect, bitmap: (u32, u32)) -> Option<(i32, i32)> {
    widget.contains(point).then(|| {
        (
            ((point.x - widget.x) * bitmap.0 as f32 / widget.width).floor() as i32,
            ((point.y - widget.y) * bitmap.1 as f32 / widget.height).floor() as i32,
        )
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct LogicalEndpoint {
    spine: usize,
    scalar: usize,
}

fn logical_range(anchor: LogicalEndpoint, focus: LogicalEndpoint) -> Option<Range<usize>> {
    (anchor.spine == focus.spine)
        .then(|| anchor.scalar.min(focus.scalar)..anchor.scalar.max(focus.scalar))
}

#[cfg(test)]
mod tests {
    use super::*;
    use iced::advanced::text::{
        Alignment, LineHeight, Paragraph as _, Shaping, Span, Text, Wrapping,
    };
    use iced::{Font, Pixels, Size, alignment};
    use shosai_core::epub::{EpubTextCluster, EpubTextLayout, EpubTextRect};

    type Paragraph = iced_tiny_skia::graphics::text::Paragraph;

    #[test]
    fn pdf_widget_coordinates_emit_owned_character_endpoints() {
        let widget = Rect {
            x: 100.0,
            y: 50.0,
            width: 300.0,
            height: 200.0,
        };
        assert_eq!(
            widget_to_bitmap(Point { x: 250.0, y: 100.0 }, widget, (600, 400)),
            Some((300, 100))
        );

        let snapshot = SelectableSurface {
            rows: vec![Row {
                bounds: Rect {
                    x: 20.0,
                    y: 90.0,
                    width: 100.0,
                    height: 20.0,
                },
                endpoints: vec![EndpointRect {
                    bounds: Rect {
                        x: 20.0,
                        y: 90.0,
                        width: 12.0,
                        height: 20.0,
                    },
                    endpoint: 17,
                }],
            }],
        };
        assert_eq!(snapshot.hit_test(Point { x: 25.0, y: 95.0 }), Some(17));
    }

    #[test]
    fn iced_rich_text_exposes_offsets_from_the_paragraph_that_paints_it() {
        let spans = [Span::<(), Font>::new("adjacent "), Span::new("spans")];
        let paragraph = Paragraph::with_spans(Text {
            content: spans.as_slice(),
            bounds: Size::new(300.0, 100.0),
            size: Pixels(18.0),
            line_height: LineHeight::default(),
            font: Font::default(),
            align_x: Alignment::Left,
            align_y: alignment::Vertical::Top,
            shaping: Shaping::Advanced,
            wrapping: Wrapping::WordOrGlyph,
        });
        let second_span = paragraph.span_bounds(1);
        let point = second_span[0].center();
        let offset = paragraph
            .hit_test(point)
            .expect("painted span must hit")
            .cursor();

        assert!(("adjacent ".chars().count()..="adjacent spans".chars().count()).contains(&offset));
    }

    #[test]
    fn native_embedded_font_hit_testing_reuses_painted_clusters() {
        let layout = EpubTextLayout {
            width: 100.0,
            height: 20.0,
            lines: Vec::new(),
            clusters: vec![EpubTextCluster {
                rect: EpubTextRect {
                    x: 12.0,
                    y: 0.0,
                    width: 18.0,
                    height: 20.0,
                },
                scalars: 4..7,
            }],
            links: Vec::new(),
        };

        assert_eq!(layout.hit_test(20.0, 10.0), Some(4..7));
    }

    #[test]
    fn epub_selection_crosses_spans_blocks_and_visual_fragments_but_not_spines() {
        // Widget and page-fragment identities deliberately do not enter the endpoint.
        let first_block_on_page_one = LogicalEndpoint {
            spine: 3,
            scalar: 19,
        };
        let later_block_on_page_two = LogicalEndpoint {
            spine: 3,
            scalar: 81,
        };
        assert_eq!(
            logical_range(first_block_on_page_one, later_block_on_page_two),
            Some(19..81)
        );
        assert_eq!(
            logical_range(later_block_on_page_two, first_block_on_page_one),
            Some(19..81),
            "reverse drags preserve logical order"
        );
        assert_eq!(
            logical_range(
                first_block_on_page_one,
                LogicalEndpoint {
                    spine: 4,
                    scalar: 2
                }
            ),
            None
        );
    }

    #[test]
    fn retained_geometry_and_hot_path_fit_phase_zero_limits() {
        const MAX_ENDPOINTS_PER_SURFACE: usize = 65_536;
        const MAX_RETAINED_BYTES_PER_DOCUMENT: usize = 8 * 1024 * 1024;
        const POINTER_SAMPLES: usize = 10_000;

        let endpoints_per_row = 256;
        let rows = (0..MAX_ENDPOINTS_PER_SURFACE / endpoints_per_row)
            .map(|row| Row {
                bounds: Rect {
                    x: 0.0,
                    y: row as f32 * 20.0,
                    width: endpoints_per_row as f32 * 8.0,
                    height: 20.0,
                },
                endpoints: (0..endpoints_per_row)
                    .map(|column| EndpointRect {
                        bounds: Rect {
                            x: column as f32 * 8.0,
                            y: row as f32 * 20.0,
                            width: 8.0,
                            height: 20.0,
                        },
                        endpoint: row * endpoints_per_row + column,
                    })
                    .collect(),
            })
            .collect();
        let surface = SelectableSurface { rows };
        let retained = surface.rows.capacity() * std::mem::size_of::<Row>()
            + surface
                .rows
                .iter()
                .map(|row| row.endpoints.capacity() * std::mem::size_of::<EndpointRect>())
                .sum::<usize>();
        assert!(retained <= MAX_RETAINED_BYTES_PER_DOCUMENT);

        let started = std::time::Instant::now();
        for sample in 0..POINTER_SAMPLES {
            let endpoint = sample % MAX_ENDPOINTS_PER_SURFACE;
            let row = endpoint / endpoints_per_row;
            let column = endpoint % endpoints_per_row;
            assert_eq!(
                surface.hit_test(Point {
                    x: column as f32 * 8.0 + 4.0,
                    y: row as f32 * 20.0 + 10.0,
                }),
                Some(endpoint)
            );
        }
        let elapsed = started.elapsed();
        eprintln!(
            "RFD 6 geometry probe: {POINTER_SAMPLES} hits in {elapsed:?}; retained {retained} bytes"
        );
        assert!(
            elapsed / POINTER_SAMPLES as u32 <= std::time::Duration::from_millis(1),
            "owned hit testing must leave ample room in a 16.7 ms frame"
        );
    }
}
