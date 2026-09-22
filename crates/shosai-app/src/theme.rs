use iced::widget::{button, container, progress_bar};
use iced::{Background, Border, Color, Shadow, Theme, Vector};

use crate::theme_tokens as tokens;

/// Converts one opaque 8-bit token into an Iced color.
const fn rgb8(rgb: (u8, u8, u8)) -> Color {
    Color::from_rgb8(rgb.0, rgb.1, rgb.2)
}

/// Converts one 8-bit token with a fractional alpha into an Iced color.
const fn rgba8(rgb: (u8, u8, u8), alpha: f32) -> Color {
    Color::from_rgba8(rgb.0, rgb.1, rgb.2, alpha)
}

/// Converts one fractional-channel token into an Iced color.
const fn rgbf(rgb: (f32, f32, f32)) -> Color {
    Color::from_rgb(rgb.0, rgb.1, rgb.2)
}

pub const APP_BACKGROUND: Color = rgb8(tokens::APP_BACKGROUND);
pub const SURFACE: Color = rgb8(tokens::APP_SURFACE);
pub const SURFACE_MUTED: Color = rgb8(tokens::APP_SURFACE_MUTED);
pub const TEXT: Color = rgb8(tokens::APP_TEXT);
pub const TEXT_MUTED: Color = rgb8(tokens::APP_TEXT_MUTED);
pub const BORDER: Color = rgb8(tokens::APP_BORDER);
pub const ACCENT: Color = rgb8(tokens::APP_ACCENT);
pub const ACCENT_HOVERED: Color = rgb8(tokens::APP_ACCENT_HOVERED);
pub const ACCENT_SOFT: Color = rgb8(tokens::APP_ACCENT_SOFT);
pub const DANGER: Color = rgb8(tokens::APP_DANGER);

const SIDEBAR_BACKGROUND: Color = rgb8(tokens::APP_SIDEBAR_BACKGROUND);
const READER_CONTROLS_BACKGROUND: Color = rgb8(tokens::APP_READER_CONTROLS_BACKGROUND);
const TAB_STRIP_BACKGROUND: Color = rgb8(tokens::APP_TAB_STRIP_BACKGROUND);
const ALERT_BACKGROUND: Color = rgb8(tokens::APP_ALERT_BACKGROUND);
const PANEL_BACKGROUND: Color = rgb8(tokens::APP_PANEL_BACKGROUND);
const SKELETON_BACKGROUND: Color = rgb8(tokens::APP_SKELETON_BACKGROUND);
const BOOK_HOVER: Color = rgb8(tokens::APP_BOOK_HOVER);
pub const COVER_PLACEHOLDER_BACKGROUND: Color = rgbf(tokens::APP_COVER_PLACEHOLDER_BACKGROUND);
const SUCCESS: Color = rgb8(tokens::APP_SUCCESS);
const WARNING: Color = rgb8(tokens::APP_WARNING);
pub const TEXT_ON_ACCENT: Color = rgb8(tokens::APP_TEXT_ON_ACCENT);
const SHADOW_COVER: Color = rgba8(tokens::APP_SHADOW_COVER.0, tokens::APP_SHADOW_COVER.1);
const SHADOW_MENU: Color = rgba8(tokens::APP_SHADOW_MENU.0, tokens::APP_SHADOW_MENU.1);
const SHADOW_MODAL: Color = rgba8(tokens::APP_SHADOW_MODAL.0, tokens::APP_SHADOW_MODAL.1);
pub const SHADOW_HAIRLINE: Color =
    rgba8(tokens::APP_SHADOW_HAIRLINE.0, tokens::APP_SHADOW_HAIRLINE.1);
const MODAL_BACKDROP: Color = rgba8(tokens::APP_BACKDROP.0, tokens::APP_BACKDROP.1);
pub const READER_CODE_BLOCK_FALLBACK_BACKGROUND: Color =
    rgbf(tokens::READER_CODE_BLOCK_FALLBACK_BACKGROUND);

pub const RADIUS_SMALL: f32 = tokens::RADIUS_SMALL;
pub const RADIUS_MEDIUM: f32 = tokens::RADIUS_MEDIUM;
const RADIUS_PROGRESS: f32 = tokens::RADIUS_PROGRESS;
const SKELETON_SUBTLE_RADIUS: f32 = tokens::APP_SKELETON_RADIUS;

pub const BUTTON_LABEL_SIZE: f32 = tokens::LAYOUT_BUTTON_LABEL_SIZE;
pub const BUTTON_PRIMARY_PADDING_VERTICAL: f32 = tokens::LAYOUT_BUTTON_PRIMARY_PADDING_VERTICAL;
pub const BUTTON_PRIMARY_PADDING_HORIZONTAL: f32 = tokens::LAYOUT_BUTTON_PRIMARY_PADDING_HORIZONTAL;
pub const BUTTON_SECONDARY_PADDING_VERTICAL: f32 = tokens::LAYOUT_BUTTON_SECONDARY_PADDING_VERTICAL;
pub const BUTTON_SECONDARY_PADDING_HORIZONTAL: f32 =
    tokens::LAYOUT_BUTTON_SECONDARY_PADDING_HORIZONTAL;
