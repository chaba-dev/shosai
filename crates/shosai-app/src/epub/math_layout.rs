//! Gate 0 native MathML spike. This deliberately test-only module lowers a
//! bounded Presentation MathML subset to measurable primitives; it is evidence
//! about the missing renderer boundary, not a production math engine.

use cosmic_text::{Attrs, Buffer, Family, FontSystem, Metrics, Shaping};
use roxmltree::Node;

use super::text_shaping::font_system;

const XHTML: &str = include_str!("../../tests/fixtures/native-mathml.xhtml");
const MATHML_NAMESPACE: &str = "http://www.w3.org/1998/Math/MathML";
const MAX_DEPTH: usize = 16;
const MAX_NODES: usize = 64;
const MAX_VISIBLE_TEXT_BYTES: usize = 1024;
const FONT_SIZE: f32 = 20.0;

#[derive(Clone, Debug, PartialEq)]
enum PrimitiveKind {
    Text(String),
    FractionRule,
    RadicalRule,
}

#[derive(Clone, Debug, PartialEq)]
struct Primitive {
    kind: PrimitiveKind,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    font_size: f32,
}

#[derive(Clone, Debug, PartialEq)]
struct MathBox {
    width: f32,
    height: f32,
    baseline: f32,
    primitives: Vec<Primitive>,
}

#[derive(Debug, PartialEq)]
struct MathEvidence {
    display: bool,
    fallback: Result<String, String>,
    layout: Result<MathBox, String>,
}

#[derive(Default)]
struct PreflightBudget {
    nodes: usize,
    visible_text_bytes: usize,
}

fn preflight_math(root: Node<'_, '_>) -> Result<(), String> {
    preflight_node(root, 0, false, false, &mut PreflightBudget::default())
}

fn preflight_node(
    node: Node<'_, '_>,
    depth: usize,
    allow_foreign: bool,
    suppress_text: bool,
    budget: &mut PreflightBudget,
) -> Result<(), String> {
    if depth > MAX_DEPTH {
        return Err("MathML nesting exceeds the spike limit".into());
    }
    budget.nodes += 1;
    if budget.nodes > MAX_NODES {
        return Err("MathML node count exceeds the spike limit".into());
    }
    if !allow_foreign && node.tag_name().namespace() != Some(MATHML_NAMESPACE) {
        return Err("MathML subtree contains a foreign namespace".into());
    }

    let name = node.tag_name().name();
    if name == "semantics" {
        let mut children = node.children().filter(Node::is_element);
        let first = children.next().ok_or_else(|| {
            "MathML semantics requires one presentation child followed by annotations".to_owned()
        })?;
        if matches!(first.tag_name().name(), "annotation" | "annotation-xml")
            || children
                .any(|child| !matches!(child.tag_name().name(), "annotation" | "annotation-xml"))
        {
            return Err(
                "MathML semantics requires one presentation child followed by annotations".into(),
            );
        }
    }

    let is_annotation = matches!(name, "annotation" | "annotation-xml");
    let suppress_text = suppress_text || is_annotation;
    if !suppress_text {
        for text in node.children().filter(Node::is_text) {
            add_visible_bytes(text.text().unwrap_or_default().trim().len(), budget)?;
        }
        if name == "mfenced" {
            add_visible_bytes(node.attribute("open").unwrap_or("(").len(), budget)?;
            add_visible_bytes(node.attribute("close").unwrap_or(")").len(), budget)?;
        }
    }

    let allow_foreign_children = allow_foreign || name == "annotation-xml";
    for child in node.children().filter(Node::is_element) {
        preflight_node(
            child,
            depth + 1,
            allow_foreign_children,
            suppress_text,
            budget,
        )?;
    }
    Ok(())
}

