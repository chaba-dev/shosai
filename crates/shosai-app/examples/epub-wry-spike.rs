//! Gate 0 spike for embedding a locked-down Wry child inside an Iced window.
//!
//! This is deliberately isolated behind the `epub-wry-spike` feature. It is a
//! feasibility harness, not a production EPUB renderer.

use std::borrow::Cow;
use std::cell::RefCell;
use std::collections::HashMap;
use std::net::TcpListener;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use iced::advanced::widget::{self, operation};
use iced::widget::{button, column, container, row, text};
use iced::{Element, Length, Rectangle, Size, Subscription, Task, window};
use shosai_core::epub::{CanonicalEpubPath, EpubDoc};
use wry::dpi::{LogicalPosition, LogicalSize};
use wry::http::{Request, Response};
use wry::raw_window_handle::{HandleError, HasWindowHandle, RawWindowHandle, WindowHandle};
use wry::{NewWindowResponse, PageLoadEvent, Rect, WebView, WebViewBuilder};

const HEADER_HEIGHT: f32 = 112.0;
const PADDING: f32 = 24.0;
const PLACEHOLDER_ID: &str = "epub-wry-spike-placeholder";
const LIFECYCLE_PROOF_ENV: &str = "SHOSAI_WRY_SPIKE_LIFECYCLE_PROOF";
const LIFECYCLE_PROOF_TIMEOUT: Duration = Duration::from_secs(10);
const LIFECYCLE_WINDOW_WIDTH: f32 = 1040.0;
const LIFECYCLE_WINDOW_HEIGHT: f32 = 760.0;
const NETWORK_PROOF_ENV: &str = "SHOSAI_WRY_SPIKE_NETWORK_PROOF";
const NETWORK_PROOF_GRACE: Duration = Duration::from_secs(1);
const NETWORK_PROOF_TIMEOUT: Duration = Duration::from_secs(10);
const NETWORK_PROOF_PATH: &str = "_spike/conformance.xhtml";
const NETWORK_PROOF_URL: &str = "shosai://book/_spike/conformance.xhtml";
const NETWORK_PROOF_URL_ALIAS: &str = "http://shosai.book/_spike/conformance.xhtml";

thread_local! {
    static WEBVIEW: RefCell<Option<WebView>> = const { RefCell::new(None) };
    static BOOK: RefCell<Option<SpikeBook>> = const { RefCell::new(None) };
    static NETWORK_PROOF: RefCell<Option<NetworkProof>> = const { RefCell::new(None) };
    static NETWORK_PROOF_RESULT: RefCell<Option<Result<(), String>>> = const { RefCell::new(None) };
    static LIFECYCLE_PROOF_RESULT: RefCell<Option<Result<(), String>>> = const { RefCell::new(None) };
}

#[derive(Debug)]
struct NetworkMonitor {
    endpoint: String,
    attempts: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<Result<(), String>>>,
}

impl NetworkMonitor {
    fn start() -> Result<Self, String> {
        let listener = TcpListener::bind("127.0.0.1:0").map_err(|error| error.to_string())?;
        listener
            .set_nonblocking(true)
            .map_err(|error| error.to_string())?;
        let endpoint = format!(
            "http://{}",
            listener.local_addr().map_err(|error| error.to_string())?
        );
        let attempts = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let worker_attempts = Arc::clone(&attempts);
        let worker_stop = Arc::clone(&stop);
        let worker = thread::spawn(move || {
            loop {
                match listener.accept() {
                    Ok((_stream, _peer)) => {
                        worker_attempts.fetch_add(1, Ordering::AcqRel);
                    }
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && worker_stop.load(Ordering::Acquire) =>
                    {
                        break;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => return Err(format!("network monitor accept failed: {error}")),
                }
            }
            Ok(())
        });

        Ok(Self {
            endpoint,
            attempts,
            stop,
            worker: Some(worker),
        })
    }

    fn attempts(&self) -> usize {
        self.attempts.load(Ordering::Acquire)
    }

    fn stop_and_count(&mut self) -> Result<usize, String> {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            worker
                .join()
                .map_err(|_| "network monitor worker panicked".to_string())??;
        }
        Ok(self.attempts())
    }
}

impl Drop for NetworkMonitor {
    fn drop(&mut self) {
        let _ = self.stop_and_count();
    }
}

#[derive(Debug)]
struct NetworkProof {
    monitor: NetworkMonitor,
    page_loaded: Arc<AtomicBool>,
}