pub const BUTTON_NAVIGATION_PADDING_VERTICAL: f32 =
    tokens::LAYOUT_BUTTON_NAVIGATION_PADDING_VERTICAL;
pub const BUTTON_NAVIGATION_PADDING_HORIZONTAL: f32 =
    tokens::LAYOUT_BUTTON_NAVIGATION_PADDING_HORIZONTAL;
pub const BUTTON_BOOK_PADDING: f32 = tokens::LAYOUT_BUTTON_BOOK_PADDING;
pub const PROGRESS_GIRTH: f32 = tokens::LAYOUT_PROGRESS_GIRTH;

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
    pub fn from_stored(value: Option<&str>) -> Self {
        match value {
            Some("dark") => Self::Dark,
            Some("sepia") => Self::Sepia,
            _ => Self::Light,
        }
    }

    pub fn stored(self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Dark => "dark",
            Self::Sepia => "sepia",
        }
    }

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
            Self::Light => rgb8(tokens::READER_LIGHT_BACKGROUND),
            Self::Dark => rgbf(tokens::READER_DARK_BACKGROUND),
            Self::Sepia => rgbf(tokens::READER_SEPIA_BACKGROUND),
        }
    }

    pub fn text_color(self) -> Color {
        match self {
            Self::Light => rgbf(tokens::READER_LIGHT_TEXT),
            Self::Dark => rgbf(tokens::READER_DARK_TEXT),
            Self::Sepia => rgbf(tokens::READER_SEPIA_TEXT),
        }
    }

    pub fn link_color(self) -> Color {
        match self {
            Self::Light => rgb8(tokens::READER_LIGHT_LINK),
            Self::Dark => rgb8(tokens::READER_DARK_LINK),
            Self::Sepia => rgb8(tokens::READER_SEPIA_LINK),
        }
    }

    pub fn table_header_background(self) -> Color {
        match self {
            Self::Light => rgb8(tokens::READER_LIGHT_TABLE_HEADER_BACKGROUND),
            Self::Dark => rgb8(tokens::READER_DARK_TABLE_HEADER_BACKGROUND),
            Self::Sepia => rgb8(tokens::READER_SEPIA_TABLE_HEADER_BACKGROUND),
        }
    }

    fn search_highlight(self, current: bool) -> Color {
        match (self, current) {
            (Self::Light, false) => rgba8(
                tokens::READER_LIGHT_SEARCH_HIGHLIGHT.0,
                tokens::READER_LIGHT_SEARCH_HIGHLIGHT.1,
            ),
            (Self::Light, true) => rgba8(
                tokens::READER_LIGHT_SEARCH_CURRENT.0,
                tokens::READER_LIGHT_SEARCH_CURRENT.1,
            ),
            (Self::Dark, false) => rgba8(
                tokens::READER_DARK_SEARCH_HIGHLIGHT.0,
                tokens::READER_DARK_SEARCH_HIGHLIGHT.1,
            ),
            (Self::Dark, true) => rgba8(
                tokens::READER_DARK_SEARCH_CURRENT.0,
                tokens::READER_DARK_SEARCH_CURRENT.1,
            ),
            (Self::Sepia, false) => rgba8(
                tokens::READER_SEPIA_SEARCH_HIGHLIGHT.0,
                tokens::READER_SEPIA_SEARCH_HIGHLIGHT.1,
            ),
            (Self::Sepia, true) => rgba8(
                tokens::READER_SEPIA_SEARCH_CURRENT.0,
                tokens::READER_SEPIA_SEARCH_CURRENT.1,
            ),
        }
    }

    fn table_header_border(self) -> Color {
        match self {
            Self::Light => rgb8(tokens::READER_LIGHT_TABLE_HEADER_BORDER),
            Self::Dark => rgb8(tokens::READER_DARK_TABLE_HEADER_BORDER),
            Self::Sepia => rgb8(tokens::READER_SEPIA_TABLE_HEADER_BORDER),
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
            success: SUCCESS,
            warning: WARNING,
            danger: DANGER,
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
        .background(SIDEBAR_BACKGROUND)
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
        .background(READER_CONTROLS_BACKGROUND)
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
        .background(TAB_STRIP_BACKGROUND)
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
    container::Style::default().background(ALERT_BACKGROUND)
}

pub fn bookmarks_panel(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(PANEL_BACKGROUND)
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
        .background(SKELETON_BACKGROUND)
        .border(Border {
            radius: SKELETON_SUBTLE_RADIUS.into(),
            ..Border::default()
        })
}

pub fn book_cover(_theme: &Theme) -> container::Style {
    container::Style::default().shadow(Shadow {
        color: SHADOW_COVER,
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
        text_color: TEXT_ON_ACCENT,
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
        button::Status::Hovered | button::Status::Pressed => Some(Background::Color(BOOK_HOVER)),
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
            color: SHADOW_MENU,
            offset: Vector::new(0.0, 3.0),
            blur_radius: 10.0,
        })
}

pub fn book_menu_action(_theme: &Theme, status: button::Status) -> button::Style {
    let danger = DANGER;
    button::Style {
        background: matches!(status, button::Status::Hovered | button::Status::Pressed)
            .then_some(Background::Color(danger.scale_alpha(0.10))),
        text_color: danger,
        border: Border {
            radius: RADIUS_SMALL.into(),
            ..Border::default()
        },
        ..button::Style::default()
    }
}

pub fn modal_backdrop(_theme: &Theme) -> container::Style {
    container::Style::default().background(MODAL_BACKDROP)
}

pub fn modal(_theme: &Theme) -> container::Style {
    container::Style::default()
        .background(SURFACE)
        .color(TEXT)
        .border(Border {
            color: BORDER,
            width: 1.0,
            radius: RADIUS_SMALL.into(),
        })
        .shadow(Shadow {
            color: SHADOW_MODAL,
            offset: Vector::new(0.0, 5.0),
            blur_radius: 18.0,
        })
}

pub fn danger_button(_theme: &Theme, status: button::Status) -> button::Style {
    let danger = DANGER;
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
            radius: RADIUS_PROGRESS.into(),
            ..Border::default()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tracked token source, as text.
    ///
    /// The generated `theme_tokens.rs` is checked byte-for-byte against this
    /// file by `scripts/generate-theme-tokens.py --check`; the tests below
    /// instead compare the *mapped* application values with independently
    /// written expectations, so a wrong mapping cannot agree with itself.
    const TOKEN_SOURCE: &str = include_str!("../../../assets/theme/tokens.json");

    fn document() -> serde_json::Value {
        serde_json::from_str(TOKEN_SOURCE).expect("the token source is valid JSON")
    }

    fn json_f64(document: &serde_json::Value, path: &str) -> f64 {
        let mut node = document;
        for segment in path.split('.') {
            node = node
                .get(segment)
                .unwrap_or_else(|| panic!("the token source has no {path}"));
        }
        node.as_f64()
            .unwrap_or_else(|| panic!("{path} is not a number"))
    }

    fn json_str<'a>(document: &'a serde_json::Value, path: &str) -> &'a str {
        let mut node = document;
        for segment in path.split('.') {
            node = node
                .get(segment)
                .unwrap_or_else(|| panic!("the token source has no {path}"));
        }
        node.as_str()
            .unwrap_or_else(|| panic!("{path} is not a string"))
    }

    fn assert_color(actual: Color, red: f32, green: f32, blue: f32, alpha: f32) {
        assert_eq!(
            (actual.r, actual.g, actual.b, actual.a),
            (red, green, blue, alpha),
            "color mismatch"
        );
    }

    fn channel(value: u8) -> f32 {
        value as f32 / 255.0
    }

    /// The application palette, transcribed from the reference specification
    /// §3.1 and §3.2 rather than read back from the token source.
    #[test]
    fn application_palette_matches_the_pinned_iced_values() {
        assert_color(
            APP_BACKGROUND,
            channel(0xF4),
            channel(0xF2),
            channel(0xED),
            1.0,
        );
        assert_color(SURFACE, channel(0xFF), channel(0xFE), channel(0xFB), 1.0);
        assert_color(
            SURFACE_MUTED,
            channel(0xEC),
            channel(0xE9),
            channel(0xE1),
            1.0,
        );
        assert_color(TEXT, channel(0x28), channel(0x27), channel(0x24), 1.0);
        assert_color(TEXT_MUTED, channel(0x72), channel(0x6F), channel(0x67), 1.0);
        assert_color(BORDER, channel(0xD9), channel(0xD5), channel(0xCB), 1.0);
        assert_color(ACCENT, channel(0x4D), channel(0x5E), channel(0x86), 1.0);
        assert_color(
            ACCENT_HOVERED,
            channel(0x3F),
            channel(0x4F),
            channel(0x76),
            1.0,
        );
        assert_color(
            ACCENT_SOFT,
            channel(0xE2),
            channel(0xE6),
            channel(0xF0),
            1.0,
        );
        assert_color(DANGER, channel(0xA5), channel(0x43), channel(0x43), 1.0);
        assert_color(TEXT_ON_ACCENT, 1.0, 1.0, 1.0, 1.0);
        assert_color(
            SHADOW_HAIRLINE,
            channel(0x21),
            channel(0x20),
            channel(0x1E),
            0.08,
        );
        assert_eq!(RADIUS_SMALL, 6.0);
        assert_eq!(RADIUS_MEDIUM, 10.0);
    }

    /// The reader palettes, transcribed from the reference specification §3.3.
    #[test]
    fn reader_palettes_match_the_pinned_iced_values() {
        let light = ReaderTheme::Light.palette();
        assert_color(light.background, 1.0, 1.0, 1.0, 1.0);
        assert_color(light.text, 0.1, 0.1, 0.1, 1.0);
        assert_color(light.link, channel(0x17), channel(0x4E), channel(0xA6), 1.0);
        assert_color(
            light.table_header_background,
            channel(0xE8),
            channel(0xEE),
            channel(0xF8),
            1.0,
        );
        assert_color(
            light.table_header_border,
            channel(0x59),
            channel(0x6B),
            channel(0x89),
            1.0,
        );

        let dark = ReaderTheme::Dark.palette();
        assert_color(dark.background, 0.12, 0.12, 0.14, 1.0);
        assert_color(dark.text, 0.85, 0.85, 0.85, 1.0);
        assert_color(dark.link, channel(0x8A), channel(0xB4), channel(0xF8), 1.0);
        assert_color(
            dark.table_header_background,
            channel(0x2B),
            channel(0x34),
            channel(0x45),
            1.0,
        );
        assert_color(
            dark.table_header_border,
            channel(0x87),
            channel(0x97),
            channel(0xB2),
            1.0,
        );

        let sepia = ReaderTheme::Sepia.palette();
        assert_color(sepia.background, 0.96, 0.92, 0.84, 1.0);
        assert_color(sepia.text, 0.3, 0.2, 0.1, 1.0);
        assert_color(sepia.link, channel(0x68), channel(0x3D), channel(0x00), 1.0);
        assert_color(
            sepia.table_header_background,
            channel(0xE5),
            channel(0xD6),
            channel(0xBA),
            1.0,
        );
        assert_color(
            sepia.table_header_border,
            channel(0x6B),
            channel(0x54),
            channel(0x2E),
            1.0,
        );

        // Search highlights are translucent: assert the alpha each palette
        // declares, since a lost alpha changes the rendering but not the hue.
        assert_color(
            ReaderTheme::Light.palette().search_highlight,
            channel(0xFF),
            channel(0xF3),
            channel(0xA3),
            0.50,
        );
        assert_color(
            ReaderTheme::Light.palette().current_search_highlight,
            channel(0xFF),
            channel(0xE0),
            channel(0x66),
            0.45,
        );
        assert_color(
            ReaderTheme::Dark.palette().search_highlight,
            channel(0x4C),
            channel(0x3B),
            channel(0x00),
            0.55,
        );
        assert_color(
            ReaderTheme::Sepia.palette().current_search_highlight,
            channel(0xF4),
            channel(0xCF),
            channel(0x64),
            0.35,
        );
    }

    /// The token source keeps the owner-decided accent and the rejected brown
    /// stays out (plan decision 2).
    #[test]
    fn token_source_keeps_the_accent_and_rejects_the_historical_brown() {
        let document = document();
        assert_eq!(
            json_str(&document, "meta.reference_revision"),
            "1e54270a6bb24f15630ece336a0575bdbe5be113"
        );
        assert_eq!(json_str(&document, "app.accent"), "#4D5E86");

        // Check the token *values*, not the file text: the meta notes name the
        // rejected brown on purpose.
        fn collect_hex(node: &serde_json::Value, found: &mut Vec<String>) {
            match node {
                serde_json::Value::String(value) if value.starts_with('#') => {
                    found.push(value.to_uppercase());
                }
                serde_json::Value::String(value) if value.starts_with("rgba(#") => {
                    found.push(
                        value
                            .trim_start_matches("rgba(#")
                            .split(',')
                            .next()
                            .unwrap_or_default()
                            .to_uppercase(),
                    );
                }
                serde_json::Value::Object(map) => {
                    for value in map.values() {
                        collect_hex(value, found);
                    }
                }
                serde_json::Value::Array(values) => {
                    for value in values {
                        collect_hex(value, found);
                    }
                }
                _ => {}
            }
        }

        let mut hexes = Vec::new();
        collect_hex(&document, &mut hexes);
        assert!(!hexes.is_empty(), "the token source declares colors");
        for rejected in ["8A6338", "FFF4D6", "FFEEC4"] {
            assert!(
                !hexes.iter().any(|hex| hex.starts_with(rejected)),
                "the rejected pre-2C color #{rejected} must not reappear in a token value"
            );
        }
    }

    /// The constants the Iced application consumes agree with the token
    /// source, so a renamed or mis-transcribed token fails here.
    #[test]
    fn consumed_constants_match_the_token_source() {
        let document = document();
        assert_eq!(RADIUS_SMALL as f64, json_f64(&document, "radius.small"));
        assert_eq!(RADIUS_MEDIUM as f64, json_f64(&document, "radius.medium"));
        assert_eq!(
            PROGRESS_GIRTH as f64,
            json_f64(&document, "layout.progress.girth")
        );
        assert_eq!(
            BUTTON_LABEL_SIZE as f64,
            json_f64(&document, "layout.button.labelSize")
        );
        assert_eq!(
            BUTTON_PRIMARY_PADDING_VERTICAL as f64,
            json_f64(&document, "layout.button.primaryPaddingVertical")
        );
        assert_eq!(
            BUTTON_PRIMARY_PADDING_HORIZONTAL as f64,
            json_f64(&document, "layout.button.primaryPaddingHorizontal")
        );
        assert_eq!(
            BUTTON_SECONDARY_PADDING_VERTICAL as f64,
            json_f64(&document, "layout.button.secondaryPaddingVertical")
        );
        assert_eq!(
            BUTTON_SECONDARY_PADDING_HORIZONTAL as f64,
            json_f64(&document, "layout.button.secondaryPaddingHorizontal")
        );
        assert_eq!(
            BUTTON_NAVIGATION_PADDING_VERTICAL as f64,
            json_f64(&document, "layout.button.navigationPaddingVertical")
        );
        assert_eq!(
            BUTTON_NAVIGATION_PADDING_HORIZONTAL as f64,
            json_f64(&document, "layout.button.navigationPaddingHorizontal")
        );
        assert_eq!(
            BUTTON_BOOK_PADDING as f64,
            json_f64(&document, "layout.button.bookPadding")
        );
        assert_eq!(
            crate::app::READER_HORIZONTAL_PADDING as f64,
            json_f64(&document, "layout.reader.horizontalPadding")
        );
        assert_eq!(
            crate::app::READER_VERTICAL_CHROME as f64,
            json_f64(&document, "layout.reader.verticalChrome")
        );
        assert_eq!(
            crate::app::MIN_TWO_PAGE_WIDTH as f64,
            json_f64(&document, "layout.reader.spreadMinWidth")
        );
        assert_eq!(
            crate::app::PAGE_GUTTER as f64,
            json_f64(&document, "layout.reader.pageGutter")
        );
        assert_eq!(
            crate::app::BOOKMARKS_PANEL_WIDTH as f64,
            json_f64(&document, "layout.reader.bookmarksPanelWidth")
        );
        assert_eq!(
            crate::app::LIBRARY_PAGE_SIZE as f64,
            json_f64(&document, "layout.library.pageSize")
        );
        assert_eq!(
            crate::app::LIBRARY_COVER_MAX_WIDTH as f64,
            json_f64(&document, "layout.cover.maxWidth")
        );
        assert_eq!(
            crate::app::LIBRARY_COVER_MAX_HEIGHT as f64,
            json_f64(&document, "layout.cover.maxHeight")
        );
        assert_eq!(
            crate::app::LIBRARY_COVER_SOURCE_MAX_DIMENSION as f64,
            json_f64(&document, "layout.cover.sourceMaxDimension")
        );
    }

    /// The interface font families the Iced application selects are the token
    /// families, and the document-side math family stays equal to the same
    /// token even though it lives in `shosai-core`.
    #[test]
    fn interface_and_math_font_families_match_the_token_source() {
        let document = document();
        fn family_name(font: iced::Font) -> &'static str {
            match font.family {
                iced::font::Family::Name(name) => name,
                other => panic!("expected a named family, got {other:?}"),
            }
        }
        assert_eq!(
            family_name(crate::typography::INTER),
            json_str(&document, "type.family.ui.latin.iced")
        );
        assert_eq!(
            family_name(crate::typography::NOTO_SANS_JP),
            json_str(&document, "type.family.ui.japanese.iced")
        );
        assert_eq!(
            shosai_core::epub::pagination::math_layout::MATH_FONT_FAMILY,
            json_str(&document, "type.family.math.iced")
        );
    }

    /// Every source file the Iced application renders from, with its text.
    ///
    /// Each entry is the path relative to `src/`, so the allowlist below names
    /// a file the same way on every machine.
    fn application_sources() -> Vec<(String, String)> {
        fn walk(
            root: &std::path::Path,
            directory: &std::path::Path,
            sources: &mut Vec<(String, String)>,
        ) {
            let Ok(entries) = std::fs::read_dir(directory) else {
                return;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(root, &path, sources);
                } else if path.extension().is_some_and(|extension| extension == "rs")
                    && let (Ok(text), Ok(relative)) =
                        (std::fs::read_to_string(&path), path.strip_prefix(root))
                {
                    sources.push((relative.display().to_string(), text));
                }
            }
        }

        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut sources = Vec::new();
        walk(&root, &root, &mut sources);
        assert!(sources.len() > 10, "the source scan found too few files");
        sources
    }

    /// Source text with comments and string or character literals blanked out.
    ///
    /// Blanking replaces each skipped byte with a space, so line numbers and
    /// byte offsets survive and a finding can name its line. The scanner
    /// understands line comments, nested block comments, escaped strings, raw
    /// strings and character literals; lifetimes (`'a`) are not literals.
    fn strip_rust_noise(source: &str) -> String {
        let bytes = source.as_bytes();
        let mut out = vec![b' '; bytes.len()];
        let mut index = 0;
        while index < bytes.len() {
            let byte = bytes[index];
            match byte {
                b'/' if bytes.get(index + 1) == Some(&b'/') => {
                    while index < bytes.len() && bytes[index] != b'\n' {
                        index += 1;
                    }
                }
                b'/' if bytes.get(index + 1) == Some(&b'*') => {
                    let mut depth = 0;
                    while index < bytes.len() {
                        if bytes[index] == b'/' && bytes.get(index + 1) == Some(&b'*') {
                            depth += 1;
                            index += 2;
                            continue;
                        }
                        if bytes[index] == b'*' && bytes.get(index + 1) == Some(&b'/') {
                            depth -= 1;
                            index += 2;
                            if depth == 0 {
                                break;
                            }
                            continue;
                        }
                        if bytes[index] == b'\n' {
                            out[index] = b'\n';
                        }
                        index += 1;
                    }
                }
                b'r' | b'b' if is_raw_string_start(bytes, index) => {
                    // The prefix is `r`, `br` or `b`+`r`; `b"…"` is an ordinary
                    // byte string and is handled by the string branch below.
                    let prefix = if bytes[index] == b'b' { 2 } else { 1 };
                    let hashes = bytes[index + prefix..]
                        .iter()
                        .take_while(|byte| **byte == b'#')
                        .count();
                    index += prefix + hashes + 1;
                    loop {
                        if index >= bytes.len() {
                            break;
                        }
                        if bytes[index] == b'"'
                            && bytes[index + 1..]
                                .iter()
                                .take(hashes)
                                .all(|byte| *byte == b'#')
                        {
                            index += 1 + hashes;
                            break;
                        }
                        if bytes[index] == b'\n' {
                            out[index] = b'\n';
                        }
                        index += 1;
                    }
                }
                b'"' => {
                    index += 1;
                    while index < bytes.len() {
                        match bytes[index] {
                            b'\\' => index += 2,
                            b'"' => {
                                index += 1;
                                break;
                            }
                            b'\n' => {
                                out[index] = b'\n';
                                index += 1;
                            }
                            _ => index += 1,
                        }
                    }
                }
                b'\'' if is_char_literal(bytes, index) => {
                    index += 1;
                    while index < bytes.len() {
                        match bytes[index] {
                            b'\\' => index += 2,
                            b'\'' => {
                                index += 1;
                                break;
                            }
                            _ => index += 1,
                        }
                    }
                }
                _ => {
                    out[index] = byte;
                    index += 1;
                }
            }
        }
        String::from_utf8(out).unwrap_or_default()
    }

    /// True when the prefix at [index] starts a raw string literal.
    ///
    /// Only `r"…"`, `r#"…"#`, `br"…"` and `br#"…"#` are raw strings; an
    /// ordinary byte string (`b"…"`) has escapes and must not be treated as
    /// one, or an escaped quote would blank the code after it.
    fn is_raw_string_start(bytes: &[u8], index: usize) -> bool {
        let mut cursor = index;
        if bytes.get(cursor) == Some(&b'b') {
            cursor += 1;
        }
        if bytes.get(cursor) != Some(&b'r') {
            return false;
        }
        cursor += 1;
        while bytes.get(cursor) == Some(&b'#') {
            cursor += 1;
        }
        bytes.get(cursor) == Some(&b'"')
    }

    /// True when the quote at [index] opens a character literal, not a lifetime.
    fn is_char_literal(bytes: &[u8], index: usize) -> bool {
        match bytes.get(index + 1) {
            Some(b'\\') => bytes.get(index + 3) == Some(&b'\''),
            Some(_) => bytes.get(index + 2) == Some(&b'\''),
            None => false,
        }
    }

    /// Removes a top-level `mod tests { … }` block, keeping the rest.
    ///
    /// The block is matched by braces in the blanked source, so items after it
    /// are still scanned: a test module may build its own fixture colors, and
    /// nothing else may.
    fn strip_test_module(source: &str) -> String {
        let blanked = strip_rust_noise(source);
        let Some(start) = blanked.find("\nmod tests {") else {
            return source.to_string();
        };
        let bytes = blanked.as_bytes();
        let mut depth = 0usize;
        let mut index = start + 1;
        let mut end = blanked.len();
        while index < bytes.len() {
            match bytes[index] {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        end = index + 1;
                        break;
                    }
                }
                _ => {}
            }
            index += 1;
        }
        let mut result = String::with_capacity(source.len());
        result.push_str(&source[..start]);
        result.push_str(&source[end..]);
        result
    }

    /// The top-level arguments of the call whose `(` is at [open].
    fn call_arguments(source: &str, open: usize) -> Vec<String> {
        let bytes = source.as_bytes();
        let mut depth = 1usize;
        let mut index = open + 1;
        let mut current = String::new();
        let mut arguments = Vec::new();
        while index < bytes.len() {
            match bytes[index] {
                b'(' | b'[' | b'{' => {
                    depth += 1;
                    current.push(bytes[index] as char);
                }
                b')' | b']' | b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                    current.push(bytes[index] as char);
                }
                b',' if depth == 1 => {
                    arguments.push(current.split_whitespace().collect::<Vec<_>>().join(" "));
                    current.clear();
                }
                byte => current.push(byte as char),
            }
            index += 1;
        }
        let last = current.split_whitespace().collect::<Vec<_>>().join(" ");
        if !last.is_empty() {
            arguments.push(last);
        }
        arguments
    }

    /// True when [argument] is a bare numeric literal, optionally cast.
    ///
    /// A channel expression (`255 - rgb.0`, `1.0 as f32 * red`,
    /// `tokens::APP_TEXT.0`, `run.foreground[0]`) is a dynamic conversion, not
    /// a literal, so a data-derived color cannot hide behind a numeric prefix.
    /// The grammar accepts Rust's separators (`1_000`), exponents (`1e-1`),
    /// radix prefixes and numeric type suffixes (`255u8`), and an anchored
    /// `as <numeric type>` cast.
    fn is_numeric_literal(argument: &str) -> bool {
        let mut value = argument.trim();
        if let Some((body, cast)) = value.rsplit_once(" as ")
            && is_numeric_type(cast.trim())
        {
            value = body.trim();
        }
        if value.is_empty()
            || value.chars().any(|character| {
                character.is_whitespace()
                    || matches!(
                        character,
                        '*' | '/' | '?' | ':' | '(' | ')' | '[' | ']' | '{' | '}'
                    )
            })
        {
            return false;
        }
        let unsigned = value.strip_prefix('-').unwrap_or(value);
        // Radix forms take an integer suffix only: `0xffu8` is a literal, while
        // the `f`/`e` inside a hexadecimal body are digits, not a float suffix.
        if let Some(rest) = unsigned.strip_prefix("0x") {
            let (digits, suffix) = split_integer_suffix(rest);
            return is_integer_suffix(suffix)
                && !digits.is_empty()
                && digits.chars().all(|c| c.is_ascii_hexdigit() || c == '_');
        }
        if let Some(rest) = unsigned.strip_prefix("0b") {
            let (digits, suffix) = split_integer_suffix(rest);
            return is_integer_suffix(suffix)
                && !digits.is_empty()
                && digits.chars().all(|c| c == '0' || c == '1' || c == '_');
        }
        if let Some(rest) = unsigned.strip_prefix("0o") {
            let (digits, suffix) = split_integer_suffix(rest);
            return is_integer_suffix(suffix)
                && !digits.is_empty()
                && digits.chars().all(|c| ('0'..='7').contains(&c) || c == '_');
        }
        let (body, suffix) = split_numeric_suffix(unsigned);
        if !is_integer_suffix(suffix) && !matches!(suffix, "f32" | "f64") {
            return false;
        }
        let (mantissa, exponent) = match body.split_once(['e', 'E']) {
            Some((mantissa, exponent)) => (mantissa, Some(exponent)),
            None => (body, None),
        };
        if let Some(exponent) = exponent {
            let digits = exponent.strip_prefix(['+', '-']).unwrap_or(exponent);
            if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit() || c == '_') {
                return false;
            }
        }
        // A decimal literal starts with a digit; an identifier such as `_1` is
        // a value, not a literal.
        mantissa.chars().next().is_some_and(|c| c.is_ascii_digit())
            && mantissa.matches('.').count() <= 1
            && mantissa
                .chars()
                .all(|c| c.is_ascii_digit() || c == '.' || c == '_')
    }

    /// True when [value] names a Rust numeric type.
    fn is_numeric_type(value: &str) -> bool {
        is_integer_suffix(value) || matches!(value, "f32" | "f64")
    }

    /// True when [value] is an integer type suffix or the empty suffix.
    fn is_integer_suffix(value: &str) -> bool {
        matches!(
            value,
            "" | "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64" | "isize"
        )
    }

    /// Splits a numeric body from a trailing Rust numeric type suffix.
    fn split_numeric_suffix(value: &str) -> (&str, &str) {
        for suffix in [
            "f32", "f64", "usize", "isize", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64",
        ] {
            if let Some(body) = value.strip_suffix(suffix) {
                return (body, suffix);
            }
        }
        (value, "")
    }

    /// Splits a radix body from a trailing Rust integer type suffix.
    fn split_integer_suffix(value: &str) -> (&str, &str) {
        for suffix in [
            "usize", "isize", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64",
        ] {
            if let Some(body) = value.strip_suffix(suffix) {
                return (body, suffix);
            }
        }
        (value, "")
    }

    /// True when every argument of a call is a bare numeric literal.
    fn all_numeric_literals(arguments: &[String]) -> bool {
        !arguments.is_empty()
            && arguments
                .iter()
                .all(|argument| is_numeric_literal(argument))
    }

    /// Literal color constructions in Rust source: (line, description).
    ///
    /// Dynamic conversions are not findings: `Color::from_rgb8(rgb.0, …)` and
    /// `Color::from_rgba8(run.foreground[0], …)` derive a color from data.
    fn rust_color_literals(source: &str) -> Vec<(usize, String)> {
        let blanked = strip_rust_noise(source);
        let mut found = Vec::new();
        for (needle, takes_argument) in [
            ("Color::from_rgb8", true),
            ("Color::from_rgba8", true),
            ("Color::from_rgb", true),
            ("Color::from_rgba", true),
            ("Color::WHITE", false),
            ("Color::BLACK", false),
        ] {
            // `Color::TRANSPARENT` is deliberately not a marker: it is the
            // absence of paint (an unselected tab's background), not a design
            // value that could carry an unapproved hue.
            let mut from = 0;
            while let Some(offset) = blanked[from..].find(needle) {
                let start = from + offset;
                from = start + needle.len();
                let line = blanked[..start].matches('\n').count() + 1;
                if !takes_argument {
                    found.push((line, needle.to_string()));
                    continue;
                }
                let rest = &blanked[from..];
                let Some(open) = rest.find('(') else {
                    continue;
                };
                if !rest[..open].trim().is_empty() {
                    continue; // e.g. `Color::from_rgb8` matching inside `from_rgb8`
                }
                let arguments = call_arguments(&blanked, from + open);
                if all_numeric_literals(&arguments) {
                    found.push((line, format!("{needle}({})", arguments.join(", "))));
                }
            }
        }
        found.sort();
        found
    }

    #[test]
    fn the_literal_color_scan_recognizes_literals_and_ignores_dynamic_conversions() {
        let source = r#"
            // Color::from_rgb8(0x11, 0x22, 0x33)
            /* Color::from_rgb8(0x11, 0x22, 0x33) */
            let message = "Color::from_rgb8(0x11, 0x22, 0x33)";
            let a = Color::from_rgb8(255, 0, 0);
            let b = Color::from_rgba8(
                0x11,
                0x22,
                0x33,
                0.5,
            );
            let c = Color::from_rgb(0.5, 0.5, 0.5);
            let d = Color::WHITE;
            let e = Color::from_rgba8(
                run.foreground[0],
                run.foreground[1],
                run.foreground[2],
                run.foreground[3] as f32 / 255.0,
            );
            let f = Color::from_rgb8(tokens::APP_TEXT.0, tokens::APP_TEXT.1, tokens::APP_TEXT.2);
            let g = Color::from_rgb8(color[0], color[1], color[2]);
            let h = Color::from_rgb8(255 - rgb.0, 255 - rgb.1, 255 - rgb.2);
            let i = Color::from_rgb(1.0 as f32 * red, 0.0, 0.0);
            let j = Color::from_rgb8(255u8, 0u8, 0u8);
            let k = Color::from_rgb(1e-1, 0.0, 0.0);
            let l = Color::from_rgb(1e+0, 0.0, 0.0);
            let m = Color::from_rgb8(0xffu8, 0u8, 0u8);
            fn tint(_1: f32) -> Color {
                Color::from_rgb(_1, 0.0, 0.0)
            }
            let bytes = b"\\\"";
            let after_bytes = Color::BLACK;
            let raw = r"Color::from_rgb8(0x11, 0x22, 0x33)";
            let after_raw = Color::from_rgb8(0x01, 0x02, 0x03);
            let lifetime = 'a;
            let character = '/';
        "#;
        let found = rust_color_literals(source);
        assert_eq!(
            found.len(),
            10,
            "expected the ten literal constructions, got {found:?}"
        );
        assert!(found.iter().any(|(_, text)| text == "Color::WHITE"));
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgb8(255"))
        );
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgba8(0x11"))
        );
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgb(0.5"))
        );
        assert!(
            found.iter().any(|(_, text)| text == "Color::BLACK"),
            "code after an ordinary byte string is still production code"
        );
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgb8(0x01")),
            "code after a raw string is still production code"
        );
        assert!(
            !found
                .iter()
                .any(|(_, text)| text.contains("255 -") || text.contains("as f32 *")),
            "a channel expression is a dynamic conversion, not a literal"
        );
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgb8(255u8")),
            "a suffixed integer literal is still a literal"
        );
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgb(1e-1")),
            "an exponent literal is still a literal"
        );
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgb(1e+0")),
            "a signed exponent literal is still a literal"
        );
        assert!(
            found
                .iter()
                .any(|(_, text)| text.starts_with("Color::from_rgb8(0xffu8")),
            "a suffixed hexadecimal literal is still a literal"
        );
    }

    #[test]
    fn the_test_module_strip_keeps_later_items() {
        let source = "fn before() {}\nmod tests {\n    fn fixture() { let _ = Color::WHITE; }\n}\nfn after() { let _ = Color::WHITE; }\n";
        let found = rust_color_literals(&strip_test_module(source));
        assert_eq!(
            found.len(),
            1,
            "only the item after the test module is production code"
        );
    }

    /// Literal theme colors may not be reintroduced outside the token source.
    ///
    /// The generated module holds the values and `theme.rs` converts them; a
    /// literal in any other application module bypasses the shared source.
    /// Dynamic conversions from a palette, a token or a syntax-highlight span
    /// are not literals. A trailing `mod tests` block is not scanned: a test
    /// module may build its own fixture colors.
    #[test]
    fn no_literal_theme_colors_remain_in_application_modules() {
        /// Reviewed exceptions: file, marker and the exact occurrence count.
        const ALLOWED: [(&str, &str, usize); 1] = [("epub/native_text.rs", "Color::BLACK", 1)];

        let mut found: Vec<(String, usize, String)> = Vec::new();
        for (relative, text) in application_sources() {
            if relative.ends_with("theme_tokens.rs") {
                continue; // the generated token table
            }
            let production = strip_test_module(&text);
            for (line, marker) in rust_color_literals(&production) {
                found.push((relative.clone(), line, marker));
            }
        }

        let unexpected: Vec<String> = found
            .iter()
            .filter(|(path, _, marker)| {
                !ALLOWED.iter().any(|(allowed_path, allowed_marker, _)| {
                    path == allowed_path && marker == allowed_marker
                })
            })
            .map(|(path, line, marker)| format!("{path}:{line}: {marker}"))
            .collect();
        let wrong_count: Vec<String> = ALLOWED
            .iter()
            .filter_map(|(path, marker, expected)| {
                let count = found
                    .iter()
                    .filter(|(found_path, _, found_marker)| {
                        found_path == path && found_marker == marker
                    })
                    .count();
                (count != *expected)
                    .then(|| format!("{path}: {marker} occurs {count} times, expected {expected}"))
            })
            .collect();
        assert!(
            unexpected.is_empty() && wrong_count.is_empty(),
            "literal theme colors changed.\nnew or unlisted:\n  {}\nexception counts:\n  {}\nreviewed exceptions:\n  {}",
            unexpected.join("\n  "),
            wrong_count.join("\n  "),
            ALLOWED
                .iter()
                .map(|(path, marker, count)| format!("  {path}: {marker} x{count}"))
                .collect::<Vec<_>>()
                .join("\n"),
        );
    }
}
