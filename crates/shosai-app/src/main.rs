mod app;
mod epub;
mod i18n;
mod pdf;
mod theme;
mod widgets;

const APPLICATION_ICON: &[u8] = if option_env!("SHOSAI_DEV_BUILD").is_some() {
    include_bytes!("../../../assets/shosai-dev-icon.png")
} else {
    include_bytes!("../../../assets/shosai-icon.png")
};

fn window_icon() -> Option<iced::window::Icon> {
    let icon = image::load_from_memory(APPLICATION_ICON).ok()?.into_rgba8();
    let (width, height) = icon.dimensions();
    iced::window::icon::from_rgba(icon.into_raw(), width, height).ok()
}

#[cfg(target_os = "macos")]
fn set_macos_application_icon() {
    use objc2::{AnyThread, MainThreadMarker};
    use objc2_app_kit::{NSApplication, NSImage};
    use objc2_foundation::NSData;

    let Some(main_thread) = MainThreadMarker::new() else {
        return;
    };
    let data = NSData::with_bytes(APPLICATION_ICON);
    let Some(icon) = NSImage::initWithData(NSImage::alloc(), &data) else {
        return;
    };

    unsafe {
        NSApplication::sharedApplication(main_thread).setApplicationIconImage(Some(&icon));
    }
}

fn application_icon_task(window_id: iced::window::Id) -> iced::Task<app::Message> {
    #[cfg(target_os = "macos")]
    {
        use iced::window;

        window::run(window_id, |_| set_macos_application_icon()).discard()
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = window_id;
        iced::Task::none()
    }
}

fn main() -> iced::Result {
    let benchmark_size = std::env::var("SHOSAI_PERF_ACTION")
        .ok()
        .filter(|action| matches!(action.as_str(), "warm" | "chapter" | "relayout"))
        .and_then(|_| std::env::var("SHOSAI_PERF_WIDTH").ok())
        .and_then(|value| value.parse().ok())
        .map(|width| iced::Size::new(width, 700.0));
    let window_size = benchmark_size.unwrap_or_else(|| iced::Size::new(900.0, 700.0));
    iced::application(app::boot, app::update, app::view)
        .title(app::title)
        .theme(theme::application())
        .subscription(app::subscription)
        .font(epub::math_layout::MATH_FONT_BYTES)
        .window(iced::window::Settings {
            icon: window_icon(),
            size: window_size,
            min_size: benchmark_size,
            max_size: benchmark_size,
            resizable: benchmark_size.is_none(),
            ..iced::window::Settings::default()
        })
        .exit_on_close_request(false)
        .centered()
        .run()
}