#[derive(Debug)]
struct SpikeResource {
    content_type: String,
    body: Vec<u8>,
}

#[derive(Debug)]
struct SpikeBook {
    start_url: String,
    resources: HashMap<CanonicalEpubPath, SpikeResource>,
    requests: Vec<String>,
    network_proof_page_served: bool,
}

impl SpikeBook {
    fn from_epub_bytes(bytes: Vec<u8>) -> Result<Self, String> {
        let epub =
            EpubDoc::from_bytes_for_renderer_spike(bytes).map_err(|error| error.to_string())?;
        let first_chapter = epub
            .content
            .chapters
            .first()
            .ok_or_else(|| "EPUB has no readable spine chapter".to_string())?;
        let first_path =
            CanonicalEpubPath::new(&first_chapter.path).map_err(|error| error.to_string())?;
        let start_url = first_path.to_protocol_uri();
        let mut resources = HashMap::new();
        let mut chapter_resources = epub
            .content
            .chapters
            .into_iter()
            .map(|chapter| (chapter.path, chapter.content.into_bytes()))
            .collect::<HashMap<_, _>>();
        let mut manifest_resources = epub.content.resources;

        for item in epub.content.manifest.into_values() {
            if let Some(body) = manifest_resources
                .remove(&item.href)
                .or_else(|| chapter_resources.remove(&item.href))
            {
                let path = CanonicalEpubPath::new(&item.href).map_err(|error| error.to_string())?;
                resources.insert(
                    path,
                    SpikeResource {
                        content_type: item.media_type,
                        body,
                    },
                );
            }
        }
        resources.insert(
            CanonicalEpubPath::new(NETWORK_PROOF_PATH).map_err(|error| error.to_string())?,
            SpikeResource {
                content_type: "text/html; charset=utf-8".into(),
                body: SPIKE_CHAPTER.as_bytes().to_vec(),
            },
        );

        Ok(Self {
            start_url,
            resources,
            requests: Vec::new(),
            network_proof_page_served: false,
        })
    }
}

#[derive(Debug, Default)]
struct State {
    window: Option<window::Id>,
    measured_bounds: Option<Rectangle>,
    creation_bounds: Option<Rectangle>,
    applied_bounds: Option<Rectangle>,
    webview_ready: bool,
    lifecycle_proof: LifecycleProof,
    measurement_epoch: u64,
    proof_timeout: Option<Instant>,
    status: String,
    network_proof_deadline: Option<Instant>,
    network_proof_finished: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
enum LifecycleProof {
    #[default]
    Disabled,
    WaitingForCreation,
    WaitingForResize {
        initial: Rectangle,
    },
    WaitingForMeasurement {
        initial: Rectangle,
        epoch: u64,
    },
    Synchronizing {
        expected: Rectangle,
    },
    Complete,
}

impl LifecycleProof {
    fn observe_resize_event(&mut self, size: Size, epoch: u64) -> bool {
        if size == Size::new(LIFECYCLE_WINDOW_WIDTH, LIFECYCLE_WINDOW_HEIGHT)
            && let Self::WaitingForResize { initial } = *self
        {
            *self = Self::WaitingForMeasurement { initial, epoch };
            return true;
        }
        false
    }

    fn observe_measurement(&mut self, epoch: u64, bounds: Option<Rectangle>) -> bool {
        let Self::WaitingForMeasurement {
            initial,
            epoch: expected_epoch,
        } = *self
        else {
            return false;
        };
        if epoch != expected_epoch {
            return false;
        }
        let Some(expected) = bounds.filter(|bounds| *bounds != initial) else {
            return false;
        };
        *self = Self::Synchronizing { expected };
        true
    }

    fn observe_synchronization(&mut self, bounds: Option<Rectangle>, succeeded: bool) -> bool {
        let Self::Synchronizing { expected } = *self else {
            return false;
        };
        if succeeded && bounds == Some(expected) {
            return true;
        }
        false
    }

    fn expects_synchronization(&self, bounds: Option<Rectangle>) -> bool {
        matches!(self, Self::Synchronizing { expected } if bounds == Some(*expected))
    }

    fn complete(&mut self) -> bool {
        if *self == Self::Complete {
            return false;
        }
        *self = Self::Complete;
        true
    }
}

struct PlaceholderBoundsOperation {
    target: widget::Id,
    bounds: Option<Rectangle>,
}

impl operation::Operation<Option<Rectangle>> for PlaceholderBoundsOperation {
    fn traverse(
        &mut self,
        operate: &mut dyn FnMut(&mut dyn operation::Operation<Option<Rectangle>>),
    ) {
        operate(self);
    }

