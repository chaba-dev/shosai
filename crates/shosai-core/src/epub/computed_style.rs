//! Bounded native CSS cascade and computed-style engine for EPUB XHTML.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use anyhow::{Context, Result};
use cssparser::{Parser, ParserInput};
use lightningcss::declaration::DeclarationBlock;
use lightningcss::media_query::{MediaList, MediaType, Qualifier};
use lightningcss::properties::Property;
use lightningcss::properties::display::{Display, DisplayInside, DisplayKeyword, DisplayOutside};
use lightningcss::properties::font::{
    AbsoluteFontWeight, FamilyName, FontFamily, FontSize, FontStyle, FontWeight, GenericFontFamily,
};
use lightningcss::properties::size::{MaxSize as CssMaxSize, Size as CssSize};
use lightningcss::properties::text::{Direction as CssDirection, TextAlign, WhiteSpace};
use lightningcss::rules::{CssRule, font_face::FontFaceProperty};
use lightningcss::selector::{Combinator, Component, Selector};
use lightningcss::stylesheet::{ParserOptions, StyleAttribute, StyleSheet};
use lightningcss::traits::ToCss;
use lightningcss::values::length::{LengthPercentageOrAuto, LengthValue};
use lightningcss::values::percentage::DimensionPercentage;
use roxmltree::{Node, NodeId};

use super::EpubLimits;

