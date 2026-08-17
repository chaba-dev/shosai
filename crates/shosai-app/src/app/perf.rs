use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use iced::{Size, Subscription, Task, window};

use super::{
    Message, State, epub_uses_spread, flush_reading_state_before_close, sync_epub_location,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    WarmPageTurn,
    ChapterTransition,
    Relayout,
}

impl Kind {
    fn label(self) -> &'static str {
        match self {
            Self::WarmPageTurn => "warm-page-turn",
            Self::ChapterTransition => "chapter-transition",
            Self::Relayout => "relayout",
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum AutomatedAction {
    WarmPageTurn,
    ChapterTransition,
    Relayout,
}

impl AutomatedAction {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "warm" => Some(Self::WarmPageTurn),
            "chapter" => Some(Self::ChapterTransition),
            "relayout" => Some(Self::Relayout),
            _ => None,
        }
    }
}

#[derive(Debug)]
struct Pending {
    kind: Kind,
    started: Instant,
    mode: &'static str,
    reader_width: f32,
}

#[derive(Debug)]
struct Runner {
    action: AutomatedAction,
    remaining: usize,
    forward: bool,
    positioned: bool,
    action_scheduled: bool,
    warmup_frames: usize,
    warmup_samples: usize,
    readiness_frames: usize,
}

impl Runner {
    fn pages_timed_out(&mut self) -> bool {
        self.readiness_frames = self.readiness_frames.saturating_sub(1);
        self.readiness_frames == 0
    }
}

#[derive(Debug)]
pub(super) struct Performance {
    enabled: bool,
    fixture: String,
    pending: Option<Pending>,
    samples: BTreeMap<Kind, Vec<Duration>>,
    runner: Option<Runner>,
    window_size: Option<Size>,
}

impl Performance {
    pub(super) fn from_environment() -> (Self, Option<PathBuf>) {
        let file = std::env::var_os("SHOSAI_PERF_FILE").map(PathBuf::from);
        let action = std::env::var("SHOSAI_PERF_ACTION")
            .ok()
            .and_then(|value| AutomatedAction::parse(&value));
        let enabled = std::env::var_os("SHOSAI_PERF").is_some() || action.is_some();
        let fixture = file
            .as_deref()
            .and_then(|path| path.file_name())
            .and_then(|name| name.to_str())
            .unwrap_or("interactive")
            .to_string();
        let samples = std::env::var("SHOSAI_PERF_SAMPLES")
            .ok()
            .and_then(|value| value.parse().ok())
            .filter(|samples| *samples > 0)
            .unwrap_or(50);
        let window_size = action.and_then(|_| {
            std::env::var("SHOSAI_PERF_WIDTH")
                .ok()
                .and_then(|value| value.parse().ok())
                .map(|width| Size::new(width, 700.0))
        });
        let runner = action.map(|action| Runner {
            action,
            remaining: samples,
            forward: true,
            positioned: false,
            action_scheduled: false,
            warmup_frames: 60,
            warmup_samples: 5,
            readiness_frames: 600,
        });

        if enabled {
            eprintln!(
                "perf-config profile={} fixture={} samples={} action={}",
                if cfg!(debug_assertions) {
                    "debug"
                } else {
                    "release"
                },
                fixture,
                samples,
                std::env::var("SHOSAI_PERF_ACTION").unwrap_or_else(|_| "interactive".into())
            );
        }

        (
            Self {
                enabled,
                fixture,
                pending: None,
                samples: BTreeMap::new(),
                runner,
                window_size,
            },
            file,
        )
    }

    pub(super) fn is_automated(&self) -> bool {
        self.runner.is_some()
    }

    pub(super) fn window_size(&self) -> Option<Size> {
        self.window_size
    }
}

