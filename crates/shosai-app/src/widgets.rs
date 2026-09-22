use iced::widget::{Button, ProgressBar, button, progress_bar, text};
use iced::{Element, Font, Length};

use crate::theme;

pub fn primary_button<'a, Message: Clone + 'a>(
    label: impl Into<String>,
    message: Option<Message>,
    font: Font,
) -> Button<'a, Message> {
    button(text(label.into()).size(theme::BUTTON_LABEL_SIZE).font(font))
        .on_press_maybe(message)
        .padding([
            theme::BUTTON_PRIMARY_PADDING_VERTICAL,
            theme::BUTTON_PRIMARY_PADDING_HORIZONTAL,
        ])
        .style(theme::primary_button)
}

pub fn secondary_button<'a, Message: Clone + 'a>(
    label: impl Into<String>,
    message: Option<Message>,
    font: Font,
) -> Button<'a, Message> {
    button(text(label.into()).size(theme::BUTTON_LABEL_SIZE).font(font))
        .on_press_maybe(message)
        .padding([
            theme::BUTTON_SECONDARY_PADDING_VERTICAL,
            theme::BUTTON_SECONDARY_PADDING_HORIZONTAL,
        ])
        .style(theme::secondary_button)
}

pub fn navigation_button<'a, Message: Clone + 'a>(
    label: impl Into<String>,
    selected: bool,
    message: Message,
    font: Font,
) -> Button<'a, Message> {
    button(text(label.into()).size(theme::BUTTON_LABEL_SIZE).font(font))
        .on_press(message)
        .padding([
            theme::BUTTON_NAVIGATION_PADDING_VERTICAL,
            theme::BUTTON_NAVIGATION_PADDING_HORIZONTAL,
        ])
        .width(Length::Fill)
        .style(theme::navigation_button(selected))
}

pub fn book_button<'a, Message: Clone + 'a>(
    content: impl Into<Element<'a, Message>>,
    message: Option<Message>,
) -> Button<'a, Message> {
    button(content)
        .on_press_maybe(message)
        .padding(theme::BUTTON_BOOK_PADDING)
        .width(Length::Fill)
        .style(theme::book_button)
}

pub fn reading_progress(progress: f64) -> ProgressBar<'static> {
    progress_bar(0.0..=1.0, progress.clamp(0.0, 1.0) as f32)
        .girth(theme::PROGRESS_GIRTH)
        .style(theme::progress)
}
