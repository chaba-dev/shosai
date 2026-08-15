mod app;
mod epub;
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
    iced::application(app::boot, app::update, app::view)
        .title(app::title)
        .theme(theme::application())
        .subscription(app::subscription)
        .window(iced::window::Settings {
            icon: window_icon(),
            ..iced::window::Settings::default()
        })
        .exit_on_close_request(false)
        .centered()
        .window_size((900.0, 700.0))
        .run()
}