pub(super) fn window_resized(state: &mut State, size: Size) {
    if !state.performance.is_automated() {
        return;
    }
    eprintln!(
        "perf-window width={} height={}",
        size.width.round(),
        size.height.round()
    );
    state.performance.pending = None;
    if let Some(runner) = state.performance.runner.as_mut() {
        runner.forward = true;
        runner.positioned = false;
        runner.action_scheduled = false;
        runner.warmup_frames = 60;
        runner.readiness_frames = 600;
    }
}

pub(super) fn begin_page_turn(state: &mut State, target_page: usize) {
    if !state.performance.enabled || state.performance.pending.is_some() {
        return;
    }
    let Some(current) = state.epub_pages.get(state.epub_page) else {
        return;
    };
    let Some(target) = state.epub_pages.get(target_page) else {
        return;
    };
    let kind = if current.chapter == target.chapter {
        Kind::WarmPageTurn
    } else {
        Kind::ChapterTransition
    };
    begin(state, kind);
}

pub(super) fn begin_relayout(state: &mut State) {
    if state.performance.enabled && state.performance.pending.is_none() {
        begin(state, Kind::Relayout);
    }
}

fn begin(state: &mut State, kind: Kind) {
    state.performance.pending = Some(Pending {
        kind,
        started: Instant::now(),
        mode: if epub_uses_spread(state) {
            "spread"
        } else {
            "single"
        },
        reader_width: super::available_reader_size(state).width,
    });
}

pub(super) fn subscription(state: &State) -> Subscription<Message> {
    let runner_needs_frame = state
        .performance
        .runner
        .as_ref()
        .is_some_and(|runner| !runner.action_scheduled);
    if state.performance.pending.is_some() || runner_needs_frame {
        window::frames().map(|_| Message::PerfFramePresented)
    } else {
        Subscription::none()
    }
}

pub(super) fn frame_presented(state: &mut State) -> Task<Message> {
    let completed_sample = if let Some(pending) = state.performance.pending.take() {
        let elapsed = pending.started.elapsed();
        let is_warmup = state
            .performance
            .runner
            .as_ref()
            .is_some_and(|runner| runner.warmup_samples > 0);
        eprintln!(
            "perf-{} operation={} fixture={} mode={} reader_width={} duration_ms={:.3}",
            if is_warmup { "warmup" } else { "sample" },
            pending.kind.label(),
            state.performance.fixture,
            pending.mode,
            pending.reader_width.round(),
            elapsed.as_secs_f64() * 1_000.0
        );
        if !is_warmup {
            state
                .performance
                .samples
                .entry(pending.kind)
                .or_default()
                .push(elapsed);
        }
        if let Some(runner) = state.performance.runner.as_mut() {
            if runner.warmup_samples > 0 {
                runner.warmup_samples -= 1;
            } else {
                runner.remaining = runner.remaining.saturating_sub(1);
            }
            runner.action_scheduled = false;
        }
        true
    } else {
        false
    };

    let Some(runner) = state.performance.runner.as_ref() else {
        if completed_sample {
            print_summaries(&state.performance);
        }
        return Task::none();
    };
    if runner.remaining == 0 {
        print_summaries(&state.performance);
        state.performance.runner = None;
        return state
            .window_id
            .map(|id| flush_reading_state_before_close(state, id))
            .unwrap_or_else(iced::exit);
    }
    if runner.action_scheduled || state.performance.pending.is_some() {
        return Task::none();
    }
    if state.epub_pages.is_empty() {
        if state
            .performance
            .runner
            .as_mut()
            .is_some_and(Runner::pages_timed_out)
        {
            return fail(state, "pages did not become ready");
        }
        return Task::none();
    }

    if runner.warmup_frames > 0 {
        state.performance.runner.as_mut().unwrap().warmup_frames -= 1;
        return Task::none();
    }

    if !runner.positioned {
        let pair = match runner.action {
            AutomatedAction::WarmPageTurn => find_page_pair(state, true),
            AutomatedAction::ChapterTransition => find_page_pair(state, false),
            AutomatedAction::Relayout => Some((state.epub_page, state.epub_page)),
        };
        let Some((start, _)) = pair else {
            return fail(state, "action has no matching page pair");
        };
        state.epub_page = start;
        sync_epub_location(state);
        state.performance.runner.as_mut().unwrap().positioned = true;
        return Task::none();
    }

    let runner = state.performance.runner.as_mut().unwrap();
    let message = match runner.action {
        AutomatedAction::WarmPageTurn | AutomatedAction::ChapterTransition => {
            if runner.forward {
                Message::NextPage
            } else {
                Message::PrevPage
            }
        }
        AutomatedAction::Relayout => {
            if runner.forward {
                Message::FontSizeUp
            } else {
                Message::FontSizeDown
            }
        }
    };
    runner.forward = !runner.forward;
    runner.action_scheduled = true;
    Task::perform(
        async move { tokio::time::sleep(Duration::from_millis(40)).await },
        move |_| message.clone(),
    )
}