    fn container(&mut self, id: Option<&widget::Id>, bounds: Rectangle) {
        if id == Some(&self.target) {
            self.bounds = Some(bounds);
        }
    }

    fn finish(&self) -> operation::Outcome<Option<Rectangle>> {
        operation::Outcome::Some(self.bounds)
    }
}

#[derive(Debug, Clone)]
enum Message {
    WindowEvent(window::Id, window::Event),
    PlaceholderMeasured {
        epoch: u64,
        bounds: Option<Rectangle>,
    },
    WebViewCreated(Result<(), String>),
    WebViewSynchronized {
        bounds: Option<Rectangle>,
        result: Result<(), String>,
    },
    FocusWebView,
    NetworkProofTick(Instant),
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

fn main() -> ExitCode {
    let result = iced::application(boot, update, view)
        .title("Shōsai EPUB Wry spike")
        .subscription(subscription)
        .window_size((900.0, 700.0))
        .run();
    if let Err(error) = result {
        eprintln!("EPUB Wry spike failed: {error}");
        return ExitCode::FAILURE;
    }
    if network_proof_requested() {
        return NETWORK_PROOF_RESULT.with(|result| match result.borrow_mut().take() {
            Some(Ok(())) => ExitCode::SUCCESS,
            Some(Err(error)) => {
                eprintln!("wry-spike-network-proof FAIL: {error}");
                ExitCode::FAILURE
            }
            None => {
                eprintln!("wry-spike-network-proof FAIL: proof did not complete");
                ExitCode::FAILURE
            }
        });
    }
    if lifecycle_proof_requested() {
        return LIFECYCLE_PROOF_RESULT.with(|result| match result.borrow_mut().take() {
            Some(Ok(())) => ExitCode::SUCCESS,
            Some(Err(error)) => {
                eprintln!("wry-spike-lifecycle-proof FAIL: {error}");
                ExitCode::FAILURE
            }
            None => {
                eprintln!("wry-spike-lifecycle-proof FAIL: proof did not complete");
                ExitCode::FAILURE
            }
        });
    }
    ExitCode::SUCCESS
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
    let events = window::events().map(|(id, event)| Message::WindowEvent(id, event));
    if network_proof_requested() || lifecycle_proof_requested() {
        Subscription::batch([
            events,
            iced::time::every(Duration::from_millis(100)).map(Message::NetworkProofTick),
        ])
    } else {
        events
    }
}

fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::WindowEvent(id, window::Event::Opened { .. }) => {
            state.window = Some(id);
            if network_proof_requested() || lifecycle_proof_requested() {
                let timeout = if lifecycle_proof_requested() {
                    LIFECYCLE_PROOF_TIMEOUT
                } else {
                    NETWORK_PROOF_TIMEOUT
                };
                state.proof_timeout = Some(Instant::now() + timeout);
            }
            if lifecycle_proof_requested() {
                state.lifecycle_proof = LifecycleProof::WaitingForCreation;
            }
            state.status = "measuring Iced reader placeholder".into();
            measure_placeholder(state.measurement_epoch)
        }
        Message::WindowEvent(id, window::Event::Resized(size)) if state.window == Some(id) => {
            let next_epoch = state.measurement_epoch.wrapping_add(1);
            if state.lifecycle_proof.observe_resize_event(size, next_epoch) {
                state.measurement_epoch = next_epoch;
            }
            measure_placeholder(state.measurement_epoch)
        }
        Message::WindowEvent(id, window::Event::Rescaled(_)) if state.window == Some(id) => {
            measure_placeholder(state.measurement_epoch)
        }
        Message::WindowEvent(id, window::Event::Closed) if state.window == Some(id) => {
            teardown_webview();
            Task::none()
        }
        Message::WindowEvent(_, _) => Task::none(),
        Message::PlaceholderMeasured { epoch, bounds } => {
            state.measured_bounds = bounds.and_then(usable_bounds);
            if lifecycle_proof_requested() {
                let should_synchronize =
                    matches!(state.lifecycle_proof, LifecycleProof::WaitingForCreation)
                        || state
                            .lifecycle_proof
                            .observe_measurement(epoch, state.measured_bounds);
                if should_synchronize {
                    synchronize_webview(state)
                } else {
                    Task::none()
                }
            } else {
                synchronize_webview(state)
            }
        }
        Message::WebViewCreated(result) => match result {
            Ok(()) => {
                state.webview_ready = true;
                state.applied_bounds = state.creation_bounds.take();
                state.status = if network_proof_requested() {
                    "embedded; waiting for hostile page to finish loading".into()
                } else {
                    "embedded in measured Iced placeholder; deny-by-default handlers configured"
                        .into()
                };
                if lifecycle_proof_requested() {
                    let Some(initial) = state.applied_bounds else {
                        return finish_lifecycle_proof(
                            state,
                            Err("webview was created without measured bounds".into()),
                        );
                    };
                    state.lifecycle_proof = LifecycleProof::WaitingForResize { initial };
                    state.window.map_or_else(Task::none, |id| {
                        window::resize(
                            id,
                            Size::new(LIFECYCLE_WINDOW_WIDTH, LIFECYCLE_WINDOW_HEIGHT),
                        )
                    })
                } else {
                    synchronize_webview(state)
                }
            }
            Err(error) if network_proof_requested() => {
                state.creation_bounds = None;
                finish_network_proof(state, Err(format!("webview creation failed: {error}")))
            }
            Err(error) if lifecycle_proof_requested() => {
                state.creation_bounds = None;
                finish_lifecycle_proof(state, Err(format!("webview creation failed: {error}")))
            }
            Err(error) => {
                state.creation_bounds = None;
                state.status = format!("webview creation failed: {error}");
                Task::none()
            }
        },
        Message::WebViewSynchronized { bounds, result } => {
            if lifecycle_proof_requested()
                && state.lifecycle_proof.expects_synchronization(bounds)
                && let Err(error) = &result
            {
                return finish_lifecycle_proof(
                    state,
                    Err(format!("webview synchronization failed: {error}")),
                );
            }
            match result {
                Ok(()) => {
                    state.applied_bounds = bounds;
                    if lifecycle_proof_requested()
                        && state.lifecycle_proof.observe_synchronization(bounds, true)
                    {
                        return finish_lifecycle_proof(state, Ok(()));
                    }
                }
                Err(error) => state.status = format!("webview synchronization failed: {error}"),
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
        Message::NetworkProofTick(now) if lifecycle_proof_requested() => {
            update_lifecycle_proof(state, now)
        }
        Message::NetworkProofTick(now) => update_network_proof(state, now),
    }
}

fn update_lifecycle_proof(state: &mut State, now: Instant) -> Task<Message> {
    if state.lifecycle_proof == LifecycleProof::Complete {
        return Task::none();
    }
    if state.proof_timeout.is_some_and(|deadline| now >= deadline) {
        return finish_lifecycle_proof(
            state,
            Err(format!(
                "timed out during lifecycle phase {:?}",
                state.lifecycle_proof
            )),
        );
    }
    measure_placeholder(state.measurement_epoch)
}

fn finish_lifecycle_proof(state: &mut State, result: Result<(), String>) -> Task<Message> {
    if !state.lifecycle_proof.complete() {
        return Task::none();
    }
    teardown_webview();
    if result.is_ok() {
        eprintln!("wry-spike-lifecycle-proof PASS: measured resize and teardown completed");
    }
    LIFECYCLE_PROOF_RESULT.with(|slot| {
        record_terminal_result(&mut slot.borrow_mut(), result);
    });
    state.window.map_or_else(Task::none, window::close)
}

fn update_network_proof(state: &mut State, now: Instant) -> Task<Message> {
    if state.network_proof_finished {
        return Task::none();
    }
    let (loaded, served, attempts) = NETWORK_PROOF.with(|proof| {
        let proof = proof.borrow();
        proof.as_ref().map_or((false, false, 0), |proof| {
            (
                proof.page_loaded.load(Ordering::Acquire),
                BOOK.with(|book| {
                    book.borrow()
                        .as_ref()
                        .is_some_and(|book| book.network_proof_page_served)
                }),
                proof.monitor.attempts(),
            )
        })
    });
    if attempts > 0 {
        return finish_network_proof(
            state,
            Err(format!("observed {attempts} network connection(s)")),
        );
    }
    if loaded && served && state.network_proof_deadline.is_none() {
        state.network_proof_deadline = Some(now + NETWORK_PROOF_GRACE);
        state.status = "hostile page loaded; observing network grace period".into();
    }
    if state
        .network_proof_deadline
        .is_some_and(|deadline| now >= deadline)
    {
        return finish_network_proof(state, Ok(()));
    }
    if state.proof_timeout.is_some_and(|timeout| now >= timeout) {
        let stage = if state.webview_ready {
            "hostile page did not finish loading"
        } else {
            "timed out waiting for placeholder measurement and webview creation"
        };
        return finish_network_proof(state, Err(stage.into()));
    }
    Task::none()
}

fn finish_network_proof(state: &mut State, result: Result<(), String>) -> Task<Message> {
    if state.network_proof_finished {
        return Task::none();
    }
    state.network_proof_finished = true;
    let monitor_result = NETWORK_PROOF.with(|proof| {
        proof
            .borrow_mut()
            .take()
            .map(|mut proof| proof.monitor.stop_and_count())
    });
    let result = match monitor_result {
        Some(Err(error)) => Err(error),
        Some(Ok(attempts)) if result.is_ok() && attempts > 0 => {
            Err(format!("observed {attempts} network connection(s)"))
        }
        None if result.is_ok() => Err("network monitor was not running".into()),
        _ => result,
    };
    if result.is_ok() {
        eprintln!("wry-spike-network-proof PASS: zero book-initiated network connections");
    }
    NETWORK_PROOF_RESULT.with(|slot| {
        record_terminal_result(&mut slot.borrow_mut(), result);
    });
    state.window.map_or_else(Task::none, window::close)
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
            .id(PLACEHOLDER_ID)
            .width(Length::Fill)
            .height(Length::Fill)
            .center(Length::Fill),
    ]
    .into()
}

fn measure_placeholder(epoch: u64) -> Task<Message> {
    iced::advanced::widget::operate(PlaceholderBoundsOperation {
        target: widget::Id::from(PLACEHOLDER_ID),
        bounds: None,
    })
    .map(move |bounds| Message::PlaceholderMeasured { epoch, bounds })
}

fn create_webview(id: window::Id, bounds: Rectangle) -> Task<Message> {
    window::run(id, move |window| {
        let mut book = SpikeBook::from_epub_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )?;
        let page_loaded = Arc::new(AtomicBool::new(false));
        let start_url = if network_proof_requested() {
            let monitor = NetworkMonitor::start()?;
            let path =
                CanonicalEpubPath::new(NETWORK_PROOF_PATH).map_err(|error| error.to_string())?;
            book.resources.get_mut(&path).unwrap().body =
                remote_content_chapter(&monitor.endpoint).into_bytes();
            NETWORK_PROOF.with(|slot| {
                *slot.borrow_mut() = Some(NetworkProof {
                    monitor,
                    page_loaded: Arc::clone(&page_loaded),
                });
            });
            NETWORK_PROOF_URL.to_string()
        } else if std::env::var("SHOSAI_WRY_SPIKE_PAGE").as_deref() == Ok("conformance") {
            NETWORK_PROOF_URL.to_string()
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
            .with_bounds(webview_bounds(bounds))
            .with_custom_protocol("shosai".into(), serve_epub_resource)
            .with_url(&start_url)
            .with_javascript_disabled()
            .with_navigation_handler(|url| is_allowed_navigation(&url))
            .with_download_started_handler(|_, _| false)
            .with_new_window_req_handler(|_, _| NewWindowResponse::Deny)
            .with_on_page_load_handler(move |event, url| {
                if matches!(event, PageLoadEvent::Finished) && is_network_proof_page(&url) {
                    page_loaded.store(true, Ordering::Release);
                }
            })
            .build_as_child(&parent)
            .map_err(|error| error.to_string())?;

        WEBVIEW.with(|slot| *slot.borrow_mut() = Some(webview));
        Ok(())
    })
    .map(Message::WebViewCreated)
}

fn network_proof_requested() -> bool {
    std::env::var_os(NETWORK_PROOF_ENV).is_some()
}

fn lifecycle_proof_requested() -> bool {
    std::env::var_os(LIFECYCLE_PROOF_ENV).is_some()
}

fn is_network_proof_page(url: &str) -> bool {
    matches!(url, NETWORK_PROOF_URL | NETWORK_PROOF_URL_ALIAS)
}

fn remote_content_chapter(endpoint: &str) -> String {
    format!(
        r#"<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta charset="utf-8" />
  <link rel="stylesheet" href="{endpoint}/remote.css" />
  <style>
    @import url("{endpoint}/import.css");
    @font-face {{ font-family: blocked; src: url("{endpoint}/font.woff2"); }}
    body {{ background-image: url("{endpoint}/background.png"); font-family: blocked; }}
  </style>
</head>
<body>
  <h1>Remote-content security proof</h1>
  <img src="{endpoint}/image.png" alt="blocked remote image" />
  <iframe src="{endpoint}/frame.xhtml"></iframe>
  <object data="{endpoint}/object.bin"></object>
  <script src="{endpoint}/script.js"></script>
  <script>fetch("{endpoint}/inline-script-ran")</script>
</body>
</html>"#
    )
}

fn synchronize_webview(state: &mut State) -> Task<Message> {
    let Some(id) = state.window else {
        return Task::none();
    };
    if !state.webview_ready {
        if state.creation_bounds.is_none()
            && let Some(bounds) = state.measured_bounds
        {
            state.creation_bounds = Some(bounds);
            state.status = "creating locked-down child webview in measured bounds".into();
            return create_webview(id, bounds);
        }
        return Task::none();
    }
    if state.measured_bounds == state.applied_bounds {
        return Task::none();
    }
    let bounds = state.measured_bounds;
    window::run(id, move |_| {
        WEBVIEW.with(|slot| synchronize_webview_instance(slot.borrow().as_ref(), bounds))
    })
    .map(move |result| Message::WebViewSynchronized { bounds, result })
}

fn synchronize_webview_instance(
    webview: Option<&WebView>,
    bounds: Option<Rectangle>,
) -> Result<(), String> {
    let webview = webview.ok_or_else(|| "webview is not available".to_string())?;
    if let Some(bounds) = bounds {
        webview
            .set_bounds(webview_bounds(bounds))
            .map_err(|error| error.to_string())?;
        webview
            .set_visible(true)
            .map_err(|error| error.to_string())?;
    } else {
        webview
            .set_visible(false)
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn record_terminal_result(slot: &mut Option<Result<(), String>>, result: Result<(), String>) {
    if slot.is_none() {
        *slot = Some(result);
    }
}

fn usable_bounds(bounds: Rectangle) -> Option<Rectangle> {
    (bounds.x.is_finite()
        && bounds.y.is_finite()
        && bounds.width.is_finite()
        && bounds.height.is_finite()
        && bounds.width > 0.0
        && bounds.height > 0.0)
        .then_some(bounds)
}

fn webview_bounds(bounds: Rectangle) -> Rect {
    Rect {
        position: LogicalPosition::new(bounds.x, bounds.y).into(),
        size: LogicalSize::new(bounds.width, bounds.height).into(),
    }
}

fn teardown_webview() {
    WEBVIEW.with(|slot| slot.borrow_mut().take());
}

fn is_allowed_navigation(url: &str) -> bool {
    if url == "shosai://book" || url == "http://shosai.book" {
        return true;
    }
    let canonical_url = url
        .strip_prefix("http://shosai.book/")
        .map(|path| format!("shosai://book/{path}"))
        .unwrap_or_else(|| url.to_string());
    CanonicalEpubPath::from_protocol_uri(&canonical_url).is_ok()
}

fn serve_epub_resource(
    _webview_id: wry::WebViewId<'_>,
    request: Request<Vec<u8>>,
) -> Response<Cow<'static, [u8]>> {
    let uri = request.uri().to_string();
    eprintln!("wry-spike-request uri={uri}");
    let path = CanonicalEpubPath::from_protocol_uri(&uri)
        .ok()
        .map(|reference| reference.path);
    let response = BOOK.with(|slot| {
        let mut slot = slot.borrow_mut();
        let book = slot.as_mut()?;
        book.requests.push(uri);
        let resource = path
            .as_ref()
            .and_then(|path| book.resources.get(path))
            .map(|resource| (resource.content_type.clone(), resource.body.clone()));
        if resource.is_some()
            && path
                .as_ref()
                .is_some_and(|path| path.as_str() == NETWORK_PROOF_PATH)
        {
            book.network_proof_page_served = true;
        }
        resource
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
    use std::net::TcpStream;

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
    fn network_proof_accepts_only_the_expected_finished_page() {
        assert!(is_network_proof_page(NETWORK_PROOF_URL));
        assert!(is_network_proof_page(NETWORK_PROOF_URL_ALIAS));
        for unrelated in [
            "about:blank",
            "shosai://book",
            "shosai://book/OEBPS/chapter1.xhtml",
            "shosai://book/_spike/conformance.xhtml?retry=1",
            "shosai://other/_spike/conformance.xhtml",
        ] {
            assert!(!is_network_proof_page(unrelated), "accepted {unrelated}");
        }
    }

    #[test]
    fn remote_content_fixture_targets_the_controlled_monitor() {
        let endpoint = "http://127.0.0.1:12345";
        let chapter = remote_content_chapter(endpoint);
        for path in [
            "remote.css",
            "import.css",
            "font.woff2",
            "background.png",
            "image.png",
            "frame.xhtml",
            "object.bin",
            "script.js",
            "inline-script-ran",
        ] {
            assert!(chapter.contains(&format!("{endpoint}/{path}")));
        }
    }

    #[test]
    fn network_monitor_observes_a_control_connection() {
        let mut monitor = NetworkMonitor::start().unwrap();
        let address = monitor.endpoint.strip_prefix("http://").unwrap();
        let _connection = TcpStream::connect(address).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while monitor.attempts() == 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(monitor.attempts(), 1);
        assert_eq!(monitor.stop_and_count().unwrap(), 1);
    }

    #[test]
    fn network_monitor_reports_worker_panics() {
        let mut monitor = NetworkMonitor::start().unwrap();
        monitor.stop_and_count().unwrap();
        monitor.worker = Some(thread::spawn(|| -> Result<(), String> {
            panic!("simulated monitor failure")
        }));

        assert_eq!(
            monitor.stop_and_count().unwrap_err(),
            "network monitor worker panicked"
        );
    }

    #[test]
    fn placeholder_bounds_reject_empty_and_non_finite_geometry() {
        let valid = Rectangle {
            x: 24.0,
            y: 112.0,
            width: 852.0,
            height: 564.0,
        };
        assert_eq!(usable_bounds(valid), Some(valid));

        for invalid in [
            Rectangle {
                width: 0.0,
                ..valid
            },
            Rectangle {
                height: -1.0,
                ..valid
            },
            Rectangle {
                x: f32::NAN,
                ..valid
            },
            Rectangle {
                height: f32::INFINITY,
                ..valid
            },
        ] {
            assert_eq!(usable_bounds(invalid), None);
        }
    }

    #[test]
    fn measured_iced_bounds_are_preserved_as_logical_wry_bounds() {
        let bounds = Rectangle {
            x: 17.5,
            y: 93.25,
            width: 640.5,
            height: 480.75,
        };

        assert_eq!(
            webview_bounds(bounds),
            Rect {
                position: LogicalPosition::new(17.5, 93.25).into(),
                size: LogicalSize::new(640.5, 480.75).into(),
            }
        );
    }

    #[test]
    fn lifecycle_proof_ignores_measurements_until_requested_resize_event() {
        let initial = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let resized = Rectangle::new((0.0, 100.0).into(), (1040.0, 660.0).into());
        let mut proof = LifecycleProof::WaitingForResize { initial };

        assert!(!proof.observe_measurement(0, Some(resized)));
        assert_eq!(proof, LifecycleProof::WaitingForResize { initial });

        assert!(!proof.observe_resize_event(Size::new(900.0, 700.0), 1));
        assert_eq!(proof, LifecycleProof::WaitingForResize { initial });

        assert!(proof.observe_resize_event(
            Size::new(LIFECYCLE_WINDOW_WIDTH, LIFECYCLE_WINDOW_HEIGHT),
            1,
        ));
        assert!(!proof.observe_measurement(0, Some(resized)));
        assert!(proof.observe_measurement(1, Some(resized)));
        assert_eq!(proof, LifecycleProof::Synchronizing { expected: resized });
    }

    #[test]
    fn lifecycle_proof_accepts_only_its_expected_synchronization_once() {
        let expected = Rectangle::new((0.0, 100.0).into(), (1040.0, 660.0).into());
        let stale = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut proof = LifecycleProof::Synchronizing { expected };

        assert!(!proof.observe_synchronization(Some(stale), true));
        assert!(!proof.observe_synchronization(Some(expected), false));
        assert!(proof.observe_synchronization(Some(expected), true));
        assert_eq!(proof, LifecycleProof::Synchronizing { expected });
        assert!(proof.complete());
        assert_eq!(proof, LifecycleProof::Complete);
        assert!(!proof.observe_synchronization(Some(expected), true));
        assert!(!proof.complete());
    }

    #[test]
    fn proof_results_are_terminal() {
        let mut result = None;
        record_terminal_result(&mut result, Err("timed out".into()));
        record_terminal_result(&mut result, Ok(()));

        assert_eq!(result, Some(Err("timed out".into())));
    }

    #[test]
    fn lifecycle_timeout_covers_initial_placeholder_measurement() {
        let now = Instant::now();
        let mut state = State {
            lifecycle_proof: LifecycleProof::WaitingForCreation,
            proof_timeout: Some(now),
            ..State::default()
        };
        LIFECYCLE_PROOF_RESULT.with(|result| *result.borrow_mut() = None);

        drop(update_lifecycle_proof(&mut state, now));

        assert_eq!(state.lifecycle_proof, LifecycleProof::Complete);
        LIFECYCLE_PROOF_RESULT.with(|result| {
            assert!(
                result
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .as_ref()
                    .unwrap_err()
                    .contains("WaitingForCreation")
            );
        });
    }

    #[test]
    fn network_timeout_covers_initial_placeholder_measurement() {
        let now = Instant::now();
        let mut state = State {
            proof_timeout: Some(now),
            ..State::default()
        };
        NETWORK_PROOF_RESULT.with(|result| *result.borrow_mut() = None);

        drop(update_network_proof(&mut state, now));

        assert!(state.network_proof_finished);
        NETWORK_PROOF_RESULT.with(|result| {
            assert_eq!(
                result.borrow().as_ref().unwrap().as_ref().unwrap_err(),
                "timed out waiting for placeholder measurement and webview creation"
            );
        });
    }

    #[test]
    fn missing_placeholder_is_an_explicit_measurement() {
        let operation = PlaceholderBoundsOperation {
            target: widget::Id::from(PLACEHOLDER_ID),
            bounds: None,
        };

        assert!(matches!(
            operation::Operation::finish(&operation),
            operation::Outcome::Some(None)
        ));
    }

    #[test]
    fn synchronization_fails_when_the_webview_is_missing() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        assert_eq!(
            synchronize_webview_instance(None, Some(bounds)).unwrap_err(),
            "webview is not available"
        );
    }

    #[test]
    fn protocol_serves_epub_chapters_and_manifest_resources_with_csp() {
        install_sample_book();
        BOOK.with(|slot| {
            let mut slot = slot.borrow_mut();
            let book = slot.as_mut().unwrap();
            for path in [
                "OEBPS/space name.css",
                "OEBPS/日本語.css",
                "OEBPS/literal%name.css",
            ] {
                book.resources.insert(
                    CanonicalEpubPath::new(path).unwrap(),
                    SpikeResource {
                        content_type: "text/css".into(),
                        body: path.as_bytes().to_vec(),
                    },
                );
            }
        });
        let chapter = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/OEBPS/chapter1.xhtml")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(chapter.status(), 200);
        assert_eq!(chapter.headers()["Content-Type"], "application/xhtml+xml");
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

        let navigation = serve_epub_resource(
            "spike".into(),
            Request::get("shosai://book/OEBPS/nav.xhtml")
                .body(Vec::new())
                .unwrap(),
        );
        assert_eq!(navigation.status(), 200);
        assert_eq!(
            navigation.headers()["Content-Type"],
            "application/xhtml+xml"
        );

        let conformance = serve_epub_resource(
            "spike".into(),
            Request::get(NETWORK_PROOF_URL).body(Vec::new()).unwrap(),
        );
        assert_eq!(conformance.status(), 200);
        assert!(conformance.body().starts_with(b"<!DOCTYPE html>"));
        BOOK.with(|slot| {
            assert!(slot.borrow().as_ref().unwrap().network_proof_page_served);
        });

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

        for alias in [
            "shosai://book//OEBPS/chapter1.xhtml",
            "shosai://book/OEBPS/./chapter1.xhtml",
            "shosai://book/OEBPS/chapter1.xhtml?variant=2",
        ] {
            let response = serve_epub_resource(
                "spike".into(),
                Request::get(alias).body(Vec::new()).unwrap(),
            );
            assert_eq!(response.status(), 404, "served alias {alias}");
        }

        for url in [
            "shosai://book/OEBPS/space%20name.css",
            "shosai://book/OEBPS/%E6%97%A5%E6%9C%AC%E8%AA%9E.css",
            "shosai://book/OEBPS/literal%25name.css",
        ] {
            let response =
                serve_epub_resource("spike".into(), Request::get(url).body(Vec::new()).unwrap());
            assert_eq!(response.status(), 200, "did not serve {url}");
        }

        BOOK.with(|slot| {
            let slot = slot.borrow();
            assert_eq!(slot.as_ref().unwrap().requests.len(), 14);
        });
    }
}
