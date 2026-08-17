//! Gate 0 spike for embedding a locked-down Wry child inside an Iced window.
//!
//! This is deliberately isolated behind the `epub-wry-spike` feature. It is a
//! feasibility harness, not a production EPUB renderer.

use std::borrow::Cow;
use std::cell::RefCell;

use iced::widget::{button, column, container, row, text};
use iced::{Element, Length, Size, Subscription, Task, window};
use wry::dpi::{LogicalPosition, LogicalSize};
use wry::http::{Request, Response};
use wry::raw_window_handle::{HandleError, HasWindowHandle, RawWindowHandle, WindowHandle};
use wry::{NewWindowResponse, Rect, WebView, WebViewBuilder};

const HEADER_HEIGHT: f32 = 112.0;
const PADDING: f32 = 24.0;

thread_local! {
    static WEBVIEW: RefCell<Option<WebView>> = const { RefCell::new(None) };
}

#[derive(Debug, Default)]
struct State {
    window: Option<window::Id>,
    size: Size,
    status: String,
}

#[derive(Debug, Clone)]
enum Message {
    WindowEvent(window::Id, window::Event),
    WebViewCreated(Result<(), String>),
    WebViewResized(Result<(), String>),
    FocusWebView,
}

#[derive(Clone, Copy)]
struct ParentHandle(RawWindowHandle);

impl HasWindowHandle for ParentHandle {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        // SAFETY: Wry consumes this handle while the Iced-owned parent window
        // remains alive. The wrapper never outlives the window::run callback.
        Ok(unsafe { WindowHandle::borrow_raw(self.0) })
    }
}

fn main() -> iced::Result {
    iced::application(boot, update, view)
        .title("Shōsai EPUB Wry spike")
        .subscription(subscription)
        .window_size((900.0, 700.0))
        .run()
}

fn boot() -> (State, Task<Message>) {
    (
        State {
            status: "waiting for Iced window".into(),
            ..State::default()
        },
        Task::none(),
    )
}

fn subscription(_state: &State) -> Subscription<Message> {
    window::events().map(|(id, event)| Message::WindowEvent(id, event))
}

fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::WindowEvent(id, window::Event::Opened { size, .. }) => {
            state.window = Some(id);
            state.size = size;
            state.status = "creating locked-down child webview".into();
            create_webview(id, size)
        }
        Message::WindowEvent(id, window::Event::Resized(size)) if state.window == Some(id) => {
            state.size = size;
            resize_webview(id, size)
        }
        Message::WindowEvent(id, window::Event::Closed) if state.window == Some(id) => {
            WEBVIEW.with(|slot| slot.borrow_mut().take());
            Task::none()
        }
        Message::WindowEvent(_, _) => Task::none(),
        Message::WebViewCreated(result) => {
            state.status = match result {
                Ok(()) => "embedded; deny-by-default handlers configured".into(),
                Err(error) => format!("webview creation failed: {error}"),
            };
            Task::none()
        }
        Message::WebViewResized(result) => {
            if let Err(error) = result {
                state.status = format!("webview resize failed: {error}");
            }
            Task::none()
        }
        Message::FocusWebView => {
            WEBVIEW.with(|slot| {
                if let Some(webview) = slot.borrow().as_ref() {
                    let _ = webview.focus();
                }
            });
            Task::none()
        }
    }
}

fn view(state: &State) -> Element<'_, Message> {
    let controls = row![
        text("EPUB Wry child-view spike").size(24),
        button("Focus webview").on_press(Message::FocusWebView),
    ]
    .spacing(20);

    column![
        container(column![controls, text(&state.status)].spacing(8))
            .height(HEADER_HEIGHT)
            .padding([20, PADDING as u16]),
        container(text("Native child webview overlays this placeholder"))
            .width(Length::Fill)
            .height(Length::Fill)
            .center(Length::Fill),
    ]
    .into()
}

