//! Gate 0 spike for embedding a locked-down Wry child inside an Iced window.
//!
//! This is deliberately isolated behind the `epub-wry-spike` feature. It is a
//! feasibility harness, not a production EPUB renderer.

use std::borrow::Cow;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::net::TcpListener;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use iced::advanced::widget::{self, operation};
use iced::widget::{button, column, container, row, stack, text};
use iced::{Background, Color, Element, Length, Rectangle, Size, Subscription, Task, window};
use shosai_core::epub::{CanonicalEpubPath, EpubDoc};
use wry::dpi::{LogicalPosition, LogicalSize};
use wry::http::{Request, Response};
use wry::raw_window_handle::{HandleError, HasWindowHandle, RawWindowHandle, WindowHandle};
use wry::{NewWindowResponse, PageLoadEvent, Rect, WebView, WebViewBuilder};

const HEADER_HEIGHT: f32 = 112.0;
const PADDING: f32 = 24.0;
const PLACEHOLDER_ID: &str = "epub-wry-spike-placeholder";
#[cfg(target_os = "linux")]
const GTK_PUMP_INTERVAL: Duration = Duration::from_millis(16);
const LIFECYCLE_PROOF_ENV: &str = "SHOSAI_WRY_SPIKE_LIFECYCLE_PROOF";
const LIFECYCLE_PROOF_TIMEOUT: Duration = Duration::from_secs(10);
const LIFECYCLE_WINDOW_WIDTH: f32 = 1040.0;
const LIFECYCLE_WINDOW_HEIGHT: f32 = 760.0;
const OVERLAY_PROOF_ENV: &str = "SHOSAI_WRY_SPIKE_OVERLAY_PROOF";
const OVERLAY_OBSERVATION_ENV: &str = "SHOSAI_WRY_SPIKE_OVERLAY_OBSERVATION";
const OVERLAY_PROOF_HOLD: Duration = Duration::from_secs(1);
const OVERLAY_DISMISS_SETTLE: Duration = Duration::from_millis(100);
const OVERLAY_PROOF_TIMEOUT: Duration = Duration::from_secs(10);
const BOUNDS_PROOF_ENV: &str = "SHOSAI_WRY_SPIKE_BOUNDS_PROOF";
const BOUNDS_PROOF_TIMEOUT: Duration = Duration::from_secs(10);
const NETWORK_PROOF_ENV: &str = "SHOSAI_WRY_SPIKE_NETWORK_PROOF";
const NETWORK_PROOF_GRACE: Duration = Duration::from_secs(1);
const NETWORK_PROOF_TIMEOUT: Duration = Duration::from_secs(10);
const NETWORK_PROOF_PATH: &str = "_spike/conformance.xhtml";
const NETWORK_PROOF_URL: &str = "shosai://book/_spike/conformance.xhtml";
const NETWORK_PROOF_URL_ALIAS: &str = "http://shosai.book/_spike/conformance.xhtml";
#[cfg(target_os = "linux")]
static X11_TEARDOWN_STARTED: AtomicBool = AtomicBool::new(false);

