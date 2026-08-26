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

/// Color theme for EPUB reader content.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum ReaderTheme {
    #[default]
    Light,
    Dark,
    Sepia,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReaderPalette {
    pub background: Color,
    pub text: Color,
    pub link: Color,
    pub search_highlight: Color,
    pub current_search_highlight: Color,
    pub table_header_background: Color,
    pub table_header_border: Color,
}

impl ReaderTheme {
    pub fn palette(self) -> ReaderPalette {
        ReaderPalette {
            background: self.background(),
            text: self.text_color(),
            link: self.link_color(),
            search_highlight: self.search_highlight(false),
            current_search_highlight: self.search_highlight(true),
            table_header_background: self.table_header_background(),
            table_header_border: self.table_header_border(),
        }
    }

    pub fn background(self) -> Color {
        match self {
            Self::Light => Color::WHITE,
            Self::Dark => Color::from_rgb(0.12, 0.12, 0.14),
            Self::Sepia => Color::from_rgb(0.96, 0.92, 0.84),
        }
    }

    pub fn text_color(self) -> Color {
        match self {
            Self::Light => Color::from_rgb(0.1, 0.1, 0.1),
            Self::Dark => Color::from_rgb(0.85, 0.85, 0.85),
            Self::Sepia => Color::from_rgb(0.3, 0.2, 0.1),
        }
    }

    pub fn link_color(self) -> Color {
        match self {
            Self::Light => Color::from_rgb8(0x17, 0x4E, 0xA6),
            Self::Dark => Color::from_rgb8(0x8A, 0xB4, 0xF8),
            Self::Sepia => Color::from_rgb8(0x68, 0x3D, 0x00),
        }
    }

    pub fn table_header_background(self) -> Color {
        match self {
            Self::Light => Color::from_rgb8(0xE8, 0xEE, 0xF8),
            Self::Dark => Color::from_rgb8(0x2B, 0x34, 0x45),
            Self::Sepia => Color::from_rgb8(0xE5, 0xD6, 0xBA),
        }
    }

    fn search_highlight(self, current: bool) -> Color {
        match (self, current) {
            (Self::Light, false) => Color::from_rgba8(0xFF, 0xF3, 0xA3, 0.50),
            (Self::Light, true) => Color::from_rgba8(0xFF, 0xE0, 0x66, 0.45),
            (Self::Dark, false) => Color::from_rgba8(0x4C, 0x3B, 0x00, 0.55),
            (Self::Dark, true) => Color::from_rgba8(0x5C, 0x45, 0x00, 0.50),
            (Self::Sepia, false) => Color::from_rgba8(0xFF, 0xE6, 0x9A, 0.45),
            (Self::Sepia, true) => Color::from_rgba8(0xF4, 0xCF, 0x64, 0.35),
        }
    }

    fn table_header_border(self) -> Color {
        match self {
            Self::Light => Color::from_rgb8(0x59, 0x6B, 0x89),
            Self::Dark => Color::from_rgb8(0x87, 0x97, 0xB2),
            Self::Sepia => Color::from_rgb8(0x6B, 0x54, 0x2E),
        }
    }

    pub fn next(self) -> Self {
        match self {
            Self::Light => Self::Dark,
            Self::Dark => Self::Sepia,
            Self::Sepia => Self::Light,
        }
    }
}

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

pub fn reader_header(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .color(TEXT)
        .border(Border {
            color: BORDER,
            width: 0.0,
            radius: 0.0.into(),
        })
}

pub fn reader_controls(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(Color::from_rgb8(0xEE, 0xEB, 0xE4))
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: 0.0.into(),
        })
}

pub fn reader_control_group(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_MEDIUM.into(),
        })
}

pub fn reader_control_button(selected: bool) -> impl Fn(&Theme, button::Status) -> button::Style {
    move |_theme, status| {
        let background = if selected {
            Some(Background::Color(ACCENT_SOFT))
        } else if matches!(status, button::Status::Hovered | button::Status::Pressed) {
            Some(Background::Color(SURFACE_MUTED))
        } else {
            None
        };
        let disabled = status == button::Status::Disabled;

        button::Style {
            background,
            text_color: if disabled {
                TEXT_MUTED.scale_alpha(0.55)
            } else if selected {
                ACCENT
            } else {
                TEXT
            },
            border: Border {
                radius: RADIUS_SMALL.into(),
                ..Border::default()
            },
            ..button::Style::default()
        }
    }
}

