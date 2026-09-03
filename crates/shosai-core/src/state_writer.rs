//! Coalesced, bounded persistence for reader state, progress, and preferences.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use thiserror::Error;
use tokio::sync::{Notify, oneshot};

use crate::library::Library;
use crate::path_key::canonical_path_key;
use crate::reading_state::{FileReadingState, ReadingStateStore};

pub const MAX_PENDING_STATE_WRITES: usize = 4_096;
pub const MAX_PENDING_STATE_FLUSHES: usize = 256;
const RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(100);

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
    Path(String),
}

impl SaveKey {
    fn for_save(save: &StateSave) -> Self {
        save.book_id
            .map_or_else(|| Self::Path(canonical_path_key(&save.path)), Self::Book)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum WriteKey {
    Save(SaveKey),
    Progress(i64),
    Preference(String),
}

#[derive(Debug, Default)]
struct Pending {
    saves: HashMap<SaveKey, StateSave>,
    progress: HashMap<i64, f64>,
    preferences: HashMap<String, String>,
    flushes: Vec<oneshot::Sender<Result<(), PersistError>>>,
}

impl Pending {
    fn insert(&mut self, message: StateWriterMessage) {
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

    fn write_keys(&self) -> HashSet<WriteKey> {
        self.saves
            .keys()
            .cloned()
            .map(WriteKey::Save)
            .chain(self.progress.keys().copied().map(WriteKey::Progress))
            .chain(self.preferences.keys().cloned().map(WriteKey::Preference))
            .collect()
    }

    fn contains(&self, key: &WriteKey) -> bool {
        match key {
            WriteKey::Save(key) => self.saves.contains_key(key),
            WriteKey::Progress(book_id) => self.progress.contains_key(book_id),
            WriteKey::Preference(key) => self.preferences.contains_key(key),
        }
    }
}

#[derive(Debug, Default)]
struct WriterState {
    pending: Pending,
    admitted: HashSet<WriteKey>,
}

impl WriterState {
    fn insert(&mut self, message: StateWriterMessage) -> Result<(), StateWriterSendError> {
        let key = message_key(&message);
        if let Some(key) = &key
            && !self.admitted.contains(key)
            && self.admitted.len() >= MAX_PENDING_STATE_WRITES
        {
            return Err(StateWriterSendError::Full);
        }
        if let Some(key) = key {
            self.admitted.insert(key);
        }
        self.pending.insert(message);
        Ok(())
    }
}

#[derive(Debug)]
struct StateWriterInner {
    state: Mutex<WriterState>,
    notify: Notify,
    stopped: AtomicBool,
    handles: AtomicUsize,
    outstanding_flushes: AtomicUsize,
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
        let is_flush = matches!(message, StateWriterMessage::Flush(_));
        if is_flush
            && !increment_bounded(&self.inner.outstanding_flushes, MAX_PENDING_STATE_FLUSHES)
        {
            return Err(StateWriterSendError::Full);
        }
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.inner.stopped.load(Ordering::Acquire) {
            if is_flush {
                self.inner
                    .outstanding_flushes
                    .fetch_sub(1, Ordering::AcqRel);
            }
            return Err(StateWriterSendError::Stopped);
        }
        if let Err(error) = state.insert(message) {
            if is_flush {
                self.inner
                    .outstanding_flushes
                    .fetch_sub(1, Ordering::AcqRel);
            }
            return Err(error);
        }
        drop(state);
        self.inner.notify.notify_one();
        Ok(())
    }
}

pub fn start_state_writer(store: ReadingStateStore) -> StateWriter {
    let inner = Arc::new(StateWriterInner {
        state: Mutex::new(WriterState::default()),
        notify: Notify::new(),
        stopped: AtomicBool::new(false),
        handles: AtomicUsize::new(1),
        outstanding_flushes: AtomicUsize::new(0),
    });
    let worker = Arc::clone(&inner);
    let library = Library::new(store.pool().clone(), store.managed_books_dir());
    tokio::spawn(async move {
        loop {
            worker.notify.notified().await;
            let mut batch = {
                let mut state = worker
                    .state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                std::mem::take(&mut state.pending)
            };
            let flushes = std::mem::take(&mut batch.flushes);
            let attempted = batch.write_keys();
            let (failed, error) = persist_batch(&store, &library, batch).await;
            let failed_keys = failed.write_keys();
            {
                let mut state = worker
                    .state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                state.pending.merge_failed(failed);
                for key in attempted {
                    if !failed_keys.contains(&key) && !state.pending.contains(&key) {
                        state.admitted.remove(&key);
                    }
                }
            }
            for flush in flushes {
                let _ = flush.send(error.clone().map_or(Ok(()), Err));
                worker.outstanding_flushes.fetch_sub(1, Ordering::AcqRel);
            }
            if worker.stopped.load(Ordering::Acquire) {
                break;
            }
            if !failed_keys.is_empty() {
                tokio::time::sleep(RETRY_DELAY).await;
                worker.notify.notify_one();
            }
        }
    });
    StateWriter { inner }
}

fn message_key(message: &StateWriterMessage) -> Option<WriteKey> {
    match message {
        StateWriterMessage::Save(save) => Some(WriteKey::Save(SaveKey::for_save(save))),
        StateWriterMessage::Progress { book_id, .. } => Some(WriteKey::Progress(*book_id)),
        StateWriterMessage::Preference(key, _) => Some(WriteKey::Preference(key.clone())),
        StateWriterMessage::Flush(_) => None,
    }
}

fn increment_bounded(counter: &AtomicUsize, limit: usize) -> bool {
    counter
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < limit).then_some(count + 1)
        })
        .is_ok()
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
        let mut state = WriterState::default();
        for (path, page) in [("old.epub", 1), ("new.epub", 2)] {
            state
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

        assert_eq!(state.pending.saves.len(), 1);
        assert_eq!(
            state.pending.saves[&SaveKey::Book(7)].path,
            PathBuf::from("new.epub")
        );
        assert_eq!(state.pending.saves[&SaveKey::Book(7)].reading.page, 2);
    }

    #[test]
    fn distinct_pending_writes_are_bounded_but_existing_keys_can_update() {
        let mut state = WriterState::default();
        for index in 0..MAX_PENDING_STATE_WRITES {
            state
                .insert(StateWriterMessage::Preference(
                    format!("key-{index}"),
                    "old".to_owned(),
                ))
                .unwrap();
        }

        state
            .insert(StateWriterMessage::Preference(
                "key-0".to_owned(),
                "new".to_owned(),
            ))
            .unwrap();
        assert_eq!(
            state.insert(StateWriterMessage::Preference(
                "overflow".to_owned(),
                "value".to_owned()
            )),
            Err(StateWriterSendError::Full)
        );
        assert_eq!(state.pending.preferences["key-0"], "new");
    }

    #[test]
    fn failed_in_flight_writes_remain_inside_the_global_admission_bound() {
        let mut state = WriterState::default();
        for index in 0..MAX_PENDING_STATE_WRITES {
            state
                .insert(StateWriterMessage::Preference(
                    format!("first-{index}"),
                    "value".to_owned(),
                ))
                .unwrap();
        }
        let failed = std::mem::take(&mut state.pending);

        assert_eq!(
            state.insert(StateWriterMessage::Preference(
                "not-admitted".to_owned(),
                "value".to_owned(),
            )),
            Err(StateWriterSendError::Full)
        );
        state.pending.merge_failed(failed);
        assert_eq!(state.admitted.len(), MAX_PENDING_STATE_WRITES);
        assert_eq!(state.pending.write_keys().len(), MAX_PENDING_STATE_WRITES);
    }

    #[test]
    fn canonical_path_aliases_coalesce_to_the_latest_save() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.epub");
        std::fs::write(&path, b"book").unwrap();
        let alias = directory.path().join(".").join("book.epub");
        let mut state = WriterState::default();
        for (path, page) in [(path, 1), (alias, 2)] {
            state
                .insert(StateWriterMessage::Save(StateSave {
                    book_id: None,
                    path,
                    reading: FileReadingState {
                        page,
                        location_offset: None,
                        zoom: 1.0,
                    },
                }))
                .unwrap();
        }

        assert_eq!(state.pending.saves.len(), 1);
        assert_eq!(state.pending.saves.values().next().unwrap().reading.page, 2);
    }

    #[test]
    fn outstanding_flushes_are_bounded() {
        let counter = AtomicUsize::new(0);
        for _ in 0..MAX_PENDING_STATE_FLUSHES {
            assert!(increment_bounded(&counter, MAX_PENDING_STATE_FLUSHES));
        }
        assert!(!increment_bounded(&counter, MAX_PENDING_STATE_FLUSHES));
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

    #[tokio::test]
    async fn failed_writes_retry_without_another_producer_message() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        sqlx::query(
            "CREATE TRIGGER reject_test_preference
             BEFORE INSERT ON preferences
             BEGIN SELECT RAISE(FAIL, 'temporary failure'); END",
        )
        .execute(store.pool())
        .await
        .unwrap();
        let writer = start_state_writer(store.clone());
        writer
            .send(StateWriterMessage::Preference(
                "language".to_owned(),
                "en".to_owned(),
            ))
            .unwrap();
        let (flushed, wait) = oneshot::channel();
        writer.send(StateWriterMessage::Flush(flushed)).unwrap();
        assert!(wait.await.unwrap().is_err());

        sqlx::query("DROP TRIGGER reject_test_preference")
            .execute(store.pool())
            .await
            .unwrap();

        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if store.get_pref_async("language").await.as_deref() == Some("en") {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("retained write should retry autonomously");
    }
}
