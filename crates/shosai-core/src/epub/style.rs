//! Native EPUB stylesheet ownership and supported CSS surface.
//!
//! Stylesheets are retained by canonical archive path and selected in each
//! XHTML document's source order. The computed-style engine supports type,
//! class, ID, child, descendant, adjacent-sibling, and general-sibling
//! selectors, plus `:root`, `:empty`, `:is()`, `:where()`, and `:not()`.
//! Supported declarations are `display`, `font-family`, `font-size`,
//! `font-style`, `font-weight`, `text-align`, `direction`, `white-space`,
//! `text-indent`, and `margin-left`. Unconditional `screen`, `all`, and inverse
//! `print` media rules participate in the cascade. Unsupported selectors,
//! declarations, and conditional rules are ignored rather than aborting the
//! book. `@import` resolution is a separate bounded-resource milestone.

use std::collections::HashMap;

use lightningcss::rules::CssRule;
use lightningcss::stylesheet::{ParserOptions, StyleSheet};
use lightningcss::traits::ToCss;
use roxmltree::Node;

use super::CanonicalEpubPath;

/// Simplified text alignment consumed by native reader widgets.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TextAlignment {
    Left,
    Center,
    Right,
    Justify,
}

/// Admitted author stylesheets keyed by canonical archive path.
#[derive(Debug, Clone, Default)]
pub struct EpubStyles {
    sources: HashMap<CanonicalEpubPath, String>,
}

impl EpubStyles {
    /// Retain UTF-8 stylesheets for document-scoped matching and cascade.
    pub fn parse<'a>(css_sources: impl IntoIterator<Item = (&'a str, &'a str)>) -> Self {
        let sources = css_sources
            .into_iter()
            .filter_map(|(path, css)| {
                Some((CanonicalEpubPath::new(path).ok()?, normalized_css(css)?))
            })
            .collect();
        Self { sources }
    }

    pub(crate) fn document_css(
        &self,
        document: &roxmltree::Document<'_>,
        base_path: &str,
    ) -> String {
        let mut css = String::new();
        for element in document.descendants().filter(Node::is_element) {
            match element.tag_name().name() {
                "link" if is_stylesheet_link(element) => {
                    let Some(href) = element.attribute("href") else {
                        continue;
                    };
                    let Ok(reference) = CanonicalEpubPath::resolve(base_path, href) else {
                        continue;
                    };
                    if let Some(source) = self.sources.get(&reference.path) {
                        append_stylesheet(&mut css, source, element.attribute("media"));
                    }
                }
                "style" => {
                    let source = element.children().filter_map(|child| child.text()).fold(
                        String::new(),
                        |mut source, text| {
                            source.push_str(text);
                            source
                        },
                    );
                    if let Some(source) = normalized_css(&source) {
                        append_stylesheet(&mut css, &source, element.attribute("media"));
                    }
                }
                _ => {}
            }
        }
        css
    }

    /// Number of admitted external stylesheet resources.
    pub fn len(&self) -> usize {
        self.sources.len()
    }

    /// Whether no external stylesheet resources were admitted.
    pub fn is_empty(&self) -> bool {
        self.sources.is_empty()
    }
}

fn append_stylesheet(target: &mut String, source: &str, media: Option<&str>) {
    if let Some(media) = media.filter(|media| !media.trim().is_empty()) {
        let Some(media) = normalized_media(media) else {
            return;
        };
        target.push_str("@media ");
        target.push_str(&media);
        target.push('{');
        target.push_str(source);
        target.push_str("}\n");
    } else {
        target.push_str(source);
        target.push('\n');
    }
}

fn normalized_media(source: &str) -> Option<String> {
    let wrapper = format!("@media {source} {{}}");
    let sheet = StyleSheet::parse(&wrapper, ParserOptions::default()).ok()?;
    let [CssRule::Media(rule)] = sheet.rules.0.as_slice() else {
        return None;
    };
    if !rule.rules.0.is_empty() {
        return None;
    }
    rule.query.to_css_string(Default::default()).ok()
}

fn normalized_css(source: &str) -> Option<String> {
    let sheet = StyleSheet::parse(source, ParserOptions::default()).ok()?;
    let mut normalized = String::new();
    for rule in &sheet.rules.0 {
        if matches!(rule, CssRule::Import(_) | CssRule::Namespace(_)) {
            continue;
        }
        normalized.push_str(&rule.to_css_string(Default::default()).ok()?);
        normalized.push('\n');
    }
    Some(normalized)
}

fn is_stylesheet_link(element: Node<'_, '_>) -> bool {
    if element.attribute("disabled").is_some() {
        return false;
    }
    element.attribute("rel").is_some_and(|relations| {
        let relations = relations.split_ascii_whitespace().collect::<Vec<_>>();
        relations
            .iter()
            .any(|relation| relation.eq_ignore_ascii_case("stylesheet"))
            && !relations
                .iter()
                .any(|relation| relation.eq_ignore_ascii_case("alternate"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn document_styles_follow_link_and_inline_source_order() {
        let styles = EpubStyles::parse([
            ("OEBPS/Styles/first.css", ".target { font-style: italic; }"),
            ("OEBPS/Styles/second.css", ".target { font-style: normal; }"),
        ]);
        let document = roxmltree::Document::parse(
            r#"<html><head>
                <link rel="stylesheet" href="../Styles/first.css"/>
                <style>.target { font-weight: bold; }</style>
                <link rel="stylesheet" href="../Styles/second.css"/>
            </head><body/></html>"#,
        )
        .unwrap();

        let css = styles.document_css(&document, "OEBPS/Text");
        let italic = css.find("font-style: italic").unwrap();
        let bold = css.find("font-weight: bold").unwrap();
        let normal = css.find("font-style: normal").unwrap();
        assert!(italic < bold && bold < normal);
    }

    #[test]
    fn document_styles_preserve_media_without_accepting_css_injection() {
        let styles = EpubStyles::parse([
            ("OEBPS/Styles/print.css", ".target { display: none; }"),
            (
                "OEBPS/Styles/injected.css",
                ".target { font-weight: normal; }",
            ),
        ]);
        let document = roxmltree::Document::parse(
            r#"<html><head>
                <link rel="stylesheet" href="../Styles/print.css" media="print"/>
                <style media="screen">.target { font-weight: bold; }</style>
                <link rel="stylesheet" href="../Styles/injected.css"
                      media="screen} .target { display: none }"/>
            </head><body/></html>"#,
        )
        .unwrap();

        let css = styles.document_css(&document, "OEBPS/Text");
        assert!(css.contains("@media print"));
        assert!(css.contains("@media screen"));
        assert!(css.contains("font-weight: bold"));
        assert!(!css.contains("font-weight: normal"));
        assert_eq!(css.matches("display: none").count(), 1);
    }

    #[test]
    fn foreign_and_missing_stylesheet_links_are_ignored() {
        let styles = EpubStyles::default();
        let document = roxmltree::Document::parse(
            r#"<html><head>
                <link rel="stylesheet" href="https://example.com/book.css"/>
                <link rel="stylesheet" href="../../../escape.css"/>
            </head><body/></html>"#,
        )
        .unwrap();

        assert!(styles.document_css(&document, "OEBPS/Text").is_empty());
    }
}