pub fn reader_edge_button(_theme: &Theme, status: button::Status) -> button::Style {
    let disabled = status == button::Status::Disabled;
    button::Style {
        background: matches!(status, button::Status::Hovered | button::Status::Pressed)
            .then_some(Background::Color(SURFACE_MUTED.scale_alpha(0.7))),
        text_color: if disabled {
            TEXT_MUTED.scale_alpha(0.25)
        } else {
            TEXT_MUTED.scale_alpha(0.75)
        },
        ..button::Style::default()
    }
}

pub fn reader_tab_strip(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(Color::from_rgb8(0xE7, 0xE3, 0xDA))
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: 0.0.into(),
        })
}

pub fn reader_tab(selected: bool) -> impl Fn(&Theme) -> container::Style {
    move |_theme| {
        container::Style::default()
            .background(if selected {
                SURFACE
            } else {
                Color::TRANSPARENT
            })
            .border(Border {
                color: if selected { BORDER } else { Color::TRANSPARENT },
                width: if selected { 1.0 } else { 0.0 },
                radius: RADIUS_SMALL.into(),
            })
    }
}

pub fn reader_tab_label(selected: bool) -> impl Fn(&Theme, button::Status) -> button::Style {
    move |_theme, _status| button::Style {
        text_color: if selected { ACCENT } else { TEXT_MUTED },
        ..button::Style::default()
    }
}

pub fn reader_tab_close(_theme: &Theme, status: button::Status) -> button::Style {
    button::Style {
        background: matches!(status, button::Status::Hovered | button::Status::Pressed)
            .then_some(Background::Color(SURFACE_MUTED)),
        text_color: TEXT_MUTED,
        border: Border {
            radius: RADIUS_SMALL.into(),
            ..Border::default()
        },
        ..button::Style::default()
    }
}

pub fn reader_status(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: 0.0.into(),
        })
}

pub fn reader_search(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: 0.0.into(),
        })
}

pub fn reader_alert(_theme: &Theme) -> container::Style {
    container::Style::default().background(Color::from_rgb8(0xF6, 0xE5, 0xE2))
}

pub fn bookmarks_panel(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(Color::from_rgb8(0xEE, 0xEB, 0xE4))
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: 0.0.into(),
        })
}

pub fn bookmark_entry(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_MEDIUM.into(),
        })
}

pub fn bookmark_link(_theme: &Theme, status: button::Status) -> button::Style {
    button::Style {
        background: matches!(status, button::Status::Hovered | button::Status::Pressed)
            .then_some(Background::Color(ACCENT_SOFT)),
        text_color: ACCENT,
        border: Border {
            radius: RADIUS_SMALL.into(),
            ..Border::default()
        },
        ..button::Style::default()
    }
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

pub fn book_card_action(_theme: &Theme, status: button::Status) -> button::Style {
    let background = match status {
        button::Status::Hovered | button::Status::Pressed => SURFACE_MUTED,
        button::Status::Disabled => SURFACE.scale_alpha(0.7),
        button::Status::Active => SURFACE,
    };
    button::Style {
        background: Some(Background::Color(background)),
        text_color: TEXT_MUTED,
        border: Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_SMALL.into(),
        },
        ..button::Style::default()
    }
}

pub fn book_action_menu(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_SMALL.into(),
        })
        .shadow(Shadow {
            color: Color::from_rgba8(0x21, 0x20, 0x1E, 0.18),
            offset: Vector::new(0.0, 3.0),
            blur_radius: 10.0,
        })
}

pub fn book_confirmation(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .color(TEXT)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_SMALL.into(),
        })
}

pub fn danger_button(_theme: &Theme, status: button::Status) -> button::Style {
    let danger = Color::from_rgb8(0xA5, 0x43, 0x43);
    button::Style {
        background: matches!(status, button::Status::Hovered | button::Status::Pressed)
            .then_some(Background::Color(danger.scale_alpha(0.12))),
        text_color: danger,
        border: Border {
            color: danger.scale_alpha(0.35),
            width: 1.0,
            radius: RADIUS_SMALL.into(),
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
