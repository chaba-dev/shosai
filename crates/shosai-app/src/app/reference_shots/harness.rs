//! The capture driver: it dispatches the production `update` messages against a
//! seeded `State` and settles everything the application starts, so a capture
//! state is produced by the same code path a running window uses.
//!
//! A capture never mutates the model from the harness: every field change comes
//! from `update`. The only exception is documented per capture in
//! [`super::scenarios`] and is limited to seeding (disposable database) and to
//! injecting a *real* failure result through the production message that would
//! carry it.

use std::collections::VecDeque;

use iced::Task;

use super::super::{Message, State, update};

/// Upper bound on settled messages per capture. A task that never finishes
/// fails the run instead of hanging it.
const SETTLE_LIMIT: usize = 200_000;

/// Upper bound on the frame rounds a capture may take to settle.
///
/// `iced_winit` bounds the redraw events it delivers per message batch
/// ([`super::render::MAX_REDRAW_EVENTS`]), but its event loop then dispatches the
/// messages and draws again: a view that publishes a message per frame — the
/// reader's continuous-mode chapter sensors and scroll viewport do — settles
/// over several such rounds as the state it reads converges. This is the
/// harness's equivalent of that outer loop, so the bound is larger than the
/// inner one. A capture that never settles still fails instead of looping.
const MAX_FRAME_ROUNDS: usize = 16;

/// A capture-state driver.
pub(crate) struct Harness {
    pub(crate) state: State,
    /// How many task outputs were delivered, for the run log.
    pub(crate) settled: usize,
    /// The interface tree the capture is building.
    ///
    /// It is carried across the scenario, the widget operations the scenario's
    /// messages start (a focus request, a scroll) and every rendered frame, the
    /// way a window carries one interface across its event loop. A widget
    /// operation mutates widget-local state, so applying it to a fresh tree
    /// would drop the focus ring or the scroll offset the capture is supposed to
    /// show.
    pub(crate) interface_cache: iced_runtime::user_interface::Cache,
    /// The pointer position the frames are drawn with.
    ///
    /// A capture that shows a hover state (`RD-06`) sets it; every other
    /// capture keeps the pointer unavailable, which is what a window with no
    /// pointer over it delivers.
    pub(crate) cursor: iced::mouse::Cursor,
}

impl Harness {
    pub(crate) fn new(state: State) -> Self {
        Self {
            state,
            settled: 0,
            interface_cache: iced_runtime::user_interface::Cache::new(),
            cursor: iced::mouse::Cursor::Unavailable,
        }
    }

    /// Dispatch one production message and settle every task it starts.
    pub(crate) async fn dispatch(&mut self, message: Message) {
        let task = self.start(message);
        self.settle(task).await;
    }

    /// Dispatch one production message and return the task *without* settling
    /// it: this is the in-flight state a real window shows while the task runs.
    pub(crate) fn start(&mut self, message: Message) -> Task<Message> {
        update(&mut self.state, message)
    }

    /// Drive a task and all follow-up tasks to completion, delivering every
    /// output message through `update` exactly like the runtime would.
    pub(crate) async fn settle(&mut self, task: Task<Message>) {
        use iced::futures::StreamExt;

        let mut pending: VecDeque<Task<Message>> = VecDeque::new();
        pending.push_back(task);
        while let Some(task) = pending.pop_front() {
            let Some(mut stream) = iced_runtime::task::into_stream(task) else {
                continue;
            };
            while let Some(action) = stream.next().await {
                match action {
                    iced_runtime::Action::Output(message) => {
                        self.settled += 1;
                        assert!(
                            self.settled <= SETTLE_LIMIT,
                            "capture task did not settle within {SETTLE_LIMIT} messages"
                        );
                        pending.push_back(update(&mut self.state, message));
                    }
                    // A widget operation is part of the production path: the
                    // reader's continuous-mode scroll resolution is one. In a
                    // window the runtime applies it to the live interface;
                    // `render::operate` applies it to an interface built from
                    // the same state and view, so the task completes with the
                    // value it would have reported.
                    iced_runtime::Action::Widget(mut operation) => {
                        let cache = std::mem::take(&mut self.interface_cache);
                        self.interface_cache =
                            super::render::operate(&self.state, operation.as_mut(), cache);
                    }
                    _ => continue,
                }
            }
        }
    }

    /// Run a task to completion without delivering its outputs.
    ///
    /// This is how the discovery "checking copies" phase is captured: the
    /// background snapshot in the model advances for real, while the final
    /// `BooksDiscovered` message is deliberately not delivered, exactly like a
    /// window that is still polling.
    pub(crate) async fn run_without_delivery(&mut self, task: Task<Message>) {
        use iced::futures::StreamExt;

        let Some(mut stream) = iced_runtime::task::into_stream(task) else {
            return;
        };
        while let Some(action) = stream.next().await {
            // The outputs are deliberately not delivered, but a widget
            // operation has to run for the stream to make progress at all: the
            // task is waiting on the value the operation sends.
            if let iced_runtime::Action::Widget(mut operation) = action {
                let cache = std::mem::take(&mut self.interface_cache);
                self.interface_cache =
                    super::render::operate(&self.state, operation.as_mut(), cache);
            }
        }
    }

    /// Render the current state through the production view.
    ///
    /// The frame is drawn after the first-frame requests the view itself makes
    /// (the library's card sensors ask for covers) have been dispatched through
    /// the production `update` and settled, with the interface tree kept across
    /// those frames, exactly like a real window's event loop.
    pub(crate) async fn render_image(
        &mut self,
        width: f32,
        height: f32,
        dpr: f32,
    ) -> super::render::RenderedImage {
        let mut rounds: Vec<Vec<Message>> = Vec::new();
        for _ in 0..MAX_FRAME_ROUNDS {
            let cache = std::mem::take(&mut self.interface_cache);
            match super::render::render_frame(&self.state, width, height, dpr, cache, self.cursor) {
                super::render::FrameOutcome::Settled(image) => return image,
                super::render::FrameOutcome::Requests(messages, next_cache) => {
                    self.interface_cache = next_cache;
                    for message in &messages {
                        self.dispatch(message.clone()).await;
                    }
                    rounds.push(messages);
                }
            }
        }
        panic!(
            "the capture view still asked for new frames after {MAX_FRAME_ROUNDS} frame rounds; \
             the last frames asked for {rounds:?}"
        );
    }
}
