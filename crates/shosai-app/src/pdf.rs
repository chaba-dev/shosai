//! Pure layout calculations for fixed-page raster documents (PDF and CBZ).

use iced::Size;

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ZoomMode {
    Manual(f32),
    FitWidth,
    FitPage,
}

impl ZoomMode {
    pub(crate) fn scale(self) -> f32 {
        match self {
            Self::Manual(scale) => scale,
            Self::FitWidth | Self::FitPage => 1.0,
        }
    }
}

impl Default for ZoomMode {
    fn default() -> Self {
        Self::Manual(1.0)
    }
}

pub(crate) fn spread_start(page: usize) -> usize {
    page - page % 2
}

pub(crate) fn visible_pages(total_pages: usize, page: usize, use_spread: bool) -> Vec<usize> {
    if total_pages == 0 {
        return Vec::new();
    }
    if use_spread {
        let start = spread_start(page);
        (start..=(start + 1).min(total_pages - 1)).collect()
    } else {
        vec![page.min(total_pages - 1)]
    }
}

pub(crate) fn fit_scale(
    page_sizes: &[(f32, f32)],
    available: Size,
    gutter: f32,
    fit_page: bool,
) -> f32 {
    if page_sizes.is_empty() {
        return 1.0;
    }
    let content_width = page_sizes.iter().map(|(width, _)| width).sum::<f32>();
    let gutter_width = gutter * page_sizes.len().saturating_sub(1) as f32;
    let content_height = page_sizes
        .iter()
        .map(|(_, height)| *height)
        .fold(0.0_f32, f32::max);
    let width_scale = (available.width - gutter_width).max(1.0) / content_width.max(1.0);
    if fit_page {
        width_scale.min(available.height / content_height.max(1.0))
    } else {
        width_scale
    }
    .clamp(0.1, 5.0)
}

pub(crate) fn slot_width(
    available_width: f32,
    page_count: usize,
    gutter: f32,
    rendered_width: f32,
) -> f32 {
    let gutters = gutter * page_count.saturating_sub(1) as f32;
    let stable_width = (available_width - gutters).max(1.0) / page_count.max(1) as f32;
    stable_width.max(rendered_width)
}

pub(crate) fn next_page(total_pages: usize, current_page: usize, spread: bool) -> Option<usize> {
    let next = if spread {
        spread_start(current_page).saturating_add(2)
    } else {
        current_page.saturating_add(1)
    };
    (next < total_pages).then_some(next)
}

pub(crate) fn previous_page(current_page: usize, spread: bool) -> Option<usize> {
    if spread {
        let start = spread_start(current_page);
        (start > 0).then_some(start.saturating_sub(2))
    } else {
        (current_page > 0).then_some(current_page - 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spread_navigation_uses_spread_boundaries() {
        assert_eq!(visible_pages(5, 3, true), vec![2, 3]);
        assert_eq!(next_page(5, 3, true), Some(4));
        assert_eq!(previous_page(3, true), Some(0));
    }

    #[test]
    fn single_page_navigation_moves_one_page() {
        assert_eq!(visible_pages(5, 3, false), vec![3]);
        assert_eq!(next_page(5, 3, false), Some(4));
        assert_eq!(previous_page(3, false), Some(2));
    }
}
