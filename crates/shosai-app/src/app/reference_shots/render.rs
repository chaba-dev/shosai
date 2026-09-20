//! Offscreen software rasterization of the production Iced view.
//!
//! The harness builds the real `app::view` element and draws it with
//! `iced_tiny_skia`, the same renderer Iced uses as its software fallback, into
//! a `tiny_skia::Pixmap`. No window, X server or GPU is involved: the capture
//! path is deterministic and runs in-process.
//!
//! Fidelity notes (recorded in the manifest as well):
//!
//! - the bundled application fonts are loaded into Iced's global font system
//!   (`iced_graphics::text::font_system`) exactly like `iced::application(..)
//!   .font(..)`, and the renderer's default font is `typography::INTER`, the
//!   same default the application sets;
//! - the renderer style (`text_color`, `background_color`) comes from
//!   `iced::theme::Base::base`, which is what `iced_winit` uses for a program
//!   that does not override `Program::style`;
//! - the theme is `theme::application()`, the application's own theme;
//! - the interface receives the same `window::Event::RedrawRequested` event the
//!   real `iced_winit` event loop delivers before a frame, repeated until it
//!   stops producing messages or layout invalidations, exactly like
//!   `iced_winit::run_instance`. That event is what latches each widget's
//!   interaction status (button and text-input styles are drawn from it), so an
//!   enabled control draws enabled and a disabled control draws disabled;
//! - the whole element is laid out and drawn into a fresh cache, exactly like
//!   the first frame of a real window; the interface tree then stays alive for
//!   the frames a view request causes, like a real window keeps it.

use std::borrow::Cow;
use std::sync::OnceLock;

use iced::Size;
use iced_tiny_skia::graphics::Viewport;
use iced_tiny_skia::graphics::text::font_system;

use super::super::{Message, State, view};
use crate::{epub, theme as app_theme, typography};

/// One rendered capture.
pub(crate) struct RenderedImage {
    pub(crate) png: Vec<u8>,
    pub(crate) physical_width: u32,
    pub(crate) physical_height: u32,
}

/// Matches `iced::Settings::default().default_text_size`.
pub(crate) const DEFAULT_TEXT_SIZE: f32 = 16.0;

/// The bundled UI font the application sets as its default font.
pub(crate) const DEFAULT_FONT_NAME: &str = "Inter Variable";

/// Upper bound on redraw events, matching `iced_winit`'s own guard against a
/// view that keeps invalidating its layout.
pub(crate) const MAX_REDRAW_EVENTS: usize = 3;

/// Loads the bundled application fonts into Iced's global font system.
///
/// `FontSystem::load_font` de-duplicates borrowed byte slices by address, so
/// this is idempotent and can be called for every capture.
pub(crate) fn install_application_fonts() {
    static INSTALLED: OnceLock<()> = OnceLock::new();
    INSTALLED.get_or_init(|| {
        let mut system = font_system().write().expect("lock Iced font system");
        system.load_font(Cow::Borrowed(typography::INTER_BYTES));
        system.load_font(Cow::Borrowed(typography::NOTO_SANS_JP_BYTES));
        system.load_font(Cow::Borrowed(epub::math_layout::MATH_FONT_BYTES));
    });
}

/// The bytes of every application font the captures load, with their SHA-256,
/// so the manifest pins the exact typography toolchain used. Iced's built-in
/// icon font is not listed: it is pinned by the locked dependencies instead.
pub(crate) fn font_identities() -> Vec<(&'static str, String)> {
    vec![
        (
            "InterVariable.ttf (type.ui.family.latin)",
            super::fixtures::sha256_hex(typography::INTER_BYTES),
        ),
        (
            "NotoSansJP-Variable.ttf (type.ui.family.japanese)",
            super::fixtures::sha256_hex(typography::NOTO_SANS_JP_BYTES),
        ),
        (
            "math font (type.math.family)",
            super::fixtures::sha256_hex(epub::math_layout::MATH_FONT_BYTES),
        ),
    ]
}

/// The renderer's font database: `(in-memory faces, file-backed faces)`.
///
/// The capture entry point pins font discovery, so this must report only
/// in-memory faces: the application fonts and Iced's built-ins. A file-backed
/// face means a host font became eligible, which would make the rendered pixels
/// depend on the machine's installed fonts even though every application font
/// hash in the manifest still matched.
pub(crate) fn font_database_faces() -> (usize, usize) {
    install_application_fonts();
    let mut system = font_system().write().expect("lock Iced font system");
    let mut in_memory = 0;
    let mut file_backed = 0;
    for face in system.raw().db().faces() {
        match &face.source {
            cosmic_text::fontdb::Source::Binary(_) => in_memory += 1,
            _ => file_backed += 1,
        }
    }
    (in_memory, file_backed)
}

