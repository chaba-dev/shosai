mod app;
mod epub;

fn main() -> iced::Result {
    iced::application(app::boot, app::update, app::view)
        .title(app::title)
        .subscription(app::subscription)
        .exit_on_close_request(false)
        .centered()
        .window_size((900.0, 700.0))
        .run()
}
