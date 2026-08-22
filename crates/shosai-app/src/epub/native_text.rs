//! Book-local EPUB text widget. Raster handles live only in the Iced tree.

use std::{
    cell::RefCell,
    collections::HashMap,
    sync::{
        Arc, Mutex, OnceLock, Weak,
        atomic::{AtomicUsize, Ordering},
    },
};

use iced::advanced::{Clipboard, Layout, Shell, Widget, layout, renderer, widget::Tree};
use iced::widget::image;
use iced::{Element, Event, Length, Rectangle, Size, mouse};
use shosai_core::epub::{EpubFontBook, EpubTextLayout, EpubTextRequest};

struct Cache {
    fonts: u64,
    request: Option<EpubTextRequest>,
    layout: Option<EpubTextLayout>,
    fallback_height: f32,
    budget: Arc<BookRasterBudget>,
    raster: RefCell<Option<Raster>>,
}

const BOOK_RASTER_PIXEL_BUDGET: usize = 16 * 1024 * 1024;
static BOOK_RASTER_BUDGETS: OnceLock<Mutex<HashMap<u64, Weak<BookRasterBudget>>>> = OnceLock::new();

struct BookRasterBudget {
    pixels: AtomicUsize,
}

struct RasterPermit {
    budget: Arc<BookRasterBudget>,
    pixels: usize,
}

impl Drop for RasterPermit {
    fn drop(&mut self) {
        self.budget.pixels.fetch_sub(self.pixels, Ordering::Relaxed);
    }
}

struct Raster {
    handles: Vec<image::Handle>,
    _permit: RasterPermit,
}

fn book_raster_budget(id: u64) -> Arc<BookRasterBudget> {
    let budgets = BOOK_RASTER_BUDGETS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut budgets = budgets
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    budgets.retain(|_, budget| budget.strong_count() > 0);
    if let Some(budget) = budgets.get(&id).and_then(Weak::upgrade) {
        return budget;
    }
    let budget = Arc::new(BookRasterBudget {
        pixels: AtomicUsize::new(0),
    });
    budgets.insert(id, Arc::downgrade(&budget));
    budget
}

fn reserve_raster(budget: &Arc<BookRasterBudget>, pixels: usize) -> Option<RasterPermit> {
    budget
        .pixels
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            current
                .checked_add(pixels)
                .filter(|total| *total <= BOOK_RASTER_PIXEL_BUDGET)
        })
        .ok()?;
    Some(RasterPermit {
        budget: Arc::clone(budget),
        pixels,
    })
}

pub(crate) struct NativeText<'a, Message> {
    fonts: &'a EpubFontBook,
    request: EpubTextRequest,
    on_link: fn(String) -> Message,
}

pub(crate) fn native_text<'a, Message: 'a>(
    fonts: &'a EpubFontBook,
    request: EpubTextRequest,
    on_link: fn(String) -> Message,
) -> Element<'a, Message> {
    Element::new(NativeText {
        fonts,
        request,
        on_link,
    })
}

