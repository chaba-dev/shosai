//! Coalesced persistence for reader state, progress, and preferences.

use std::collections::HashMap;
use std::path::PathBuf;

use tokio::sync::{mpsc, oneshot};

use crate::library::Library;
use crate::reading_state::{FileReadingState, ReadingStateStore};

#[derive(Debug)]
pub struct StateSave {
    pub book_id: Option<i64>,
    pub path: PathBuf,
    pub reading: FileReadingState,
}

#[derive(Debug)]
pub enum StateWriterMessage {
    Save(StateSave),
    Progress { book_id: i64, progress: f64 },
    Preference(String, String),
    Flush(oneshot::Sender<()>),
}

pub fn start_state_writer(store: ReadingStateStore) -> mpsc::UnboundedSender<StateWriterMessage> {
    let (sender, mut receiver) = mpsc::unbounded_channel::<StateWriterMessage>();
    let library = Library::new(store.pool().clone(), store.managed_books_dir());
    tokio::spawn(async move {
        while let Some(first) = receiver.recv().await {
            let mut pending = HashMap::new();
            let mut progress = HashMap::new();
            let mut preferences = HashMap::new();
            let mut flushes = Vec::new();
            collect(
                first,
                &mut pending,
                &mut progress,
                &mut preferences,
                &mut flushes,
            );
            while let Ok(message) = receiver.try_recv() {
                collect(
                    message,
                    &mut pending,
                    &mut progress,
                    &mut preferences,
                    &mut flushes,
                );
            }

            for ((book_id, path), reading) in pending {
                let result = if let Some(book_id) = book_id {
                    store.set_for_book_async(book_id, &path, &reading).await
                } else {
                    store.set_async(&path, &reading).await
                };
                if let Err(error) = result {
                    eprintln!("warning: failed to save reading state: {error}");
                }
            }
            for (book_id, progress) in progress {
                if let Err(error) = library.update_progress(book_id, progress).await {
                    eprintln!("warning: failed to save library progress: {error}");
                }
            }
            for (key, value) in preferences {
                if let Err(error) = store.set_pref_async(&key, &value).await {
                    eprintln!("warning: failed to save preference {key}: {error}");
                }
            }
            for flush in flushes {
                let _ = flush.send(());
            }
        }
    });
    sender
}

fn collect(
    message: StateWriterMessage,
    pending: &mut HashMap<(Option<i64>, PathBuf), FileReadingState>,
    progress: &mut HashMap<i64, f64>,
    preferences: &mut HashMap<String, String>,
    flushes: &mut Vec<oneshot::Sender<()>>,
) {
    match message {
        StateWriterMessage::Save(save) => {
            pending.insert((save.book_id, save.path), save.reading);
        }
        StateWriterMessage::Progress {
            book_id,
            progress: value,
        } => {
            progress.insert(book_id, value);
        }
        StateWriterMessage::Preference(key, value) => {
            preferences.insert(key, value);
        }
        StateWriterMessage::Flush(flush) => flushes.push(flush),
    }
}