fn add_visible_bytes(bytes: usize, budget: &mut PreflightBudget) -> Result<(), String> {
    budget.visible_text_bytes = budget
        .visible_text_bytes
        .checked_add(bytes)
        .ok_or_else(|| "MathML visible text exceeds the spike limit".to_owned())?;
    if budget.visible_text_bytes > MAX_VISIBLE_TEXT_BYTES {
        return Err("MathML visible text exceeds the spike limit".into());
    }
    Ok(())
}

fn element_children<'a, 'input>(node: Node<'a, 'input>) -> Vec<Node<'a, 'input>> {
    node.children()
        .filter(Node::is_element)
        .take(MAX_NODES + 1)
        .collect()
}

fn place(target: &mut Vec<Primitive>, source: MathBox, x: f32, y: f32) {
    target.extend(source.primitives.into_iter().map(|mut primitive| {
        primitive.x += x;
        primitive.y += y;
        primitive
    }));
}

fn token_text(node: Node<'_, '_>) -> Result<String, String> {
    let mut text = String::new();
    for child in node.children() {
        if child.is_text() {
            text.push_str(child.text().unwrap_or_default());
        } else if child.is_comment() {
            continue;
        } else {
            return Err("MathML tokens may contain only text and comments".into());
        }
    }
    let text = text.trim().to_owned();
    if text.contains(['\n', '\r']) {
        return Err("multiline MathML tokens are unsupported by the spike".into());
    }
    Ok(text)
}

fn text_box(text: &str, size: f32, fonts: &mut FontSystem) -> Result<MathBox, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("MathML token is empty".into());
    }
    let mut buffer = Buffer::new(fonts, Metrics::new(size, size * 1.2));
    buffer.set_size(fonts, None, None);
    buffer.set_text(
        fonts,
        text,
        &Attrs::new().family(Family::SansSerif),
        Shaping::Advanced,
        None,
    );
    buffer.shape_until_scroll(fonts, false);
    let mut width = None;
    let mut height = 0.0f32;
    let mut baseline = 0.0f32;
    let mut covered = vec![false; text.len()];
    for run in buffer.layout_runs() {
        if width.is_some() {
            return Err("multiline MathML tokens are unsupported by the spike".into());
        }
        if run.glyphs.iter().any(|glyph| {
            glyph.glyph_id == 0
                || glyph.start > glyph.end
                || glyph.end > text.len()
                || !text.is_char_boundary(glyph.start)
                || !text.is_char_boundary(glyph.end)
        }) {
            return Err(format!("math font cannot shape {text:?}"));
        }
        for glyph in run.glyphs {
            covered[glyph.start..glyph.end].fill(true);
        }
        width = Some(run.line_w);
        height = run.line_height;
        baseline = run.line_y;
    }
    let width = width.ok_or_else(|| "MathML token produced no layout".to_owned())?;
    if covered.iter().any(|covered| !covered) {
        return Err(format!(
            "math font did not cover all source bytes in {text:?}"
        ));
    }
    Ok(MathBox {
        width,
        height,
        baseline,
        primitives: vec![Primitive {
            kind: PrimitiveKind::Text(text.into()),
            x: 0.0,
            y: 0.0,
            width,
            height,
            font_size: size,
        }],
    })
}