thread_local! {
    static WEBVIEW: RefCell<Option<WebView>> = const { RefCell::new(None) };
    static WEBVIEW_CREATION_GENERATION: Cell<u64> = const { Cell::new(0) };
    static BOOK: RefCell<Option<SpikeBook>> = const { RefCell::new(None) };
    static NETWORK_PROOF: RefCell<Option<NetworkProof>> = const { RefCell::new(None) };
    static NETWORK_PROOF_RESULT: RefCell<Option<Result<(), String>>> = const { RefCell::new(None) };
    static LIFECYCLE_PROOF_RESULT: RefCell<Option<Result<(), String>>> = const { RefCell::new(None) };
    static OVERLAY_PROOF_RESULT: RefCell<Option<Result<(), String>>> = const { RefCell::new(None) };
    static BOUNDS_PROOF_RESULT: RefCell<Option<Result<(), String>>> = const { RefCell::new(None) };
    #[cfg(test)]
    static TEARDOWN_CALLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
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
    overlay_proof: OverlayProof,
    overlay_active: bool,
    bounds_proof: BoundsProof,
    placeholder_collapsed: bool,
    webview_generation: u64,
    measurement_epoch: u64,
    proof_timeout: Option<Instant>,
    status: String,
    network_proof_deadline: Option<Instant>,
    overlay_restore_deadline: Option<Instant>,
    network_proof_finished: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
enum BoundsProof {
    #[default]
    Disabled,
    WaitingForCreation,
    WaitingForInvalid {
        epoch: u64,
        generation: u64,
    },
    Hiding {
        generation: u64,
    },
    WaitingForRestored {
        epoch: u64,
    },
    Recreating {
        expected: Rectangle,
    },
    Complete,
}

impl BoundsProof {
    fn begin_collapse(&mut self, epoch: u64, generation: u64) -> bool {
        if *self != Self::WaitingForCreation {
            return false;
        }
        *self = Self::WaitingForInvalid { epoch, generation };
        true
    }

    fn observe_invalid(&mut self, epoch: u64, bounds: Option<Rectangle>) -> bool {
        let Self::WaitingForInvalid {
            epoch: expected_epoch,
            generation,
        } = *self
        else {
            return false;
        };
        if epoch != expected_epoch || !bounds.is_none_or(is_collapsed_bounds) {
            return false;
        }
        *self = Self::Hiding { generation };
        true
    }

    fn begin_restore(&mut self, generation: u64, epoch: u64) -> bool {
        let Self::Hiding {
            generation: expected_generation,
        } = *self
        else {
            return false;
        };
        if generation != expected_generation {
            return false;
        }
        *self = Self::WaitingForRestored { epoch };
        true
    }

    fn observe_restored(&mut self, epoch: u64, bounds: Option<Rectangle>) -> Option<Rectangle> {
        let Self::WaitingForRestored {
            epoch: expected_epoch,
        } = *self
        else {
            return None;
        };
        if epoch != expected_epoch {
            return None;
        }
        let expected = bounds.and_then(usable_bounds)?;
        *self = Self::Recreating { expected };
        Some(expected)
    }

    fn expects_replacement(&self, bounds: Rectangle) -> bool {
        matches!(self, Self::Recreating { expected } if *expected == bounds)
    }

    fn complete(&mut self) -> bool {
        if *self == Self::Complete {
            return false;
        }
        *self = Self::Complete;
        true
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
enum OverlayProof {
    #[default]
    Disabled,
    WaitingForCreation,
    Hiding {
        bounds: Rectangle,
        generation: u64,
    },
    Hidden {
        bounds: Rectangle,
        generation: u64,
    },
    Dismissing {
        bounds: Rectangle,
        generation: u64,
    },
    Recreating {
        bounds: Rectangle,
    },
    Complete,
}

impl OverlayProof {
    fn begin_hiding(&mut self, bounds: Rectangle, generation: u64) -> bool {
        if *self != Self::WaitingForCreation {
            return false;
        }
        *self = Self::Hiding { bounds, generation };
        true
    }

    fn observe_hidden(&mut self, generation: u64, succeeded: bool) -> bool {
        let Self::Hiding {
            bounds,
            generation: expected_generation,
        } = *self
        else {
            return false;
        };
        if generation != expected_generation || !succeeded {
            return false;
        }
        *self = Self::Hidden { bounds, generation };
        true
    }

    fn begin_dismissing(&mut self) -> bool {
        let Self::Hidden { bounds, generation } = *self else {
            return false;
        };
        *self = Self::Dismissing { bounds, generation };
        true
    }

    fn begin_recreating(&mut self) -> Option<Rectangle> {
        let Self::Dismissing { bounds, .. } = *self else {
            return None;
        };
        *self = Self::Recreating { bounds };
        Some(bounds)
    }

    fn expects_replacement_verification(&self, bounds: Rectangle) -> bool {
        matches!(self, Self::Recreating { bounds: expected } if *expected == bounds)
    }

    fn blocks_geometry_synchronization(&self) -> bool {
        matches!(
            self,
            Self::Hiding { .. } | Self::Hidden { .. } | Self::Dismissing { .. }
        )
    }

    fn update_bounds_while_hidden(&mut self, updated: Rectangle) -> bool {
        match self {
            Self::Hiding { bounds, .. }
            | Self::Hidden { bounds, .. }
            | Self::Dismissing { bounds, .. } => {
                *bounds = updated;
                true
            }
            _ => false,
        }
    }

    fn complete(&mut self) -> bool {
        if *self == Self::Complete {
            return false;
        }
        *self = Self::Complete;
        true
    }
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
    Interacting {
        expected: Rectangle,
    },
    Recreating {
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
            *self = Self::Interacting { expected };
            return true;
        }
        false
    }

    fn expects_synchronization(&self, bounds: Option<Rectangle>) -> bool {
        matches!(self, Self::Synchronizing { expected } if bounds == Some(*expected))
    }

    fn expects_replacement_verification(&self, bounds: Rectangle) -> bool {
        matches!(self, Self::Recreating { expected } if bounds == *expected)
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
    LifecycleInteractionsCompleted(Result<(), String>),
    LifecycleReplacementVerified(Result<(), String>),
    OverlayHidden {
        generation: u64,
        result: Result<(), String>,
    },
    OverlayReplacementVerified {
        generation: u64,
        bounds: Rectangle,
        result: Result<(), String>,
    },
    BoundsChildHidden {
        generation: u64,
        result: Result<(), String>,
    },
    BoundsReplacementVerified {
        generation: u64,
        bounds: Rectangle,
        result: Result<(), String>,
    },
    FocusWebView,
    NetworkProofTick(Instant),
    #[cfg(target_os = "linux")]
    PumpGtk,
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
    if let Err(error) = validate_proof_mode_selection(
        network_proof_requested(),
        lifecycle_proof_requested(),
        overlay_proof_requested(),
        overlay_observation_requested(),
        bounds_proof_requested(),
    ) {
        eprintln!("EPUB Wry spike failed: {error}");
        return ExitCode::FAILURE;
    }
    if let Err(error) = initialize_platform() {
        eprintln!("EPUB Wry spike failed: {error}");
        return ExitCode::FAILURE;
    }
    let result = iced::application(boot, update, view)
        .title("Shōsai EPUB Wry spike")
        .subscription(subscription)
        .exit_on_close_request(false)
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
    if overlay_proof_requested() {
        return OVERLAY_PROOF_RESULT.with(|result| match result.borrow_mut().take() {
            Some(Ok(())) => ExitCode::SUCCESS,
            Some(Err(error)) => {
                eprintln!("wry-spike-overlay-proof FAIL: {error}");
                ExitCode::FAILURE
            }
            None => {
                eprintln!("wry-spike-overlay-proof FAIL: proof did not complete");
                ExitCode::FAILURE
            }
        });
    }
    if bounds_proof_requested() {
        return BOUNDS_PROOF_RESULT.with(|result| match result.borrow_mut().take() {
            Some(Ok(())) => ExitCode::SUCCESS,
            Some(Err(error)) => {
                eprintln!("wry-spike-bounds-proof FAIL: {error}");
                ExitCode::FAILURE
            }
            None => {
                eprintln!("wry-spike-bounds-proof FAIL: proof did not complete");
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
    let mut subscriptions = vec![events];
    if network_proof_requested()
        || lifecycle_proof_requested()
        || overlay_proof_requested()
        || bounds_proof_requested()
    {
        subscriptions
            .push(iced::time::every(Duration::from_millis(100)).map(Message::NetworkProofTick));
    }
    #[cfg(target_os = "linux")]
    subscriptions.push(iced::time::every(GTK_PUMP_INTERVAL).map(|_| Message::PumpGtk));
    Subscription::batch(subscriptions)
}

fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::WindowEvent(id, window::Event::Opened { .. }) => {
            state.window = Some(id);
            if network_proof_requested()
                || lifecycle_proof_requested()
                || overlay_proof_requested()
                || bounds_proof_requested()
            {
                let timeout = if lifecycle_proof_requested() {
                    LIFECYCLE_PROOF_TIMEOUT
                } else if overlay_proof_requested() {
                    OVERLAY_PROOF_TIMEOUT
                } else if bounds_proof_requested() {
                    BOUNDS_PROOF_TIMEOUT
                } else {
                    NETWORK_PROOF_TIMEOUT
                };
                state.proof_timeout = Some(Instant::now() + timeout);
            }
            if lifecycle_proof_requested() {
                state.lifecycle_proof = LifecycleProof::WaitingForCreation;
            }
            if overlay_proof_requested() {
                state.overlay_proof = OverlayProof::WaitingForCreation;
            }
            if bounds_proof_requested() {
                state.bounds_proof = BoundsProof::WaitingForCreation;
            }
            if overlay_observation_requested() {
                state.overlay_active = true;
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
        Message::WindowEvent(id, window::Event::CloseRequested) if state.window == Some(id) => {
            if overlay_proof_requested() && state.overlay_proof != OverlayProof::Complete {
                return finish_overlay_proof(
                    state,
                    Err("parent closed before overlay proof completed".into()),
                );
            }
            if bounds_proof_requested() && state.bounds_proof != BoundsProof::Complete {
                return finish_bounds_proof(
                    state,
                    Err("parent closed before bounds proof completed".into()),
                );
            }
            state.webview_generation = state.webview_generation.wrapping_add(1);
            let webview_dropped = teardown_webview();
            eprintln!("wry-spike-close-request teardown webview_dropped={webview_dropped}");
            window::close(id)
        }
        Message::WindowEvent(id, window::Event::Closed) if state.window == Some(id) => {
            if overlay_proof_requested() && state.overlay_proof != OverlayProof::Complete {
                return finish_overlay_proof(
                    state,
                    Err("parent closed before overlay proof completed".into()),
                );
            }
            if bounds_proof_requested() && state.bounds_proof != BoundsProof::Complete {
                return finish_bounds_proof(
                    state,
                    Err("parent closed before bounds proof completed".into()),
                );
            }
            state.webview_generation = state.webview_generation.wrapping_add(1);
            teardown_webview();
            Task::none()
        }
        Message::WindowEvent(_, _) => Task::none(),
        Message::PlaceholderMeasured { .. } if state.bounds_proof == BoundsProof::Complete => {
            Task::none()
        }
        Message::PlaceholderMeasured { epoch, bounds } => {
            state.measured_bounds = bounds.and_then(usable_bounds);
            if bounds_proof_requested()
                && !matches!(
                    state.bounds_proof,
                    BoundsProof::Disabled | BoundsProof::WaitingForCreation | BoundsProof::Complete
                )
            {
                return update_bounds_measurement(state, epoch, bounds);
            }
            if overlay_proof_requested() && state.overlay_proof.blocks_geometry_synchronization() {
                let Some(bounds) = state.measured_bounds else {
                    return finish_overlay_proof(
                        state,
                        Err("placeholder became unusable while the Iced modal was active".into()),
                    );
                };
                state.overlay_proof.update_bounds_while_hidden(bounds);
                return Task::none();
            }
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
        Message::WebViewCreated(_)
            if state.lifecycle_proof == LifecycleProof::Complete
                || state.overlay_proof == OverlayProof::Complete
                || state.bounds_proof == BoundsProof::Complete
                || state.network_proof_finished =>
        {
            teardown_webview();
            Task::none()
        }
        Message::WebViewCreated(result) => match result {
            Ok(()) => {
                state.webview_ready = true;
                state.webview_generation = state.webview_generation.wrapping_add(1);
                state.applied_bounds = state.creation_bounds.take();
                if let LifecycleProof::Recreating { expected } = state.lifecycle_proof {
                    return verify_lifecycle_replacement(state, expected);
                }
                if state.applied_bounds.is_some_and(|bounds| {
                    state.overlay_proof.expects_replacement_verification(bounds)
                }) {
                    return verify_overlay_replacement(state);
                }
                if state
                    .applied_bounds
                    .is_some_and(|bounds| state.bounds_proof.expects_replacement(bounds))
                {
                    return verify_bounds_replacement(state);
                }
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
                } else if overlay_proof_requested() {
                    begin_overlay_proof(state)
                } else if bounds_proof_requested() {
                    begin_bounds_proof(state)
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
            Err(error) if overlay_proof_requested() => {
                state.creation_bounds = None;
                finish_overlay_proof(state, Err(format!("webview creation failed: {error}")))
            }
            Err(error) if bounds_proof_requested() => {
                state.creation_bounds = None;
                finish_bounds_proof(state, Err(format!("webview creation failed: {error}")))
            }
            Err(error) => {
                state.creation_bounds = None;
                state.status = format!("webview creation failed: {error}");
                Task::none()
            }
        },
        Message::WebViewSynchronized { bounds, result } => {
            if !matches!(
                state.bounds_proof,
                BoundsProof::Disabled | BoundsProof::Complete
            ) {
                return finish_bounds_proof(
                    state,
                    Err("unexpected webview synchronization during bounds proof".into()),
                );
            }
            if overlay_proof_requested() && state.overlay_proof.blocks_geometry_synchronization() {
                return finish_overlay_proof(
                    state,
                    Err(
                        "unexpected webview synchronization while the Iced modal was active".into(),
                    ),
                );
            }
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
                        let expected = bounds.expect("successful lifecycle sync has bounds");
                        return exercise_lifecycle_interactions(state, expected);
                    }
                }
                Err(error) => state.status = format!("webview synchronization failed: {error}"),
            }
            Task::none()
        }
        Message::LifecycleInteractionsCompleted(result) => match result {
            Ok(()) => recreate_lifecycle_webview(state),
            Err(error) => finish_lifecycle_proof(
                state,
                Err(format!("webview interaction sequence failed: {error}")),
            ),
        },
        Message::LifecycleReplacementVerified(result) => match result {
            Ok(()) => finish_lifecycle_proof(state, Ok(())),
            Err(error) => finish_lifecycle_proof(
                state,
                Err(format!("replacement verification failed: {error}")),
            ),
        },
        Message::OverlayHidden { generation, result } => {
            update_overlay_hidden(state, generation, result)
        }
        Message::OverlayReplacementVerified {
            generation,
            bounds,
            result,
        } => update_overlay_replacement(state, generation, bounds, result),
        Message::BoundsChildHidden { generation, result } => {
            update_bounds_hidden(state, generation, result)
        }
        Message::BoundsReplacementVerified {
            generation,
            bounds,
            result,
        } => update_bounds_replacement(state, generation, bounds, result),
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
        Message::NetworkProofTick(now) if overlay_proof_requested() => {
            update_overlay_proof(state, now)
        }
        Message::NetworkProofTick(now) if bounds_proof_requested() => {
            update_bounds_proof(state, now)
        }
        Message::NetworkProofTick(now) => update_network_proof(state, now),
        #[cfg(target_os = "linux")]
        Message::PumpGtk => {
            pump_gtk_events();
            Task::none()
        }
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

fn begin_bounds_proof(state: &mut State) -> Task<Message> {
    let Some(_initial) = state.applied_bounds else {
        return finish_bounds_proof(
            state,
            Err("webview was created without measured bounds".into()),
        );
    };
    let epoch = state.measurement_epoch.wrapping_add(1);
    let generation = state.webview_generation;
    if !state.bounds_proof.begin_collapse(epoch, generation) {
        return Task::none();
    }
    state.measurement_epoch = epoch;
    state.placeholder_collapsed = true;
    state.status = "collapsing Iced placeholder to zero height".into();
    eprintln!("wry-spike-bounds-proof phase=collapsing generation={generation}");
    measure_placeholder(epoch)
}

fn update_bounds_measurement(
    state: &mut State,
    epoch: u64,
    raw_bounds: Option<Rectangle>,
) -> Task<Message> {
    eprintln!("wry-spike-bounds-proof measurement epoch={epoch} bounds={raw_bounds:?}");
    match state.bounds_proof {
        BoundsProof::WaitingForInvalid {
            epoch: expected_epoch,
            generation,
        } if epoch == expected_epoch => {
            if !state.bounds_proof.observe_invalid(epoch, raw_bounds) {
                return Task::none();
            }
            let Some(id) = state.window else {
                return finish_bounds_proof(state, Err("parent window is not available".into()));
            };
            state.status = "zero-height placeholder observed; hiding native child".into();
            eprintln!("wry-spike-bounds-proof phase=hiding generation={generation}");
            window::run(id, move |_| {
                WEBVIEW.with(|slot| set_webview_visible(slot.borrow().as_ref(), false))
            })
            .map(move |result| Message::BoundsChildHidden { generation, result })
        }
        BoundsProof::WaitingForRestored {
            epoch: expected_epoch,
        } if epoch == expected_epoch => {
            let Some(bounds) = state.bounds_proof.observe_restored(epoch, raw_bounds) else {
                return Task::none();
            };
            let Some(id) = state.window else {
                return finish_bounds_proof(state, Err("parent window is not available".into()));
            };
            state.creation_bounds = Some(bounds);
            state.status = "valid placeholder restored; recreating native child".into();
            eprintln!("wry-spike-bounds-proof phase=recreating");
            create_webview(id, bounds)
        }
        _ => Task::none(),
    }
}

fn update_bounds_hidden(
    state: &mut State,
    generation: u64,
    result: Result<(), String>,
) -> Task<Message> {
    if generation != state.webview_generation
        || !matches!(
            state.bounds_proof,
            BoundsProof::Hiding {
                generation: expected
            } if expected == generation
        )
    {
        return Task::none();
    }
    if let Err(error) = result {
        return finish_bounds_proof(state, Err(format!("webview hide failed: {error}")));
    }
    if !teardown_webview() {
        return finish_bounds_proof(state, Err("webview was missing after hide".into()));
    }
    state.webview_ready = false;
    state.applied_bounds = None;
    state.placeholder_collapsed = false;
    let epoch = state.measurement_epoch.wrapping_add(1);
    if !state.bounds_proof.begin_restore(generation, epoch) {
        return Task::none();
    }
    state.measurement_epoch = epoch;
    state.status = "native child destroyed; restoring Iced placeholder".into();
    eprintln!("wry-spike-bounds-proof phase=restoring-placeholder");
    measure_placeholder(epoch)
}

fn verify_bounds_replacement(state: &State) -> Task<Message> {
    let BoundsProof::Recreating { expected } = state.bounds_proof else {
        return Task::none();
    };
    let Some(id) = state.window else {
        return Task::done(Message::BoundsReplacementVerified {
            generation: state.webview_generation,
            bounds: expected,
            result: Err("parent window is not available".into()),
        });
    };
    let generation = state.webview_generation;
    window::run(id, move |_| {
        WEBVIEW.with(|slot| verify_webview_size(slot.borrow().as_ref(), expected))
    })
    .map(move |result| Message::BoundsReplacementVerified {
        generation,
        bounds: expected,
        result,
    })
}

fn update_bounds_replacement(
    state: &mut State,
    generation: u64,
    bounds: Rectangle,
    result: Result<(), String>,
) -> Task<Message> {
    if generation != state.webview_generation
        || state.applied_bounds != Some(bounds)
        || !state.bounds_proof.expects_replacement(bounds)
    {
        return Task::none();
    }
    match result {
        Ok(()) => finish_bounds_proof(state, Ok(())),
        Err(error) => finish_bounds_proof(
            state,
            Err(format!("bounds replacement verification failed: {error}")),
        ),
    }
}

fn update_bounds_proof(state: &mut State, now: Instant) -> Task<Message> {
    if state.bounds_proof == BoundsProof::Complete {
        return Task::none();
    }
    if state.proof_timeout.is_some_and(|deadline| now >= deadline) {
        return finish_bounds_proof(
            state,
            Err(format!(
                "timed out during bounds phase {:?}",
                state.bounds_proof
            )),
        );
    }
    if matches!(
        state.bounds_proof,
        BoundsProof::WaitingForInvalid { .. } | BoundsProof::WaitingForRestored { .. }
    ) {
        return measure_placeholder(state.measurement_epoch);
    }
    Task::none()
}

fn finish_bounds_proof(state: &mut State, result: Result<(), String>) -> Task<Message> {
    if !state.bounds_proof.complete() {
        return Task::none();
    }
    state.placeholder_collapsed = false;
    state.webview_ready = false;
    state.measured_bounds = None;
    state.creation_bounds = None;
    state.applied_bounds = None;
    state.webview_generation = state.webview_generation.wrapping_add(1);
    teardown_webview();
    if result.is_ok() {
        eprintln!(
            "wry-spike-bounds-proof PASS: unusable bounds, hide, placeholder restore, replacement size, and teardown completed"
        );
    }
    BOUNDS_PROOF_RESULT.with(|slot| {
        record_terminal_result(&mut slot.borrow_mut(), result);
    });
    state.window.map_or_else(Task::none, window::close)
}

fn begin_overlay_proof(state: &mut State) -> Task<Message> {
    let Some(bounds) = state.applied_bounds else {
        return finish_overlay_proof(
            state,
            Err("webview was created without measured bounds".into()),
        );
    };
    let generation = state.webview_generation;
    if !state.overlay_proof.begin_hiding(bounds, generation) {
        return Task::none();
    }
    let Some(id) = state.window else {
        return finish_overlay_proof(state, Err("parent window is not available".into()));
    };

    state.overlay_active = true;
    state.status = "Iced modal active; hiding native child webview".into();
    eprintln!("wry-spike-overlay-proof phase=hiding generation={generation}");
    window::run(id, move |_| {
        WEBVIEW.with(|slot| set_webview_visible(slot.borrow().as_ref(), false))
    })
    .map(move |result| Message::OverlayHidden { generation, result })
}

fn update_overlay_hidden(
    state: &mut State,
    generation: u64,
    result: Result<(), String>,
) -> Task<Message> {
    if generation != state.webview_generation {
        return Task::none();
    }

    if !matches!(
        state.overlay_proof,
        OverlayProof::Hiding {
            generation: expected,
            ..
        } if expected == generation
    ) {
        return Task::none();
    }
    if let Err(error) = result {
        return finish_overlay_proof(state, Err(format!("webview hide failed: {error}")));
    }
    if state.overlay_proof.observe_hidden(generation, true) {
        state.overlay_restore_deadline = Some(Instant::now() + OVERLAY_PROOF_HOLD);
        state.status = "Iced modal active; native child hidden".into();
        eprintln!("wry-spike-overlay-proof phase=hidden generation={generation}");
    }
    Task::none()
}

fn verify_overlay_replacement(state: &State) -> Task<Message> {
    let OverlayProof::Recreating { bounds } = state.overlay_proof else {
        return Task::none();
    };
    let Some(id) = state.window else {
        return Task::done(Message::OverlayReplacementVerified {
            generation: state.webview_generation,
            bounds,
            result: Err("parent window is not available".into()),
        });
    };
    let generation = state.webview_generation;
    window::run(id, move |_| {
        WEBVIEW.with(|slot| verify_webview_size(slot.borrow().as_ref(), bounds))
    })
    .map(move |result| Message::OverlayReplacementVerified {
        generation,
        bounds,
        result,
    })
}

fn update_overlay_replacement(
    state: &mut State,
    generation: u64,
    bounds: Rectangle,
    result: Result<(), String>,
) -> Task<Message> {
    if generation != state.webview_generation
        || state.applied_bounds != Some(bounds)
        || !state.overlay_proof.expects_replacement_verification(bounds)
    {
        return Task::none();
    }
    match result {
        Ok(()) => finish_overlay_proof(state, Ok(())),
        Err(error) => finish_overlay_proof(
            state,
            Err(format!("overlay replacement verification failed: {error}")),
        ),
    }
}

fn update_overlay_proof(state: &mut State, now: Instant) -> Task<Message> {
    if state.overlay_proof == OverlayProof::Complete {
        return Task::none();
    }
    if state.proof_timeout.is_some_and(|deadline| now >= deadline) {
        return finish_overlay_proof(
            state,
            Err(format!(
                "timed out during overlay phase {:?}",
                state.overlay_proof
            )),
        );
    }
    if matches!(state.overlay_proof, OverlayProof::Hidden { .. })
        && state
            .overlay_restore_deadline
            .is_some_and(|deadline| now >= deadline)
    {
        if state.overlay_proof.begin_dismissing() {
            state.overlay_active = false;
            state.overlay_restore_deadline = Some(now + OVERLAY_DISMISS_SETTLE);
            state.status = "Iced modal dismissed; waiting to restore native child".into();
        }
        return Task::none();
    }
    if matches!(state.overlay_proof, OverlayProof::Dismissing { .. })
        && state
            .overlay_restore_deadline
            .is_some_and(|deadline| now >= deadline)
    {
        let Some(bounds) = state.overlay_proof.begin_recreating() else {
            return Task::none();
        };
        let Some(id) = state.window else {
            return finish_overlay_proof(state, Err("parent window is not available".into()));
        };
        if !teardown_webview() {
            return finish_overlay_proof(
                state,
                Err("webview was missing before overlay replacement".into()),
            );
        }
        state.webview_ready = false;
        state.applied_bounds = None;
        state.creation_bounds = Some(bounds);
        state.status = "Iced modal dismissed; recreating native child at saved bounds".into();
        eprintln!("wry-spike-overlay-proof phase=recreating");
        return create_webview(id, bounds);
    }
    Task::none()
}

fn finish_overlay_proof(state: &mut State, result: Result<(), String>) -> Task<Message> {
    if !state.overlay_proof.complete() {
        return Task::none();
    }
    state.overlay_active = false;
    state.webview_generation = state.webview_generation.wrapping_add(1);
    teardown_webview();
    if result.is_ok() {
        eprintln!(
            "wry-spike-overlay-proof PASS: child hide, Iced modal hold, replacement at saved bounds, and teardown completed"
        );
    }
    OVERLAY_PROOF_RESULT.with(|slot| {
        record_terminal_result(&mut slot.borrow_mut(), result);
    });
    state.window.map_or_else(Task::none, window::close)
}

fn exercise_lifecycle_interactions(state: &State, expected: Rectangle) -> Task<Message> {
    let Some(id) = state.window else {
        return Task::done(Message::LifecycleInteractionsCompleted(Err(
            "parent window is not available".into(),
        )));
    };
    window::run(id, move |_| {
        WEBVIEW.with(|slot| exercise_webview_interactions(slot.borrow().as_ref(), expected))
    })
    .map(Message::LifecycleInteractionsCompleted)
}

fn recreate_lifecycle_webview(state: &mut State) -> Task<Message> {
    let LifecycleProof::Interacting { expected } = state.lifecycle_proof else {
        return Task::none();
    };
    let Some(id) = state.window else {
        return finish_lifecycle_proof(state, Err("parent window is not available".into()));
    };
    teardown_webview();
    state.webview_ready = false;
    state.applied_bounds = None;
    state.creation_bounds = Some(expected);
    state.lifecycle_proof = LifecycleProof::Recreating { expected };
    create_webview(id, expected)
}

fn verify_lifecycle_replacement(state: &State, expected: Rectangle) -> Task<Message> {
    if !state
        .lifecycle_proof
        .expects_replacement_verification(expected)
    {
        return Task::none();
    }
    let Some(id) = state.window else {
        return Task::done(Message::LifecycleReplacementVerified(Err(
            "parent window is not available".into(),
        )));
    };
    window::run(id, move |_| {
        WEBVIEW.with(|slot| verify_webview_size(slot.borrow().as_ref(), expected))
    })
    .map(Message::LifecycleReplacementVerified)
}

fn finish_lifecycle_proof(state: &mut State, result: Result<(), String>) -> Task<Message> {
    if !state.lifecycle_proof.complete() {
        return Task::none();
    }
    teardown_webview();
    if result.is_ok() {
        eprintln!(
            "wry-spike-lifecycle-proof PASS: resize, focus, visibility, replacement, and teardown completed"
        );
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
    teardown_webview();
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

    let reader: Element<'_, Message> = column![
        container(column![controls, text(&state.status)].spacing(8))
            .height(HEADER_HEIGHT)
            .padding([20, PADDING as u16]),
        container(text("Native child webview overlays this placeholder"))
            .id(PLACEHOLDER_ID)
            .width(Length::Fill)
            .height(if state.placeholder_collapsed {
                Length::Fixed(0.0)
            } else {
                Length::Fill
            })
            .align_x(iced::alignment::Horizontal::Center)
            .align_y(iced::alignment::Vertical::Center),
    ]
    .into();

    if !state.overlay_active {
        return reader;
    }

    let modal = container(
        container(
            column![
                text("Iced modal overlay").size(28),
                text("The native child webview must be hidden while this layer is active."),
            ]
            .spacing(12),
        )
        .padding(28)
        .style(|_| container::Style {
            background: Some(Background::Color(Color::from_rgb8(245, 245, 245))),
            text_color: Some(Color::BLACK),
            ..container::Style::default()
        }),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .center(Length::Fill)
    .style(|_| container::Style {
        background: Some(Background::Color(Color::from_rgba8(20, 24, 32, 0.82))),
        ..container::Style::default()
    });

    stack([reader, modal.into()])
        .width(Length::Fill)
        .height(Length::Fill)
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
    let generation = begin_webview_creation();
    window::run(id, move |window| {
        ensure_webview_creation_is_current(generation)?;
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
        ensure_supported_parent_handle(raw)?;
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

fn overlay_proof_requested() -> bool {
    cfg!(target_os = "macos") && std::env::var_os(OVERLAY_PROOF_ENV).is_some()
}

fn overlay_observation_requested() -> bool {
    cfg!(target_os = "macos") && std::env::var_os(OVERLAY_OBSERVATION_ENV).is_some()
}

fn bounds_proof_requested() -> bool {
    cfg!(target_os = "macos") && std::env::var_os(BOUNDS_PROOF_ENV).is_some()
}

fn validate_proof_mode_selection(
    network: bool,
    lifecycle: bool,
    overlay: bool,
    overlay_observation: bool,
    bounds: bool,
) -> Result<(), String> {
    if (overlay || overlay_observation || bounds)
        && [network, lifecycle, overlay, overlay_observation, bounds]
            .into_iter()
            .filter(|selected| *selected)
            .count()
            > 1
    {
        return Err(
            "macOS overlay and bounds modes cannot be combined with another proof mode".into(),
        );
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn initialize_platform() -> Result<(), String> {
    use gtk::prelude::DisplayExtManual;

    gtk::init().map_err(|error| format!("GTK initialization failed: {error}"))?;
    let display = gtk::gdk::Display::default().ok_or_else(|| {
        "GTK did not find a display; run this spike in an X11 session".to_string()
    })?;
    if display.backend().is_wayland() {
        return Err(
            "native Wayland child embedding is unsupported by Wry with the Iced host; run the bounded X11 spike with WINIT_UNIX_BACKEND=x11 GDK_BACKEND=x11"
                .into(),
        );
    }
    winit::platform::x11::register_xlib_error_hook(Box::new(|_display, error| {
        let error = error.cast::<x11_dl::xlib::XErrorEvent>();
        // SAFETY: winit invokes this hook with the Xlib error event pointer for
        // the duration of the callback. Wry documents GLX error 170 as benign
        // for its GTK child-window bridge and uses the same hook in its example.
        // Once this one-shot harness starts teardown, GTK may win races with
        // winit's XIM child, making idempotent cleanup return BadWindow (3).
        unsafe {
            (*error).error_code == 170
                || ((*error).error_code == 3 && X11_TEARDOWN_STARTED.load(Ordering::Acquire))
        }
    }));
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn initialize_platform() -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn pump_gtk_events() {
    while gtk::events_pending() {
        gtk::main_iteration_do(false);
    }
}

fn ensure_supported_parent_handle(handle: RawWindowHandle) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    if !matches!(handle, RawWindowHandle::Xlib(_)) {
        return Err(format!(
            "Wry child embedding requires an Iced X11/Xlib window on Linux, but Iced provided {handle:?}; unset WAYLAND_DISPLAY and WAYLAND_SOCKET, set DISPLAY to an X11 server, and run with GDK_BACKEND=x11"
        ));
    }
    let _ = handle;
    Ok(())
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

fn set_webview_visible(webview: Option<&WebView>, visible: bool) -> Result<(), String> {
    webview
        .ok_or_else(|| "webview is not available".to_string())?
        .set_visible(visible)
        .map_err(|error| error.to_string())
}

fn exercise_webview_interactions(
    webview: Option<&WebView>,
    expected: Rectangle,
) -> Result<(), String> {
    verify_webview_size(webview, expected)?;
    let webview = webview.expect("size verification requires a webview");
    webview.focus().map_err(|error| error.to_string())?;
    webview.focus_parent().map_err(|error| error.to_string())?;
    webview
        .set_visible(false)
        .map_err(|error| error.to_string())?;
    webview
        .set_visible(true)
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn verify_webview_size(webview: Option<&WebView>, expected: Rectangle) -> Result<(), String> {
    let webview = webview.ok_or_else(|| "webview is not available".to_string())?;
    let actual = webview.bounds().map_err(|error| error.to_string())?;
    let expected = webview_bounds(expected);
    if actual.size != expected.size {
        return Err(format!(
            "webview size mismatch: expected {:?}, got {:?}",
            expected.size, actual.size
        ));
    }
    Ok(())
}

fn begin_webview_creation() -> u64 {
    WEBVIEW_CREATION_GENERATION.with(|generation| {
        let next = generation.get().wrapping_add(1);
        generation.set(next);
        next
    })
}

fn invalidate_webview_creation() {
    WEBVIEW_CREATION_GENERATION.with(|generation| {
        generation.set(generation.get().wrapping_add(1));
    });
}

fn ensure_webview_creation_is_current(generation: u64) -> Result<(), String> {
    WEBVIEW_CREATION_GENERATION.with(|current| {
        (current.get() == generation)
            .then_some(())
            .ok_or_else(|| "webview creation was canceled".to_string())
    })
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

fn is_collapsed_bounds(bounds: Rectangle) -> bool {
    bounds.x.is_finite()
        && bounds.y.is_finite()
        && bounds.width.is_finite()
        && bounds.height.is_finite()
        && (bounds.width <= 0.0 || bounds.height <= 0.0)
}

fn webview_bounds(bounds: Rectangle) -> Rect {
    Rect {
        position: LogicalPosition::new(bounds.x, bounds.y).into(),
        size: LogicalSize::new(bounds.width, bounds.height).into(),
    }
}

fn teardown_webview() -> bool {
    invalidate_webview_creation();
    #[cfg(test)]
    TEARDOWN_CALLS.with(|calls| calls.set(calls.get() + 1));
    #[cfg(target_os = "linux")]
    X11_TEARDOWN_STARTED.store(true, Ordering::Release);
    let webview_dropped = WEBVIEW.with(|slot| slot.borrow_mut().take().is_some());
    BOOK.with(|slot| slot.borrow_mut().take());
    webview_dropped
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

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_child_embedding_accepts_xlib_and_rejects_wayland() {
        use std::ffi::c_void;
        use std::ptr::NonNull;
        use wry::raw_window_handle::{WaylandWindowHandle, XlibWindowHandle};

        let xlib = RawWindowHandle::Xlib(XlibWindowHandle::new(1));
        assert_eq!(ensure_supported_parent_handle(xlib), Ok(()));

        let surface = NonNull::new(1_usize as *mut c_void).unwrap();
        let wayland = RawWindowHandle::Wayland(WaylandWindowHandle::new(surface));
        let error = ensure_supported_parent_handle(wayland).unwrap_err();
        assert!(error.contains("requires an Iced X11/Xlib window"));
        assert!(error.contains("unset WAYLAND_DISPLAY and WAYLAND_SOCKET"));
    }

    #[test]
    fn every_parent_close_path_tears_down_the_webview_first() {
        let id = window::Id::unique();
        let mut state = State {
            window: Some(id),
            ..State::default()
        };

        TEARDOWN_CALLS.with(|calls| calls.set(0));
        drop(update(
            &mut state,
            Message::WindowEvent(id, window::Event::CloseRequested),
        ));
        TEARDOWN_CALLS.with(|calls| assert_eq!(calls.get(), 1, "ordinary close must teardown"));

        TEARDOWN_CALLS.with(|calls| calls.set(0));
        drop(finish_network_proof(
            &mut state,
            Err("simulated proof failure".into()),
        ));
        TEARDOWN_CALLS.with(|calls| assert_eq!(calls.get(), 1, "network proof must teardown"));
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
        assert_eq!(proof, LifecycleProof::Interacting { expected });
        assert!(proof.complete());
        assert_eq!(proof, LifecycleProof::Complete);
        assert!(!proof.observe_synchronization(Some(expected), true));
        assert!(!proof.complete());
    }

    #[test]
    fn overlay_proof_requires_current_successful_hide_before_advancing() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut proof = OverlayProof::WaitingForCreation;

        assert!(proof.begin_hiding(bounds, 7));
        assert!(!proof.observe_hidden(6, true));
        assert!(!proof.observe_hidden(7, false));
        assert_eq!(
            proof,
            OverlayProof::Hiding {
                bounds,
                generation: 7
            }
        );
        assert!(proof.observe_hidden(7, true));
        assert_eq!(
            proof,
            OverlayProof::Hidden {
                bounds,
                generation: 7
            }
        );
    }

    #[test]
    fn bounds_proof_requires_observed_zero_bounds_at_current_epoch() {
        let valid = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let collapsed = Rectangle {
            height: 0.0,
            ..valid
        };
        let mut proof = BoundsProof::WaitingForCreation;

        assert!(proof.begin_collapse(4, 9));
        assert!(!proof.observe_invalid(3, Some(collapsed)));
        assert!(!proof.observe_invalid(4, Some(valid)));
        assert!(!proof.observe_invalid(
            4,
            Some(Rectangle {
                height: f32::NAN,
                ..valid
            })
        ));
        assert!(proof.observe_invalid(4, Some(collapsed)));
        assert_eq!(proof, BoundsProof::Hiding { generation: 9 });

        let mut missing = BoundsProof::WaitingForCreation;
        assert!(missing.begin_collapse(5, 10));
        assert!(missing.observe_invalid(5, None));
        assert_eq!(missing, BoundsProof::Hiding { generation: 10 });
    }

    #[test]
    fn bounds_proof_restores_only_after_current_hide_and_valid_measurement() {
        let valid = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut proof = BoundsProof::Hiding { generation: 9 };

        assert!(!proof.begin_restore(8, 5));
        assert!(proof.begin_restore(9, 5));
        assert_eq!(proof.observe_restored(4, Some(valid)), None);
        assert_eq!(
            proof.observe_restored(
                5,
                Some(Rectangle {
                    height: 0.0,
                    ..valid
                })
            ),
            None
        );
        assert_eq!(proof.observe_restored(5, Some(valid)), Some(valid));
        assert!(proof.expects_replacement(valid));
    }

    #[test]
    fn stale_bounds_replacement_cannot_complete_proof() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut state = State {
            bounds_proof: BoundsProof::Recreating { expected: bounds },
            applied_bounds: Some(bounds),
            webview_generation: 4,
            ..State::default()
        };

        drop(update_bounds_replacement(&mut state, 3, bounds, Ok(())));
        drop(update_bounds_replacement(
            &mut state,
            4,
            Rectangle {
                width: 1.0,
                ..bounds
            },
            Ok(()),
        ));

        assert_eq!(
            state.bounds_proof,
            BoundsProof::Recreating { expected: bounds }
        );
    }

    #[test]
    fn stale_bounds_hide_callback_cannot_destroy_current_webview() {
        let mut state = State {
            bounds_proof: BoundsProof::Hiding { generation: 2 },
            webview_generation: 3,
            ..State::default()
        };

        drop(update_bounds_hidden(&mut state, 2, Ok(())));

        assert_eq!(state.bounds_proof, BoundsProof::Hiding { generation: 2 });
    }

    #[test]
    fn bounds_proof_timeout_is_terminal() {
        let now = Instant::now();
        let mut state = State {
            bounds_proof: BoundsProof::WaitingForInvalid {
                epoch: 1,
                generation: 1,
            },
            proof_timeout: Some(now),
            ..State::default()
        };
        BOUNDS_PROOF_RESULT.with(|result| *result.borrow_mut() = None);

        drop(update_bounds_proof(&mut state, now));

        assert_eq!(state.bounds_proof, BoundsProof::Complete);
        BOUNDS_PROOF_RESULT.with(|result| {
            assert!(
                result
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .as_ref()
                    .unwrap_err()
                    .contains("WaitingForInvalid")
            );
        });
    }

    #[test]
    fn overlay_proof_recreates_only_after_dismissal() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut proof = OverlayProof::Hidden {
            bounds,
            generation: 11,
        };

        assert!(proof.begin_dismissing());
        assert_eq!(proof.begin_recreating(), Some(bounds));
        assert!(proof.expects_replacement_verification(bounds));
        assert!(!proof.expects_replacement_verification(Rectangle {
            width: 1.0,
            ..bounds
        }));
    }

    #[test]
    fn active_overlay_phases_block_geometry_synchronization() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        for mut proof in [
            OverlayProof::Hiding {
                bounds,
                generation: 1,
            },
            OverlayProof::Hidden {
                bounds,
                generation: 1,
            },
            OverlayProof::Dismissing {
                bounds,
                generation: 1,
            },
        ] {
            assert!(proof.blocks_geometry_synchronization());
            let updated = Rectangle {
                width: 1.0,
                ..bounds
            };
            assert!(proof.update_bounds_while_hidden(updated));
            assert!(matches!(
                proof,
                OverlayProof::Hiding { bounds, .. }
                    | OverlayProof::Hidden { bounds, .. }
                    | OverlayProof::Dismissing { bounds, .. }
                    if bounds == updated
            ));
        }
        let mut recreating = OverlayProof::Recreating { bounds };
        assert!(!recreating.blocks_geometry_synchronization());
        assert!(!recreating.update_bounds_while_hidden(Rectangle {
            width: 1.0,
            ..bounds
        }));
    }

    #[test]
    fn overlay_replacement_rejects_stale_generation_and_bounds() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut state = State {
            overlay_proof: OverlayProof::Recreating { bounds },
            applied_bounds: Some(bounds),
            webview_generation: 4,
            ..State::default()
        };

        drop(update_overlay_replacement(&mut state, 3, bounds, Ok(())));
        drop(update_overlay_replacement(
            &mut state,
            4,
            Rectangle {
                width: 1.0,
                ..bounds
            },
            Ok(()),
        ));

        assert_eq!(state.overlay_proof, OverlayProof::Recreating { bounds });
    }

    #[test]
    fn overlay_modes_reject_conflicting_proofs() {
        assert!(validate_proof_mode_selection(false, false, true, false, false).is_ok());
        assert!(validate_proof_mode_selection(false, false, false, true, false).is_ok());
        assert!(validate_proof_mode_selection(false, false, false, false, true).is_ok());
        assert!(validate_proof_mode_selection(true, false, true, false, false).is_err());
        assert!(validate_proof_mode_selection(false, true, true, false, false).is_err());
        assert!(validate_proof_mode_selection(false, false, true, true, false).is_err());
        assert!(validate_proof_mode_selection(true, false, false, true, false).is_err());
        assert!(validate_proof_mode_selection(false, true, false, false, true).is_err());
    }

    #[test]
    fn stale_overlay_callbacks_cannot_change_a_replacement_webview() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut state = State {
            overlay_proof: OverlayProof::Hiding {
                bounds,
                generation: 2,
            },
            overlay_active: true,
            webview_generation: 3,
            ..State::default()
        };

        drop(update_overlay_hidden(&mut state, 2, Ok(())));

        assert_eq!(
            state.overlay_proof,
            OverlayProof::Hiding {
                bounds,
                generation: 2
            }
        );
        assert!(state.overlay_active);
    }

    #[test]
    fn parent_close_invalidates_queued_overlay_callbacks() {
        let id = window::Id::unique();
        let mut state = State {
            window: Some(id),
            webview_generation: 9,
            ..State::default()
        };

        drop(update(
            &mut state,
            Message::WindowEvent(id, window::Event::CloseRequested),
        ));

        assert_eq!(state.webview_generation, 10);
    }

    #[test]
    fn overlay_hide_fails_when_webview_is_missing() {
        assert_eq!(
            set_webview_visible(None, false).unwrap_err(),
            "webview is not available"
        );
    }

    #[test]
    fn overlay_recreation_fails_when_hidden_webview_is_missing() {
        let now = Instant::now();
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut state = State {
            window: Some(window::Id::unique()),
            overlay_proof: OverlayProof::Dismissing {
                bounds,
                generation: 1,
            },
            overlay_restore_deadline: Some(now),
            webview_generation: 1,
            ..State::default()
        };
        OVERLAY_PROOF_RESULT.with(|result| *result.borrow_mut() = None);
        WEBVIEW.with(|webview| *webview.borrow_mut() = None);

        drop(update_overlay_proof(&mut state, now));

        assert_eq!(state.overlay_proof, OverlayProof::Complete);
        OVERLAY_PROOF_RESULT.with(|result| {
            assert_eq!(
                result.borrow().as_ref().unwrap().as_ref().unwrap_err(),
                "webview was missing before overlay replacement"
            );
        });
    }

    #[test]
    fn proof_results_are_terminal() {
        let mut result = None;
        record_terminal_result(&mut result, Err("timed out".into()));
        record_terminal_result(&mut result, Ok(()));

        assert_eq!(result, Some(Err("timed out".into())));
    }

    #[test]
    fn completed_proof_ignores_late_webview_creation() {
        let bounds = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let mut state = State {
            lifecycle_proof: LifecycleProof::Complete,
            creation_bounds: Some(bounds),
            ..State::default()
        };

        drop(update(&mut state, Message::WebViewCreated(Ok(()))));

        assert!(!state.webview_ready);
        assert_eq!(state.creation_bounds, Some(bounds));
    }

    #[test]
    fn completed_bounds_proof_ignores_late_placeholder_measurement() {
        let bounds = Rectangle::new((0.0, 112.0).into(), (900.0, 588.0).into());
        let mut state = State {
            window: Some(window::Id::unique()),
            bounds_proof: BoundsProof::Complete,
            ..State::default()
        };

        drop(update(
            &mut state,
            Message::PlaceholderMeasured {
                epoch: 2,
                bounds: Some(bounds),
            },
        ));

        assert_eq!(state.measured_bounds, None);
        assert_eq!(state.creation_bounds, None);
        assert!(!state.webview_ready);
    }

    #[test]
    fn terminal_bounds_proof_clears_native_geometry_state() {
        let bounds = Rectangle::new((0.0, 112.0).into(), (900.0, 588.0).into());
        let mut state = State {
            bounds_proof: BoundsProof::WaitingForInvalid {
                epoch: 1,
                generation: 1,
            },
            measured_bounds: Some(bounds),
            creation_bounds: Some(bounds),
            applied_bounds: Some(bounds),
            webview_ready: true,
            ..State::default()
        };
        BOUNDS_PROOF_RESULT.with(|result| *result.borrow_mut() = None);

        drop(finish_bounds_proof(
            &mut state,
            Err("simulated failure".into()),
        ));

        assert!(!state.webview_ready);
        assert_eq!(state.measured_bounds, None);
        assert_eq!(state.creation_bounds, None);
        assert_eq!(state.applied_bounds, None);
    }

    #[test]
    fn bounds_proof_rejects_synchronization_while_waiting_for_creation() {
        let bounds = Rectangle::new((0.0, 112.0).into(), (900.0, 588.0).into());
        let mut state = State {
            bounds_proof: BoundsProof::WaitingForCreation,
            ..State::default()
        };
        BOUNDS_PROOF_RESULT.with(|result| *result.borrow_mut() = None);

        drop(update(
            &mut state,
            Message::WebViewSynchronized {
                bounds: Some(bounds),
                result: Ok(()),
            },
        ));

        assert_eq!(state.bounds_proof, BoundsProof::Complete);
        BOUNDS_PROOF_RESULT.with(|result| {
            assert_eq!(
                result.borrow().as_ref().unwrap().as_ref().unwrap_err(),
                "unexpected webview synchronization during bounds proof"
            );
        });
    }

    #[test]
    fn invalidated_creation_is_rejected_before_callback_mutation() {
        let generation = begin_webview_creation();
        invalidate_webview_creation();

        assert_eq!(
            ensure_webview_creation_is_current(generation).unwrap_err(),
            "webview creation was canceled"
        );
    }

    #[test]
    fn replacement_requires_observed_size_before_completion() {
        let expected = Rectangle::new((0.0, 100.0).into(), (900.0, 600.0).into());
        let proof = LifecycleProof::Recreating { expected };

        assert!(proof.expects_replacement_verification(expected));
        assert!(!proof.expects_replacement_verification(Rectangle {
            width: 1.0,
            ..expected
        }));
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
        assert_eq!(
            exercise_webview_interactions(None, bounds).unwrap_err(),
            "webview is not available"
        );
        assert_eq!(
            verify_webview_size(None, bounds).unwrap_err(),
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