fn hit(layout: &EpubTextLayout, x: f32, y: f32) -> Option<&str> {
    layout.links.iter().find_map(|link| {
        let r = link.rect;
        (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
            .then_some(link.link.as_str())
    })
}

impl<Message> Widget<Message, iced::Theme, iced::Renderer> for NativeText<'_, Message> {
    fn tag(&self) -> iced::advanced::widget::tree::Tag {
        iced::advanced::widget::tree::Tag::of::<Cache>()
    }

    fn state(&self) -> iced::advanced::widget::tree::State {
        iced::advanced::widget::tree::State::new(Cache {
            fonts: self.fonts.native_text_id(),
            request: None,
            layout: None,
            fallback_height: 0.0,
            budget: book_raster_budget(self.fonts.native_text_id()),
            raster: RefCell::new(None),
        })
    }

    fn size(&self) -> Size<Length> {
        Size::new(Length::Fill, Length::Shrink)
    }

    fn layout(
        &mut self,
        tree: &mut Tree,
        renderer: &iced::Renderer,
        limits: &layout::Limits,
    ) -> layout::Node {
        let width = if limits.max().width.is_finite() {
            limits.max().width.max(1.0)
        } else {
            limits.min().width.max(1.0)
        };
        self.request.max_width = width;
        let fonts = self.fonts.native_text_id();
        let cache = tree.state.downcast_mut::<Cache>();
        if cache.fonts != fonts || cache.request.as_ref() != Some(&self.request) {
            cache.fonts = fonts;
            cache.request = Some(self.request.clone());
            cache.layout = self.fonts.measure_text(&self.request).ok();
            cache.fallback_height = fallback_height(renderer, &self.request);
            cache.budget = book_raster_budget(fonts);
            *cache.raster.get_mut() = None;
        }
        let height = cache
            .layout
            .as_ref()
            .map_or(cache.fallback_height, |layout| {
                layout.height.max(cache.fallback_height)
            });
        layout::Node::new(limits.resolve(Length::Fill, Length::Fixed(height), Size::ZERO))
    }

    fn draw(
        &self,
        tree: &Tree,
        renderer: &mut iced::Renderer,
        _theme: &iced::Theme,
        _style: &renderer::Style,
        layout: Layout<'_>,
        _cursor: mouse::Cursor,
        viewport: &Rectangle,
    ) {
        use iced::advanced::image::Renderer as _;
        let bounds = layout.bounds();
        if !bounds.intersects(viewport) {
            return;
        }
        let cache = tree.state.downcast_ref::<Cache>();
        let Some(text_layout) = &cache.layout else {
            draw_system_fallback(renderer, &self.request, bounds, viewport);
            return;
        };
        let mut raster = cache.raster.borrow_mut();
        if raster.is_none() {
            let pixels = text_layout.lines.iter().try_fold(0_usize, |total, line| {
                total.checked_add(line.pixel_width as usize * line.pixel_height as usize)
            });
            if let Some(permit) = pixels.and_then(|pixels| reserve_raster(&cache.budget, pixels))
                && let Ok(layout) = self.fonts.layout_text(&self.request)
            {
                let handles = layout
                    .lines
                    .into_iter()
                    .map(|line| {
                        image::Handle::from_rgba(line.pixel_width, line.pixel_height, line.rgba)
                    })
                    .collect();
                *raster = Some(Raster {
                    handles,
                    _permit: permit,
                });
            }
        }
        let Some(raster) = raster.as_ref() else {
            draw_system_fallback(renderer, &self.request, bounds, viewport);
            return;
        };
        for (line, handle) in text_layout.lines.iter().zip(&raster.handles) {
            let line_bounds = Rectangle::new(
                iced::Point::new(bounds.x, bounds.y + line.top),
                Size::new(
                    line.pixel_width as f32 / self.request.scale,
                    line.pixel_height as f32 / self.request.scale,
                ),
            );
            renderer.draw_image(
                iced::advanced::image::Image {
                    handle: handle.clone(),
                    border_radius: iced::border::Radius::default(),
                    filter_method: iced::advanced::image::FilterMethod::Linear,
                    rotation: iced::Radians(0.0),
                    opacity: 1.0,
                    snap: true,
                },
                line_bounds,
                bounds.intersection(viewport).unwrap_or(bounds),
            );
        }
    }

    fn update(
        &mut self,
        tree: &mut Tree,
        event: &Event,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        _renderer: &iced::Renderer,
        _clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
        _viewport: &Rectangle,
    ) {
        if !matches!(
            event,
            Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left))
        ) {
            return;
        }
        let Some(position) = cursor.position_over(layout.bounds()) else {
            return;
        };
        let local = position - layout.position();
        if let Some(link) = tree
            .state
            .downcast_ref::<Cache>()
            .layout
            .as_ref()
            .and_then(|l| hit(l, local.x, local.y))
        {
            shell.publish((self.on_link)(link.to_owned()));
            shell.capture_event();
        }
    }

    fn mouse_interaction(
        &self,
        tree: &Tree,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        _viewport: &Rectangle,
        _renderer: &iced::Renderer,
    ) -> mouse::Interaction {
        let Some(p) = cursor.position_over(layout.bounds()) else {
            return mouse::Interaction::None;
        };
        let p = p - layout.position();
        if tree
            .state
            .downcast_ref::<Cache>()
            .layout
            .as_ref()
            .and_then(|l| hit(l, p.x, p.y))
            .is_some()
        {
            mouse::Interaction::Pointer
        } else {
            mouse::Interaction::None
        }
    }
}

