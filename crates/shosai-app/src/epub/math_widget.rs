//! Iced painting for shared native MathML geometry.

use iced::advanced::{
    Clipboard, Layout, Renderer as _, Shell, Widget, layout, renderer, widget::Tree,
};
use iced::{Element, Event, Font, Length, Rectangle, Size, mouse};

use super::math_layout::{MATH_FONT_FAMILY, MathLayout, MathPrimitiveKind};

pub(crate) fn math<'a, Message: Clone + 'a>(
    layout: MathLayout,
    color: iced::Color,
    highlight: Option<iced::Color>,
) -> Element<'a, Message> {
    Element::new(Math {
        layout,
        color,
        highlight,
        on_press: None,
    })
}

pub(crate) fn linked_math<'a, Message: Clone + 'a>(
    layout: MathLayout,
    color: iced::Color,
    highlight: Option<iced::Color>,
    on_press: Message,
) -> Element<'a, Message> {
    Element::new(Math {
        layout,
        color,
        highlight,
        on_press: Some(on_press),
    })
}

struct Math<Message> {
    layout: MathLayout,
    color: iced::Color,
    highlight: Option<iced::Color>,
    on_press: Option<Message>,
}

fn linked_math_message<Message: Clone>(
    event: &Event,
    bounds: Rectangle,
    cursor: mouse::Cursor,
    message: &Message,
) -> Option<Message> {
    matches!(
        event,
        Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left))
    )
    .then(|| cursor.position_over(bounds))
    .flatten()
    .map(|_| message.clone())
}

impl<Message: Clone> Widget<Message, iced::Theme, iced::Renderer> for Math<Message> {
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
        if let Some(highlight) = self.highlight {
            renderer.fill_quad(
                renderer::Quad {
                    bounds,
                    snap: true,
                    ..renderer::Quad::default()
                },
                highlight,
            );
        }
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

    fn update(
        &mut self,
        _tree: &mut Tree,
        event: &Event,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        _renderer: &iced::Renderer,
        _clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
        _viewport: &Rectangle,
    ) {
        if let Some(message) = self
            .on_press
            .as_ref()
            .and_then(|message| linked_math_message(event, layout.bounds(), cursor, message))
        {
            shell.publish(message);
            shell.capture_event();
        }
    }

    fn mouse_interaction(
        &self,
        _tree: &Tree,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        _viewport: &Rectangle,
        _renderer: &iced::Renderer,
    ) -> mouse::Interaction {
        if self.on_press.is_some() && cursor.is_over(layout.bounds()) {
            mouse::Interaction::Pointer
        } else {
            mouse::Interaction::None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linked_math_publishes_on_a_hit_tested_press() {
        let bounds = Rectangle::new(iced::Point::new(20.0, 30.0), Size::new(80.0, 40.0));
        let event = Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left));

        assert_eq!(
            linked_math_message(
                &event,
                bounds,
                mouse::Cursor::Available(iced::Point::new(60.0, 50.0)),
                &"chapter.xhtml#proof",
            ),
            Some("chapter.xhtml#proof")
        );
        assert_eq!(
            linked_math_message(
                &event,
                bounds,
                mouse::Cursor::Available(iced::Point::new(10.0, 10.0)),
                &"chapter.xhtml#proof",
            ),
            None
        );
    }
}
