use iced::widget::{Button, ProgressBar, button, container, progress_bar, row, text};
use iced::{Element, Length};

use crate::theme;

pub fn primary_button<'a, Message: Clone + 'a>(
    label: &'a str,
    message: Option<Message>,
) -> Button<'a, Message> {
    button(text(label).size(14))
        .on_press_maybe(message)
        .padding([9, 14])
        .style(theme::primary_button)
}

pub fn secondary_button<'a, Message: Clone + 'a>(
    label: &'a str,
    message: Option<Message>,
) -> Button<'a, Message> {
    button(text(label).size(14))
        .on_press_maybe(message)
        .padding([9, 14])
        .style(theme::secondary_button)
}

pub fn navigation_button<'a, Message: Clone + 'a>(
    label: &'a str,
    selected: bool,
    message: Message,
) -> Button<'a, Message> {
    button(text(label).size(14))
        .on_press(message)
        .padding([9, 12])
        .width(Length::Fill)
        .style(theme::navigation_button(selected))
}

pub fn activity_bar<'a, Message: 'a>(active: bool, progress: f32) -> Element<'a, Message> {
    let leading = (progress.clamp(0.0, 1.0) * 800.0).round() as u16;
    let trailing = 800 - leading;
    let mut line = row![].height(2);
    if leading > 0 {
        line = line.push(iced::widget::Space::new().width(Length::FillPortion(leading)));
    }
    line = line.push(
        container(iced::widget::Space::new())
            .width(Length::FillPortion(200))
            .height(2)
            .style(theme::activity_bar(active)),
    );
    if trailing > 0 {
        line = line.push(iced::widget::Space::new().width(Length::FillPortion(trailing)));
    }

    container(line).width(Length::Fill).height(2).into()
}

pub fn book_button<'a, Message: Clone + 'a>(
    content: impl Into<Element<'a, Message>>,
    message: Message,
) -> Button<'a, Message> {
    button(content)
        .on_press(message)
        .padding(8)
        .width(Length::Fill)
        .style(theme::book_button)
}

pub fn reading_progress(progress: f64) -> ProgressBar<'static> {
    progress_bar(0.0..=1.0, progress.clamp(0.0, 1.0) as f32)
        .girth(4)
        .style(theme::progress)
}