fn fallback_height(renderer: &iced::Renderer, request: &EpubTextRequest) -> f32 {
    use iced::advanced::text::{Paragraph as _, Renderer as _};
    let content = fallback_content(request);
    let paragraph =
        <<iced::Renderer as iced::advanced::text::Renderer>::Paragraph as iced::advanced::text::Paragraph>::with_text(
            iced::advanced::Text {
                content: &content,
                bounds: Size::new(request.max_width, f32::INFINITY),
                size: iced::Pixels(request.runs.first().map_or(16.0, |run| run.font_size)),
                line_height: iced::advanced::text::LineHeight::Absolute(iced::Pixels(
                    request.line_height,
                )),
                font: renderer.default_font(),
                align_x: fallback_alignment(request),
                align_y: iced::alignment::Vertical::Top,
                shaping: iced::advanced::text::Shaping::Advanced,
                wrapping: iced::advanced::text::Wrapping::WordOrGlyph,
            },
        );
    paragraph.min_height().max(request.line_height)
}

fn draw_system_fallback(
    renderer: &mut iced::Renderer,
    request: &EpubTextRequest,
    bounds: Rectangle,
    viewport: &Rectangle,
) {
    use iced::advanced::text::Renderer as _;
    let content = fallback_content(request);
    let color = request.runs.first().map_or(iced::Color::BLACK, |run| {
        iced::Color::from_rgba8(
            run.foreground[0],
            run.foreground[1],
            run.foreground[2],
            run.foreground[3] as f32 / 255.0,
        )
    });
    renderer.fill_text(
        iced::advanced::Text {
            content,
            bounds: bounds.size(),
            size: iced::Pixels(request.runs.first().map_or(16.0, |run| run.font_size)),
            line_height: iced::advanced::text::LineHeight::Absolute(iced::Pixels(
                request.line_height,
            )),
            font: renderer.default_font(),
            align_x: fallback_alignment(request),
            align_y: iced::alignment::Vertical::Top,
            shaping: iced::advanced::text::Shaping::Advanced,
            wrapping: iced::advanced::text::Wrapping::WordOrGlyph,
        },
        bounds.position(),
        color,
        bounds.intersection(viewport).unwrap_or(bounds),
    );
}

fn fallback_content(request: &EpubTextRequest) -> String {
    let isolate = match request.direction {
        shosai_core::epub::EpubTextDirection::LeftToRight => '\u{2066}',
        shosai_core::epub::EpubTextDirection::RightToLeft => '\u{2067}',
    };
    std::iter::once(isolate)
        .chain(request.runs.iter().flat_map(|run| run.text.chars()))
        .chain(std::iter::once('\u{2069}'))
        .collect()
}

fn fallback_alignment(request: &EpubTextRequest) -> iced::advanced::text::Alignment {
    match request.align {
        shosai_core::epub::EpubTextAlign::Left | shosai_core::epub::EpubTextAlign::Justified => {
            iced::advanced::text::Alignment::Left
        }
        shosai_core::epub::EpubTextAlign::Center => iced::advanced::text::Alignment::Center,
        shosai_core::epub::EpubTextAlign::Right => iced::advanced::text::Alignment::Right,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shosai_core::epub::{EpubTextHit, EpubTextRect};

    #[test]
    fn raster_budget_is_shared_and_released_per_book() {
        let budget = book_raster_budget(u64::MAX);
        let first = reserve_raster(&budget, BOOK_RASTER_PIXEL_BUDGET).unwrap();
        assert!(reserve_raster(&budget, 1).is_none());
        drop(first);
        assert!(reserve_raster(&budget, BOOK_RASTER_PIXEL_BUDGET).is_some());
    }

    #[test]
    fn link_hit_rectangles_use_widget_local_coordinates() {
        let layout = EpubTextLayout {
            width: 100.0,
            height: 20.0,
            lines: vec![],
            links: vec![EpubTextHit {
                rect: EpubTextRect {
                    x: 10.0,
                    y: 2.0,
                    width: 30.0,
                    height: 12.0,
                },
                scalars: 1..4,
                link: "chapter.xhtml#note".into(),
            }],
        };
        assert_eq!(hit(&layout, 10.0, 2.0), Some("chapter.xhtml#note"));
        assert_eq!(hit(&layout, 39.9, 13.9), Some("chapter.xhtml#note"));
        assert_eq!(hit(&layout, 40.0, 14.0), None);
    }
}