fn row_box(children: Vec<MathBox>) -> Result<MathBox, String> {
    if children.is_empty() {
        return Err("MathML row is empty".into());
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
    Ok(MathBox {
        width,
        height: baseline + below,
        baseline,
        primitives,
    })
}

fn fraction_box(numerator: MathBox, denominator: MathBox, size: f32) -> MathBox {
    let gap = size * 0.12;
    let padding = size * 0.15;
    let rule_height = (size * 0.06).max(1.0);
    let width = numerator.width.max(denominator.width) + padding * 2.0;
    let rule_y = numerator.height + gap;
    let denominator_y = rule_y + rule_height + gap;
    let baseline = rule_y + rule_height;
    let height = denominator_y + denominator.height;
    let numerator_x = (width - numerator.width) / 2.0;
    let denominator_x = (width - denominator.width) / 2.0;
    let mut primitives = Vec::new();
    place(&mut primitives, numerator, numerator_x, 0.0);
    primitives.push(Primitive {
        kind: PrimitiveKind::FractionRule,
        x: 0.0,
        y: rule_y,
        width,
        height: rule_height,
        font_size: size,
    });
    place(&mut primitives, denominator, denominator_x, denominator_y);
    MathBox {
        width,
        height,
        baseline,
        primitives,
    }
}

fn radical_box(content: MathBox, size: f32, fonts: &mut FontSystem) -> Result<MathBox, String> {
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
    primitives.push(Primitive {
        kind: PrimitiveKind::RadicalRule,
        x: radical_width,
        y: overbar_y,
        width: content_width,
        height: overbar_height,
        font_size: size,
    });
    place(&mut primitives, content, radical_width, content_y);
    Ok(MathBox {
        width,
        height,
        baseline,
        primitives,
    })
}

fn scripts_box(base: MathBox, sub: Option<MathBox>, sup: Option<MathBox>, size: f32) -> MathBox {
    let script_width = sub
        .as_ref()
        .map_or(0.0, |script| script.width)
        .max(sup.as_ref().map_or(0.0, |script| script.width));
    let sup_height = sup.as_ref().map_or(0.0, |script| script.height * 0.7);
    let base_y = sup_height;
    let sub_y = base_y + base.baseline + size * 0.12;
    let height = (base_y + base.height)
        .max(sup.as_ref().map_or(0.0, |script| script.height))
        .max(sub.as_ref().map_or(0.0, |script| sub_y + script.height));
    let baseline = base_y + base.baseline;
    let width = base.width + script_width;
    let base_width = base.width;
    let mut primitives = Vec::new();
    place(&mut primitives, base, 0.0, base_y);
    if let Some(sup) = sup {
        place(&mut primitives, sup, base_width, 0.0);
    }
    if let Some(sub) = sub {
        place(&mut primitives, sub, base_width, sub_y);
    }
    MathBox {
        width,
        height,
        baseline,
        primitives,
    }
}

fn table_box(
    node: Node<'_, '_>,
    size: f32,
    fonts: &mut FontSystem,
    count: &mut usize,
    depth: usize,
) -> Result<MathBox, String> {
    let mut rows = Vec::new();
    for row in element_children(node) {
        if depth > MAX_DEPTH {
            return Err("MathML nesting exceeds the spike limit".into());
        }
        admit_node(count)?;
        if row.tag_name().name() != "mtr" {
            return Err("MathML table contains a non-row child".into());
        }
        let cells = element_children(row)
            .into_iter()
            .map(|cell| {
                admit_node(count)?;
                if cell.tag_name().name() != "mtd" {
                    return Err("MathML row contains a non-cell child".into());
                }
                layout_children(cell, size, fonts, count, depth + 1)
            })
            .collect::<Result<Vec<_>, _>>()?;
        if cells.is_empty() {
            return Err("MathML table row is empty".into());
        }
        rows.push(cells);
    }
    if rows.is_empty() {
        return Err("MathML table is empty".into());
    }
    let columns = rows.iter().map(Vec::len).max().unwrap();
    if rows.iter().any(|row| row.len() != columns) {
        return Err("MathML table rows have different cell counts".into());
    }
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
    Ok(MathBox {
        width,
        height,
        baseline: height / 2.0 + size * 0.25,
        primitives,
    })
}

fn layout_children(
    node: Node<'_, '_>,
    size: f32,
    fonts: &mut FontSystem,
    count: &mut usize,
    depth: usize,
) -> Result<MathBox, String> {
    element_children(node)
        .into_iter()
        .map(|child| layout_node(child, size, fonts, count, depth))
        .collect::<Result<Vec<_>, _>>()
        .and_then(row_box)
}

fn layout_node(
    node: Node<'_, '_>,
    size: f32,
    fonts: &mut FontSystem,
    count: &mut usize,
    depth: usize,
) -> Result<MathBox, String> {
    if depth > MAX_DEPTH {
        return Err("MathML nesting exceeds the spike limit".into());
    }
    admit_node(count)?;
    if node.tag_name().namespace() != Some(MATHML_NAMESPACE) {
        return Err("MathML subtree contains a foreign namespace".into());
    }
    match node.tag_name().name() {
        "math" | "mrow" | "mstyle" | "mtd" => layout_children(node, size, fonts, count, depth + 1),
        "mi" | "mn" | "mo" | "mtext" => text_box(&token_text(node)?, size, fonts),
        "mfrac" => {
            let children = element_children(node);
            if children.len() != 2 {
                return Err("MathML fraction requires numerator and denominator".into());
            }
            let numerator = layout_node(children[0], size * 0.8, fonts, count, depth + 1)?;
            let denominator = layout_node(children[1], size * 0.8, fonts, count, depth + 1)?;
            Ok(fraction_box(numerator, denominator, size))
        }
        "msqrt" => {
            let content = layout_children(node, size, fonts, count, depth + 1)?;
            radical_box(content, size, fonts)
        }
        "mroot" => {
            let children = element_children(node);
            if children.len() != 2 {
                return Err("MathML root requires radicand and index".into());
            }
            let content = layout_node(children[0], size, fonts, count, depth + 1)?;
            let index = layout_node(children[1], size * 0.55, fonts, count, depth + 1)?;
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
            Ok(MathBox {
                width,
                height,
                baseline,
                primitives,
            })
        }
        "msub" | "msup" | "msubsup" => {
            let children = element_children(node);
            let expected = if node.tag_name().name() == "msubsup" {
                3
            } else {
                2
            };
            if children.len() != expected {
                return Err("MathML script element has the wrong child count".into());
            }
            let base = layout_node(children[0], size, fonts, count, depth + 1)?;
            let (sub, sup) = match node.tag_name().name() {
                "msub" => (
                    Some(layout_node(
                        children[1],
                        size * 0.7,
                        fonts,
                        count,
                        depth + 1,
                    )?),
                    None,
                ),
                "msup" => (
                    None,
                    Some(layout_node(
                        children[1],
                        size * 0.7,
                        fonts,
                        count,
                        depth + 1,
                    )?),
                ),
                _ => (
                    Some(layout_node(
                        children[1],
                        size * 0.7,
                        fonts,
                        count,
                        depth + 1,
                    )?),
                    Some(layout_node(
                        children[2],
                        size * 0.7,
                        fonts,
                        count,
                        depth + 1,
                    )?),
                ),
            };
            Ok(scripts_box(base, sub, sup, size))
        }
        "mtable" => table_box(node, size, fonts, count, depth + 1),
        "mfenced" => {
            let open = text_box(node.attribute("open").unwrap_or("("), size, fonts)?;
            let content = layout_children(node, size, fonts, count, depth + 1)?;
            let close = text_box(node.attribute("close").unwrap_or(")"), size, fonts)?;
            row_box(vec![open, content, close])
        }
        "semantics" => {
            let presentation = element_children(node)
                .into_iter()
                .find(|child| !matches!(child.tag_name().name(), "annotation" | "annotation-xml"))
                .ok_or_else(|| "MathML semantics has no presentation child".to_owned())?;
            layout_node(presentation, size, fonts, count, depth + 1)
        }
        unsupported => Err(format!("unsupported MathML element <{unsupported}>")),
    }
}

fn admit_node(count: &mut usize) -> Result<(), String> {
    *count += 1;
    if *count > MAX_NODES {
        return Err("MathML node count exceeds the spike limit".into());
    }
    Ok(())
}

fn readable_fallback(node: Node<'_, '_>) -> Result<String, String> {
    let mut count = 0;
    fallback_node(node, 0, &mut count)
}

fn fallback_node(node: Node<'_, '_>, depth: usize, count: &mut usize) -> Result<String, String> {
    if depth > MAX_DEPTH {
        return Err("MathML fallback nesting exceeds the spike limit".into());
    }
    *count += 1;
    if *count > MAX_NODES {
        return Err("MathML fallback node count exceeds the spike limit".into());
    }
    match node.tag_name().name() {
        "mi" | "mn" | "mo" | "mtext" => token_text(node),
        "mfrac" => {
            let children = element_children(node);
            match children.as_slice() {
                [numerator, denominator] => Ok(format!(
                    "({})/({})",
                    fallback_node(*numerator, depth + 1, count)?,
                    fallback_node(*denominator, depth + 1, count)?
                )),
                _ => children
                    .into_iter()
                    .map(|child| fallback_node(child, depth + 1, count))
                    .collect::<Result<Vec<_>, _>>()
                    .map(|children| children.join(" ")),
            }
        }
        "msqrt" => Ok(format!("sqrt({})", fallback_children(node, depth, count)?)),
        "mroot" => {
            let children = element_children(node);
            match children.as_slice() {
                [radicand, index] => Ok(format!(
                    "root({}, {})",
                    fallback_node(*radicand, depth + 1, count)?,
                    fallback_node(*index, depth + 1, count)?
                )),
                _ => fallback_children(node, depth, count),
            }
        }
        "msub" => fallback_script(node, "_", depth, count),
        "msup" => fallback_script(node, "^", depth, count),
        "msubsup" => {
            let children = element_children(node);
            match children.as_slice() {
                [base, sub, sup] => Ok(format!(
                    "{}_{}^{}",
                    fallback_node(*base, depth + 1, count)?,
                    fallback_node(*sub, depth + 1, count)?,
                    fallback_node(*sup, depth + 1, count)?
                )),
                _ => fallback_children(node, depth, count),
            }
        }
        "annotation" | "annotation-xml" => Ok(String::new()),
        _ => fallback_children(node, depth, count),
    }
}

fn fallback_script(
    node: Node<'_, '_>,
    operator: &str,
    depth: usize,
    count: &mut usize,
) -> Result<String, String> {
    let children = element_children(node);
    match children.as_slice() {
        [base, script] => Ok(format!(
            "{}{operator}{}",
            fallback_node(*base, depth + 1, count)?,
            fallback_node(*script, depth + 1, count)?
        )),
        _ => fallback_children(node, depth, count),
    }
}

fn fallback_children(
    node: Node<'_, '_>,
    depth: usize,
    count: &mut usize,
) -> Result<String, String> {
    let mut parts = Vec::new();
    for child in node.children() {
        let text = if child.is_text() {
            child.text().unwrap_or_default().trim().to_owned()
        } else if child.is_element() {
            if matches!(child.tag_name().name(), "annotation" | "annotation-xml") {
                continue;
            }
            fallback_node(child, depth + 1, count)?
        } else {
            continue;
        };
        if !text.is_empty() {
            parts.push(text);
        }
    }
    Ok(parts.join(" "))
}

fn evidence(node: Node<'_, '_>) -> MathEvidence {
    if let Err(error) = preflight_math(node) {
        return MathEvidence {
            display: node.attribute("display") == Some("block"),
            fallback: Err(error.clone()),
            layout: Err(error),
        };
    }
    let mut fonts = font_system();
    let mut count = 0;
    MathEvidence {
        display: node.attribute("display") == Some("block"),
        fallback: readable_fallback(node),
        layout: layout_node(node, FONT_SIZE, &mut fonts, &mut count, 0),
    }
}

fn fixture() -> roxmltree::Document<'static> {
    roxmltree::Document::parse(XHTML).expect("native MathML fixture must be valid XHTML")
}