pub(super) fn fail(state: &mut State, reason: &str) -> Task<Message> {
    if state.performance.runner.take().is_none() {
        return Task::none();
    }
    eprintln!(
        "perf-error fixture={} reason={reason}",
        state.performance.fixture
    );
    state
        .window_id
        .map(|id| flush_reading_state_before_close(state, id))
        .unwrap_or_else(iced::exit)
}

fn find_page_pair(state: &State, same_chapter: bool) -> Option<(usize, usize)> {
    let step = if epub_uses_spread(state) { 2 } else { 1 };
    (0..state.epub_pages.len()).step_by(step).find_map(|start| {
        let next = start + step;
        let (Some(current), Some(target)) =
            (state.epub_pages.get(start), state.epub_pages.get(next))
        else {
            return None;
        };
        (same_chapter == (current.chapter == target.chapter)).then_some((start, next))
    })
}

fn print_summaries(performance: &Performance) {
    for (kind, samples) in &performance.samples {
        if samples.is_empty() {
            continue;
        }
        let mut milliseconds = samples
            .iter()
            .map(|sample| sample.as_secs_f64() * 1_000.0)
            .collect::<Vec<_>>();
        milliseconds.sort_by(f64::total_cmp);
        eprintln!(
            "perf-summary operation={} fixture={} samples={} p50_ms={:.3} p95_ms={:.3}",
            kind.label(),
            performance.fixture,
            milliseconds.len(),
            nearest_rank(&milliseconds, 0.50),
            nearest_rank(&milliseconds, 0.95)
        );
    }
}

fn nearest_rank(sorted_values: &[f64], percentile: f64) -> f64 {
    let rank = (percentile * sorted_values.len() as f64).ceil() as usize;
    sorted_values[rank.saturating_sub(1).min(sorted_values.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automated_actions_use_explicit_names() {
        assert!(matches!(
            AutomatedAction::parse("warm"),
            Some(AutomatedAction::WarmPageTurn)
        ));
        assert!(matches!(
            AutomatedAction::parse("chapter"),
            Some(AutomatedAction::ChapterTransition)
        ));
        assert!(matches!(
            AutomatedAction::parse("relayout"),
            Some(AutomatedAction::Relayout)
        ));
        assert!(AutomatedAction::parse("unknown").is_none());
    }

    #[test]
    fn percentile_uses_nearest_rank() {
        let values = (1..=20).map(f64::from).collect::<Vec<_>>();
        assert_eq!(nearest_rank(&values, 0.50), 10.0);
        assert_eq!(nearest_rank(&values, 0.95), 19.0);
    }

    #[test]
    fn automated_runner_bounds_waiting_for_pages() {
        let mut runner = Runner {
            action: AutomatedAction::WarmPageTurn,
            remaining: 1,
            forward: true,
            positioned: false,
            action_scheduled: false,
            warmup_frames: 0,
            warmup_samples: 0,
            readiness_frames: 2,
        };

        assert!(!runner.pages_timed_out());
        assert!(runner.pages_timed_out());
    }
}