fn create_webview(id: window::Id, size: Size) -> Task<Message> {
    window::run(id, move |window| {
        let raw = window
            .window_handle()
            .map_err(|error| error.to_string())?
            .as_raw();
        let parent = ParentHandle(raw);
        let webview = WebViewBuilder::new()
            .with_bounds(webview_bounds(size))
            .with_custom_protocol("shosai".into(), serve_epub_resource)
            .with_url("shosai://book/chapter.xhtml")
            .with_javascript_disabled()
            .with_navigation_handler(|url| is_allowed_navigation(&url))
            .with_download_started_handler(|_, _| false)
            .with_new_window_req_handler(|_, _| NewWindowResponse::Deny)
            .build_as_child(&parent)
            .map_err(|error| error.to_string())?;

        WEBVIEW.with(|slot| *slot.borrow_mut() = Some(webview));
        Ok(())
    })
    .map(Message::WebViewCreated)
}

fn resize_webview(id: window::Id, size: Size) -> Task<Message> {
    window::run(id, move |_| {
        WEBVIEW.with(|slot| {
            if let Some(webview) = slot.borrow().as_ref() {
                webview
                    .set_bounds(webview_bounds(size))
                    .map_err(|error| error.to_string())?;
            }
            Ok(())
        })
    })
    .map(Message::WebViewResized)
}

fn webview_bounds(size: Size) -> Rect {
    Rect {
        position: LogicalPosition::new(PADDING, HEADER_HEIGHT).into(),
        size: LogicalSize::new(
            (size.width - PADDING * 2.0).max(1.0),
            (size.height - HEADER_HEIGHT - PADDING).max(1.0),
        )
        .into(),
    }
}

fn is_allowed_navigation(url: &str) -> bool {
    url == "shosai://book"
        || url.starts_with("shosai://book/")
        || url == "http://shosai.book"
        || url.starts_with("http://shosai.book/")
}

fn serve_epub_resource(
    _webview_id: wry::WebViewId<'_>,
    request: Request<Vec<u8>>,
) -> Response<Cow<'static, [u8]>> {
    let path = request.uri().path();
    let (status, content_type, body) = if path.ends_with("chapter.xhtml") || path == "/" {
        (200, "text/html; charset=utf-8", SPIKE_CHAPTER.as_bytes())
    } else {
        (404, "text/plain", b"not found" as &[u8])
    };

    Response::builder()
        .status(status)
        .header("Content-Type", content_type)
        .header("Content-Security-Policy", SPIKE_CSP)
        .body(Cow::Owned(body.to_vec()))
        .expect("static spike response must be valid")
}

const SPIKE_CSP: &str = "default-src 'none'; style-src 'unsafe-inline' shosai:; img-src shosai: data:; font-src shosai:";

const SPIKE_CHAPTER: &str = r#"<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta charset="utf-8" />
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline' shosai:; img-src shosai: data:; font-src shosai:" />
  <style>
    :root { color-scheme: light dark; font-family: serif; font-size: 20px; }
    body { max-width: 42rem; margin: 2rem auto; line-height: 1.5; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid currentColor; padding: .4rem; }
  </style>
</head>
<body>
  <h1>Renderer spike chapter</h1>
  <p>This page came from the in-memory <code>shosai:</code> protocol.</p>
  <table><caption>Table fidelity</caption><tr><th>Feature</th><th>State</th></tr><tr><td>rowspan</td><td rowspan="2">visible</td></tr><tr><td>caption</td></tr></table>
  <math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><mfrac><mi>a</mi><mi>b</mi></mfrac></math>
  <p><a href="https://example.invalid/blocked">Remote navigation must be denied</a></p>
</body>
</html>"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn navigation_policy_allows_only_book_protocol() {
        assert!(is_allowed_navigation("shosai://book/chapter.xhtml"));
        assert!(is_allowed_navigation("http://shosai.book/chapter.xhtml"));
        assert!(!is_allowed_navigation("shosai://other/chapter.xhtml"));
        assert!(!is_allowed_navigation("http://shosai.evil/chapter.xhtml"));
        assert!(!is_allowed_navigation("https://example.com"));
        assert!(!is_allowed_navigation("file:///etc/passwd"));
        assert!(!is_allowed_navigation("data:text/html,hello"));
    }

    #[test]
    fn protocol_serves_only_known_resources_with_csp() {
        let chapter = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/chapter.xhtml")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(chapter.status(), 200);
        assert_eq!(chapter.headers()["Content-Security-Policy"], SPIKE_CSP);
        assert!(chapter.body().starts_with(b"<!DOCTYPE html>"));

        let missing = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/missing.css")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(missing.status(), 404);
    }
}