fn by_id<'a>(document: &'a roxmltree::Document<'a>, id: &str) -> Node<'a, 'a> {
    document
        .descendants()
        .find(|node| node.attribute("id") == Some(id))
        .unwrap_or_else(|| panic!("fixture is missing #{id}"))
}

fn source_evidence(source: &str) -> MathEvidence {
    let document = roxmltree::Document::parse(source).unwrap();
    evidence(document.root_element())
}

fn assert_primitives_in_bounds(layout: &MathBox) {
    assert!(
        layout.primitives.iter().all(|primitive| {
            [primitive.x, primitive.y, primitive.width, primitive.height]
                .into_iter()
                .all(f32::is_finite)
                && primitive.x >= 0.0
                && primitive.y >= 0.0
                && primitive.width > 0.0
                && primitive.height > 0.0
                && primitive.x + primitive.width <= layout.width + 0.01
                && primitive.y + primitive.height <= layout.height + 0.01
        }),
        "{layout:?}"
    );
}

#[test]
fn presentation_mathml_subset_produces_bounded_geometry() {
    let document = fixture();
    for id in ["fraction", "root", "scripts", "matrix", "annotated"] {
        let evidence = evidence(by_id(&document, id));
        let layout = evidence
            .layout
            .unwrap_or_else(|error| panic!("#{id} failed: {error}"));
        assert!(layout.width > 0.0 && layout.height > 0.0, "#{id}");
        assert!(
            layout.baseline > 0.0 && layout.baseline <= layout.height,
            "#{id}"
        );
        assert!(!layout.primitives.is_empty(), "#{id}");
        assert!(layout.primitives.len() <= MAX_NODES * 2, "#{id}");
        assert_primitives_in_bounds(&layout);
    }

    let fraction = evidence(by_id(&document, "fraction")).layout.unwrap();
    let fraction_rule = fraction
        .primitives
        .iter()
        .find(|primitive| primitive.kind == PrimitiveKind::FractionRule)
        .unwrap();
    let numerator = fraction
        .primitives
        .iter()
        .find(|primitive| primitive.kind == PrimitiveKind::Text("a".into()))
        .unwrap();
    let denominator = fraction
        .primitives
        .iter()
        .find(|primitive| primitive.kind == PrimitiveKind::Text("b".into()))
        .unwrap();
    assert!(numerator.y + numerator.height <= fraction_rule.y);
    assert!(denominator.y >= fraction_rule.y + fraction_rule.height);

    let root = evidence(by_id(&document, "root")).layout.unwrap();
    assert_eq!(
        root.primitives
            .iter()
            .filter(|primitive| primitive.kind == PrimitiveKind::RadicalRule)
            .count(),
        2
    );

    let scripts = evidence(by_id(&document, "scripts")).layout.unwrap();
    assert!(scripts.primitives.iter().any(|primitive| {
        matches!(&primitive.kind, PrimitiveKind::Text(text) if text == "i" || text == "n")
            && primitive.font_size < FONT_SIZE
    }));

    let matrix = evidence(by_id(&document, "matrix")).layout.unwrap();
    let token = |text: &str| {
        matrix
            .primitives
            .iter()
            .find(
                |primitive| matches!(&primitive.kind, PrimitiveKind::Text(value) if value == text),
            )
            .unwrap()
    };
    assert!(token("a").x < token("b").x && token("c").x < token("d").x);
    assert!(token("a").y < token("c").y && token("b").y < token("d").y);

    assert!(!evidence(by_id(&document, "fraction")).display);
    assert!(evidence(by_id(&document, "root")).display);
}

