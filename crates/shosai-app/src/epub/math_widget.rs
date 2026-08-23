//! Iced painting for shared native MathML geometry.

use iced::advanced::{Layout, Renderer as _, Widget, layout, renderer, widget::Tree};
use iced::{Element, Font, Length, Rectangle, Size, mouse};

use super::math_layout::{MATH_FONT_FAMILY, MathLayout, MathPrimitiveKind};

pub(crate) fn math<'a, Message: 'a>(
    layout: MathLayout,
    color: iced::Color,
) -> Element<'a, Message> {
    Element::new(Math { layout, color })
}

struct Math {
    layout: MathLayout,
    color: iced::Color,
}

impl<Message> Widget<Message, iced::Theme, iced::Renderer> for Math {
    fn size(&self) -> Size<Length> {
        Size::new(
            Length::Fixed(self.layout.width),
            Length::Fixed(self.layout.height),
        )
    }

    fn layout(
        &mut self,
        _tree: &mut Tree,
        _renderer: &iced::Renderer,
        limits: &layout::Limits,
    ) -> layout::Node {
        layout::Node::new(limits.resolve(
            Length::Fixed(self.layout.width),
            Length::Fixed(self.layout.height),
            Size::ZERO,
        ))
    }

    fn draw(
        &self,
        _tree: &Tree,
        renderer: &mut iced::Renderer,
        _theme: &iced::Theme,
        _style: &renderer::Style,
        layout: Layout<'_>,
        _cursor: mouse::Cursor,
        viewport: &Rectangle,
    ) {
        use iced::advanced::text::Renderer as _;

        let bounds = layout.bounds();
        let Some(clip) = bounds.intersection(viewport) else {
            return;
        };
        for primitive in &self.layout.primitives {
            let position = iced::Point::new(bounds.x + primitive.x, bounds.y + primitive.y);
            let primitive_bounds =
                Rectangle::new(position, Size::new(primitive.width, primitive.height));
            match &primitive.kind {
                MathPrimitiveKind::Text(content) => renderer.fill_text(
                    iced::advanced::Text {
                        content: content.clone(),
                        bounds: primitive_bounds.size(),
                        size: iced::Pixels(primitive.font_size),
                        line_height: iced::advanced::text::LineHeight::Absolute(iced::Pixels(
                            primitive.height,
                        )),
                        font: Font::with_name(MATH_FONT_FAMILY),
                        align_x: iced::advanced::text::Alignment::Left,
                        align_y: iced::alignment::Vertical::Top,
                        shaping: iced::advanced::text::Shaping::Advanced,
                        wrapping: iced::advanced::text::Wrapping::None,
                    },
                    position,
                    self.color,
                    clip,
                ),
                MathPrimitiveKind::Rule(_) => renderer.fill_quad(
                    renderer::Quad {
                        bounds: primitive_bounds,
                        snap: true,
                        ..renderer::Quad::default()
                    },
                    self.color,
                ),
            }
        }
    }
}
