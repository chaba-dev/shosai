//! Coalesced, bounded persistence for reader state, progress, and preferences.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use thiserror::Error;
use tokio::sync::{Notify, oneshot};

use crate::library::Library;
use crate::reading_state::{FileReadingState, ReadingStateStore};

pub const MAX_PENDING_STATE_WRITES: usize = 4_096;

#[derive(Debug, Clone)]
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
    Flush(oneshot::Sender<Result<(), PersistError>>),
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
#[error("state persistence failed: {details}")]
pub struct PersistError {
    details: String,
}

impl PersistError {
    pub fn details(&self) -> &str {
        &self.details
    }
}

#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum StateWriterSendError {
    #[error("state writer stopped")]
    Stopped,
    #[error("state writer has {MAX_PENDING_STATE_WRITES} distinct pending writes")]
    Full,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum SaveKey {
    Book(i64),
    Path(PathBuf),
}

impl SaveKey {
    fn for_save(save: &StateSave) -> Self {
        save.book_id
            .map_or_else(|| Self::Path(save.path.clone()), Self::Book)
    }
}

#[derive(Debug, Default)]
struct Pending {
    saves: HashMap<SaveKey, StateSave>,
    progress: HashMap<i64, f64>,
    preferences: HashMap<String, String>,
    flushes: Vec<oneshot::Sender<Result<(), PersistError>>>,
}

impl Pending {
    fn write_count(&self) -> usize {
        self.saves.len() + self.progress.len() + self.preferences.len()
    }

    fn insert(&mut self, message: StateWriterMessage) -> Result<(), StateWriterSendError> {
        let adds_key = match &message {
            StateWriterMessage::Save(save) => !self.saves.contains_key(&SaveKey::for_save(save)),
            StateWriterMessage::Progress { book_id, .. } => !self.progress.contains_key(book_id),
            StateWriterMessage::Preference(key, _) => !self.preferences.contains_key(key),
            StateWriterMessage::Flush(_) => false,
        };
        if adds_key && self.write_count() >= MAX_PENDING_STATE_WRITES {
            return Err(StateWriterSendError::Full);
        }
        match message {
            StateWriterMessage::Save(save) => {
                self.saves.insert(SaveKey::for_save(&save), save);
            }
            StateWriterMessage::Progress {
                book_id,
                progress: value,
            } => {
                self.progress.insert(book_id, value);
            }
            StateWriterMessage::Preference(key, value) => {
                self.preferences.insert(key, value);
            }
            StateWriterMessage::Flush(flush) => self.flushes.push(flush),
        }
        Ok(())
    }

    fn merge_failed(&mut self, failed: Pending) {
        for (key, save) in failed.saves {
            self.saves.entry(key).or_insert(save);
        }
        for (book_id, progress) in failed.progress {
            self.progress.entry(book_id).or_insert(progress);
        }
        for (key, value) in failed.preferences {
            self.preferences.entry(key).or_insert(value);
        }
    }
}

#[derive(Debug)]
struct StateWriterInner {
    pending: Mutex<Pending>,
    notify: Notify,
    stopped: AtomicBool,
    handles: AtomicUsize,
}

#[derive(Debug)]
pub struct StateWriter {
    inner: Arc<StateWriterInner>,
}

