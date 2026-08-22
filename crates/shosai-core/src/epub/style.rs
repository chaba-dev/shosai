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
//! book. Stylesheet imports are resolved recursively within bounded depth,
//! application, and selected-byte budgets. Resource URLs are canonicalized to
//! the isolated book origin relative to the stylesheet that owns them.

use std::collections::{HashMap, HashSet};

use anyhow::{Context, Result};
use lightningcss::dependencies::{Dependency, DependencyOptions};
use lightningcss::rules::CssRule;
use lightningcss::stylesheet::{ParserOptions, PrinterOptions, StyleSheet};
use lightningcss::traits::ToCss;
use roxmltree::Node;

use super::{CanonicalEpubPath, EpubLimits};

/// Simplified text alignment consumed by native reader widgets.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TextAlignment {
    Left,
    Center,
    Right,
    Justify,
}

/// Base text direction consumed by native reader widgets.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum TextDirection {
    #[default]
    Ltr,
    Rtl,
}

#[derive(Debug, Clone)]
struct StylesheetImport {
    href: String,
    media: Option<String>,
}

#[derive(Debug, Clone)]
struct StylesheetSource {
    body: String,
    imports: Vec<StylesheetImport>,
}

/// Admitted author stylesheets keyed by canonical archive path.
#[derive(Debug, Clone, Default)]
pub struct EpubStyles {
    sources: HashMap<CanonicalEpubPath, StylesheetSource>,
}