#[test]
fn unsupported_or_structurally_invalid_mathml_keeps_readable_fallback() {
    let document = fixture();
    let invalid = evidence(by_id(&document, "invalid-fraction"));
    assert_eq!(invalid.fallback.unwrap(), "only");
    assert_eq!(
        invalid.layout.unwrap_err(),
        "MathML fraction requires numerator and denominator"
    );

    let unsupported = evidence(by_id(&document, "unsupported"));
    assert_eq!(unsupported.fallback.unwrap(), "fallback");
    assert_eq!(
        unsupported.layout.unwrap_err(),
        "unsupported MathML element <menclose>"
    );

    let annotated = evidence(by_id(&document, "annotated"));
    assert_eq!(annotated.fallback.unwrap(), "E = m c^2");
    assert!(annotated.layout.is_ok());
}

#[test]
fn mathml_depth_and_node_limits_fail_before_layout_growth() {
    let deep = format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\">{}<mi>x</mi>{}</math>",
        "<mrow>".repeat(MAX_DEPTH + 1),
        "</mrow>".repeat(MAX_DEPTH + 1)
    );
    let document = roxmltree::Document::parse(&deep).unwrap();
    let deep = evidence(document.root_element());
    assert_eq!(
        deep.layout.unwrap_err(),
        "MathML nesting exceeds the spike limit"
    );
    assert_eq!(
        deep.fallback.unwrap_err(),
        "MathML nesting exceeds the spike limit"
    );

    let wide = format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\">{}</math>",
        "<mi>x</mi>".repeat(MAX_NODES)
    );
    let document = roxmltree::Document::parse(&wide).unwrap();
    let wide = evidence(document.root_element());
    assert_eq!(
        wide.layout.unwrap_err(),
        "MathML node count exceeds the spike limit"
    );
    assert_eq!(
        wide.fallback.unwrap_err(),
        "MathML node count exceeds the spike limit"
    );
}

