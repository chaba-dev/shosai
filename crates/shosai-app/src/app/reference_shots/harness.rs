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

/// A capture-state driver.
pub(crate) struct Harness {
    pub(crate) state: State,
    /// How many task outputs were delivered, for the run log.
    pub(crate) settled: usize,
}

impl Harness {
    pub(crate) fn new(state: State) -> Self {
        Self { state, settled: 0 }
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
                let iced_runtime::Action::Output(message) = action else {
                    continue;
                };
                self.settled += 1;
                assert!(
                    self.settled <= SETTLE_LIMIT,
                    "capture task did not settle within {SETTLE_LIMIT} messages"
                );
                pending.push_back(update(&mut self.state, message));
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
        while stream.next().await.is_some() {}
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
        let mut cache = iced_runtime::user_interface::Cache::new();
        for _ in 0..super::render::MAX_REDRAW_EVENTS {
            match super::render::render_frame(&self.state, width, height, dpr, cache) {
                super::render::FrameOutcome::Settled(image) => return image,
                super::render::FrameOutcome::Requests(messages, next_cache) => {
                    cache = next_cache;
                    for message in messages {
                        self.dispatch(message).await;
                    }
                }
            }
        }
        panic!(
            "the capture view still asked for new frames after {} redraw events",
            super::render::MAX_REDRAW_EVENTS
        );
    }
}