const INITIAL_FONT_SIZE_PX: f32 = 16.0;
const INLINE_SPECIFICITY: u32 = u32::MAX;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Direction {
    Ltr,
    Rtl,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Alignment {
    Start,
    End,
    Left,
    Right,
    Center,
    Justify,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DisplayRole {
    None,
    Inline,
    Block,
    Table,
    TableRowGroup,
    TableRow,
    TableCell,
    TableCaption,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum ComputedWidth {
    Percent(f32),
    Px(f32),
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ComputedStyle {
    pub(crate) display: DisplayRole,
    pub(crate) font_size_px: f32,
    pub(crate) bold: bool,
    pub(crate) italic: bool,
    pub(crate) monospace: bool,
    pub(crate) font_families: Arc<[Arc<str>]>,
    pub(crate) alignment: Alignment,
    pub(crate) direction: Direction,
    pub(crate) preserve_whitespace: bool,
    pub(crate) margin_left_px: f32,
    pub(crate) margin_top_px: Option<f32>,
    pub(crate) margin_bottom_px: Option<f32>,
    pub(crate) text_indent_px: f32,
    pub(crate) width: Option<ComputedWidth>,
    pub(crate) max_width: Option<ComputedWidth>,
}

#[derive(Debug)]
pub(crate) struct ComputedDocumentStyles {
    node_styles: HashMap<NodeId, ComputedStyle>,
    #[allow(dead_code)]
    element_styles: HashMap<String, ComputedStyle>,
    #[allow(dead_code)]
    pub(crate) font_face_rules: usize,
    #[allow(dead_code)]
    pub(crate) unsupported_selectors: Vec<String>,
    #[allow(dead_code)]
    pub(crate) unsupported_rules: Vec<String>,
    #[allow(dead_code)]
    pub(crate) unsupported_declarations: Vec<String>,
}

impl ComputedDocumentStyles {
    pub(crate) fn get(&self, node: Node<'_, '_>) -> Option<&ComputedStyle> {
        self.node_styles.get(&node.id())
    }

    pub(crate) fn resolve_font_families(
        &mut self,
        chapter_path: Option<&str>,
        fonts: Option<&super::font::EpubFontBook>,
    ) {
        for style in self.node_styles.values_mut() {
            style.font_families = style
                .font_families
                .iter()
                .filter(|family| {
                    fonts.is_some_and(|fonts| {
                        chapter_path
                            .is_some_and(|path| fonts.contains_family_for_chapter(path, family))
                    })
                })
                .cloned()
                .collect();
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Priority {
    important: bool,
    specificity: u32,
    source_order: usize,
}

impl Ord for Priority {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.important, self.specificity, self.source_order).cmp(&(
            other.important,
            other.specificity,
            other.source_order,
        ))
    }
}

impl PartialOrd for Priority {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug)]
struct Slot<T> {
    candidate: Option<(Priority, T)>,
}

impl<T> Default for Slot<T> {
    fn default() -> Self {
        Self { candidate: None }
    }
}

impl<T> Slot<T> {
    fn offer(&mut self, priority: Priority, value: T) {
        if self
            .candidate
            .as_ref()
            .is_none_or(|(current, _)| priority >= *current)
        {
            self.candidate = Some((priority, value));
        }
    }

    fn value(self) -> Option<T> {
        self.candidate.map(|(_, value)| value)
    }
}

#[derive(Clone, Copy, Debug)]
enum RelativeLength {
    Em(f32),
    Rem(f32),
    Px(f32),
    Percent(f32),
}

#[derive(Clone, Copy, Debug)]
enum SpecifiedAlignment {
    Value(Alignment),
    MatchParent,
}

impl RelativeLength {
    fn resolve(self, parent_font_size: f32, root_font_size: f32) -> f32 {
        match self {
            Self::Em(value) => value * parent_font_size,
            Self::Rem(value) => value * root_font_size,
            Self::Px(value) => value,
            Self::Percent(value) => value * parent_font_size,
        }
    }
}

#[derive(Default)]
struct SpecifiedStyle {
    display: Slot<DisplayRole>,
    font_size: Slot<RelativeLength>,
    bold: Slot<bool>,
    italic: Slot<bool>,
    monospace: Slot<bool>,
    font_families: Slot<Arc<[Arc<str>]>>,
    alignment: Slot<SpecifiedAlignment>,
    direction: Slot<Direction>,
    preserve_whitespace: Slot<bool>,
    margin_left: Slot<RelativeLength>,
    margin_top: Slot<RelativeLength>,
    margin_bottom: Slot<RelativeLength>,
    text_indent: Slot<RelativeLength>,
    width: Slot<SpecifiedWidth>,
    max_width: Slot<SpecifiedWidth>,
}

#[derive(Clone, Copy, Debug)]
enum SpecifiedWidth {
    Percent(f32),
    Length(RelativeLength),
}

struct ProcessingBudget {
    remaining: usize,
}

impl ProcessingBudget {
    fn step(&mut self) -> Result<()> {
        self.remaining = self
            .remaining
            .checked_sub(1)
            .context("EPUB document exceeds CSS processing step limit")?;
        Ok(())
    }
}

#[cfg(test)]
fn compute_document_styles(xhtml: &str, css: &str) -> Result<ComputedDocumentStyles> {
    let document =
        roxmltree::Document::parse(xhtml).map_err(|error| anyhow::anyhow!(error.to_string()))?;
    compute_parsed_document_styles(&document, css, &EpubLimits::default())
}

pub(crate) fn compute_parsed_document_styles(
    document: &roxmltree::Document<'_>,
    css: &str,
    limits: &EpubLimits,
) -> Result<ComputedDocumentStyles> {
    if !limits.min_css_computed_font_size_px.is_finite()
        || !limits.max_css_computed_font_size_px.is_finite()
        || limits.min_css_computed_font_size_px <= 0.0
        || limits.max_css_computed_font_size_px < limits.min_css_computed_font_size_px
        || !(limits.max_css_computed_font_size_px / limits.min_css_computed_font_size_px)
            .is_finite()
    {
        anyhow::bail!("EPUB computed font size limits are invalid");
    }
    let sheet = StyleSheet::parse(css, ParserOptions::default())
        .map_err(|error| anyhow::anyhow!(error.to_string()))?;
    validate_stylesheet_complexity(&sheet.rules.0, limits)?;
    validate_inline_font_families(document.root_element(), limits)?;
    let mut unsupported_selectors = HashSet::new();
    let mut unsupported_rules = HashSet::new();
    let mut unsupported_declarations = HashSet::new();
    let mut font_face_rules = 0;
    inventory_rules(
        &sheet.rules.0,
        &mut unsupported_selectors,
        &mut unsupported_rules,
        &mut unsupported_declarations,
        &mut font_face_rules,
    );
    inventory_inline_declarations(document.root_element(), &mut unsupported_declarations);

    let mut node_styles = HashMap::new();
    let mut element_styles = HashMap::new();
    let mut processing_budget = ProcessingBudget {
        remaining: limits.max_css_processing_steps_per_document,
    };
    walk_element(
        document.root_element(),
        None,
        None,
        &sheet.rules.0,
        &mut node_styles,
        &mut element_styles,
        &mut processing_budget,
        limits,
    )?;
    let mut unsupported_selectors = unsupported_selectors.into_iter().collect::<Vec<_>>();
    unsupported_selectors.sort();
    let mut unsupported_rules = unsupported_rules.into_iter().collect::<Vec<_>>();
    unsupported_rules.sort();
    let mut unsupported_declarations = unsupported_declarations.into_iter().collect::<Vec<_>>();
    unsupported_declarations.sort();

    Ok(ComputedDocumentStyles {
        node_styles,
        element_styles,
        font_face_rules,
        unsupported_selectors,
        unsupported_rules,
        unsupported_declarations,
    })
}

#[allow(clippy::too_many_arguments)]
fn walk_element(
    element: Node<'_, '_>,
    parent: Option<&ComputedStyle>,
    root_font_size: Option<f32>,
    rules: &[CssRule<'_>],
    node_styles: &mut HashMap<NodeId, ComputedStyle>,
    styles: &mut HashMap<String, ComputedStyle>,
    processing_budget: &mut ProcessingBudget,
    limits: &EpubLimits,
) -> Result<()> {
    let style = compute_element_style(
        element,
        parent,
        root_font_size.unwrap_or(INITIAL_FONT_SIZE_PX),
        rules,
        processing_budget,
    )?;
    if !style.font_size_px.is_finite()
        || style.font_size_px < limits.min_css_computed_font_size_px
        || style.font_size_px > limits.max_css_computed_font_size_px
    {
        anyhow::bail!(
            "EPUB document computed font size is outside limits ({}px, min {}px, max {}px)",
            style.font_size_px,
            limits.min_css_computed_font_size_px,
            limits.max_css_computed_font_size_px
        );
    }
    let root_font_size = root_font_size.unwrap_or(style.font_size_px);
    node_styles.insert(element.id(), style.clone());
    if let Some(id) = element.attribute("id") {
        styles.insert(id.to_string(), style.clone());
    }
    for child in element.children().filter(Node::is_element) {
        walk_element(
            child,
            Some(&style),
            Some(root_font_size),
            rules,
            node_styles,
            styles,
            processing_budget,
            limits,
        )?;
    }
    Ok(())
}

fn compute_element_style(
    element: Node<'_, '_>,
    parent: Option<&ComputedStyle>,
    root_font_size: f32,
    rules: &[CssRule<'_>],
    processing_budget: &mut ProcessingBudget,
) -> Result<ComputedStyle> {
    let inherited = parent.cloned().unwrap_or(ComputedStyle {
        display: DisplayRole::Block,
        font_size_px: INITIAL_FONT_SIZE_PX,
        bold: false,
        italic: false,
        monospace: false,
        font_families: Arc::from([]),
        alignment: Alignment::Start,
        direction: Direction::Ltr,
        preserve_whitespace: false,
        margin_left_px: 0.0,
        margin_top_px: None,
        margin_bottom_px: None,
        text_indent_px: 0.0,
        width: None,
        max_width: None,
    });
    let tag = element.tag_name().name();
    let mut style = inherited.clone();
    style.display = ua_display(tag);
    style.margin_left_px = 0.0;
    style.margin_top_px = None;
    style.margin_bottom_px = None;
    style.width = None;
    style.max_width = None;
    apply_ua_text_defaults(tag, &mut style);
    if let Some(direction) = element.attribute("dir") {
        if direction.eq_ignore_ascii_case("rtl") {
            style.direction = Direction::Rtl;
        } else if direction.eq_ignore_ascii_case("ltr") {
            style.direction = Direction::Ltr;
        }
    }

    let mut specified = SpecifiedStyle::default();
    let mut source_order = 0;
    apply_rules(
        rules,
        element,
        &mut specified,
        &mut source_order,
        processing_budget,
    )?;
    if let Some(inline) = element.attribute("style")
        && let Ok(attribute) = StyleAttribute::parse(inline, ParserOptions::default())
    {
        apply_declarations(
            &attribute.declarations,
            INLINE_SPECIFICITY,
            &mut source_order,
            &mut specified,
            processing_budget,
        )?;
    }

    let parent_font_size = parent.map_or(INITIAL_FONT_SIZE_PX, |style| style.font_size_px);
    if let Some(value) = specified.font_size.value() {
        style.font_size_px = value.resolve(parent_font_size, root_font_size);
    }
    if let Some(value) = specified.display.value() {
        style.display = value;
    }
    if let Some(value) = specified.bold.value() {
        style.bold = value;
    }
    if let Some(value) = specified.italic.value() {
        style.italic = value;
    }
    if let Some(value) = specified.monospace.value() {
        style.monospace = value;
    }
    if let Some(value) = specified.font_families.value() {
        style.font_families = value;
    }
    if let Some(value) = specified.alignment.value() {
        style.alignment = match value {
            SpecifiedAlignment::Value(value) => value,
            SpecifiedAlignment::MatchParent => {
                parent.map_or(Alignment::Start, |parent| match parent.alignment {
                    Alignment::Start => match parent.direction {
                        Direction::Ltr => Alignment::Left,
                        Direction::Rtl => Alignment::Right,
                    },
                    Alignment::End => match parent.direction {
                        Direction::Ltr => Alignment::Right,
                        Direction::Rtl => Alignment::Left,
                    },
                    value => value,
                })
            }
        };
    }
    if let Some(value) = specified.direction.value() {
        style.direction = value;
    }
    if let Some(value) = specified.preserve_whitespace.value() {
        style.preserve_whitespace = value;
    }
    if let Some(value) = specified.margin_left.value() {
        style.margin_left_px = value.resolve(style.font_size_px, root_font_size);
    }
    if let Some(value) = specified.margin_top.value() {
        style.margin_top_px = Some(value.resolve(style.font_size_px, root_font_size).max(0.0));
    }
    if let Some(value) = specified.margin_bottom.value() {
        style.margin_bottom_px = Some(value.resolve(style.font_size_px, root_font_size).max(0.0));
    }
    if let Some(value) = specified.text_indent.value() {
        style.text_indent_px = value.resolve(style.font_size_px, root_font_size);
    }
    if let Some(value) = specified.width.value() {
        style.width = Some(match value {
            SpecifiedWidth::Percent(value) => ComputedWidth::Percent(value),
            SpecifiedWidth::Length(value) => {
                ComputedWidth::Px(value.resolve(style.font_size_px, root_font_size).max(0.0))
            }
        });
    }
    if let Some(value) = specified.max_width.value() {
        style.max_width = Some(match value {
            SpecifiedWidth::Percent(value) => ComputedWidth::Percent(value),
            SpecifiedWidth::Length(value) => {
                ComputedWidth::Px(value.resolve(style.font_size_px, root_font_size).max(0.0))
            }
        });
    }
    Ok(style)
}

fn apply_rules(
    rules: &[CssRule<'_>],
    element: Node<'_, '_>,
    specified: &mut SpecifiedStyle,
    source_order: &mut usize,
    processing_budget: &mut ProcessingBudget,
) -> Result<()> {
    for rule in rules {
        processing_budget.step()?;
        match rule {
            CssRule::Style(rule) => {
                let mut specificity = None;
                for selector in &rule.selectors.0 {
                    if selector_supported_with_budget(selector, processing_budget)?
                        && selector_matches(selector, element, processing_budget)?
                    {
                        let candidate = selector.specificity();
                        specificity = Some(
                            specificity.map_or(candidate, |current: u32| current.max(candidate)),
                        );
                    }
                }
                if let Some(specificity) = specificity {
                    apply_declarations(
                        &rule.declarations,
                        specificity,
                        source_order,
                        specified,
                        processing_budget,
                    )?;
                }
            }
            CssRule::Media(media)
                if screen_media_matches_with_budget(&media.query, processing_budget)? =>
            {
                apply_rules(
                    &media.rules.0,
                    element,
                    specified,
                    source_order,
                    processing_budget,
                )?;
            }
            _ => {}
        }
    }
    Ok(())
}

pub(crate) fn screen_media_matches(media: &MediaList<'_>) -> bool {
    media.media_queries.iter().any(screen_media_query_matches)
}

fn screen_media_matches_with_budget(
    media: &MediaList<'_>,
    processing_budget: &mut ProcessingBudget,
) -> Result<bool> {
    for query in &media.media_queries {
        processing_budget.step()?;
        if screen_media_query_matches(query) {
            return Ok(true);
        }
    }
    Ok(false)
}

fn screen_media_query_matches(query: &lightningcss::media_query::MediaQuery<'_>) -> bool {
    if query.condition.is_some() {
        return false;
    }
    matches!(
        (&query.qualifier, &query.media_type),
        (
            None | Some(Qualifier::Only),
            MediaType::All | MediaType::Screen
        ) | (Some(Qualifier::Not), MediaType::Print)
    )
}

pub(crate) fn bounded_media_query(media: &MediaList<'_>) -> bool {
    media
        .media_queries
        .iter()
        .all(|query| query.condition.is_none() && !matches!(query.media_type, MediaType::Custom(_)))
}

fn apply_declarations(
    declarations: &DeclarationBlock<'_>,
    specificity: u32,
    source_order: &mut usize,
    specified: &mut SpecifiedStyle,
    processing_budget: &mut ProcessingBudget,
) -> Result<()> {
    for (important, properties) in [
        (false, &declarations.declarations),
        (true, &declarations.important_declarations),
    ] {
        for property in properties {
            processing_budget.step()?;
            *source_order = source_order
                .checked_add(1)
                .context("EPUB CSS source order overflowed")?;
            let priority = Priority {
                important,
                specificity,
                source_order: *source_order,
            };
            if property_supported(property) {
                apply_property(property, priority, specified);
            }
        }
    }
    Ok(())
}

fn apply_property(property: &Property<'_>, priority: Priority, specified: &mut SpecifiedStyle) {
    match property {
        Property::Display(display) => {
            if let Some(display) = css_display(display) {
                specified.display.offer(priority, display);
            }
        }
        Property::FontSize(FontSize::Length(value)) => {
            if let Some(value) = font_size_length(value) {
                specified.font_size.offer(priority, value);
            }
        }
        Property::FontWeight(weight) => specified.bold.offer(priority, is_bold(weight)),
        Property::FontStyle(style) => specified.italic.offer(
            priority,
            matches!(style, FontStyle::Italic | FontStyle::Oblique(_)),
        ),
        Property::FontFamily(families) => {
            specified
                .monospace
                .offer(priority, has_monospace_family(families));
            specified
                .font_families
                .offer(priority, named_font_families(families));
        }
        Property::TextAlign(alignment) => {
            specified
                .alignment
                .offer(priority, css_alignment(alignment));
        }
        Property::Direction(direction) => specified.direction.offer(
            priority,
            match direction {
                CssDirection::Ltr => Direction::Ltr,
                CssDirection::Rtl => Direction::Rtl,
            },
        ),
        Property::WhiteSpace(white_space) => specified.preserve_whitespace.offer(
            priority,
            matches!(
                white_space,
                WhiteSpace::Pre | WhiteSpace::PreWrap | WhiteSpace::BreakSpaces
            ),
        ),
        Property::MarginLeft(LengthPercentageOrAuto::LengthPercentage(value)) => {
            if let Some(value) = margin_length(value) {
                specified.margin_left.offer(priority, value);
            }
        }
        Property::MarginTop(LengthPercentageOrAuto::LengthPercentage(value)) => {
            if let Some(value) = margin_length(value) {
                specified.margin_top.offer(priority, value);
            }
        }
        Property::MarginBottom(LengthPercentageOrAuto::LengthPercentage(value)) => {
            if let Some(value) = margin_length(value) {
                specified.margin_bottom.offer(priority, value);
            }
        }
        Property::Margin(margin) => {
            if let LengthPercentageOrAuto::LengthPercentage(value) = &margin.left
                && let Some(value) = margin_length(value)
            {
                specified.margin_left.offer(priority, value);
            }
            if let LengthPercentageOrAuto::LengthPercentage(value) = &margin.top
                && let Some(value) = margin_length(value)
            {
                specified.margin_top.offer(priority, value);
            }
            if let LengthPercentageOrAuto::LengthPercentage(value) = &margin.bottom
                && let Some(value) = margin_length(value)
            {
                specified.margin_bottom.offer(priority, value);
            }
        }
        Property::TextIndent(indent) => {
            if let Some(value) = margin_length(&indent.value) {
                specified.text_indent.offer(priority, value);
            }
        }
        Property::Width(CssSize::LengthPercentage(value)) => {
            if let Some(value) = specified_width(value) {
                specified.width.offer(priority, value);
            }
        }
        Property::MaxWidth(CssMaxSize::LengthPercentage(value)) => {
            if let Some(value) = specified_width(value) {
                specified.max_width.offer(priority, value);
            }
        }
        _ => {}
    }
}

#[derive(Default)]
struct StylesheetComplexity {
    rules: usize,
    selectors: usize,
    selector_components: usize,
}

pub(crate) fn validate_stylesheet_complexity(
    rules: &[CssRule<'_>],
    limits: &EpubLimits,
) -> Result<()> {
    fn inspect(
        rules: &[CssRule<'_>],
        complexity: &mut StylesheetComplexity,
        limits: &EpubLimits,
    ) -> Result<()> {
        for rule in rules {
            complexity.rules = complexity
                .rules
                .checked_add(1)
                .context("EPUB CSS rule count overflowed")?;
            if complexity.rules > limits.max_css_rules_per_document {
                anyhow::bail!(
                    "EPUB document exceeds CSS rule limit ({} > {})",
                    complexity.rules,
                    limits.max_css_rules_per_document
                );
            }

            match rule {
                CssRule::Style(rule) => {
                    validate_declaration_font_families(&rule.declarations, limits)?;
                    complexity.selectors = complexity
                        .selectors
                        .checked_add(rule.selectors.0.len())
                        .context("EPUB CSS selector count overflowed")?;
                    if complexity.selectors > limits.max_css_selectors_per_document {
                        anyhow::bail!(
                            "EPUB document exceeds CSS selector limit ({} > {})",
                            complexity.selectors,
                            limits.max_css_selectors_per_document
                        );
                    }
                    for selector in &rule.selectors.0 {
                        complexity.selector_components = complexity
                            .selector_components
                            .checked_add(selector_component_count(selector)?)
                            .context("EPUB CSS selector component count overflowed")?;
                        if complexity.selector_components
                            > limits.max_css_selector_components_per_document
                        {
                            anyhow::bail!(
                                "EPUB document exceeds CSS selector component limit ({} > {})",
                                complexity.selector_components,
                                limits.max_css_selector_components_per_document
                            );
                        }
                    }
                    inspect(&rule.rules.0, complexity, limits)?;
                }
                CssRule::FontFace(rule) => {
                    for property in &rule.properties {
                        if let FontFaceProperty::FontFamily(FontFamily::FamilyName(name)) = property
                        {
                            validate_family_name(name, limits)?;
                        }
                    }
                }
                CssRule::Media(rule) => inspect(&rule.rules.0, complexity, limits)?,
                _ => {}
            }
        }
        Ok(())
    }

    inspect(rules, &mut StylesheetComplexity::default(), limits)
}

fn validate_declaration_font_families(
    declarations: &DeclarationBlock<'_>,
    limits: &EpubLimits,
) -> Result<()> {
    for property in declarations
        .declarations
        .iter()
        .chain(&declarations.important_declarations)
    {
        if let Property::FontFamily(families) = property {
            validate_font_families(families, limits)?;
        }
    }
    Ok(())
}

fn validate_font_families(families: &[FontFamily<'_>], limits: &EpubLimits) -> Result<()> {
    let mut count = 0_usize;
    let mut bytes = 0_usize;
    for family in families {
        let FontFamily::FamilyName(name) = family else {
            continue;
        };
        let name = validate_family_name(name, limits)?;
        count = count
            .checked_add(1)
            .context("EPUB CSS font family count overflowed")?;
        bytes = bytes
            .checked_add(name.len())
            .context("EPUB CSS font family byte count overflowed")?;
    }
    if count > limits.max_css_font_families_per_declaration {
        anyhow::bail!(
            "EPUB CSS font family declaration exceeds name limit ({count} > {})",
            limits.max_css_font_families_per_declaration
        );
    }
    if bytes > limits.max_css_font_family_bytes_per_declaration {
        anyhow::bail!(
            "EPUB CSS font family declaration exceeds byte limit ({bytes} > {})",
            limits.max_css_font_family_bytes_per_declaration
        );
    }
    Ok(())
}

fn validate_family_name(name: &FamilyName<'_>, limits: &EpubLimits) -> Result<String> {
    let name =
        decoded_family_name(name).context("EPUB CSS font family name could not be decoded")?;
    if name.len() > limits.max_css_font_family_name_bytes {
        anyhow::bail!(
            "EPUB CSS font family name exceeds byte limit ({} > {})",
            name.len(),
            limits.max_css_font_family_name_bytes
        );
    }
    Ok(name)
}

fn validate_inline_font_families(element: Node<'_, '_>, limits: &EpubLimits) -> Result<()> {
    for element in element.descendants().filter(Node::is_element) {
        if let Some(inline) = element.attribute("style")
            && let Ok(attribute) = StyleAttribute::parse(inline, ParserOptions::default())
        {
            validate_declaration_font_families(&attribute.declarations, limits)?;
        }
    }
    Ok(())
}

fn selector_component_count(selector: &Selector<'_>) -> Result<usize> {
    let mut count = 0_usize;
    for component in selector.iter_raw_match_order() {
        count = count
            .checked_add(1)
            .context("EPUB CSS selector component count overflowed")?;
        if let Component::Negation(selectors)
        | Component::Where(selectors)
        | Component::Is(selectors)
        | Component::Any(_, selectors) = component
        {
            for nested in selectors.iter() {
                count = count
                    .checked_add(selector_component_count(nested)?)
                    .context("EPUB CSS selector component count overflowed")?;
            }
        }
    }
    Ok(count)
}

fn inventory_rules(
    rules: &[CssRule<'_>],
    unsupported_selectors: &mut HashSet<String>,
    unsupported_rules: &mut HashSet<String>,
    unsupported_declarations: &mut HashSet<String>,
    font_face_rules: &mut usize,
) {
    for rule in rules {
        match rule {
            CssRule::Style(rule) => {
                inventory_declarations(&rule.declarations, unsupported_declarations);
                for selector in &rule.selectors.0 {
                    if !selector_supported(selector) {
                        unsupported_selectors.insert(
                            selector
                                .to_css_string(Default::default())
                                .unwrap_or_else(|_| "<unserializable selector>".into()),
                        );
                    }
                }
                if !rule.rules.0.is_empty() {
                    unsupported_rules.insert("nested style rules".into());
                }
            }
            CssRule::FontFace(_) => *font_face_rules += 1,
            CssRule::Media(media) if bounded_media_query(&media.query) => {
                if screen_media_matches(&media.query) {
                    inventory_rules(
                        &media.rules.0,
                        unsupported_selectors,
                        unsupported_rules,
                        unsupported_declarations,
                        font_face_rules,
                    );
                }
            }
            rule => {
                unsupported_rules.insert(unsupported_rule_name(rule).into());
            }
        }
    }
}

fn inventory_declarations(
    declarations: &DeclarationBlock<'_>,
    unsupported_declarations: &mut HashSet<String>,
) {
    for property in declarations
        .declarations
        .iter()
        .chain(&declarations.important_declarations)
    {
        if !property_supported(property) {
            unsupported_declarations.insert(
                property
                    .to_css_string(false, Default::default())
                    .unwrap_or_else(|_| "<unserializable declaration>".into()),
            );
        }
    }
}

fn inventory_inline_declarations(
    root: Node<'_, '_>,
    unsupported_declarations: &mut HashSet<String>,
) {
    for element in root.descendants().filter(Node::is_element) {
        let Some(inline) = element.attribute("style") else {
            continue;
        };
        match StyleAttribute::parse(inline, ParserOptions::default()) {
            Ok(attribute) => {
                inventory_declarations(&attribute.declarations, unsupported_declarations)
            }
            Err(_) => {
                unsupported_declarations.insert("<invalid inline style>".into());
            }
        }
    }
}

fn unsupported_rule_name(rule: &CssRule<'_>) -> &'static str {
    match rule {
        CssRule::Media(_) => "@media",
        CssRule::Import(_) => "@import",
        CssRule::Keyframes(_) => "@keyframes",
        CssRule::FontPaletteValues(_) => "@font-palette-values",
        CssRule::FontFeatureValues(_) => "@font-feature-values",
        CssRule::Page(_) => "@page",
        CssRule::Supports(_) => "@supports",
        CssRule::CounterStyle(_) => "@counter-style",
        CssRule::Namespace(_) => "@namespace",
        CssRule::MozDocument(_) => "@-moz-document",
        CssRule::Nesting(_) => "@nest",
        CssRule::NestedDeclarations(_) => "nested declarations",
        CssRule::Viewport(_) => "@viewport",
        CssRule::CustomMedia(_) => "@custom-media",
        CssRule::LayerStatement(_) | CssRule::LayerBlock(_) => "@layer",
        CssRule::Property(_) => "@property",
        CssRule::Container(_) => "@container",
        CssRule::Scope(_) => "@scope",
        CssRule::StartingStyle(_) => "@starting-style",
        CssRule::ViewTransition(_) => "@view-transition",
        CssRule::Ignored => "ignored rule",
        CssRule::Unknown(_) => "unknown at-rule",
        CssRule::Custom(_) => "custom at-rule",
        CssRule::Style(_) | CssRule::FontFace(_) => unreachable!("supported rule"),
    }
}

fn property_supported(property: &Property<'_>) -> bool {
    match property {
        Property::Display(display) => css_display(display).is_some(),
        Property::FontSize(FontSize::Length(value)) => font_size_length(value).is_some(),
        Property::FontWeight(FontWeight::Absolute(_)) => true,
        Property::FontStyle(_)
        | Property::FontFamily(_)
        | Property::TextAlign(_)
        | Property::Direction(_)
        | Property::WhiteSpace(_) => true,
        Property::MarginLeft(LengthPercentageOrAuto::LengthPercentage(value)) => {
            margin_length(value).is_some()
        }
        Property::MarginTop(LengthPercentageOrAuto::LengthPercentage(value))
        | Property::MarginBottom(LengthPercentageOrAuto::LengthPercentage(value)) => {
            margin_length(value).is_some()
        }
        Property::Margin(margin) => {
            [&margin.left, &margin.top, &margin.bottom]
                .into_iter()
                .any(|value| {
                    let LengthPercentageOrAuto::LengthPercentage(value) = value else {
                        return false;
                    };
                    margin_length(value).is_some()
                })
        }
        Property::TextIndent(indent) => margin_length(&indent.value).is_some(),
        Property::Width(CssSize::LengthPercentage(value)) => specified_width(value).is_some(),
        Property::MaxWidth(CssMaxSize::LengthPercentage(value)) => specified_width(value).is_some(),
        _ => false,
    }
}

fn selector_supported(selector: &Selector<'_>) -> bool {
    selector
        .iter_raw_match_order()
        .all(|component| match component {
            Component::Combinator(combinator) => matches!(
                combinator,
                Combinator::Child
                    | Combinator::Descendant
                    | Combinator::NextSibling
                    | Combinator::LaterSibling
            ),
            Component::ExplicitAnyNamespace
            | Component::ExplicitUniversalType
            | Component::LocalName(_)
            | Component::ID(_)
            | Component::Class(_)
            | Component::Root
            | Component::Empty => true,
            Component::Negation(selectors)
            | Component::Where(selectors)
            | Component::Is(selectors)
            | Component::Any(_, selectors) => selectors.iter().all(selector_supported),
            _ => false,
        })
}

fn selector_supported_with_budget(
    selector: &Selector<'_>,
    budget: &mut ProcessingBudget,
) -> Result<bool> {
    for component in selector.iter_raw_match_order() {
        budget.step()?;
        let supported = match component {
            Component::Combinator(combinator) => matches!(
                combinator,
                Combinator::Child
                    | Combinator::Descendant
                    | Combinator::NextSibling
                    | Combinator::LaterSibling
            ),
            Component::ExplicitAnyNamespace
            | Component::ExplicitUniversalType
            | Component::LocalName(_)
            | Component::ID(_)
            | Component::Class(_)
            | Component::Root
            | Component::Empty => true,
            Component::Negation(selectors)
            | Component::Where(selectors)
            | Component::Is(selectors)
            | Component::Any(_, selectors) => {
                for nested in selectors.iter() {
                    if !selector_supported_with_budget(nested, budget)? {
                        return Ok(false);
                    }
                }
                true
            }
            _ => false,
        };
        if !supported {
            return Ok(false);
        }
    }
    Ok(true)
}

fn selector_matches(
    selector: &Selector<'_>,
    element: Node<'_, '_>,
    budget: &mut ProcessingBudget,
) -> Result<bool> {
    selector_matches_from(selector, element, 0, budget)
}

fn selector_matches_from(
    selector: &Selector<'_>,
    element: Node<'_, '_>,
    offset: usize,
    budget: &mut ProcessingBudget,
) -> Result<bool> {
    for (index, component) in selector.iter_raw_match_order().enumerate().skip(offset) {
        budget.step()?;
        if let Component::Combinator(combinator) = component {
            let next = index + 1;
            return Ok(match combinator {
                Combinator::Child => parent_element(element)
                    .map(|parent| selector_matches_from(selector, parent, next, budget))
                    .transpose()?
                    .unwrap_or(false),
                Combinator::Descendant => {
                    let mut parent = parent_element(element);
                    while let Some(ancestor) = parent {
                        if selector_matches_from(selector, ancestor, next, budget)? {
                            return Ok(true);
                        }
                        parent = parent_element(ancestor);
                    }
                    false
                }
                Combinator::NextSibling => previous_element(element, budget)?
                    .map(|sibling| selector_matches_from(selector, sibling, next, budget))
                    .transpose()?
                    .unwrap_or(false),
                Combinator::LaterSibling => {
                    let mut sibling = previous_element(element, budget)?;
                    while let Some(previous) = sibling {
                        if selector_matches_from(selector, previous, next, budget)? {
                            return Ok(true);
                        }
                        sibling = previous_element(previous, budget)?;
                    }
                    false
                }
                _ => false,
            });
        }
        if !component_matches(component, element, budget)? {
            return Ok(false);
        }
    }
    Ok(true)
}

fn component_matches(
    component: &Component<'_>,
    element: Node<'_, '_>,
    budget: &mut ProcessingBudget,
) -> Result<bool> {
    Ok(match component {
        Component::ExplicitAnyNamespace | Component::ExplicitUniversalType => true,
        Component::LocalName(name) => name.name.0.as_ref() == element.tag_name().name(),
        Component::ID(id) => element.attribute("id") == Some(id.0.as_ref()),
        Component::Class(class) => {
            let mut matched = false;
            if let Some(classes) = element.attribute("class") {
                for value in classes.split_whitespace() {
                    budget.step()?;
                    if value == class.0.as_ref() {
                        matched = true;
                        break;
                    }
                }
            }
            matched
        }
        Component::Root => parent_element(element).is_none(),
        Component::Empty => {
            let mut empty = true;
            for child in element.children() {
                budget.step()?;
                if child.is_element() || child.text().is_some_and(|text| !text.is_empty()) {
                    empty = false;
                    break;
                }
            }
            empty
        }
        Component::Negation(selectors) => {
            for selector in selectors.iter() {
                if selector_matches(selector, element, budget)? {
                    return Ok(false);
                }
            }
            true
        }
        Component::Where(selectors) | Component::Is(selectors) | Component::Any(_, selectors) => {
            let mut matched = false;
            for selector in selectors.iter() {
                if selector_matches(selector, element, budget)? {
                    matched = true;
                    break;
                }
            }
            matched
        }
        _ => false,
    })
}

fn parent_element<'a, 'input>(node: Node<'a, 'input>) -> Option<Node<'a, 'input>> {
    node.parent().and_then(|parent| {
        if parent.is_element() {
            Some(parent)
        } else {
            None
        }
    })
}

fn previous_element<'a, 'input>(
    node: Node<'a, 'input>,
    budget: &mut ProcessingBudget,
) -> Result<Option<Node<'a, 'input>>> {
    let mut sibling = node.prev_sibling();
    while let Some(previous) = sibling {
        budget.step()?;
        if previous.is_element() {
            return Ok(Some(previous));
        }
        sibling = previous.prev_sibling();
    }
    Ok(None)
}

fn ua_display(tag: &str) -> DisplayRole {
    match tag {
        "html" | "body" | "article" | "aside" | "blockquote" | "div" | "figure" | "figcaption"
        | "footer" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "header" | "main" | "nav" | "ol"
        | "p" | "pre" | "section" | "ul" => DisplayRole::Block,
        "table" => DisplayRole::Table,
        "thead" | "tbody" | "tfoot" => DisplayRole::TableRowGroup,
        "tr" => DisplayRole::TableRow,
        "td" | "th" => DisplayRole::TableCell,
        "caption" => DisplayRole::TableCaption,
        _ => DisplayRole::Inline,
    }
}

fn apply_ua_text_defaults(tag: &str, style: &mut ComputedStyle) {
    match tag {
        "h1" => {
            style.bold = true;
            style.font_size_px *= 2.0;
        }
        "h2" => {
            style.bold = true;
            style.font_size_px *= 1.6;
        }
        "h3" => {
            style.bold = true;
            style.font_size_px *= 1.3;
        }
        "h4" => {
            style.bold = true;
            style.font_size_px *= 1.1;
        }
        "h5" | "h6" | "strong" | "b" | "th" => style.bold = true,
        "em" | "i" | "cite" => style.italic = true,
        "code" | "kbd" | "pre" | "samp" | "tt" => {
            style.monospace = true;
            style.preserve_whitespace = tag == "pre";
        }
        _ => {}
    }
}

fn css_display(display: &Display) -> Option<DisplayRole> {
    match display {
        Display::Keyword(keyword) => match keyword {
            DisplayKeyword::None => Some(DisplayRole::None),
            DisplayKeyword::TableRowGroup
            | DisplayKeyword::TableHeaderGroup
            | DisplayKeyword::TableFooterGroup => Some(DisplayRole::TableRowGroup),
            DisplayKeyword::TableRow => Some(DisplayRole::TableRow),
            DisplayKeyword::TableCell => Some(DisplayRole::TableCell),
            DisplayKeyword::TableCaption => Some(DisplayRole::TableCaption),
            _ => None,
        },
        Display::Pair(pair) => {
            if matches!(pair.inside, DisplayInside::Table) {
                Some(DisplayRole::Table)
            } else if !matches!(pair.inside, DisplayInside::Flow) || pair.is_list_item {
                None
            } else {
                match pair.outside {
                    DisplayOutside::Block => Some(DisplayRole::Block),
                    DisplayOutside::Inline => Some(DisplayRole::Inline),
                    DisplayOutside::RunIn => None,
                }
            }
        }
    }
}

fn css_alignment(alignment: &TextAlign) -> SpecifiedAlignment {
    match alignment {
        TextAlign::Start => SpecifiedAlignment::Value(Alignment::Start),
        TextAlign::End => SpecifiedAlignment::Value(Alignment::End),
        TextAlign::Left => SpecifiedAlignment::Value(Alignment::Left),
        TextAlign::Right => SpecifiedAlignment::Value(Alignment::Right),
        TextAlign::Center => SpecifiedAlignment::Value(Alignment::Center),
        TextAlign::Justify | TextAlign::JustifyAll => SpecifiedAlignment::Value(Alignment::Justify),
        TextAlign::MatchParent => SpecifiedAlignment::MatchParent,
    }
}

fn is_bold(weight: &FontWeight) -> bool {
    match weight {
        FontWeight::Absolute(AbsoluteFontWeight::Weight(value)) => *value >= 600.0,
        FontWeight::Absolute(AbsoluteFontWeight::Bold) => true,
        _ => false,
    }
}

fn has_monospace_family(families: &[FontFamily]) -> bool {
    families.iter().any(|family| match family {
        FontFamily::Generic(family) => matches!(
            family,
            GenericFontFamily::Monospace | GenericFontFamily::UIMonospace
        ),
        FontFamily::FamilyName(name) => decoded_family_name(name)
            .unwrap_or_default()
            .to_ascii_lowercase()
            .contains("mono"),
    })
}

pub(crate) fn decoded_family_name(name: &FamilyName<'_>) -> Option<String> {
    let css = name.to_css_string(Default::default()).ok()?;
    let mut input = ParserInput::new(&css);
    let mut parser = Parser::new(&mut input);
    if let Ok(value) = parser.try_parse(|parser| parser.expect_string_cloned()) {
        parser.expect_exhausted().ok()?;
        return Some(value.to_string());
    }
    let mut value = parser.expect_ident_cloned().ok()?.to_string();
    while let Ok(ident) = parser.try_parse(|parser| parser.expect_ident_cloned()) {
        value.push(' ');
        value.push_str(&ident);
    }
    parser.expect_exhausted().ok()?;
    Some(value)
}

fn named_font_families(families: &[FontFamily]) -> Arc<[Arc<str>]> {
    families
        .iter()
        .filter_map(|family| match family {
            FontFamily::FamilyName(name) => decoded_family_name(name).map(Arc::<str>::from),
            FontFamily::Generic(_) => None,
        })
        .collect()
}

fn relative_length(value: &DimensionPercentage<LengthValue>) -> Option<RelativeLength> {
    match value {
        DimensionPercentage::Percentage(value) => Some(RelativeLength::Percent(value.0)),
        DimensionPercentage::Dimension(LengthValue::Em(value)) => Some(RelativeLength::Em(*value)),
        DimensionPercentage::Dimension(LengthValue::Rem(value)) => {
            Some(RelativeLength::Rem(*value))
        }
        DimensionPercentage::Dimension(LengthValue::Px(value)) => Some(RelativeLength::Px(*value)),
        DimensionPercentage::Dimension(LengthValue::Pt(value)) => {
            Some(RelativeLength::Px(*value * 96.0 / 72.0))
        }
        _ => None,
    }
}

fn font_size_length(value: &DimensionPercentage<LengthValue>) -> Option<RelativeLength> {
    let value = relative_length(value)?;
    match value {
        RelativeLength::Em(value)
        | RelativeLength::Rem(value)
        | RelativeLength::Px(value)
        | RelativeLength::Percent(value)
            if value < 0.0 =>
        {
            None
        }
        value => Some(value),
    }
}

fn margin_length(value: &DimensionPercentage<LengthValue>) -> Option<RelativeLength> {
    match value {
        DimensionPercentage::Percentage(_) => None,
        _ => relative_length(value),
    }
}

fn specified_width(value: &DimensionPercentage<LengthValue>) -> Option<SpecifiedWidth> {
    match value {
        DimensionPercentage::Percentage(value) if value.0 >= 0.0 => {
            Some(SpecifiedWidth::Percent(value.0))
        }
        DimensionPercentage::Dimension(_) => relative_length(value)
            .filter(|value| match value {
                RelativeLength::Em(value)
                | RelativeLength::Rem(value)
                | RelativeLength::Px(value)
                | RelativeLength::Percent(value) => *value >= 0.0,
            })
            .map(SpecifiedWidth::Length),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const XHTML: &str = include_str!("../../tests/fixtures/native-computed-style.xhtml");
    const CSS: &str = include_str!("../../tests/fixtures/native-computed-style.css");

    fn report() -> ComputedDocumentStyles {
        compute_document_styles(XHTML, CSS).expect("computed-style fixture should parse")
    }

    #[test]
    fn cascade_respects_specificity_importance_inline_style_and_source_order() {
        let report = report();
        let lead = &report.element_styles["lead"];
        assert!(!lead.bold, "author !important must beat an ID selector");
        assert!(lead.italic, "inline style must beat an author class rule");
        assert_eq!(lead.alignment, Alignment::Right);
        assert!((lead.font_size_px - 24.0).abs() < 0.01);
        assert!((lead.margin_left_px - 48.0).abs() < 0.01);
        assert!(
            lead.preserve_whitespace,
            "adjacent sibling selector must match"
        );

        assert_eq!(
            report.element_styles["source-order"].alignment,
            Alignment::Center,
            "later equal-specificity declarations must win"
        );
        assert!(
            report.element_styles["source-order"].monospace,
            "general sibling selector must match"
        );
        assert_eq!(report.element_styles["hidden"].display, DisplayRole::None);
        assert_eq!(report.element_styles["margin-percent"].margin_left_px, 0.0);
        assert_eq!(
            report.element_styles["display-contents"].display,
            DisplayRole::Block
        );
        assert!(!report.element_styles["bolder-weight"].bold);
        assert!(report.element_styles["lighter-weight"].bold);
        assert_eq!(
            report.element_styles["match-parent-child"].alignment,
            Alignment::Right
        );
        assert!((report.element_styles["rem-length"].font_size_px - 32.0).abs() < 0.01);
        assert!((report.element_styles["px-length"].font_size_px - 10.0).abs() < 0.01);
        assert!((report.element_styles["pt-length"].font_size_px - 16.0).abs() < 0.01);
    }

    #[test]
    fn inherited_and_ua_styles_preserve_table_math_font_and_bidi_evidence() {
        let report = report();
        let mixed = &report.element_styles["mixed"];
        assert_eq!(mixed.direction, Direction::Rtl);
        assert!(mixed.italic);
        assert!((mixed.font_size_px - 24.0).abs() < 0.01);
        assert_eq!(
            report.element_styles["css-direction-child"].direction,
            Direction::Rtl
        );

        let title = &report.element_styles["title"];
        assert!(title.bold);
        assert!((title.font_size_px - 40.0).abs() < 0.01);
        assert_eq!(report.element_styles["table"].display, DisplayRole::Table);
        assert_eq!(report.element_styles["row"].display, DisplayRole::TableRow);
        assert_eq!(
            report.element_styles["body-rows"].display,
            DisplayRole::TableRowGroup
        );
        assert_eq!(
            report.element_styles["caption"].display,
            DisplayRole::TableCaption
        );
        assert_eq!(
            report.element_styles["heading"].display,
            DisplayRole::TableCell
        );
        assert!(report.element_styles["heading"].bold);
        assert!(report.element_styles["cell"].monospace);
        assert!(report.element_styles["code"].monospace);
        assert_eq!(
            report.element_styles["equation"].display,
            DisplayRole::Inline
        );

        let document = roxmltree::Document::parse(XHTML).unwrap();
        let math = document
            .descendants()
            .find(|node| node.attribute("id") == Some("equation"))
            .unwrap();
        assert_eq!(
            math.tag_name().namespace(),
            Some("http://www.w3.org/1998/Math/MathML")
        );
        assert_eq!(
            math.children()
                .filter(Node::is_element)
                .map(|node| node.tag_name().name())
                .collect::<Vec<_>>(),
            ["mfrac"]
        );
        assert_eq!(
            math.descendants()
                .filter(|node| node.is_element() && node.tag_name().name() == "mi")
                .count(),
            2
        );
    }

    #[test]
    fn inventory_keeps_unsupported_selector_and_font_work_visible() {
        let report = report();
        assert_eq!(report.font_face_rules, 1);
        assert_eq!(report.unsupported_selectors, ["p:nth-child(2)"]);
        assert_eq!(report.unsupported_rules, ["@layer"]);
        for value in [
            "margin-left:25%",
            "margin-left:50%",
            "display:contents",
            "font-weight:bolder",
            "font-weight:lighter",
        ] {
            assert!(
                report
                    .unsupported_declarations
                    .iter()
                    .any(|declaration| declaration.replace(' ', "") == value),
                "missing unsupported declaration {value:?}: {:?}",
                report.unsupported_declarations
            );
        }
        assert_eq!(report.element_styles["lead"].alignment, Alignment::Right);
        assert_eq!(
            report.element_styles["layer-target"].alignment,
            Alignment::Start
        );
    }

    #[test]
    fn bounded_screen_media_rules_participate_in_source_order() {
        let xhtml = r#"<html><body><p id="target">Target</p></body></html>"#;
        let css = r#"
            #target { text-align: left; }
            @media print { #target { text-align: right; } }
            @media screen { #target { text-align: center; } }
        "#;

        let report = compute_document_styles(xhtml, css).unwrap();

        assert_eq!(report.element_styles["target"].alignment, Alignment::Center);
        assert!(report.unsupported_rules.is_empty());
    }

    #[test]
    fn text_indent_inherits_but_unsupported_percentages_do_not_guess_a_width() {
        let xhtml = r#"<html><body>
            <section id="parent"><p id="child">Child</p></section>
            <p id="percentage">Percentage</p>
        </body></html>"#;
        let css = "#parent { text-indent: 2em; } #percentage { text-indent: 25%; }";

        let report = compute_document_styles(xhtml, css).unwrap();

        assert_eq!(report.element_styles["parent"].text_indent_px, 32.0);
        assert_eq!(report.element_styles["child"].text_indent_px, 32.0);
        assert_eq!(report.element_styles["percentage"].text_indent_px, 0.0);
        assert!(
            report
                .unsupported_declarations
                .iter()
                .any(|declaration| declaration.replace(' ', "") == "text-indent:25%")
        );
    }

    #[test]
    fn empty_and_direction_follow_xhtml_selector_and_attribute_semantics() {
        let xhtml = r#"<html><body>
            <p id="truly-empty"></p>
            <p id="whitespace"> </p>
            <p id="rtl" dir="RTL">Direction</p>
        </body></html>"#;
        let css = ":empty { font-weight: bold; }";

        let report = compute_document_styles(xhtml, css).unwrap();

        assert!(report.element_styles["truly-empty"].bold);
        assert!(!report.element_styles["whitespace"].bold);
        assert_eq!(report.element_styles["rtl"].direction, Direction::Rtl);
    }

    #[test]
    fn stylesheet_complexity_and_matching_stop_at_configured_budgets() {
        let document =
            roxmltree::Document::parse(r#"<html><body><p class="target">Target</p></body></html>"#)
                .unwrap();
        let css = ".target, body > p { font-weight: bold; }";

        for (limits, expected) in [
            (
                EpubLimits {
                    max_css_rules_per_document: 0,
                    ..EpubLimits::default()
                },
                "CSS rule limit",
            ),
            (
                EpubLimits {
                    max_css_selectors_per_document: 1,
                    ..EpubLimits::default()
                },
                "CSS selector limit",
            ),
            (
                EpubLimits {
                    max_css_selector_components_per_document: 1,
                    ..EpubLimits::default()
                },
                "CSS selector component limit",
            ),
            (
                EpubLimits {
                    max_css_processing_steps_per_document: 0,
                    ..EpubLimits::default()
                },
                "CSS processing step limit",
            ),
        ] {
            let error = compute_parsed_document_styles(&document, css, &limits).unwrap_err();
            assert!(
                error.to_string().contains(expected),
                "expected {expected:?}, got {error:#}"
            );
        }

        let non_style_rules = "@font-face {}".repeat(3);
        let error = compute_parsed_document_styles(
            &document,
            &non_style_rules,
            &EpubLimits {
                max_css_processing_steps_per_document: 8,
                ..EpubLimits::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("CSS processing step limit"));

        let one_element = roxmltree::Document::parse(r#"<html class="target"/>"#).unwrap();
        let error = compute_parsed_document_styles(
            &one_element,
            ".target { font-weight: bold; font-style: italic; }",
            &EpubLimits {
                max_css_processing_steps_per_document: 4,
                ..EpubLimits::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("CSS processing step limit"));

        let class_tokens = roxmltree::Document::parse(r#"<html class="one two three"/>"#).unwrap();
        let error = compute_parsed_document_styles(
            &class_tokens,
            ".missing { font-weight: bold; }",
            &EpubLimits {
                max_css_processing_steps_per_document: 5,
                ..EpubLimits::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("CSS processing step limit"));
    }

    #[test]
    fn computed_font_sizes_stop_at_the_configured_admission_boundary() {
        let document =
            roxmltree::Document::parse(r#"<html><body><p class="huge">Target</p></body></html>"#)
                .unwrap();
        let error = compute_parsed_document_styles(
            &document,
            ".huge { font-size: 1000000000px; }",
            &EpubLimits {
                max_css_computed_font_size_px: 512.0,
                ..EpubLimits::default()
            },
        )
        .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("computed font size is outside limits")
        );
    }

    #[test]
    fn invalid_negative_font_size_does_not_hide_document_content() {
        let report = compute_document_styles(
            r#"<html><body><p id="target" style="font-size: -1">Target</p></body></html>"#,
            "",
        )
        .unwrap();

        assert_eq!(report.element_styles["target"].font_size_px, 16.0);
    }

    #[test]
    fn vertical_block_margins_are_computed_without_inheriting() {
        let report = compute_document_styles(
            r#"<html><body><div id="parent"><p id="child">Target</p></div></body></html>"#,
            "#parent { margin: 1em 0 2em; }",
        )
        .unwrap();

        let parent = &report.element_styles["parent"];
        assert_eq!(parent.margin_top_px, Some(16.0));
        assert_eq!(parent.margin_bottom_px, Some(32.0));
        let child = &report.element_styles["child"];
        assert_eq!(child.margin_top_px, None);
        assert_eq!(child.margin_bottom_px, None);
    }

    #[test]
    fn width_hints_are_computed_without_inheriting() {
        let report = compute_document_styles(
            r#"<html><body><table><tr><td id="percent"><span id="child">A</span></td><td id="fixed">B</td></tr></table><img id="bounded"/></body></html>"#,
            "#percent { width: 15.6%; } #fixed { width: 72pt; } #bounded { max-width: 95%; }",
        )
        .unwrap();

        assert_eq!(
            report.element_styles["percent"].width,
            Some(ComputedWidth::Percent(0.156))
        );
        assert_eq!(
            report.element_styles["fixed"].width,
            Some(ComputedWidth::Px(96.0))
        );
        assert_eq!(report.element_styles["child"].width, None);
        assert_eq!(
            report.element_styles["bounded"].max_width,
            Some(ComputedWidth::Percent(0.95))
        );
        assert_eq!(report.element_styles["child"].max_width, None);
    }

    #[test]
    fn zero_and_tiny_computed_font_sizes_stop_before_span_normalization() {
        for size in [0.0, 0.000_001] {
            let document = roxmltree::Document::parse(
                r#"<html><body><p class="parent"><span class="child">Target</span></p></body></html>"#,
            )
            .unwrap();
            let error = compute_parsed_document_styles(
                &document,
                &format!(".parent {{ font-size: {size}px; }} .child {{ font-size: 512px; }}"),
                &EpubLimits::default(),
            )
            .unwrap_err();

            assert!(error.to_string().contains("outside limits"));
        }
    }
}