#[test]
fn preflight_counts_every_element_and_rejects_foreign_table_structure() {
    let foreign = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><mtable><mtr xmlns=\"urn:foreign\"><mtd><mi xmlns=\"{MATHML_NAMESPACE}\">x</mi></mtd></mtr></mtable></math>"
    ));
    assert_eq!(
        foreign.layout.unwrap_err(),
        "MathML subtree contains a foreign namespace"
    );

    let annotations = format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><semantics><mi>x</mi>{}</semantics></math>",
        "<annotation>note</annotation>".repeat(MAX_NODES)
    );
    let annotations = source_evidence(&annotations);
    assert_eq!(
        annotations.layout.unwrap_err(),
        "MathML node count exceeds the spike limit"
    );

    let nested = format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\">{}<mi>x</mi>{}</math>",
        "<mtable><mtr><mtd>".repeat(MAX_DEPTH / 3 + 1),
        "</mtd></mtr></mtable>".repeat(MAX_DEPTH / 3 + 1)
    );
    let nested = source_evidence(&nested);
    assert_eq!(
        nested.layout.unwrap_err(),
        "MathML nesting exceeds the spike limit"
    );
}

#[test]
fn preflight_rejects_ambiguous_semantics_and_oversized_visible_text() {
    let semantics = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><semantics><mi>a</mi><mi>b</mi></semantics></math>"
    ));
    assert_eq!(
        semantics.layout.unwrap_err(),
        "MathML semantics requires one presentation child followed by annotations"
    );

    let foreign_annotation = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><semantics><mi>x</mi><annotation-xml><svg xmlns=\"http://www.w3.org/2000/svg\"><path/></svg></annotation-xml></semantics></math>"
    ));
    assert!(foreign_annotation.layout.is_ok());
    assert_eq!(foreign_annotation.fallback.unwrap(), "x");

    let oversized = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><mi>{}</mi></math>",
        "x".repeat(MAX_VISIBLE_TEXT_BYTES + 1)
    ));
    assert_eq!(
        oversized.layout.unwrap_err(),
        "MathML visible text exceeds the spike limit"
    );

    let fence = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><mfenced open=\"{}\"><mi>x</mi></mfenced></math>",
        "(".repeat(MAX_VISIBLE_TEXT_BYTES + 1)
    ));
    assert_eq!(
        fence.layout.unwrap_err(),
        "MathML visible text exceeds the spike limit"
    );
}

