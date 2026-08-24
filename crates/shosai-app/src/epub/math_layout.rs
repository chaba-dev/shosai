//! Bounded native geometry for the admitted Presentation MathML subset.

use std::sync::{Mutex, OnceLock};

use cosmic_text::{Attrs, Buffer, Family, FontSystem, Metrics, Shaping, Wrap, fontdb::Database};
use shosai_core::epub::MathExpression;

pub(crate) const MATH_FONT_BYTES: &[u8] =
    include_bytes!("../../../../assets/fonts/InterVariable.ttf");
pub(crate) const MATH_FONT_FAMILY: &str = "Inter Variable";

const MIN_SCRIPT_SIZE: f32 = 6.0;
const MAX_FONT_SIZE: f32 = 256.0;
const MAX_MATH_EXTENT: f32 = 4_096.0;
const MAX_MATH_PRIMITIVES: usize = 128;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MathRuleKind {
    Fraction,
    Radical,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum MathPrimitiveKind {
    Text(String),
    Rule(MathRuleKind),
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct MathPrimitive {
    pub(crate) kind: MathPrimitiveKind,
    pub(crate) x: f32,
    pub(crate) y: f32,
    pub(crate) width: f32,
    pub(crate) height: f32,
    pub(crate) font_size: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct MathLayout {
    pub(crate) width: f32,
    pub(crate) height: f32,
    pub(crate) baseline: f32,
    pub(crate) primitives: Vec<MathPrimitive>,
}

static FONT_SYSTEM: OnceLock<Mutex<FontSystem>> = OnceLock::new();

fn font_system() -> &'static Mutex<FontSystem> {
    FONT_SYSTEM.get_or_init(|| {
        let mut database = Database::new();
        database.load_font_data(MATH_FONT_BYTES.to_vec());
        database.set_sans_serif_family(MATH_FONT_FAMILY);
        Mutex::new(FontSystem::new_with_locale_and_db("en-US".into(), database))
    })
}

pub(crate) fn layout_math(expression: &MathExpression, font_size: f32) -> Option<MathLayout> {
    if !font_size.is_finite() || !(1.0..=MAX_FONT_SIZE).contains(&font_size) {
        return None;
    }
    let mut fonts = font_system()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let layout = layout_expression(expression, font_size, &mut fonts)?;
    valid_layout(&layout).then_some(layout)
}

pub(crate) fn layout_math_for_bounds(
    expression: &MathExpression,
    font_size: f32,
    available_width: f32,
    available_height: f32,
) -> Option<MathLayout> {
    let layout = layout_math(expression, font_size)?;
    (available_width.is_finite()
        && available_height.is_finite()
        && available_width > 0.0
        && available_height > 0.0
        && layout.width <= available_width
        && layout.height <= available_height)
        .then_some(layout)
}

fn layout_expression(
    expression: &MathExpression,
    size: f32,
    fonts: &mut FontSystem,
) -> Option<MathLayout> {
    match expression {
        MathExpression::Row(children) => layout_row(children, size, fonts),
        MathExpression::Token(text) => text_box(text, size, fonts),
        MathExpression::Fraction(numerator, denominator) => {
            let numerator = layout_expression(numerator, script_size(size, 0.8), fonts)?;
            let denominator = layout_expression(denominator, script_size(size, 0.8), fonts)?;
            Some(fraction_box(numerator, denominator, size))
        }
        MathExpression::SquareRoot(children) => {
            let content = layout_row(children, size, fonts)?;
            radical_box(content, size, fonts)
        }
        MathExpression::Root(radicand, index) => {
            let content = layout_expression(radicand, size, fonts)?;
            let index = layout_expression(index, script_size(size, 0.55), fonts)?;
            indexed_root_box(content, index, size, fonts)
        }
        MathExpression::Subscript(base, subscript) => {
            let base = layout_expression(base, size, fonts)?;
            let subscript = layout_expression(subscript, script_size(size, 0.7), fonts)?;
            Some(scripts_box(base, Some(subscript), None, size))
        }
        MathExpression::Superscript(base, superscript) => {
            let base = layout_expression(base, size, fonts)?;
            let superscript = layout_expression(superscript, script_size(size, 0.7), fonts)?;
            Some(scripts_box(base, None, Some(superscript), size))
        }
        MathExpression::SubSuperscript {
            base,
            subscript,
            superscript,
        } => {
            let base = layout_expression(base, size, fonts)?;
            let subscript = layout_expression(subscript, script_size(size, 0.7), fonts)?;
            let superscript = layout_expression(superscript, script_size(size, 0.7), fonts)?;
            Some(scripts_box(base, Some(subscript), Some(superscript), size))
        }
        MathExpression::Fenced {
            open,
            close,
            content,
        } => row_box(vec![
            text_box(open, size, fonts)?,
            layout_row(content, size, fonts)?,
            text_box(close, size, fonts)?,
        ]),
        MathExpression::Table(rows) => table_box(rows, size, fonts),
    }
}

fn layout_row(
    expressions: &[MathExpression],
    size: f32,
    fonts: &mut FontSystem,
) -> Option<MathLayout> {
    expressions
        .iter()
        .map(|expression| layout_expression(expression, size, fonts))
        .collect::<Option<Vec<_>>>()
        .and_then(row_box)
}

fn text_box(text: &str, size: f32, fonts: &mut FontSystem) -> Option<MathLayout> {
    let text = text.trim();
    if text.is_empty() || text.contains(['\n', '\r']) {
        return None;
    }
    let mut buffer = Buffer::new(fonts, Metrics::new(size, size * 1.2));
    buffer.set_wrap(fonts, Wrap::None);
    buffer.set_size(fonts, None, None);
    buffer.set_text(
        fonts,
        text,
        &Attrs::new().family(Family::Name(MATH_FONT_FAMILY)),
        Shaping::Advanced,
        None,
    );
    buffer.shape_until_scroll(fonts, false);

    let mut runs = buffer.layout_runs();
    let run = runs.next()?;
    if runs.next().is_some()
        || run.line_w <= 0.0
        || run.line_height <= 0.0
        || run.glyphs.iter().any(|glyph| {
            glyph.glyph_id == 0
                || glyph.start > glyph.end
                || glyph.end > text.len()
                || !text.is_char_boundary(glyph.start)
                || !text.is_char_boundary(glyph.end)
        })
    {
        return None;
    }
    let mut covered = vec![false; text.len()];
    for glyph in run.glyphs {
        covered[glyph.start..glyph.end].fill(true);
    }
    if covered.iter().any(|covered| !covered) {
        return None;
    }

    Some(MathLayout {
        width: run.line_w,
        height: run.line_height,
        baseline: run.line_y,
        primitives: vec![MathPrimitive {
            kind: MathPrimitiveKind::Text(text.to_owned()),
            x: 0.0,
            y: 0.0,
            width: run.line_w,
            height: run.line_height,
            font_size: size,
        }],
    })
}

fn row_box(children: Vec<MathLayout>) -> Option<MathLayout> {
    if children.is_empty() {
        return None;
    }
    let baseline = children
        .iter()
        .map(|child| child.baseline)
        .fold(0.0, f32::max);
    let below = children
        .iter()
        .map(|child| child.height - child.baseline)
        .fold(0.0, f32::max);
    let width = children.iter().map(|child| child.width).sum();
    let mut x = 0.0;
    let mut primitives = Vec::new();
    for child in children {
        let child_width = child.width;
        let y = baseline - child.baseline;
        place(&mut primitives, child, x, y);
        x += child_width;
    }
    Some(MathLayout {
        width,
        height: baseline + below,
        baseline,
        primitives,
    })
}

fn fraction_box(numerator: MathLayout, denominator: MathLayout, size: f32) -> MathLayout {
    let gap = size * 0.12;
    let padding = size * 0.15;
    let rule_height = (size * 0.06).max(1.0);
    let width = numerator.width.max(denominator.width) + padding * 2.0;
    let rule_y = numerator.height + gap;
    let denominator_y = rule_y + rule_height + gap;
    let numerator_x = (width - numerator.width) / 2.0;
    let denominator_x = (width - denominator.width) / 2.0;
    let height = denominator_y + denominator.height;
    let mut primitives = Vec::new();
    place(&mut primitives, numerator, numerator_x, 0.0);
    primitives.push(MathPrimitive {
        kind: MathPrimitiveKind::Rule(MathRuleKind::Fraction),
        x: 0.0,
        y: rule_y,
        width,
        height: rule_height,
        font_size: size,
    });
    place(&mut primitives, denominator, denominator_x, denominator_y);
    MathLayout {
        width,
        height,
        baseline: rule_y + rule_height,
        primitives,
    }
}

fn radical_box(content: MathLayout, size: f32, fonts: &mut FontSystem) -> Option<MathLayout> {
    let radical = text_box("√", size, fonts)?;
    let overbar_height = (size * 0.05).max(1.0);
    let overbar_gap = size * 0.08;
    let initial_content_y = overbar_height + overbar_gap;
    let baseline = (initial_content_y + content.baseline).max(radical.baseline);
    let content_y = baseline - content.baseline;
    let radical_y = baseline - radical.baseline;
    let overbar_y = (content_y - overbar_gap - overbar_height).max(0.0);
    let width = radical.width + content.width;
    let height = (content_y + content.height)
        .max(radical_y + radical.height)
        .max(overbar_y + overbar_height);
    let radical_width = radical.width;
    let content_width = content.width;
    let mut primitives = Vec::new();
    place(&mut primitives, radical, 0.0, radical_y);
    primitives.push(MathPrimitive {
        kind: MathPrimitiveKind::Rule(MathRuleKind::Radical),
        x: radical_width,
        y: overbar_y,
        width: content_width,
        height: overbar_height,
        font_size: size,
    });
    place(&mut primitives, content, radical_width, content_y);
    Some(MathLayout {
        width,
        height,
        baseline,
        primitives,
    })
}

fn indexed_root_box(
    content: MathLayout,
    index: MathLayout,
    size: f32,
    fonts: &mut FontSystem,
) -> Option<MathLayout> {
    let radical = radical_box(content, size, fonts)?;
    let index_width = index.width;
    let index_shift = index.height * 0.35;
    let radical_x = index_width * 0.7;
    let width = index_width.max(radical_x + radical.width);
    let height = index.height.max(index_shift + radical.height);
    let baseline = index_shift + radical.baseline;
    let mut primitives = Vec::new();
    place(&mut primitives, index, 0.0, 0.0);
    place(&mut primitives, radical, radical_x, index_shift);
    Some(MathLayout {
        width,
        height,
        baseline,
        primitives,
    })
}

fn scripts_box(
    base: MathLayout,
    subscript: Option<MathLayout>,
    superscript: Option<MathLayout>,
    size: f32,
) -> MathLayout {
    let script_width = subscript
        .as_ref()
        .map_or(0.0, |script| script.width)
        .max(superscript.as_ref().map_or(0.0, |script| script.width));
    let superscript_height = superscript
        .as_ref()
        .map_or(0.0, |script| script.height * 0.7);
    let base_y = superscript_height;
    let subscript_y = base_y + base.baseline + size * 0.12;
    let height = (base_y + base.height)
        .max(superscript.as_ref().map_or(0.0, |script| script.height))
        .max(
            subscript
                .as_ref()
                .map_or(0.0, |script| subscript_y + script.height),
        );
    let baseline = base_y + base.baseline;
    let width = base.width + script_width;
    let base_width = base.width;
    let mut primitives = Vec::new();
    place(&mut primitives, base, 0.0, base_y);
    if let Some(superscript) = superscript {
        place(&mut primitives, superscript, base_width, 0.0);
    }
    if let Some(subscript) = subscript {
        place(&mut primitives, subscript, base_width, subscript_y);
    }
    MathLayout {
        width,
        height,
        baseline,
        primitives,
    }
}

fn table_box(
    expressions: &[Vec<MathExpression>],
    size: f32,
    fonts: &mut FontSystem,
) -> Option<MathLayout> {
    if expressions.is_empty() || expressions.iter().any(Vec::is_empty) {
        return None;
    }
    let columns = expressions.first()?.len();
    if expressions.iter().any(|row| row.len() != columns) {
        return None;
    }
    let rows = expressions
        .iter()
        .map(|row| {
            row.iter()
                .map(|cell| layout_expression(cell, size, fonts))
                .collect::<Option<Vec<_>>>()
        })
        .collect::<Option<Vec<_>>>()?;
    let column_gap = size * 0.5;
    let row_gap = size * 0.25;
    let mut widths = vec![0.0f32; columns];
    for row in &rows {
        for (index, cell) in row.iter().enumerate() {
            widths[index] = widths[index].max(cell.width);
        }
    }
    let width = widths.iter().sum::<f32>() + column_gap * columns.saturating_sub(1) as f32;
    let mut y = 0.0;
    let mut primitives = Vec::new();
    for row in rows {
        let baseline = row.iter().map(|cell| cell.baseline).fold(0.0, f32::max);
        let below = row
            .iter()
            .map(|cell| cell.height - cell.baseline)
            .fold(0.0, f32::max);
        let row_height = baseline + below;
        let mut x = 0.0;
        for (index, cell) in row.into_iter().enumerate() {
            let cell_x = x + (widths[index] - cell.width) / 2.0;
            let cell_y = y + baseline - cell.baseline;
            place(&mut primitives, cell, cell_x, cell_y);
            x += widths[index] + column_gap;
        }
        y += row_height + row_gap;
    }
    let height = y - row_gap;
    Some(MathLayout {
        width,
        height,
        baseline: height / 2.0 + size * 0.25,
        primitives,
    })
}

fn place(target: &mut Vec<MathPrimitive>, source: MathLayout, x: f32, y: f32) {
    target.extend(source.primitives.into_iter().map(|mut primitive| {
        primitive.x += x;
        primitive.y += y;
        primitive
    }));
}

fn script_size(size: f32, scale: f32) -> f32 {
    (size * scale).max(MIN_SCRIPT_SIZE)
}

fn valid_layout(layout: &MathLayout) -> bool {
    layout.width.is_finite()
        && layout.height.is_finite()
        && layout.baseline.is_finite()
        && layout.width > 0.0
        && layout.height > 0.0
        && layout.width <= MAX_MATH_EXTENT
        && layout.height <= MAX_MATH_EXTENT
        && layout.baseline > 0.0
        && layout.baseline <= layout.height
        && !layout.primitives.is_empty()
        && layout.primitives.len() <= MAX_MATH_PRIMITIVES
        && layout.primitives.iter().all(|primitive| {
            [
                primitive.x,
                primitive.y,
                primitive.width,
                primitive.height,
                primitive.font_size,
            ]
            .into_iter()
            .all(f32::is_finite)
                && primitive.x >= 0.0
                && primitive.y >= 0.0
                && primitive.width > 0.0
                && primitive.height > 0.0
                && primitive.x + primitive.width <= layout.width + 0.01
                && primitive.y + primitive.height <= layout.height + 0.01
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(text: &str) -> MathExpression {
        MathExpression::Token(text.into())
    }

    #[test]
    fn supported_math_model_produces_bounded_native_geometry() {
        let expression = MathExpression::Row(vec![
            MathExpression::Fraction(Box::new(token("a")), Box::new(token("b"))),
            MathExpression::Root(Box::new(token("x")), Box::new(token("3"))),
            MathExpression::SubSuperscript {
                base: Box::new(token("c")),
                subscript: Box::new(token("i")),
                superscript: Box::new(token("2")),
            },
            MathExpression::Fenced {
                open: "(".into(),
                close: ")".into(),
                content: vec![MathExpression::Table(vec![
                    vec![token("p"), token("q")],
                    vec![token("r"), token("s")],
                ])],
            },
        ]);

        let layout = layout_math(&expression, 20.0).expect("supported math must lay out");
        assert!(valid_layout(&layout));
        assert!(layout.primitives.iter().any(|primitive| {
            primitive.kind == MathPrimitiveKind::Rule(MathRuleKind::Fraction)
        }));
        assert!(
            layout.primitives.iter().any(|primitive| {
                primitive.kind == MathPrimitiveKind::Rule(MathRuleKind::Radical)
            })
        );
        let matrix_token = |text: &str| {
            layout
                .primitives
                .iter()
                .find(|primitive| {
                    matches!(&primitive.kind, MathPrimitiveKind::Text(value) if value == text)
                })
                .expect("matrix token must be retained")
        };
        assert!(matrix_token("p").x < matrix_token("q").x);
        assert!(matrix_token("p").y < matrix_token("r").y);
    }

    #[test]
    fn reader_font_size_scales_geometry_and_scripts() {
        let expression = MathExpression::Superscript(Box::new(token("x")), Box::new(token("2")));
        let small = layout_math(&expression, 16.0).unwrap();
        let large = layout_math(&expression, 32.0).unwrap();

        assert!(large.width > small.width * 1.8);
        assert!(large.height > small.height * 1.8);
        assert!(small.primitives.iter().any(|primitive| {
            matches!(&primitive.kind, MathPrimitiveKind::Text(text) if text == "2")
                && primitive.font_size < 16.0
        }));
    }

    #[test]
    fn missing_glyphs_and_pathological_extents_use_text_fallback() {
        assert!(layout_math(&token("日本語"), 20.0).is_none());
        assert!(layout_math(&token(&"W".repeat(1024)), 256.0).is_none());
    }

    #[test]
    fn native_math_must_fit_both_page_dimensions() {
        let tall_matrix =
            MathExpression::Table((0..20).map(|row| vec![token(&format!("r{row}"))]).collect());
        let unconstrained = layout_math(&tall_matrix, 48.0).expect("bounded matrix should lay out");
        assert!(unconstrained.height > 700.0);

        assert!(layout_math_for_bounds(&tall_matrix, 48.0, 600.0, 700.0).is_none());
        assert!(layout_math_for_bounds(&tall_matrix, 48.0, 600.0, unconstrained.height,).is_some());
    }
}
