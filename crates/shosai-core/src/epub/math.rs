use roxmltree::Node;

const MATHML_NAMESPACE: &str = "http://www.w3.org/1998/Math/MathML";
const MAX_DEPTH: usize = 16;
const MAX_NODES: usize = 64;
const MAX_VISIBLE_TEXT_BYTES: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MathDisplay {
    Inline,
    Block,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MathContent {
    pub display: MathDisplay,
    pub expression: Option<MathExpression>,
    pub fallback: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MathExpression {
    Row(Vec<MathExpression>),
    Token(String),
    Fraction(Box<MathExpression>, Box<MathExpression>),
    SquareRoot(Vec<MathExpression>),
    Root(Box<MathExpression>, Box<MathExpression>),
    Subscript(Box<MathExpression>, Box<MathExpression>),
    Superscript(Box<MathExpression>, Box<MathExpression>),
    SubSuperscript {
        base: Box<MathExpression>,
        subscript: Box<MathExpression>,
        superscript: Box<MathExpression>,
    },
    Fenced {
        open: String,
        close: String,
        content: Vec<MathExpression>,
    },
    Table(Vec<Vec<MathExpression>>),
}

#[derive(Default)]
struct Budget {
    nodes: usize,
    visible_text_bytes: usize,
}

pub(super) fn is_math(node: Node<'_, '_>) -> bool {
    node.is_element()
        && node.tag_name().name() == "math"
        && node.tag_name().namespace() == Some(MATHML_NAMESPACE)
}

pub(super) fn parse_math(root: Node<'_, '_>) -> MathContent {
    let display = if root.attribute("display") == Some("block") {
        MathDisplay::Block
    } else {
        MathDisplay::Inline
    };
    let mut budget = Budget::default();
    if preflight(root, 0, false, false, &mut budget).is_err() {
        return MathContent {
            display,
            expression: None,
            fallback: "[math expression omitted]".into(),
        };
    }
    let fallback = fallback(root, 0, &mut 0).unwrap_or_else(|_| "[unsupported math]".into());
    let expression = expression(root, 0, &mut 0).ok();
    MathContent {
        display,
        expression,
        fallback,
    }
}

fn preflight(
    node: Node<'_, '_>,
    depth: usize,
    allow_foreign: bool,
    suppress_text: bool,
    budget: &mut Budget,
) -> Result<(), ()> {
    if depth > MAX_DEPTH {
        return Err(());
    }
    budget.nodes = budget.nodes.checked_add(1).ok_or(())?;
    if budget.nodes > MAX_NODES
        || (!allow_foreign && node.tag_name().namespace() != Some(MATHML_NAMESPACE))
    {
        return Err(());
    }
    let name = node.tag_name().name();
    if name == "semantics" {
        let children = elements(node);
        if children.first().is_none_or(|child| is_annotation(*child))
            || children.iter().skip(1).any(|child| !is_annotation(*child))
        {
            return Err(());
        }
    }
    let suppress_text = suppress_text || is_annotation(node);
    if !suppress_text {
        for text in node.children().filter(Node::is_text) {
            budget.visible_text_bytes = budget
                .visible_text_bytes
                .checked_add(text.text().unwrap_or_default().trim().len())
                .ok_or(())?;
            if budget.visible_text_bytes > MAX_VISIBLE_TEXT_BYTES {
                return Err(());
            }
        }
    }
    let allow_foreign = allow_foreign || name == "annotation-xml";
    for child in elements(node) {
        preflight(child, depth + 1, allow_foreign, suppress_text, budget)?;
    }
    Ok(())
}

fn expression(node: Node<'_, '_>, depth: usize, count: &mut usize) -> Result<MathExpression, ()> {
    admit(depth, count)?;
    let children = elements(node);
    match node.tag_name().name() {
        "math" | "mrow" | "mstyle" | "mtd" => row_expression(children, depth, count),
        "mi" | "mn" | "mo" | "mtext" => token(node).map(MathExpression::Token),
        "mfrac" => match children.as_slice() {
            [numerator, denominator] => Ok(MathExpression::Fraction(
                Box::new(expression(*numerator, depth + 1, count)?),
                Box::new(expression(*denominator, depth + 1, count)?),
            )),
            _ => Err(()),
        },
        "msqrt" => row_children(children, depth, count).map(MathExpression::SquareRoot),
        "mroot" => match children.as_slice() {
            [radicand, index] => Ok(MathExpression::Root(
                Box::new(expression(*radicand, depth + 1, count)?),
                Box::new(expression(*index, depth + 1, count)?),
            )),
            _ => Err(()),
        },
        "msub" => binary_script(children, depth, count, MathExpression::Subscript),
        "msup" => binary_script(children, depth, count, MathExpression::Superscript),
        "msubsup" => match children.as_slice() {
            [base, subscript, superscript] => Ok(MathExpression::SubSuperscript {
                base: Box::new(expression(*base, depth + 1, count)?),
                subscript: Box::new(expression(*subscript, depth + 1, count)?),
                superscript: Box::new(expression(*superscript, depth + 1, count)?),
            }),
            _ => Err(()),
        },
        "mfenced" => Ok(MathExpression::Fenced {
            open: node.attribute("open").unwrap_or("(").into(),
            close: node.attribute("close").unwrap_or(")").into(),
            content: row_children(children, depth, count)?,
        }),
        "mtable" => table_expression(children, depth, count),
        "semantics" => children
            .first()
            .copied()
            .ok_or(())
            .and_then(|child| expression(child, depth + 1, count)),
        _ => Err(()),
    }
}

fn row_expression(
    children: Vec<Node<'_, '_>>,
    depth: usize,
    count: &mut usize,
) -> Result<MathExpression, ()> {
    row_children(children, depth, count).map(MathExpression::Row)
}

fn row_children(
    children: Vec<Node<'_, '_>>,
    depth: usize,
    count: &mut usize,
) -> Result<Vec<MathExpression>, ()> {
    children
        .into_iter()
        .filter(|child| !is_annotation(*child))
        .map(|child| expression(child, depth + 1, count))
        .collect()
}

fn binary_script(
    children: Vec<Node<'_, '_>>,
    depth: usize,
    count: &mut usize,
    constructor: fn(Box<MathExpression>, Box<MathExpression>) -> MathExpression,
) -> Result<MathExpression, ()> {
    match children.as_slice() {
        [base, script] => Ok(constructor(
            Box::new(expression(*base, depth + 1, count)?),
            Box::new(expression(*script, depth + 1, count)?),
        )),
        _ => Err(()),
    }
}

fn table_expression(
    rows: Vec<Node<'_, '_>>,
    depth: usize,
    count: &mut usize,
) -> Result<MathExpression, ()> {
    rows.into_iter()
        .map(|row| {
            if row.tag_name().name() != "mtr" {
                return Err(());
            }
            admit(depth + 1, count)?;
            elements(row)
                .into_iter()
                .map(|cell| {
                    if cell.tag_name().name() != "mtd" {
                        return Err(());
                    }
                    expression(cell, depth + 2, count)
                })
                .collect()
        })
        .collect::<Result<Vec<_>, _>>()
        .map(MathExpression::Table)
}

fn fallback(node: Node<'_, '_>, depth: usize, count: &mut usize) -> Result<String, ()> {
    admit(depth, count)?;
    let children = elements(node);
    match node.tag_name().name() {
        "mi" | "mn" | "mo" | "mtext" => token(node),
        "mfrac" => match children.as_slice() {
            [a, b] => Ok(format!(
                "({})/({})",
                fallback(*a, depth + 1, count)?,
                fallback(*b, depth + 1, count)?
            )),
            _ => fallback_children(children, depth, count),
        },
        "msqrt" => Ok(format!(
            "sqrt({})",
            fallback_children(children, depth, count)?
        )),
        "mroot" => match children.as_slice() {
            [a, b] => Ok(format!(
                "root({}, {})",
                fallback(*a, depth + 1, count)?,
                fallback(*b, depth + 1, count)?
            )),
            _ => fallback_children(children, depth, count),
        },
        "msub" => fallback_script(children, "_", depth, count),
        "msup" => fallback_script(children, "^", depth, count),
        "msubsup" => match children.as_slice() {
            [base, sub, sup] => Ok(format!(
                "{}_{}^{}",
                fallback(*base, depth + 1, count)?,
                fallback(*sub, depth + 1, count)?,
                fallback(*sup, depth + 1, count)?
            )),
            _ => fallback_children(children, depth, count),
        },
        "annotation" | "annotation-xml" => Ok(String::new()),
        "mfenced" => Ok(format!(
            "{}{}{}",
            node.attribute("open").unwrap_or("("),
            fallback_children(children, depth, count)?,
            node.attribute("close").unwrap_or(")")
        )),
        "semantics" => children
            .first()
            .copied()
            .ok_or(())
            .and_then(|child| fallback(child, depth + 1, count)),
        _ => fallback_children(children, depth, count),
    }
}

fn fallback_script(
    children: Vec<Node<'_, '_>>,
    operator: &str,
    depth: usize,
    count: &mut usize,
) -> Result<String, ()> {
    match children.as_slice() {
        [base, script] => Ok(format!(
            "{}{operator}{}",
            fallback(*base, depth + 1, count)?,
            fallback(*script, depth + 1, count)?
        )),
        _ => fallback_children(children, depth, count),
    }
}

fn fallback_children(
    children: Vec<Node<'_, '_>>,
    depth: usize,
    count: &mut usize,
) -> Result<String, ()> {
    children
        .into_iter()
        .filter(|child| !is_annotation(*child))
        .map(|child| fallback(child, depth + 1, count))
        .collect::<Result<Vec<_>, _>>()
        .map(|parts| {
            parts
                .into_iter()
                .filter(|part| !part.is_empty())
                .collect::<Vec<_>>()
                .join(" ")
        })
}

fn token(node: Node<'_, '_>) -> Result<String, ()> {
    let mut text = String::new();
    for child in node.children() {
        if child.is_text() {
            text.push_str(child.text().unwrap_or_default());
        } else if !child.is_comment() {
            return Err(());
        }
    }
    let text = text.trim().to_owned();
    (!text.is_empty() && !text.contains(['\n', '\r']))
        .then_some(text)
        .ok_or(())
}

fn admit(depth: usize, count: &mut usize) -> Result<(), ()> {
    if depth > MAX_DEPTH {
        return Err(());
    }
    *count = count.checked_add(1).ok_or(())?;
    (*count <= MAX_NODES).then_some(()).ok_or(())
}

fn elements<'a, 'input>(node: Node<'a, 'input>) -> Vec<Node<'a, 'input>> {
    node.children()
        .filter(Node::is_element)
        .take(MAX_NODES + 1)
        .collect()
}

fn is_annotation(node: Node<'_, '_>) -> bool {
    matches!(node.tag_name().name(), "annotation" | "annotation-xml")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(source: &str) -> MathContent {
        let document = roxmltree::Document::parse(source).unwrap();
        parse_math(document.root_element())
    }

    #[test]
    fn bounded_math_model_retains_supported_structure_and_fallback() {
        let fraction = parse(
            r#"<math xmlns="http://www.w3.org/1998/Math/MathML"><mfrac><mi>a</mi><mi>b</mi></mfrac></math>"#,
        );
        assert_eq!(fraction.display, MathDisplay::Inline);
        assert_eq!(fraction.fallback, "(a)/(b)");
        assert!(matches!(
            fraction.expression,
            Some(MathExpression::Row(children))
                if matches!(children.as_slice(), [MathExpression::Fraction(_, _)])
        ));

        let matrix = parse(
            r#"<math display="block" xmlns="http://www.w3.org/1998/Math/MathML"><mfenced><mtable><mtr><mtd><mi>a</mi></mtd><mtd><msqrt><mi>b</mi></msqrt></mtd></mtr></mtable></mfenced></math>"#,
        );
        assert_eq!(matrix.display, MathDisplay::Block);
        assert!(matrix.expression.is_some());
        assert_eq!(matrix.fallback, "(a sqrt(b))");
    }

    #[test]
    fn unsupported_and_malformed_math_keep_readable_bounded_fallback() {
        let unsupported = parse(
            r#"<math xmlns="http://www.w3.org/1998/Math/MathML"><menclose><mtext>fallback</mtext></menclose></math>"#,
        );
        assert!(unsupported.expression.is_none());
        assert_eq!(unsupported.fallback, "fallback");

        let oversized = format!(
            r#"<math xmlns="http://www.w3.org/1998/Math/MathML"><mtext>{}</mtext></math>"#,
            "x".repeat(MAX_VISIBLE_TEXT_BYTES + 1)
        );
        let oversized = parse(&oversized);
        assert!(oversized.expression.is_none());
        assert_eq!(oversized.fallback, "[math expression omitted]");
    }

    #[test]
    fn semantics_uses_presentation_content_and_suppresses_annotations() {
        let content = parse(
            r#"<math xmlns="http://www.w3.org/1998/Math/MathML"><semantics><msup><mi>c</mi><mn>2</mn></msup><annotation encoding="application/x-tex">secret annotation</annotation></semantics></math>"#,
        );
        assert_eq!(content.fallback, "c^2");
        assert!(!content.fallback.contains("secret"));
        assert!(content.expression.is_some());
    }
}