#[test]
fn compound_layout_boxes_include_every_placed_child_extent() {
    for source in [
        format!(
            "<math xmlns=\"{MATHML_NAMESPACE}\"><mroot><mi>x</mi><mtext>{}</mtext></mroot></math>",
            "index".repeat(20)
        ),
        format!(
            "<math xmlns=\"{MATHML_NAMESPACE}\"><msup><mi>x</mi><mfrac><mi>a</mi><mi>b</mi></mfrac></msup></math>"
        ),
        format!(
            "<math xmlns=\"{MATHML_NAMESPACE}\"><msqrt><mfrac><mi>a</mi><mi>b</mi></mfrac></msqrt></math>"
        ),
    ] {
        let layout = source_evidence(&source).layout.unwrap();
        assert_primitives_in_bounds(&layout);
    }
}

#[test]
fn inline_fraction_baseline_tracks_the_fraction_rule() {
    let layout = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><mfrac><mi>a</mi><mi>b</mi></mfrac></math>"
    ))
    .layout
    .unwrap();
    let rule = layout
        .primitives
        .iter()
        .find(|primitive| primitive.kind == PrimitiveKind::FractionRule)
        .unwrap();
    assert!((layout.baseline - (rule.y + rule.height)).abs() <= FONT_SIZE * 0.2);
}