impl Clone for StateWriter {
    fn clone(&self) -> Self {
        self.inner.handles.fetch_add(1, Ordering::Relaxed);
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl Drop for StateWriter {
    fn drop(&mut self) {
        if self.inner.handles.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.inner.stopped.store(true, Ordering::Release);
            self.inner.notify.notify_one();
        }
    }
}

impl StateWriter {
    pub fn send(&self, message: StateWriterMessage) -> Result<(), StateWriterSendError> {
        if self.inner.stopped.load(Ordering::Acquire) {
            return Err(StateWriterSendError::Stopped);
        }
        self.inner
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(message)?;
        self.inner.notify.notify_one();
        Ok(())
    }
}

pub fn start_state_writer(store: ReadingStateStore) -> StateWriter {
    let inner = Arc::new(StateWriterInner {
        pending: Mutex::new(Pending::default()),
        notify: Notify::new(),
        stopped: AtomicBool::new(false),
        handles: AtomicUsize::new(1),
    });
    let worker = Arc::clone(&inner);
    let library = Library::new(store.pool().clone(), store.managed_books_dir());
    tokio::spawn(async move {
        loop {
            worker.notify.notified().await;
            let mut batch = {
                let mut pending = worker
                    .pending
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                std::mem::take(&mut *pending)
            };
            let flushes = std::mem::take(&mut batch.flushes);
            let (failed, error) = persist_batch(&store, &library, batch).await;
            if failed.write_count() != 0 {
                worker
                    .pending
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .merge_failed(failed);
            }
            for flush in flushes {
                let _ = flush.send(error.clone().map_or(Ok(()), Err));
            }
            if worker.stopped.load(Ordering::Acquire) {
                break;
            }
        }
    });
    StateWriter { inner }
}

async fn persist_batch(
    store: &ReadingStateStore,
    library: &Library,
    mut batch: Pending,
) -> (Pending, Option<PersistError>) {
    let mut failed = Pending::default();
    let mut errors = Vec::new();
    for (key, save) in batch.saves.drain() {
        let result = if let Some(book_id) = save.book_id {
            store
                .set_for_book_async(book_id, &save.path, &save.reading)
                .await
        } else {
            store.set_async(&save.path, &save.reading).await
        };
        if let Err(error) = result {
            errors.push(format!("reading state: {error:#}"));
            failed.saves.insert(key, save);
        }
    }
    for (book_id, progress) in batch.progress.drain() {
        if let Err(error) = library.update_progress(book_id, progress).await {
            errors.push(format!("library progress: {error:#}"));
            failed.progress.insert(book_id, progress);
        }
    }
    for (key, value) in batch.preferences.drain() {
        if let Err(error) = store.set_pref_async(&key, &value).await {
            errors.push(format!("preference {key}: {error:#}"));
            failed.preferences.insert(key, value);
        }
    }
    let error = (!errors.is_empty()).then(|| PersistError {
        details: errors.join("; "),
    });
    (failed, error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn book_saves_coalesce_across_relocated_paths() {
        let mut pending = Pending::default();
        for (path, page) in [("old.epub", 1), ("new.epub", 2)] {
            pending
                .insert(StateWriterMessage::Save(StateSave {
                    book_id: Some(7),
                    path: path.into(),
                    reading: FileReadingState {
                        page,
                        location_offset: None,
                        zoom: 1.0,
                    },
                }))
                .unwrap();
        }

        assert_eq!(pending.saves.len(), 1);
        assert_eq!(
            pending.saves[&SaveKey::Book(7)].path,
            PathBuf::from("new.epub")
        );
        assert_eq!(pending.saves[&SaveKey::Book(7)].reading.page, 2);
    }

    #[test]
    fn distinct_pending_writes_are_bounded_but_existing_keys_can_update() {
        let mut pending = Pending::default();
        for index in 0..MAX_PENDING_STATE_WRITES {
            pending
                .insert(StateWriterMessage::Preference(
                    format!("key-{index}"),
                    "old".to_owned(),
                ))
                .unwrap();
        }

        pending
            .insert(StateWriterMessage::Preference(
                "key-0".to_owned(),
                "new".to_owned(),
            ))
            .unwrap();
        assert_eq!(
            pending.insert(StateWriterMessage::Preference(
                "overflow".to_owned(),
                "value".to_owned()
            )),
            Err(StateWriterSendError::Full)
        );
        assert_eq!(pending.preferences["key-0"], "new");
    }

    #[tokio::test]
    async fn flush_reports_write_failure_instead_of_acknowledging_success() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let writer = start_state_writer(store.clone());
        store.pool().close().await;
        writer
            .send(StateWriterMessage::Preference(
                "language".to_owned(),
                "en".to_owned(),
            ))
            .unwrap();
        let (flushed, wait) = oneshot::channel();
        writer.send(StateWriterMessage::Flush(flushed)).unwrap();

        let error = wait.await.unwrap().unwrap_err();
        assert!(error.details().contains("preference language"));
    }
}
