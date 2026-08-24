//! Iced painting for shared native MathML geometry.

use iced::advanced::{
    Clipboard, Layout, Shell, Widget, layout, renderer, widget::Tree,
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

impl<Message: Clone, Renderer> Widget<Message, iced::Theme, Renderer> for Math<Message>
where
    Renderer: iced::advanced::Renderer + iced::advanced::text::Renderer<Font = Font>,
{
    fn size(&self) -> Size<Length> {
        Size::new(
            Length::Fixed(self.layout.width),
            Length::Fixed(self.layout.height),
        )
    }

    fn layout(
        &mut self,
        _tree: &mut Tree,
        _renderer: &Renderer,
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
        renderer: &mut Renderer,
        _theme: &iced::Theme,
        _style: &renderer::Style,
        layout: Layout<'_>,
        _cursor: mouse::Cursor,
        viewport: &Rectangle,
    ) {
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
        _renderer: &Renderer,
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
        _renderer: &Renderer,
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
        let mut widget = Math {
            layout: MathLayout {
                width: 80.0,
                height: 40.0,
                baseline: 30.0,
                primitives: Vec::new(),
            },
            color: iced::Color::BLACK,
            highlight: None,
            on_press: Some("chapter.xhtml#proof"),
        };
        let mut tree = Tree::empty();
        let node = layout::Node::new(Size::new(80.0, 40.0)).move_to(iced::Point::new(20.0, 30.0));
        let event = Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left));
        let renderer = ();
        let mut clipboard = iced::advanced::clipboard::Null;
        let viewport = Rectangle::new(iced::Point::ORIGIN, Size::new(200.0, 200.0));
        let mut messages = Vec::new();
        let mut shell = Shell::new(&mut messages);

        <Math<&str> as Widget<&str, iced::Theme, ()>>::update(
            &mut widget,
            &mut tree,
            &event,
            Layout::new(&node),
            mouse::Cursor::Available(iced::Point::new(60.0, 50.0)),
            &renderer,
            &mut clipboard,
            &mut shell,
            &viewport,
        );

        assert!(shell.is_event_captured());
        drop(shell);
        assert_eq!(messages, vec!["chapter.xhtml#proof"]);

        let mut messages = Vec::new();
        let mut shell = Shell::new(&mut messages);
        <Math<&str> as Widget<&str, iced::Theme, ()>>::update(
            &mut widget,
            &mut tree,
            &event,
            Layout::new(&node),
            mouse::Cursor::Available(iced::Point::new(10.0, 10.0)),
            &renderer,
            &mut clipboard,
            &mut shell,
            &viewport,
        );

        assert!(!shell.is_event_captured());
        drop(shell);
        assert!(messages.is_empty());
    }
}