#[test]
fn tokens_preserve_split_text_and_reject_nested_or_multiline_content() {
    let split = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><mi>a<!-- split -->b</mi></math>"
    ))
    .layout
    .unwrap();
    assert!(
        split
            .primitives
            .iter()
            .any(|primitive| primitive.kind == PrimitiveKind::Text("ab".into()))
    );

    let nested = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><mi>a<mtext>b</mtext></mi></math>"
    ));
    assert_eq!(
        nested.layout.unwrap_err(),
        "MathML tokens may contain only text and comments"
    );

    let multiline = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><mi>a\n日</mi></math>"
    ));
    assert_eq!(
        multiline.layout.unwrap_err(),
        "multiline MathML tokens are unsupported by the spike"
    );
}

#[test]
fn unsupported_element_fallback_preserves_direct_text_in_source_order() {
    let evidence = source_evidence(&format!(
        "<math xmlns=\"{MATHML_NAMESPACE}\"><menclose>before<mtext>inside</mtext>after</menclose></math>"
    ));
    assert_eq!(evidence.fallback.unwrap(), "before inside after");
    assert_eq!(
        evidence.layout.unwrap_err(),
        "unsupported MathML element <menclose>"
    );
}

#[test]
fn mixed_script_fixture_shapes_known_scripts_and_exposes_cjk_gap() {
    let document = fixture();
    let text = by_id(&document, "mixed").text().unwrap();
    let mut fonts = font_system();
    let mut buffer = Buffer::new(&mut fonts, Metrics::new(FONT_SIZE, FONT_SIZE * 1.4));
    buffer.set_size(&mut fonts, Some(400.0), None);
    buffer.set_text(
        &mut fonts,
        text,
        &Attrs::new().family(Family::SansSerif),
        Shaping::Advanced,
        None,
    );
    buffer.shape_until_scroll(&mut fonts, false);
    let glyphs = buffer
        .layout_runs()
        .flat_map(|run| run.glyphs)
        .map(|glyph| {
            let source = &text[glyph.start..glyph.end];
            let family = fonts.db().face(glyph.font_id).unwrap().families[0]
                .0
                .clone();
            (source, family, glyph.glyph_id, glyph.level.number())
        })
        .collect::<Vec<_>>();

    assert!(glyphs.iter().any(|(source, family, glyph, _)| {
        source
            .chars()
            .any(|character| character.is_ascii_alphabetic())
            && family == "Inter Variable"
            && *glyph != 0
    }));
    assert!(glyphs.iter().any(|(source, family, glyph, level)| {
        source
            .chars()
            .any(|character| ('\u{0600}'..='\u{06ff}').contains(&character))
            && family == "Noto Sans Arabic"
            && *glyph != 0
            && level % 2 == 1
    }));
    assert!(
        glyphs.iter().any(|(source, _, glyph, _)| {
            source
                .chars()
                .any(|character| ('\u{3000}'..='\u{9fff}').contains(&character))
                && *glyph == 0
        }),
        "the fixture must keep the known missing CJK-font evidence visible: {glyphs:?}"
    );
}
