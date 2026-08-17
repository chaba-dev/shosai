//! Gate 0 spike for embedding a locked-down Wry child inside an Iced window.
//!
//! This is deliberately isolated behind the `epub-wry-spike` feature. It is a
//! feasibility harness, not a production EPUB renderer.

use std::borrow::Cow;
use std::cell::RefCell;
use std::collections::HashMap;

use iced::widget::{button, column, container, row, text};
use iced::{Element, Length, Size, Subscription, Task, window};
use shosai_core::epub::EpubDoc;
use wry::dpi::{LogicalPosition, LogicalSize};
use wry::http::{Request, Response};
use wry::raw_window_handle::{HandleError, HasWindowHandle, RawWindowHandle, WindowHandle};
use wry::{NewWindowResponse, Rect, WebView, WebViewBuilder};

const HEADER_HEIGHT: f32 = 112.0;
const PADDING: f32 = 24.0;

thread_local! {
    static WEBVIEW: RefCell<Option<WebView>> = const { RefCell::new(None) };
    static BOOK: RefCell<Option<SpikeBook>> = const { RefCell::new(None) };
}

#[derive(Debug)]
struct SpikeResource {
    content_type: String,
    body: Vec<u8>,
}

#[derive(Debug)]
struct SpikeBook {
    start_url: String,
    resources: HashMap<String, SpikeResource>,
    requests: Vec<String>,
}

impl SpikeBook {
    fn from_epub_bytes(bytes: Vec<u8>) -> Result<Self, String> {
        let epub = EpubDoc::from_bytes(bytes).map_err(|error| error.to_string())?;
        let first_chapter = epub
            .content
            .chapters
            .first()
            .ok_or_else(|| "EPUB has no readable spine chapter".to_string())?;
        let start_url = format!("shosai://book/{}", first_chapter.path);
        let mut resources = HashMap::new();

        for chapter in &epub.content.chapters {
            resources.insert(
                chapter.path.clone(),
                SpikeResource {
                    // WebKit currently rejects the fixture when served as XML;
                    // retaining HTML here keeps that MIME question visible.
                    content_type: "text/html; charset=utf-8".into(),
                    body: chapter.content.as_bytes().to_vec(),
                },
            );
        }
        for item in epub.content.manifest.values() {
            if let Some(body) = epub.content.resources.get(&item.href) {
                resources.insert(
                    item.href.clone(),
                    SpikeResource {
                        content_type: item.media_type.clone(),
                        body: body.clone(),
                    },
                );
            }
        }
        resources.insert(
            "_spike/conformance.xhtml".into(),
            SpikeResource {
                content_type: "text/html; charset=utf-8".into(),
                body: SPIKE_CHAPTER.as_bytes().to_vec(),
            },
        );

        Ok(Self {
            start_url,
            resources,
            requests: Vec::new(),
        })
    }
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
        let book = SpikeBook::from_epub_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )?;
        let start_url = if std::env::var("SHOSAI_WRY_SPIKE_PAGE").as_deref() == Ok("conformance") {
            "shosai://book/_spike/conformance.xhtml".to_string()
        } else {
            book.start_url.clone()
        };
        BOOK.with(|slot| *slot.borrow_mut() = Some(book));
        let raw = window
            .window_handle()
            .map_err(|error| error.to_string())?
            .as_raw();
        let parent = ParentHandle(raw);
        let webview = WebViewBuilder::new()
            .with_bounds(webview_bounds(size))
            .with_custom_protocol("shosai".into(), serve_epub_resource)
            .with_url(&start_url)
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
    let uri = request.uri().to_string();
    eprintln!("wry-spike-request uri={uri}");
    let path = request.uri().path().trim_start_matches('/');
    let response = BOOK.with(|slot| {
        let mut slot = slot.borrow_mut();
        let book = slot.as_mut()?;
        book.requests.push(uri);
        (request.uri().host() == Some("book"))
            .then(|| book.resources.get(path))
            .flatten()
            .map(|resource| (resource.content_type.clone(), resource.body.clone()))
    });
    let (status, content_type, body) = response.map_or_else(
        || (404, "text/plain".to_string(), b"not found".to_vec()),
        |(content_type, body)| (200, content_type, body),
    );

    Response::builder()
        .status(status)
        .header("Content-Type", &content_type)
        .header("Content-Security-Policy", SPIKE_CSP)
        .body(Cow::Owned(body))
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

    fn install_sample_book() {
        let book = SpikeBook::from_epub_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("sample fixture should load");
        BOOK.with(|slot| *slot.borrow_mut() = Some(book));
    }

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
    fn protocol_serves_epub_chapters_and_manifest_resources_with_csp() {
        install_sample_book();
        let chapter = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/OEBPS/chapter1.xhtml")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(chapter.status(), 200);
        assert_eq!(
            chapter.headers()["Content-Type"],
            "text/html; charset=utf-8"
        );
        assert_eq!(chapter.headers()["Content-Security-Policy"], SPIKE_CSP);
        assert!(chapter.body().starts_with(b"<?xml version="));

        let stylesheet = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/OEBPS/style.css")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(stylesheet.status(), 200);
        assert_eq!(stylesheet.headers()["Content-Type"], "text/css");

        let image = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/OEBPS/images/cover.png")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(image.status(), 200);
        assert_eq!(image.headers()["Content-Type"], "image/png");

        let conformance = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/_spike/conformance.xhtml")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(conformance.status(), 200);
        assert!(conformance.body().starts_with(b"<!DOCTYPE html>"));

        let missing = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/missing.css")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(missing.status(), 404);

        let foreign_book = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://other/OEBPS/chapter1.xhtml")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(foreign_book.status(), 404);

        let encoded_traversal = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/OEBPS/%2e%2e/chapter1.xhtml")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(encoded_traversal.status(), 404);

        BOOK.with(|slot| {
            let slot = slot.borrow();
            assert_eq!(slot.as_ref().unwrap().requests.len(), 7);
        });
    }
}