impl EpubStyles {
    /// Retain UTF-8 stylesheets for document-scoped matching and cascade.
    pub fn parse<'a>(css_sources: impl IntoIterator<Item = (&'a str, &'a str)>) -> Self {
        Self::parse_with_limits(css_sources, &EpubLimits::default()).unwrap_or_default()
    }

    pub(crate) fn parse_with_limits<'a>(
        css_sources: impl IntoIterator<Item = (&'a str, &'a str)>,
        limits: &EpubLimits,
    ) -> Result<Self> {
        let sources = css_sources
            .into_iter()
            .map(|(path, css)| -> Result<Option<_>> {
                if css.len() as u64 > limits.max_css_resource_bytes {
                    anyhow::bail!(
                        "EPUB CSS resource exceeds byte limit: {path} ({} > {})",
                        css.len(),
                        limits.max_css_resource_bytes
                    );
                }
                let Ok(path) = CanonicalEpubPath::new(path) else {
                    return Ok(None);
                };
                let base_path = stylesheet_directory(path.as_str());
                let Some(css) = parsed_stylesheet(css, base_path) else {
                    return Ok(None);
                };
                Ok(Some((path, css)))
            })
            .collect::<Result<Vec<_>>>()?
            .into_iter()
            .flatten()
            .collect();
        Ok(Self { sources })
    }

    pub(crate) fn document_css(
        &self,
        document: &roxmltree::Document<'_>,
        base_path: &str,
        limits: &EpubLimits,
    ) -> Result<String> {
        let mut css = String::new();
        let mut applications = 0_usize;
        let mut active_imports = HashSet::new();
        for element in document.descendants().filter(Node::is_element) {
            match element.tag_name().name() {
                "link" if is_stylesheet_link(element) => {
                    let Some(media) = selected_media(element.attribute("media")) else {
                        continue;
                    };
                    let Some(href) = element.attribute("href") else {
                        continue;
                    };
                    let Ok(reference) = CanonicalEpubPath::resolve(base_path, href) else {
                        continue;
                    };
                    if let Some(source) = self.expand_external_stylesheet(
                        &reference.path,
                        0,
                        &mut active_imports,
                        &mut applications,
                        limits,
                    )? {
                        let _ = append_stylesheet_content(
                            &mut css,
                            &source,
                            media.as_deref(),
                            limits,
                        )?;
                    }
                }
                "style" => {
                    let Some(media) = selected_media(element.attribute("media")) else {
                        continue;
                    };
                    let source = element.children().filter_map(|child| child.text()).fold(
                        String::new(),
                        |mut source, text| {
                            source.push_str(text);
                            source
                        },
                    );
                    if let Some(source) = parsed_stylesheet(&source, base_path) {
                        let source = self.expand_stylesheet(
                            &source,
                            base_path,
                            0,
                            &mut active_imports,
                            &mut applications,
                            limits,
                        )?;
                        let _ =
                            append_stylesheet_content(&mut css, &source, media.as_deref(), limits)?;
                    }
                }
                _ => {}
            }
        }
        Ok(css)
    }

    fn expand_external_stylesheet(
        &self,
        path: &CanonicalEpubPath,
        depth: usize,
        active: &mut HashSet<CanonicalEpubPath>,
        applications: &mut usize,
        limits: &EpubLimits,
    ) -> Result<Option<String>> {
        if active.contains(path) {
            return Ok(None);
        }
        let Some(source) = self.sources.get(path) else {
            return Ok(None);
        };
        if depth > limits.max_css_import_depth {
            anyhow::bail!(
                "EPUB stylesheet import depth limit exceeded ({depth} > {})",
                limits.max_css_import_depth
            );
        }

        active.insert(path.clone());
        let result = self.expand_stylesheet(
            source,
            stylesheet_directory(path.as_str()),
            depth,
            active,
            applications,
            limits,
        );
        active.remove(path);
        result.map(Some)
    }

    fn expand_stylesheet(
        &self,
        source: &StylesheetSource,
        base_path: &str,
        depth: usize,
        active: &mut HashSet<CanonicalEpubPath>,
        applications: &mut usize,
        limits: &EpubLimits,
    ) -> Result<String> {
        reserve_stylesheet_application(applications, limits)?;
        let mut expanded = String::new();
        for import in &source.imports {
            let Ok(reference) = CanonicalEpubPath::resolve(base_path, &import.href) else {
                continue;
            };
            if reference.fragment.is_some() {
                continue;
            }
            if let Some(imported) = self.expand_external_stylesheet(
                &reference.path,
                depth.saturating_add(1),
                active,
                applications,
                limits,
            )? {
                let _ = append_stylesheet_content(
                    &mut expanded,
                    &imported,
                    import.media.as_deref(),
                    limits,
                )?;
            }
        }
        let _ = append_stylesheet_content(&mut expanded, &source.body, None, limits)?;
        Ok(expanded)
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

#[cfg(test)]
fn append_stylesheet(
    target: &mut String,
    source: &str,
    media: Option<&str>,
    applications: &mut usize,
    limits: &EpubLimits,
) -> Result<bool> {
    let mut next_applications = *applications;
    reserve_stylesheet_application(&mut next_applications, limits)?;
    let appended = append_stylesheet_content(target, source, media, limits)?;
    if appended {
        *applications = next_applications;
    }
    Ok(appended)
}

fn reserve_stylesheet_application(applications: &mut usize, limits: &EpubLimits) -> Result<()> {
    let next_applications = applications
        .checked_add(1)
        .context("EPUB stylesheet application count overflowed")?;
    if next_applications > limits.max_css_stylesheets_per_document {
        anyhow::bail!(
            "EPUB document exceeds stylesheet application limit ({next_applications} > {})",
            limits.max_css_stylesheets_per_document
        );
    }
    *applications = next_applications;
    Ok(())
}

fn append_stylesheet_content(
    target: &mut String,
    source: &str,
    media: Option<&str>,
    limits: &EpubLimits,
) -> Result<bool> {
    let media = match media.filter(|media| !media.trim().is_empty()) {
        Some(media) => {
            let Some(media) = normalized_media(media) else {
                return Ok(false);
            };
            Some(media)
        }
        None => None,
    };
    let wrapper_bytes = media.as_ref().map_or(1, |media| 10 + media.len());
    let next_bytes = target
        .len()
        .checked_add(source.len())
        .and_then(|bytes| bytes.checked_add(wrapper_bytes))
        .context("EPUB selected CSS byte count overflowed")?;
    if next_bytes as u64 > limits.max_css_bytes_per_document {
        anyhow::bail!(
            "EPUB document exceeds selected CSS byte limit ({next_bytes} > {})",
            limits.max_css_bytes_per_document
        );
    }

    if let Some(media) = media {
        target.push_str("@media ");
        target.push_str(&media);
        target.push('{');
        target.push_str(source);
        target.push_str("}\n");
    } else {
        target.push_str(source);
        target.push('\n');
    }
    Ok(true)
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

fn selected_media(source: Option<&str>) -> Option<Option<String>> {
    match source.filter(|media| !media.trim().is_empty()) {
        Some(media) => normalized_media(media).map(Some),
        None => Some(None),
    }
}

fn parsed_stylesheet(source: &str, base_path: &str) -> Option<StylesheetSource> {
    let mut sheet = StyleSheet::parse(source, ParserOptions::default()).ok()?;
    if sheet
        .rules
        .0
        .iter()
        .any(|rule| matches!(rule, CssRule::Namespace(namespace) if namespace.prefix.is_none()))
    {
        return None;
    }
    let mut imports = Vec::new();
    for rule in &sheet.rules.0 {
        if let CssRule::Import(rule) = rule {
            if rule.layer.is_some() || rule.supports.is_some() {
                continue;
            }
            let media = match rule.media.media_queries.is_empty() {
                true => None,
                false => Some(normalized_media(
                    &rule.media.to_css_string(Default::default()).ok()?,
                )?),
            };
            imports.push(StylesheetImport {
                href: rule.url.to_string(),
                media,
            });
        }
    }
    sheet
        .rules
        .0
        .retain(|rule| !matches!(rule, CssRule::Namespace(_)));

    let result = sheet
        .to_css(PrinterOptions {
            analyze_dependencies: Some(DependencyOptions {
                remove_imports: true,
            }),
            ..PrinterOptions::default()
        })
        .ok()?;
    let mut body = result.code;
    for dependency in result.dependencies.unwrap_or_default() {
        if let Dependency::Url(dependency) = dependency {
            let replacement = CanonicalEpubPath::resolve(base_path, &dependency.url).map_or_else(
                |_| "about:invalid".to_owned(),
                |reference| reference.to_protocol_uri(),
            );
            body = body.replace(&dependency.placeholder, &replacement);
        }
    }
    Some(StylesheetSource { body, imports })
}

#[cfg(test)]
fn normalized_css(source: &str) -> Option<String> {
    parsed_stylesheet(source, "").map(|source| source.body)
}

fn stylesheet_directory(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(directory, _)| directory)
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

        let css = styles
            .document_css(&document, "OEBPS/Text", &EpubLimits::default())
            .unwrap();
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

        let css = styles
            .document_css(&document, "OEBPS/Text", &EpubLimits::default())
            .unwrap();
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

        assert!(
            styles
                .document_css(&document, "OEBPS/Text", &EpubLimits::default())
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn default_namespaces_cannot_broaden_retained_type_selectors() {
        let css = r#"@namespace "http://www.w3.org/2000/svg"; a { display: none; }"#;

        assert!(
            normalized_css(css).is_none(),
            "a stylesheet with a default namespace must be ignored until matching is namespace-aware"
        );
    }

    #[test]
    fn stylesheet_resource_selection_is_bounded_before_amplification() {
        let source = ".target { font-weight: bold; }";
        let document = roxmltree::Document::parse(
            r#"<html><head>
                <link rel="stylesheet" href="style.css"/>
                <link rel="stylesheet" href="style.css"/>
            </head><body/></html>"#,
        )
        .unwrap();
        let styles = EpubStyles::parse([("style.css", source)]);

        let application_error = styles
            .document_css(
                &document,
                "",
                &EpubLimits {
                    max_css_stylesheets_per_document: 1,
                    ..EpubLimits::default()
                },
            )
            .unwrap_err();
        assert!(application_error.to_string().contains("application limit"));

        let byte_error = styles
            .document_css(
                &document,
                "",
                &EpubLimits {
                    max_css_bytes_per_document: source.len() as u64,
                    ..EpubLimits::default()
                },
            )
            .unwrap_err();
        assert!(byte_error.to_string().contains("selected CSS byte limit"));

        let resource_error = EpubStyles::parse_with_limits(
            [("style.css", source)],
            &EpubLimits {
                max_css_resource_bytes: 1,
                ..EpubLimits::default()
            },
        )
        .unwrap_err();
        assert!(resource_error.to_string().contains("CSS resource exceeds"));

        let mut target = "existing".to_string();
        let mut applications = 0;
        let existing_bytes = target.len() as u64;
        let error = append_stylesheet(
            &mut target,
            source,
            None,
            &mut applications,
            &EpubLimits {
                max_css_bytes_per_document: existing_bytes,
                ..EpubLimits::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("selected CSS byte limit"));
        assert_eq!(target, "existing");
        assert_eq!(applications, 0);

        let error = append_stylesheet(
            &mut target,
            source,
            None,
            &mut applications,
            &EpubLimits {
                max_css_stylesheets_per_document: 0,
                ..EpubLimits::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("application limit"));
        assert_eq!(target, "existing");
        assert_eq!(applications, 0);
    }

    #[test]
    fn imports_resolve_from_their_owner_in_source_order() {
        let styles = EpubStyles::parse([
            (
                "OEBPS/Styles/main.css",
                "@import 'nested/first.css'; .target { font-style: normal; }",
            ),
            (
                "OEBPS/Styles/nested/first.css",
                "@import '../shared.css'; .target { font-weight: bold; }",
            ),
            ("OEBPS/Styles/shared.css", ".target { font-style: italic; }"),
        ]);
        let document = roxmltree::Document::parse(
            r#"<html><head><link rel="stylesheet" href="../Styles/main.css"/></head><body/></html>"#,
        )
        .unwrap();

        let css = styles
            .document_css(&document, "OEBPS/Text", &EpubLimits::default())
            .unwrap();
        let italic = css.find("font-style: italic").unwrap();
        let bold = css.find("font-weight: bold").unwrap();
        let normal = css.find("font-style: normal").unwrap();
        assert!(italic < bold && bold < normal);
    }

    #[test]
    fn import_cycles_stop_and_depth_is_bounded() {
        let styles = EpubStyles::parse([
            ("Styles/a.css", "@import 'b.css'; .a { display: block; }"),
            ("Styles/b.css", "@import 'a.css'; .b { display: block; }"),
        ]);
        let document = roxmltree::Document::parse(
            r#"<html><head><link rel="stylesheet" href="Styles/a.css"/></head><body/></html>"#,
        )
        .unwrap();

        let css = styles
            .document_css(&document, "", &EpubLimits::default())
            .unwrap();
        assert_eq!(css.matches(".a").count(), 1);
        assert_eq!(css.matches(".b").count(), 1);

        let error = styles
            .document_css(
                &document,
                "",
                &EpubLimits {
                    max_css_import_depth: 0,
                    ..EpubLimits::default()
                },
            )
            .unwrap_err();
        assert!(error.to_string().contains("import depth limit"));
    }

    #[test]
    fn imports_share_application_and_selected_byte_budgets() {
        let styles = EpubStyles::parse([
            (
                "Styles/main.css",
                "@import 'shared.css'; @import 'shared.css';",
            ),
            ("Styles/shared.css", ".target { display: block; }"),
        ]);
        let document = roxmltree::Document::parse(
            r#"<html><head><link rel="stylesheet" href="Styles/main.css"/></head><body/></html>"#,
        )
        .unwrap();

        let application_error = styles
            .document_css(
                &document,
                "",
                &EpubLimits {
                    max_css_stylesheets_per_document: 2,
                    ..EpubLimits::default()
                },
            )
            .unwrap_err();
        assert!(application_error.to_string().contains("application limit"));

        let byte_error = styles
            .document_css(
                &document,
                "",
                &EpubLimits {
                    max_css_bytes_per_document: 1,
                    ..EpubLimits::default()
                },
            )
            .unwrap_err();
        assert!(byte_error.to_string().contains("selected CSS byte limit"));
    }

    #[test]
    fn imports_reject_foreign_queries_and_archive_escape() {
        let styles = EpubStyles::parse([
            (
                "Styles/main.css",
                "@import 'https://example.com/a.css'; @import '../escape.css?x'; @import 'fragment.css#target'; @import '../../escape.css'; .safe { display: block; }",
            ),
            ("Styles/fragment.css", ".fragment { display: block; }"),
        ]);
        let document = roxmltree::Document::parse(
            r#"<html><head><link rel="stylesheet" href="Styles/main.css"/></head><body/></html>"#,
        )
        .unwrap();

        let css = styles
            .document_css(&document, "", &EpubLimits::default())
            .unwrap();
        assert!(css.contains(".safe"));
        assert!(!css.contains("example.com"));
        assert!(!css.contains("escape.css"));
        assert!(!css.contains(".fragment"));
    }

    #[test]
    fn resource_urls_use_the_owning_stylesheet_or_inline_document_base() {
        let styles = EpubStyles::parse([
            (
                "OEBPS/Styles/main.css",
                ".external { background-image: url('../Images/cover image.png#view'); }",
            ),
            (
                "OEBPS/Styles/invalid.css",
                ".remote { background: url('https://example.com/a.png'); } .query { background: url('../a.png?v=1'); }",
            ),
        ]);
        let document = roxmltree::Document::parse(
            r#"<html><head>
                <link rel="stylesheet" href="../Styles/main.css"/>
                <link rel="stylesheet" href="../Styles/invalid.css"/>
                <style>.inline { background-image: url('../Images/inline.png'); }</style>
            </head><body/></html>"#,
        )
        .unwrap();

        let css = styles
            .document_css(&document, "OEBPS/Text", &EpubLimits::default())
            .unwrap();
        assert!(css.contains("shosai://book/OEBPS/Images/cover%20image.png#view"));
        assert!(css.contains("shosai://book/OEBPS/Images/inline.png"));
        assert!(!css.contains("https://example.com"));
        assert!(!css.contains("?v=1"));
    }
}
