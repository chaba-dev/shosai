use iced::widget::{button, container, progress_bar};
use iced::{Background, Border, Color, Shadow, Theme, Vector};

pub const APP_BACKGROUND: Color = Color::from_rgb8(0xF4, 0xF2, 0xED);
pub const SURFACE: Color = Color::from_rgb8(0xFF, 0xFE, 0xFB);
pub const SURFACE_MUTED: Color = Color::from_rgb8(0xEC, 0xE9, 0xE1);
pub const TEXT: Color = Color::from_rgb8(0x28, 0x27, 0x24);
pub const TEXT_MUTED: Color = Color::from_rgb8(0x72, 0x6F, 0x67);
pub const BORDER: Color = Color::from_rgb8(0xD9, 0xD5, 0xCB);
pub const ACCENT: Color = Color::from_rgb8(0x4D, 0x5E, 0x86);
pub const ACCENT_HOVERED: Color = Color::from_rgb8(0x3F, 0x4F, 0x76);
pub const ACCENT_SOFT: Color = Color::from_rgb8(0xE2, 0xE6, 0xF0);

pub const RADIUS_SMALL: f32 = 6.0;
pub const RADIUS_MEDIUM: f32 = 10.0;

pub fn application() -> Theme {
    Theme::custom(
        "Shosai",
        iced::theme::Palette {
            background: APP_BACKGROUND,
            text: TEXT,
            primary: ACCENT,
            success: Color::from_rgb8(0x4E, 0x75, 0x5D),
            warning: Color::from_rgb8(0xA7, 0x70, 0x36),
            danger: Color::from_rgb8(0xA5, 0x43, 0x43),
        },
    )
}

pub fn app_background(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(APP_BACKGROUND)
        .color(TEXT)
}

pub fn surface(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .color(TEXT)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_MEDIUM.into(),
        })
}

pub fn sidebar(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(Color::from_rgb8(0xEE, 0xEB, 0xE4))
        .color(TEXT)
        .border(Border {
            color: BORDER,
            width: 0.0,
            radius: 0.0.into(),
        })
}

pub fn activity_bar(active: bool) -> impl Fn(&Theme) -> container::Style {
    move |_theme| {
        container::Style::default().background(if active { ACCENT } else { Color::TRANSPARENT })
    }
}

pub fn skeleton(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE_MUTED)
        .border(Border {
            radius: RADIUS_SMALL.into(),
            ..Border::default()
        })
}

pub fn skeleton_subtle(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(Color::from_rgb8(0xE3, 0xDF, 0xD6))
        .border(Border {
            radius: 3.0.into(),
            ..Border::default()
        })
}

pub fn book_cover(_theme: &Theme) -> container::Style {
    container::Style::default().shadow(Shadow {
        color: Color::from_rgba8(0x21, 0x20, 0x1E, 0.16),
        offset: Vector::new(0.0, 4.0),
        blur_radius: 12.0,
    })
}

pub fn primary_button(_theme: &Theme, status: button::Status) -> button::Style {
    let background = match status {
        button::Status::Hovered | button::Status::Pressed => ACCENT_HOVERED,
        button::Status::Disabled => ACCENT.scale_alpha(0.45),
        button::Status::Active => ACCENT,
    };

    button::Style {
        background: Some(Background::Color(background)),
        text_color: Color::WHITE,
        border: Border {
            radius: RADIUS_SMALL.into(),
            ..Border::default()
        },
        ..button::Style::default()
    }
}

pub fn secondary_button(_theme: &Theme, status: button::Status) -> button::Style {
    let background = match status {
        button::Status::Hovered | button::Status::Pressed => SURFACE_MUTED,
        button::Status::Disabled => SURFACE.scale_alpha(0.55),
        button::Status::Active => SURFACE,
    };

    button::Style {
        background: Some(Background::Color(background)),
        text_color: if status == button::Status::Disabled {
            TEXT_MUTED
        } else {
            TEXT
        },
        border: Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_SMALL.into(),
        },
        ..button::Style::default()
    }
}

pub fn navigation_button(selected: bool) -> impl Fn(&Theme, button::Status) -> button::Style {
    move |_theme, status| {
        let background = if selected {
            Some(Background::Color(ACCENT_SOFT))
        } else if matches!(status, button::Status::Hovered | button::Status::Pressed) {
            Some(Background::Color(SURFACE_MUTED))
        } else {
            None
        };

        button::Style {
            background,
            text_color: if selected { ACCENT } else { TEXT },
            border: Border {
                radius: RADIUS_SMALL.into(),
                ..Border::default()
            },
            ..button::Style::default()
        }
    }
}

pub fn book_button(_theme: &Theme, status: button::Status) -> button::Style {
    let background = match status {
        button::Status::Hovered | button::Status::Pressed => {
            Some(Background::Color(Color::from_rgb8(0xE9, 0xE6, 0xDE)))
        }
        _ => None,
    };

    button::Style {
        background,
        text_color: TEXT,
        border: Border {
            radius: RADIUS_MEDIUM.into(),
            ..Border::default()
        },
        ..button::Style::default()
    }
}

pub fn progress(_theme: &Theme) -> progress_bar::Style {
    progress_bar::Style {
        background: Background::Color(SURFACE_MUTED),
        bar: Background::Color(ACCENT),
        border: Border {
            radius: 2.0.into(),
            ..Border::default()
        },
    }
}