/// Why a font database is not renderable, if it is not.
///
/// Pure, so the regression test can exercise both directions without needing a
/// machine that has host fonts.
pub(crate) fn font_database_problems(in_memory: usize, file_backed: usize) -> Vec<String> {
    let mut problems = Vec::new();
    if in_memory == 0 {
        problems.push("the renderer's font database is empty".to_owned());
    }
    if file_backed > 0 {
        problems.push(format!(
            "the renderer can see {file_backed} file-backed font face(s), so host fonts would \
             change the captures"
        ));
    }
    problems
}

/// Refuse to render when a host font is visible to the renderer.
pub(crate) fn assert_controlled_font_database() -> anyhow::Result<()> {
    let (in_memory, file_backed) = font_database_faces();
    let problems = font_database_problems(in_memory, file_backed);
    anyhow::ensure!(
        problems.is_empty(),
        "the renderer's font database is not controlled ({}). Run the documented entry point \
         `make reference-shots`, which pins font discovery (see docs/reference-captures.md).",
        problems.join("; ")
    );
    Ok(())
}

/// The redraw event `iced_winit` feeds the interface before every frame.
///
/// Widget interaction state (button and text-input styling) is latched while
/// handling it, so a capture that skips it renders every control with the
/// neutral fallback style.
fn redraw_event() -> iced::Event {
    iced::Event::Window(iced::window::Event::RedrawRequested(
        iced::time::Instant::now(),
    ))
}

/// Physical (device) pixel size of a `width`×`height` logical client at `dpr`.
///
/// This is the one place the capture's image size is derived, so the manifest
/// entry of an unrendered expectation and the raster a render produces cannot
/// disagree.
pub(crate) fn physical_size(width: f32, height: f32, dpr: f32) -> (u32, u32) {
    (
        (width * dpr).round().max(1.0) as u32,
        (height * dpr).round().max(1.0) as u32,
    )
}

/// One frame pass over the production view.
pub(crate) enum FrameOutcome {
    /// The frame is a fixed point: this is the capture image.
    Settled(RenderedImage),
    /// The view produced messages while handling the redraw event. In the
    /// running application those are dispatched and the window draws again, so
    /// the caller dispatches them through the production `update` and passes the
    /// returned interface cache to the next frame.
    Requests(Vec<Message>, iced_runtime::user_interface::Cache),
}

/// Build the production view, deliver the frame's redraw event like a real
/// window's event loop, and either draw the settled image or report the
/// messages the view asked for.
pub(crate) fn render_frame(
    state: &State,
    width: f32,
    height: f32,
    dpr: f32,
    cache: iced_runtime::user_interface::Cache,
) -> FrameOutcome {
    install_application_fonts();

    let theme = app_theme::application();
    // `iced_winit` builds exactly this: the program style paints the background
    // and the renderer style only carries the text color.
    let program_style = iced::theme::Base::base(&theme);
    let renderer_style = iced::advanced::renderer::Style {
        text_color: program_style.text_color,
    };

    let logical = Size::new(width, height);
    let (physical_width, physical_height) = physical_size(width, height, dpr);
    let physical = Size::new(physical_width, physical_height);
    let viewport = Viewport::with_physical_size(physical, dpr);

    let mut renderer = iced::Renderer::Secondary(iced_tiny_skia::Renderer::new(
        typography::INTER,
        iced::Pixels(DEFAULT_TEXT_SIZE),
    ));

    let element = view(state);
    let mut interface = iced_runtime::UserInterface::build(element, logical, cache, &mut renderer);

    // Mirror `iced_winit::run_instance`: deliver the redraw event, repeating
    // while it produces messages or invalidates the layout. That event is what
    // latches widget interaction status, and it is where a visible library card
    // without a decoded cover asks for it.
    let mut clipboard = iced::advanced::clipboard::Null;
    let mut produced = Vec::new();
    for _ in 0..MAX_REDRAW_EVENTS {
        let event = redraw_event();
        let produced_before = produced.len();
        let (state, _) = interface.update(
            std::slice::from_ref(&event),
            iced::mouse::Cursor::Unavailable,
            &mut renderer,
            &mut clipboard,
            &mut produced,
        );
        if produced.len() == produced_before && !state.has_layout_changed() {
            break;
        }
    }
    if !produced.is_empty() {
        return FrameOutcome::Requests(produced, interface.into_cache());
    }

    let mut pixmap =
        tiny_skia::Pixmap::new(physical.width, physical.height).expect("capture pixmap allocation");
    let mut clip_mask = tiny_skia::Mask::new(physical.width, physical.height)
        .expect("capture clip mask allocation");

    interface.draw(
        &mut renderer,
        &theme,
        &renderer_style,
        iced::mouse::Cursor::Unavailable,
    );

    let iced::Renderer::Secondary(tiny_skia) = &mut renderer else {
        unreachable!("the capture renderer is always the tiny-skia secondary renderer");
    };
    tiny_skia.draw(
        &mut pixmap.as_mut(),
        &mut clip_mask,
        &viewport,
        &[iced::Rectangle::with_size(logical)],
        program_style.background_color,
    );

    let png = pixmap.encode_png().expect("capture PNG encoding");
    FrameOutcome::Settled(RenderedImage {
        png,
        physical_width: physical.width,
        physical_height: physical.height,
    })
}
