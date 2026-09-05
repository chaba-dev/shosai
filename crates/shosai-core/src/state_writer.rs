//! Coalesced, bounded persistence for reader state, progress, and preferences.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use thiserror::Error;
use tokio::sync::{Notify, oneshot};

use crate::library::Library;
use crate::path_key::canonical_path_key;
use crate::reading_state::{
    CurrentBookPathSaveError, FileReadingState, MAX_PREFERENCE_KEY_BYTES,
    MAX_PREFERENCE_VALUE_BYTES, MAX_READING_STATE_PATH_BYTES, ReadingStateStore,
};

pub const MAX_PENDING_STATE_WRITES: usize = 4_096;
pub const MAX_PENDING_STATE_FLUSHES: usize = 256;
pub const MAX_STATE_PATH_KEY_BYTES: usize = MAX_READING_STATE_PATH_BYTES;
pub const MAX_PENDING_STATE_WRITE_BYTES: usize = 4 * 1024 * 1024;
const RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(100);

#[derive(Debug, Clone)]
pub struct StateSave {
    pub book_id: Option<i64>,
    pub path: PathBuf,
    pub content_hash: Option<String>,
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
    Path(String, String),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum WriteKey {
    Save(SaveKey),
    Progress(i64),
    Preference(String),
}

#[derive(Debug)]
struct PreparedMessage {
    message: StateWriterMessage,
    key: Option<WriteKey>,
    normalized_path: Option<String>,
    byte_len: usize,
}

#[derive(Debug)]
struct PendingSave {
    save: StateSave,
    normalized_path: String,
    enqueue_sequence: u64,
    persistence_revision: Option<i64>,
}

#[derive(Debug, Default)]
struct Pending {
    saves: HashMap<SaveKey, PendingSave>,
    progress: HashMap<i64, f64>,
    preferences: HashMap<String, String>,
    flushes: Vec<oneshot::Sender<Result<(), PersistError>>>,
}

impl Pending {
    fn insert(&mut self, prepared: PreparedMessage, enqueue_sequence: Option<u64>) {
        match prepared.message {
            StateWriterMessage::Save(save) => {
                let Some(WriteKey::Save(key)) = prepared.key else {
                    unreachable!("prepared save must have a save key");
                };
                self.saves.insert(
                    key,
                    PendingSave {
                        save,
                        normalized_path: prepared
                            .normalized_path
                            .expect("prepared save must have a normalized path"),
                        enqueue_sequence: enqueue_sequence
                            .expect("prepared save must have an enqueue sequence"),
                        persistence_revision: None,
                    },
                );
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

    fn is_empty(&self) -> bool {
        self.saves.is_empty()
            && self.progress.is_empty()
            && self.preferences.is_empty()
            && self.flushes.is_empty()
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
    pending_bytes: HashMap<WriteKey, usize>,
    total_admitted_bytes: usize,
    next_save_sequence: u64,
}

impl WriterState {
    #[cfg(test)]
    fn insert(&mut self, message: StateWriterMessage) -> Result<(), StateWriterSendError> {
        self.insert_prepared(prepare_message(message)?)
    }

    fn insert_prepared(&mut self, prepared: PreparedMessage) -> Result<(), StateWriterSendError> {
        let key = prepared.key.as_ref();
        if let Some(key) = &key
            && !self.admitted.contains(key)
            && self.admitted.len() >= MAX_PENDING_STATE_WRITES
        {
            return Err(StateWriterSendError::Full);
        }
        if let Some(key) = &key {
            // Only a queued payload can be replaced. An older value currently
            // being persisted remains separately charged until its batch drops.
            let previous = self.pending_bytes.get(key).copied().unwrap_or(0);
            let next_total = self
                .total_admitted_bytes
                .checked_sub(previous)
                .and_then(|total| total.checked_add(prepared.byte_len))
                .filter(|total| *total <= MAX_PENDING_STATE_WRITE_BYTES)
                .ok_or(StateWriterSendError::Full)?;
            self.total_admitted_bytes = next_total;
        }
        if let Some(key) = prepared.key.clone() {
            self.admitted.insert(key.clone());
            self.pending_bytes.insert(key, prepared.byte_len);
        }
        let enqueue_sequence = matches!(prepared.message, StateWriterMessage::Save(_)).then(|| {
            let sequence = self.next_save_sequence;
            self.next_save_sequence = self
                .next_save_sequence
                .checked_add(1)
                .expect("state save enqueue sequence exhausted");
            sequence
        });
        self.pending.insert(prepared, enqueue_sequence);
        Ok(())
    }

    fn take_batch(&mut self) -> (Pending, HashMap<WriteKey, usize>) {
        (
            std::mem::take(&mut self.pending),
            std::mem::take(&mut self.pending_bytes),
        )
    }

    fn finish_batch(&mut self, failed: Pending, batch_bytes: HashMap<WriteKey, usize>) {
        let failed_keys = failed.write_keys();
        for (key, bytes) in batch_bytes {
            if failed_keys.contains(&key) && !self.pending.contains(&key) {
                self.pending_bytes.insert(key, bytes);
            } else {
                self.total_admitted_bytes = self.total_admitted_bytes.saturating_sub(bytes);
            }
        }
        self.pending.merge_failed(failed);
        self.admitted.retain(|key| self.pending.contains(key));
    }
}

#[derive(Debug)]
struct StateWriterInner {
    state: Mutex<WriterState>,
    notify: Notify,
    stopped: AtomicBool,
    quiesced: AtomicBool,
    handles: AtomicUsize,
    outstanding_flushes: AtomicUsize,
    completed: Notify,
    completion: Mutex<Option<Result<(), PersistError>>>,
}

#[derive(Debug)]
pub struct StateWriter {
    inner: Arc<StateWriterInner>,
    worker: Arc<tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>>,
}

impl Clone for StateWriter {
    fn clone(&self) -> Self {
        self.inner.handles.fetch_add(1, Ordering::Relaxed);
        Self {
            inner: Arc::clone(&self.inner),
            worker: Arc::clone(&self.worker),
        }
    }
}

impl Drop for StateWriter {
    fn drop(&mut self) {
        if self.inner.handles.fetch_sub(1, Ordering::AcqRel) == 1 {
            let state = self
                .inner
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            self.inner.stopped.store(true, Ordering::Release);
            drop(state);
            self.inner.notify.notify_one();
        }
    }
}

impl StateWriter {
    pub fn send(&self, message: StateWriterMessage) -> Result<(), StateWriterSendError> {
        self.send_impl(message, false)
    }

    fn send_impl(
        &self,
        message: StateWriterMessage,
        allow_quiesced: bool,
    ) -> Result<(), StateWriterSendError> {
        if self.inner.stopped.load(Ordering::Acquire)
            || (!allow_quiesced && self.inner.quiesced.load(Ordering::Acquire))
        {
            return Err(StateWriterSendError::Stopped);
        }
        let is_flush = matches!(message, StateWriterMessage::Flush(_));
        if is_flush
            && !increment_bounded(&self.inner.outstanding_flushes, MAX_PENDING_STATE_FLUSHES)
        {
            return Err(StateWriterSendError::Full);
        }
        let prepared = match prepare_message(message) {
            Ok(prepared) => prepared,
            Err(error) => {
                if is_flush {
                    self.inner
                        .outstanding_flushes
                        .fetch_sub(1, Ordering::AcqRel);
                }
                return Err(error);
            }
        };
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.inner.stopped.load(Ordering::Acquire)
            || (!allow_quiesced && self.inner.quiesced.load(Ordering::Acquire))
        {
            if is_flush {
                self.inner
                    .outstanding_flushes
                    .fetch_sub(1, Ordering::AcqRel);
            }
            return Err(StateWriterSendError::Stopped);
        }
        if let Err(error) = state.insert_prepared(prepared) {
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

    /// Wait until all writes accepted before this call have been attempted.
    /// A failed flush leaves the writer running so retained writes can retry.
    pub async fn flush(&self) -> Result<(), PersistError> {
        self.flush_impl(false).await
    }

    async fn flush_impl(&self, allow_quiesced: bool) -> Result<(), PersistError> {
        let (flushed, wait) = oneshot::channel();
        self.send_impl(StateWriterMessage::Flush(flushed), allow_quiesced)
            .map_err(|error| PersistError {
                details: error.to_string(),
            })?;
        wait.await.map_err(|_| PersistError {
            details: "state writer stopped before flush completed".to_owned(),
        })?
    }

    /// Fence producers, flush accepted writes, and stop the worker. A failed
    /// flush reopens admission so callers can retry after a transient error.
    pub async fn quiesce_and_shutdown(&self) -> Result<(), PersistError> {
        if self
            .inner
            .quiesced
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(PersistError {
                details: "state writer is already quiescing".to_owned(),
            });
        }
        if let Err(error) = self.flush_impl(true).await {
            self.inner.quiesced.store(false, Ordering::Release);
            return Err(error);
        }
        self.shutdown().await
    }

    /// Stop accepting writes and wait until every accepted write has either
    /// persisted or produced a persistence error.
    pub async fn shutdown(&self) -> Result<(), PersistError> {
        let state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.inner.stopped.store(true, Ordering::Release);
        drop(state);
        self.inner.notify.notify_one();
        loop {
            let completed = self.inner.completed.notified();
            tokio::pin!(completed);
            completed.as_mut().enable();
            let result = {
                self.inner
                    .completion
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .clone()
            };
            if let Some(result) = result {
                if let Some(worker) = self.worker.lock().await.take() {
                    worker.await.map_err(|error| PersistError {
                        details: format!("state writer worker failed: {error}"),
                    })?;
                }
                return result;
            }
            completed.await;
        }
    }
}

pub fn start_state_writer(store: ReadingStateStore) -> StateWriter {
    let inner = Arc::new(StateWriterInner {
        state: Mutex::new(WriterState::default()),
        notify: Notify::new(),
        stopped: AtomicBool::new(false),
        quiesced: AtomicBool::new(false),
        handles: AtomicUsize::new(1),
        outstanding_flushes: AtomicUsize::new(0),
        completed: Notify::new(),
        completion: Mutex::new(None),
    });
    let worker = Arc::clone(&inner);
    let library = Library::new(store.pool().clone(), store.managed_books_dir());
    let worker_handle = tokio::spawn(async move {
        loop {
            worker.notify.notified().await;
            let (mut batch, batch_bytes) = {
                let mut state = worker
                    .state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                state.take_batch()
            };
            let flushes = std::mem::take(&mut batch.flushes);
            let (failed, error) = persist_batch(&store, &library, batch).await;
            let failed_keys = failed.write_keys();
            {
                let mut state = worker
                    .state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                state.finish_batch(failed, batch_bytes);
            }
            for flush in flushes {
                let _ = flush.send(error.clone().map_or(Ok(()), Err));
                worker.outstanding_flushes.fetch_sub(1, Ordering::AcqRel);
            }
            let (pending_is_empty, stopped) = {
                let state = worker
                    .state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                (
                    state.pending.is_empty(),
                    worker.stopped.load(Ordering::Acquire),
                )
            };
            if stopped {
                if let Some(error) = error
                    && worker.handles.load(Ordering::Acquire) != 0
                {
                    let flushes = {
                        let mut state = worker
                            .state
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        std::mem::take(&mut state.pending.flushes)
                    };
                    for flush in flushes {
                        let _ = flush.send(Err(error.clone()));
                        worker.outstanding_flushes.fetch_sub(1, Ordering::AcqRel);
                    }
                    *worker
                        .completion
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Err(error));
                    worker.completed.notify_waiters();
                    break;
                }
                if pending_is_empty {
                    *worker
                        .completion
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Ok(()));
                    worker.completed.notify_waiters();
                    break;
                }
            }
            if !failed_keys.is_empty() {
                tokio::time::sleep(RETRY_DELAY).await;
                worker.notify.notify_one();
            } else if !pending_is_empty {
                worker.notify.notify_one();
            }
        }
    });
    StateWriter {
        inner,
        worker: Arc::new(tokio::sync::Mutex::new(Some(worker_handle))),
    }
}

fn prepare_message(message: StateWriterMessage) -> Result<PreparedMessage, StateWriterSendError> {
    prepare_message_with(message, canonical_path_key)
}

fn prepare_message_with(
    message: StateWriterMessage,
    normalize_path: impl FnOnce(&std::path::Path) -> String,
) -> Result<PreparedMessage, StateWriterSendError> {
    match message {
        StateWriterMessage::Preference(key, value)
            if key.len() > MAX_PREFERENCE_KEY_BYTES || value.len() > MAX_PREFERENCE_VALUE_BYTES =>
        {
            Err(StateWriterSendError::Full)
        }
        StateWriterMessage::Preference(key, value) => {
            // Admission is based on retained bytes, so discard caller-provided
            // spare capacity before these strings enter the pending maps.
            let key = key.into_boxed_str().into_string();
            let value = value.into_boxed_str().into_string();
            let byte_len = key
                .len()
                .checked_mul(2)
                .and_then(|bytes| bytes.checked_add(value.len()))
                .ok_or(StateWriterSendError::Full)?;
            Ok(PreparedMessage {
                key: Some(WriteKey::Preference(key.clone())),
                message: StateWriterMessage::Preference(key, value),
                normalized_path: None,
                byte_len,
            })
        }
        StateWriterMessage::Save(mut save) => {
            let normalized = normalize_path(&save.path);
            let path = normalized.as_str().to_owned();
            if path.len() > MAX_STATE_PATH_KEY_BYTES {
                return Err(StateWriterSendError::Full);
            }
            if save
                .content_hash
                .as_deref()
                .is_some_and(|hash| !valid_content_hash(hash))
                || save.book_id.is_none() && save.content_hash.is_none()
                || i64::try_from(save.reading.page).is_err()
                || save
                    .reading
                    .location_offset
                    .is_some_and(|offset| i64::try_from(offset).is_err())
                || !save.reading.zoom.is_finite()
                || save.reading.zoom <= 0.0
            {
                return Err(StateWriterSendError::Full);
            }
            let hash = save.content_hash.as_deref().map(str::to_owned);
            save.path = PathBuf::new();
            save.content_hash = hash;
            let copies = if save.book_id.is_some() { 1 } else { 4 };
            let byte_len = path
                .len()
                .checked_mul(copies)
                .and_then(|bytes| {
                    save.content_hash.as_ref().map_or(Some(bytes), |hash| {
                        hash.len().checked_mul(copies)?.checked_add(bytes)
                    })
                })
                .ok_or(StateWriterSendError::Full)?;
            let key = save.book_id.map_or_else(
                || {
                    WriteKey::Save(SaveKey::Path(
                        path.clone(),
                        save.content_hash
                            .clone()
                            .expect("untracked saves require a content hash"),
                    ))
                },
                |book_id| WriteKey::Save(SaveKey::Book(book_id)),
            );
            Ok(PreparedMessage {
                message: StateWriterMessage::Save(save),
                key: Some(key),
                normalized_path: Some(path),
                byte_len,
            })
        }
        StateWriterMessage::Progress { book_id, progress } => {
            if !progress.is_finite() {
                return Err(StateWriterSendError::Full);
            }
            Ok(PreparedMessage {
                message: StateWriterMessage::Progress { book_id, progress },
                key: Some(WriteKey::Progress(book_id)),
                normalized_path: None,
                byte_len: 0,
            })
        }
        StateWriterMessage::Flush(flush) => Ok(PreparedMessage {
            message: StateWriterMessage::Flush(flush),
            key: None,
            normalized_path: None,
            byte_len: 0,
        }),
    }
}

fn increment_bounded(counter: &AtomicUsize, limit: usize) -> bool {
    counter
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < limit).then_some(count + 1)
        })
        .is_ok()
}

fn valid_content_hash(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
}

async fn persist_batch(
    store: &ReadingStateStore,
    library: &Library,
    mut batch: Pending,
) -> (Pending, Option<PersistError>) {
    let mut failed = Pending::default();
    let mut errors = Vec::new();
    let mut saves: Vec<_> = batch.saves.drain().collect();
    saves.sort_by_key(|(_, pending)| pending.enqueue_sequence);
    let mut failed_saves = Vec::new();
    let mut successful_saves = Vec::new();
    let mut reservation_error = None;
    for (_, pending) in &mut saves {
        if pending.persistence_revision.is_none() {
            match crate::reading_state::reserve_reading_state_revision(store.pool()).await {
                Ok(revision) => pending.persistence_revision = Some(revision),
                Err(error) => {
                    reservation_error = Some(format!("reading state revision: {error:#}"));
                    break;
                }
            }
        }
    }
    if let Some(error) = reservation_error {
        failed_saves.extend(
            saves
                .drain(..)
                .map(|(key, pending)| (key, pending, error.clone())),
        );
    }
    for (key, pending) in saves {
        let revision = pending
            .persistence_revision
            .expect("every save is revisioned before persistence");
        let result = if let Some(book_id) = pending.save.book_id {
            match store
                .set_for_book_current_path_at_revision_async(
                    book_id,
                    &pending.save.reading,
                    Some(revision),
                )
                .await
            {
                Ok(current_path) => Ok((Some(book_id), current_path)),
                Err(CurrentBookPathSaveError::MissingBook(_)) => {
                    match pending.save.content_hash.as_deref() {
                        Some(content_hash) => store
                            .set_key_at_revision_async(
                                &pending.normalized_path,
                                content_hash,
                                &pending.save.reading,
                                Some(revision),
                            )
                            .await
                            .map(|owner| (owner, pending.normalized_path.clone())),
                        None => Err(anyhow::anyhow!(
                            "removed book save has no admitted content hash"
                        )),
                    }
                }
                Err(CurrentBookPathSaveError::Persistence(error)) => Err(error),
            }
        } else {
            match pending.save.content_hash.as_deref() {
                Some(content_hash) => store
                    .set_key_at_revision_async(
                        &pending.normalized_path,
                        content_hash,
                        &pending.save.reading,
                        Some(revision),
                    )
                    .await
                    .map(|owner| (owner, pending.normalized_path.clone())),
                None => Err(anyhow::anyhow!(
                    "untracked save has no admitted content hash"
                )),
            }
        };
        match result {
            Ok((book_id, saved_path)) => {
                successful_saves.push((
                    book_id,
                    saved_path,
                    pending.save.content_hash.clone(),
                    pending.enqueue_sequence,
                ));
            }
            Err(error) => {
                failed_saves.push((key, pending, format!("reading state: {error:#}")));
            }
        }
    }
    for (key, pending, mut error) in failed_saves {
        let failed_book_id = if let Some(book_id) = pending.save.book_id {
            Ok(Some(book_id))
        } else if let Some(content_hash) = pending.save.content_hash.as_deref() {
            store
                .resolve_path_owner_async(&pending.normalized_path, content_hash)
                .await
                .map(|owner| owner.map(|(book_id, _)| book_id))
        } else {
            Ok(None)
        };
        // A newer save for the same stable book supersedes an older failed
        // path-key save even when an import changed the document's path.
        let superseded = match failed_book_id {
            Ok(failed_book_id) => successful_saves
                .iter()
                .any(|(book_id, path, hash, sequence)| {
                    *sequence > pending.enqueue_sequence
                        && (failed_book_id.is_some() && failed_book_id == *book_id
                            || failed_book_id.is_none()
                                && path == &pending.normalized_path
                                && hash == &pending.save.content_hash)
                }),
            Err(owner_error) => {
                error.push_str(&format!("; owner resolution: {owner_error:#}"));
                false
            }
        };
        if !superseded {
            errors.push(error);
            failed.saves.insert(key, pending);
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
    use std::cell::Cell;

    const CONTENT_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

    #[test]
    fn invalid_persistence_payloads_are_rejected_at_admission() {
        let save = |content_hash, reading| {
            StateWriterMessage::Save(StateSave {
                book_id: None,
                path: PathBuf::from("book.epub"),
                content_hash,
                reading,
            })
        };
        let reading = FileReadingState {
            page: 0,
            location_offset: None,
            zoom: 1.0,
        };

        assert!(prepare_message(save(None, reading.clone())).is_err());
        assert!(prepare_message(save(Some("invalid".to_owned()), reading.clone())).is_err());
        assert!(
            prepare_message(save(
                Some(CONTENT_HASH.to_owned()),
                FileReadingState {
                    zoom: f32::NAN,
                    ..reading
                },
            ))
            .is_err()
        );
        assert!(
            prepare_message(StateWriterMessage::Progress {
                book_id: 1,
                progress: f64::INFINITY,
            })
            .is_err()
        );
    }

    #[test]
    fn book_saves_coalesce_across_relocated_paths() {
        let mut state = WriterState::default();
        for (path, page) in [("old.epub", 1), ("new.epub", 2)] {
            state
                .insert(StateWriterMessage::Save(StateSave {
                    book_id: Some(7),
                    path: path.into(),
                    content_hash: Some(CONTENT_HASH.to_owned()),
                    reading: FileReadingState {
                        page,
                        location_offset: None,
                        zoom: 1.0,
                    },
                }))
                .unwrap();
        }

        assert_eq!(state.pending.saves.len(), 1);
        assert!(
            state.pending.saves[&SaveKey::Book(7)]
                .normalized_path
                .ends_with("new.epub")
        );
        assert!(
            state.pending.saves[&SaveKey::Book(7)]
                .save
                .path
                .as_os_str()
                .is_empty()
        );
        assert_eq!(state.pending.saves[&SaveKey::Book(7)].save.reading.page, 2);
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
    fn preference_strings_and_their_aggregate_retention_are_bounded() {
        let mut state = WriterState::default();
        assert_eq!(
            state.insert(StateWriterMessage::Preference(
                "k".repeat(MAX_PREFERENCE_KEY_BYTES + 1),
                String::new(),
            )),
            Err(StateWriterSendError::Full)
        );
        assert_eq!(
            state.insert(StateWriterMessage::Preference(
                "key".to_owned(),
                "v".repeat(MAX_PREFERENCE_VALUE_BYTES + 1),
            )),
            Err(StateWriterSendError::Full)
        );

        let value = "v".repeat(MAX_PREFERENCE_VALUE_BYTES);
        let mut accepted = 0;
        while state
            .insert(StateWriterMessage::Preference(
                format!("key-{accepted}"),
                value.clone(),
            ))
            .is_ok()
        {
            accepted += 1;
        }
        assert!(accepted < MAX_PENDING_STATE_WRITES);
        assert!(state.total_admitted_bytes <= MAX_PENDING_STATE_WRITE_BYTES);

        state
            .insert(StateWriterMessage::Preference(
                "key-0".to_owned(),
                "small".to_owned(),
            ))
            .expect("coalescing a smaller value must release aggregate admission");
    }

    #[test]
    fn preference_admission_discards_oversized_spare_capacity() {
        let mut key = String::with_capacity(MAX_PENDING_STATE_WRITE_BYTES * 2);
        key.push('k');
        let mut value = String::with_capacity(MAX_PENDING_STATE_WRITE_BYTES * 2);
        value.push('v');
        let mut state = WriterState::default();

        state
            .insert(StateWriterMessage::Preference(key, value))
            .unwrap();

        let (key, value) = state.pending.preferences.iter().next().unwrap();
        assert_eq!(key.capacity(), key.len());
        assert_eq!(value.capacity(), value.len());
        assert_eq!(state.total_admitted_bytes, 3);
    }

    #[test]
    fn save_paths_are_bounded_and_charged() {
        let mut state = WriterState::default();
        state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: None,
                path: PathBuf::from("book.epub"),
                content_hash: Some(CONTENT_HASH.to_owned()),
                reading: FileReadingState {
                    page: 0,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        assert!(state.total_admitted_bytes >= "book.epub".len());

        assert_eq!(
            state.insert(StateWriterMessage::Save(StateSave {
                book_id: None,
                path: PathBuf::from("x".repeat(MAX_STATE_PATH_KEY_BYTES + 1)),
                content_hash: Some(CONTENT_HASH.to_owned()),
                reading: FileReadingState {
                    page: 0,
                    location_offset: None,
                    zoom: 1.0,
                },
            })),
            Err(StateWriterSendError::Full)
        );

        let mut overallocated_path = String::with_capacity(MAX_PENDING_STATE_WRITE_BYTES);
        overallocated_path.push_str("compact.epub");
        let mut overallocated_hash = String::with_capacity(MAX_PENDING_STATE_WRITE_BYTES);
        overallocated_hash.push_str(CONTENT_HASH);
        let mut compacted = WriterState::default();
        compacted
            .insert(StateWriterMessage::Save(StateSave {
                book_id: Some(7),
                path: PathBuf::from(overallocated_path),
                content_hash: Some(overallocated_hash),
                reading: FileReadingState {
                    page: 0,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        let pending = &compacted.pending.saves[&SaveKey::Book(7)];
        assert!(pending.save.path.as_os_str().is_empty());
        assert_eq!(pending.save.content_hash.as_ref().unwrap().capacity(), 64);
        assert!(compacted.total_admitted_bytes >= pending.normalized_path.capacity());
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
                    content_hash: Some(CONTENT_HASH.to_owned()),
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
            state
                .pending
                .saves
                .values()
                .next()
                .unwrap()
                .save
                .reading
                .page,
            2
        );
    }

    #[tokio::test]
    async fn same_path_with_distinct_content_owners_keeps_both_saves() {
        const OTHER_HASH: &str = "1111111111111111111111111111111111111111111111111111111111111111";
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let source = canonical_path_key(&directory.path().join("source.epub"));
        let first_path = canonical_path_key(&directory.path().join("first.epub"));
        let second_path = canonical_path_key(&directory.path().join("second.epub"));
        for (path, hash) in [(&first_path, CONTENT_HASH), (&second_path, OTHER_HASH)] {
            let book_id: i64 = sqlx::query_scalar(
                "INSERT INTO books (title, format, file_path, content_hash)
                 VALUES ('Book', 'epub', ?, ?) RETURNING id",
            )
            .bind(path)
            .bind(hash)
            .fetch_one(store.pool())
            .await
            .unwrap();
            sqlx::query(
                "INSERT INTO book_path_aliases (file_path, content_hash, book_id)
                 VALUES (?, ?, ?)",
            )
            .bind(&source)
            .bind(hash)
            .bind(book_id)
            .execute(store.pool())
            .await
            .unwrap();
        }
        let mut writer_state = WriterState::default();
        for (hash, page) in [(CONTENT_HASH, 3), (OTHER_HASH, 17)] {
            writer_state
                .insert(StateWriterMessage::Save(StateSave {
                    book_id: None,
                    path: PathBuf::from(&source),
                    content_hash: Some(hash.to_owned()),
                    reading: FileReadingState {
                        page,
                        location_offset: None,
                        zoom: 1.0,
                    },
                }))
                .unwrap();
        }
        assert_eq!(writer_state.pending.saves.len(), 2);
        let (batch, _) = writer_state.take_batch();

        let (failed, error) = persist_batch(&store, &library, batch).await;

        assert!(failed.saves.is_empty());
        assert!(error.is_none());
        let pages: Vec<i64> = sqlx::query_scalar("SELECT page FROM reading_state ORDER BY page")
            .fetch_all(store.pool())
            .await
            .unwrap();
        assert_eq!(pages, vec![3, 17]);
    }

    #[test]
    fn save_normalization_runs_once_and_supplies_the_pending_identity() {
        let calls = Cell::new(0);
        let prepared = prepare_message_with(
            StateWriterMessage::Save(StateSave {
                book_id: None,
                path: PathBuf::from("book.epub"),
                content_hash: Some(CONTENT_HASH.to_owned()),
                reading: FileReadingState {
                    page: 0,
                    location_offset: None,
                    zoom: 1.0,
                },
            }),
            |_| {
                calls.set(calls.get() + 1);
                format!("normalized-{}", calls.get())
            },
        )
        .unwrap();
        let mut state = WriterState::default();
        state.insert_prepared(prepared).unwrap();

        assert_eq!(calls.get(), 1);
        assert!(state.pending.saves.contains_key(&SaveKey::Path(
            "normalized-1".to_owned(),
            CONTENT_HASH.to_owned()
        )));
        assert_eq!(
            state.pending.saves.values().next().unwrap().normalized_path,
            "normalized-1"
        );
        assert!(state.admitted.contains(&WriteKey::Save(SaveKey::Path(
            "normalized-1".to_owned(),
            CONTENT_HASH.to_owned()
        ))));
    }

    #[test]
    fn in_flight_payloads_remain_charged_while_replacements_queue() {
        let mut state = WriterState::default();
        let value = "v".repeat(MAX_PREFERENCE_VALUE_BYTES);
        let mut accepted = 0;
        while state
            .insert(StateWriterMessage::Preference(
                format!("key-{accepted}"),
                value.clone(),
            ))
            .is_ok()
        {
            accepted += 1;
        }
        let (batch, batch_bytes) = state.take_batch();
        let in_flight_bytes = state.total_admitted_bytes;
        let mut replacements = 0;
        while replacements < accepted
            && state
                .insert(StateWriterMessage::Preference(
                    format!("key-{replacements}"),
                    value.clone(),
                ))
                .is_ok()
        {
            replacements += 1;
        }

        assert!(replacements < accepted);
        assert!(state.total_admitted_bytes >= in_flight_bytes);
        assert!(state.total_admitted_bytes <= MAX_PENDING_STATE_WRITE_BYTES);
        state.finish_batch(Pending::default(), batch_bytes);
        drop(batch);
        assert!(state.total_admitted_bytes < in_flight_bytes);
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
                if store.get_pref_async("language").await.unwrap().as_deref() == Some("en") {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("retained write should retry autonomously");
    }

    #[tokio::test]
    async fn failed_flush_can_recover_and_then_shutdown() {
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

        assert!(writer.flush().await.is_err());
        sqlx::query("DROP TRIGGER reject_test_preference")
            .execute(store.pool())
            .await
            .unwrap();

        tokio::time::timeout(std::time::Duration::from_secs(2), writer.flush())
            .await
            .expect("a retry after transient failure must finish")
            .unwrap();
        writer.shutdown().await.unwrap();
        assert_eq!(
            store.get_pref_async("language").await.unwrap().as_deref(),
            Some("en")
        );
    }

    #[tokio::test]
    async fn failed_close_quiesce_reopens_write_admission() {
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

        assert!(writer.quiesce_and_shutdown().await.is_err());
        writer
            .send(StateWriterMessage::Preference(
                "theme".to_owned(),
                "dark".to_owned(),
            ))
            .expect("failed close preparation must reopen producer admission");
        sqlx::query("DROP TRIGGER reject_test_preference")
            .execute(store.pool())
            .await
            .unwrap();
        writer.quiesce_and_shutdown().await.unwrap();
        assert_eq!(
            store.get_pref_async("theme").await.unwrap().as_deref(),
            Some("dark")
        );
    }

    #[tokio::test]
    async fn immediate_shutdown_cannot_miss_worker_completion() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();

        for _ in 0..100 {
            let writer = start_state_writer(store.clone());
            tokio::time::timeout(std::time::Duration::from_secs(1), writer.shutdown())
                .await
                .expect("shutdown notification must not be lost")
                .unwrap();
        }
    }

    #[tokio::test]
    async fn final_drop_drains_writes_queued_behind_an_in_flight_batch() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let mut blocker = store.pool().acquire().await.unwrap();
        sqlx::query("BEGIN EXCLUSIVE")
            .execute(&mut *blocker)
            .await
            .unwrap();
        let writer = start_state_writer(store.clone());
        writer
            .send(StateWriterMessage::Preference(
                "first".to_owned(),
                "one".to_owned(),
            ))
            .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        writer
            .send(StateWriterMessage::Preference(
                "second".to_owned(),
                "two".to_owned(),
            ))
            .unwrap();
        drop(writer);
        sqlx::query("COMMIT").execute(&mut *blocker).await.unwrap();

        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if store.get_pref_async("first").await.unwrap().as_deref() == Some("one")
                    && store.get_pref_async("second").await.unwrap().as_deref() == Some("two")
                {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the final writer drop must drain every accepted write");
    }

    #[tokio::test]
    async fn final_drop_retries_a_transient_write_failure() {
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
        drop(writer);

        assert!(wait.await.unwrap().is_err());
        sqlx::query("DROP TRIGGER reject_test_preference")
            .execute(store.pool())
            .await
            .unwrap();

        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if store.get_pref_async("language").await.unwrap().as_deref() == Some("en") {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the final writer drop must retry a transient failure");
    }

    #[tokio::test]
    async fn shutdown_waits_for_persistence_and_joins_the_worker() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let mut blocker = store.pool().acquire().await.unwrap();
        sqlx::query("BEGIN EXCLUSIVE")
            .execute(&mut *blocker)
            .await
            .unwrap();
        let writer = start_state_writer(store.clone());
        writer
            .send(StateWriterMessage::Preference(
                "language".to_owned(),
                "en".to_owned(),
            ))
            .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let shutdown = {
            let writer = writer.clone();
            tokio::spawn(async move { writer.shutdown().await })
        };
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        assert!(!shutdown.is_finished());

        sqlx::query("COMMIT").execute(&mut *blocker).await.unwrap();
        shutdown.await.unwrap().unwrap();
        assert_eq!(
            store.get_pref_async("language").await.unwrap().as_deref(),
            Some("en")
        );
        assert_eq!(
            writer.send(StateWriterMessage::Progress {
                book_id: 1,
                progress: 0.5,
            }),
            Err(StateWriterSendError::Stopped)
        );
    }

    #[tokio::test]
    async fn shutdown_answers_flush_queued_behind_a_failing_in_flight_write() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        sqlx::query(
            "CREATE TRIGGER reject_test_preference
             BEFORE INSERT ON preferences
             BEGIN SELECT RAISE(FAIL, 'terminal failure'); END",
        )
        .execute(store.pool())
        .await
        .unwrap();
        let mut blocker = store.pool().acquire().await.unwrap();
        sqlx::query("BEGIN EXCLUSIVE")
            .execute(&mut *blocker)
            .await
            .unwrap();
        let writer = start_state_writer(store);
        writer
            .send(StateWriterMessage::Preference("key".into(), "value".into()))
            .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let (flushed, wait) = oneshot::channel();
        writer.send(StateWriterMessage::Flush(flushed)).unwrap();
        let shutdown = {
            let writer = writer.clone();
            tokio::spawn(async move { writer.shutdown().await })
        };
        sqlx::query("COMMIT").execute(&mut *blocker).await.unwrap();

        tokio::time::timeout(std::time::Duration::from_secs(2), wait)
            .await
            .expect("accepted flush must be answered")
            .unwrap()
            .unwrap_err();
        tokio::time::timeout(std::time::Duration::from_secs(2), shutdown)
            .await
            .expect("shutdown must finish")
            .unwrap()
            .unwrap_err();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn untracked_save_persists_the_path_identity_prepared_at_admission() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let first = directory.path().join("first.epub");
        let second = directory.path().join("second.epub");
        let alias = directory.path().join("current.epub");
        std::fs::write(&first, b"first").unwrap();
        std::fs::write(&second, b"second").unwrap();
        symlink(&first, &alias).unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let mut writer_state = WriterState::default();
        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: None,
                path: alias.clone(),
                content_hash: Some(CONTENT_HASH.to_owned()),
                reading: FileReadingState {
                    page: 7,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        let (batch, _) = writer_state.take_batch();
        std::fs::remove_file(&alias).unwrap();
        symlink(&second, &alias).unwrap();

        let (failed, error) = persist_batch(&store, &library, batch).await;

        assert!(failed.saves.is_empty());
        assert!(error.is_none());
        assert_eq!(
            store
                .get_async(&first, CONTENT_HASH)
                .await
                .unwrap()
                .unwrap()
                .page,
            7
        );
        assert!(
            store
                .get_async(&second, CONTENT_HASH)
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn tracked_save_uses_the_current_library_path_at_persistence() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let book = library.import_file(&source).await.unwrap();
        let relocated = directory.path().join("relocated.epub");
        std::fs::copy(&source, &relocated).unwrap();
        let mut writer_state = WriterState::default();
        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: Some(book.id),
                path: source,
                content_hash: book.content_hash.clone(),
                reading: FileReadingState {
                    page: 9,
                    location_offset: Some(3),
                    zoom: 1.0,
                },
            }))
            .unwrap();
        let (batch, _) = writer_state.take_batch();
        let relocated_key = canonical_path_key(&relocated);
        sqlx::query("UPDATE books SET file_path = ? WHERE id = ?")
            .bind(&relocated_key)
            .bind(book.id)
            .execute(store.pool())
            .await
            .unwrap();

        let (failed, error) = persist_batch(&store, &library, batch).await;

        assert!(failed.saves.is_empty());
        assert!(error.is_none());
        let row: (String, i64) =
            sqlx::query_as("SELECT file_path, page FROM reading_state WHERE book_id = ?")
                .bind(book.id)
                .fetch_one(store.pool())
                .await
                .unwrap();
        assert_eq!(row, (relocated_key, 9));
    }

    #[tokio::test]
    async fn path_save_owned_by_another_book_is_promoted_without_retry() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let book = library.import_file(&source).await.unwrap();
        let foreign_path = directory.path().join("foreign.epub");
        let foreign_key = canonical_path_key(&foreign_path);
        let foreign_id: i64 = sqlx::query_scalar(
            "INSERT INTO books (title, format, file_path, content_hash)
             VALUES ('Foreign', 'epub', ?, ?) RETURNING id",
        )
        .bind(&foreign_key)
        .bind(CONTENT_HASH)
        .fetch_one(store.pool())
        .await
        .unwrap();
        store
            .set_for_book_async(
                foreign_id,
                &FileReadingState {
                    page: 1,
                    location_offset: None,
                    zoom: 1.0,
                },
            )
            .await
            .unwrap();
        let mut writer_state = WriterState::default();
        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: None,
                path: foreign_path.clone(),
                content_hash: Some(CONTENT_HASH.to_owned()),
                reading: FileReadingState {
                    page: 2,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: Some(book.id),
                path: foreign_path,
                content_hash: book.content_hash.clone(),
                reading: FileReadingState {
                    page: 3,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        let (batch, _) = writer_state.take_batch();

        let (failed, error) = persist_batch(&store, &library, batch).await;

        assert!(error.is_none());
        assert!(failed.saves.is_empty());
        assert_eq!(
            store
                .get_for_book_async(foreign_id)
                .await
                .unwrap()
                .unwrap()
                .page,
            2
        );
        assert_eq!(
            store
                .get_for_book_async(book.id)
                .await
                .unwrap()
                .unwrap()
                .page,
            3
        );
    }

    #[tokio::test]
    async fn promoted_book_save_wins_over_older_path_save_in_the_same_batch() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let book = library.import_file(&source).await.unwrap();
        let content_hash = book.content_hash.clone();
        let mut writer_state = WriterState::default();
        for (book_id, page) in [(None, 3), (Some(book.id), 17)] {
            writer_state
                .insert(StateWriterMessage::Save(StateSave {
                    book_id,
                    path: source.clone(),
                    content_hash: content_hash.clone(),
                    reading: FileReadingState {
                        page,
                        location_offset: None,
                        zoom: 1.0,
                    },
                }))
                .unwrap();
        }
        let (batch, _) = writer_state.take_batch();

        let (failed, error) = persist_batch(&store, &library, batch).await;

        assert!(failed.saves.is_empty());
        assert!(error.is_none());
        assert_eq!(
            store
                .get_for_book_async(book.id)
                .await
                .unwrap()
                .unwrap()
                .page,
            17
        );
    }

    #[tokio::test]
    async fn stable_save_supersedes_failed_historical_source_save() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let first_source = directory.path().join("first.epub");
        let historical_source = directory.path().join("second.epub");
        std::fs::copy(&fixture, &first_source).unwrap();
        std::fs::copy(&fixture, &historical_source).unwrap();
        let book = library.import_managed_file(&first_source).await.unwrap();
        sqlx::query(
            "CREATE TRIGGER reject_older_reading_state
             BEFORE INSERT ON reading_state WHEN NEW.page = 3
             BEGIN SELECT RAISE(FAIL, 'temporary failure'); END",
        )
        .execute(store.pool())
        .await
        .unwrap();
        let mut writer_state = WriterState::default();
        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: None,
                path: historical_source.clone(),
                content_hash: book.content_hash.clone(),
                reading: FileReadingState {
                    page: 3,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        let (older_batch, _) = writer_state.take_batch();
        let (failed_older, error) = persist_batch(&store, &library, older_batch).await;
        assert!(error.is_some());
        assert_eq!(failed_older.saves.len(), 1);

        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: Some(book.id),
                path: PathBuf::from(&book.file_path),
                content_hash: book.content_hash.clone(),
                reading: FileReadingState {
                    page: 17,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        let (newer_batch, _) = writer_state.take_batch();
        let (failed_newer, error) = persist_batch(&store, &library, newer_batch).await;
        assert!(failed_newer.saves.is_empty());
        assert!(error.is_none());

        let duplicate = library
            .import_managed_file(&historical_source)
            .await
            .unwrap();
        assert_eq!(duplicate.id, book.id);
        sqlx::query("DROP TRIGGER reject_older_reading_state")
            .execute(store.pool())
            .await
            .unwrap();

        let (failed, error) = persist_batch(&store, &library, failed_older).await;

        assert!(failed.saves.is_empty());
        assert!(error.is_none());
        assert_eq!(
            store
                .get_for_book_async(book.id)
                .await
                .unwrap()
                .unwrap()
                .page,
            17
        );
    }

    #[tokio::test]
    async fn retried_tracked_save_ignores_newer_untracked_different_content_at_same_path() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let path = directory.path().join("shared.epub");
        let key = canonical_path_key(&path);
        let other_hash = "1111111111111111111111111111111111111111111111111111111111111111";
        let book_id: i64 = sqlx::query_scalar(
            "INSERT INTO books (title, format, file_path, content_hash)
             VALUES ('tracked', 'epub', ?, ?) RETURNING id",
        )
        .bind(&key)
        .bind(CONTENT_HASH)
        .fetch_one(store.pool())
        .await
        .unwrap();
        store
            .set_key_at_revision_async(
                &key,
                other_hash,
                &FileReadingState {
                    page: 22,
                    location_offset: None,
                    zoom: 1.0,
                },
                Some(2),
            )
            .await
            .unwrap();

        store
            .set_for_book_current_path_at_revision_async(
                book_id,
                &FileReadingState {
                    page: 11,
                    location_offset: None,
                    zoom: 1.0,
                },
                Some(1),
            )
            .await
            .unwrap();

        let rows: Vec<(Option<i64>, String, i64)> = sqlx::query_as(
            "SELECT book_id, content_hash, page FROM reading_state
             WHERE file_path = ? ORDER BY book_id IS NULL",
        )
        .bind(&key)
        .fetch_all(store.pool())
        .await
        .unwrap();
        assert_eq!(
            rows,
            vec![
                (Some(book_id), CONTENT_HASH.to_owned(), 11),
                (None, other_hash.to_owned(), 22),
            ]
        );
    }

    #[tokio::test]
    async fn revision_failure_blocks_later_saves_in_the_batch() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let book = library.import_file(&source).await.unwrap();
        sqlx::query(
            "CREATE TRIGGER reject_test_revision
             BEFORE UPDATE ON reading_state_revision
             BEGIN SELECT RAISE(FAIL, 'temporary failure'); END",
        )
        .execute(store.pool())
        .await
        .unwrap();
        let mut writer_state = WriterState::default();
        for (book_id, page) in [(None, 3), (Some(book.id), 17)] {
            writer_state
                .insert(StateWriterMessage::Save(StateSave {
                    book_id,
                    path: source.clone(),
                    content_hash: book.content_hash.clone(),
                    reading: FileReadingState {
                        page,
                        location_offset: None,
                        zoom: 1.0,
                    },
                }))
                .unwrap();
        }
        let (batch, _) = writer_state.take_batch();

        let (failed, error) = persist_batch(&store, &library, batch).await;

        assert!(error.is_some());
        assert_eq!(failed.saves.len(), 2);
        assert!(store.get_for_book_async(book.id).await.unwrap().is_none());
        sqlx::query("DROP TRIGGER reject_test_revision")
            .execute(store.pool())
            .await
            .unwrap();
        let (failed, error) = persist_batch(&store, &library, failed).await;
        assert!(failed.saves.is_empty());
        assert!(error.is_none());
        assert_eq!(
            store
                .get_for_book_async(book.id)
                .await
                .unwrap()
                .unwrap()
                .page,
            17
        );
    }

    #[tokio::test]
    async fn removed_book_does_not_expose_newer_unowned_state_to_an_old_retry() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let book = library.import_file(&source).await.unwrap();
        let content_hash = book.content_hash.clone().unwrap();
        sqlx::query(
            "CREATE TRIGGER reject_old_unowned_save
             BEFORE INSERT ON reading_state WHEN NEW.page = 3
             BEGIN SELECT RAISE(FAIL, 'temporary failure'); END",
        )
        .execute(store.pool())
        .await
        .unwrap();
        let mut writer_state = WriterState::default();
        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: None,
                path: source.clone(),
                content_hash: Some(content_hash.clone()),
                reading: FileReadingState {
                    page: 3,
                    location_offset: None,
                    zoom: 1.0,
                },
            }))
            .unwrap();
        let (batch, _) = writer_state.take_batch();
        let (failed, error) = persist_batch(&store, &library, batch).await;
        assert!(error.is_some());
        store
            .set_for_book_async(
                book.id,
                &FileReadingState {
                    page: 17,
                    location_offset: None,
                    zoom: 1.0,
                },
            )
            .await
            .unwrap();
        library.remove(book.id).await.unwrap();
        sqlx::query("DROP TRIGGER reject_old_unowned_save")
            .execute(store.pool())
            .await
            .unwrap();

        let (failed, error) = persist_batch(&store, &library, failed).await;

        assert!(failed.saves.is_empty());
        assert!(error.is_none());
        assert_eq!(
            store
                .get_async(&source, &content_hash)
                .await
                .unwrap()
                .unwrap()
                .page,
            17
        );
    }

    #[tokio::test]
    async fn removed_tracked_save_falls_back_to_admitted_path_and_releases_admission() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let book = library.import_file(&source).await.unwrap();
        let mut writer_state = WriterState::default();
        writer_state
            .insert(StateWriterMessage::Save(StateSave {
                book_id: Some(book.id),
                path: source.clone(),
                content_hash: Some(CONTENT_HASH.to_owned()),
                reading: FileReadingState {
                    page: 11,
                    location_offset: Some(4),
                    zoom: 1.25,
                },
            }))
            .unwrap();
        let (batch, batch_bytes) = writer_state.take_batch();

        library.remove(book.id).await.unwrap();
        let (failed, error) = persist_batch(&store, &library, batch).await;
        assert!(
            error.is_none(),
            "fallback save should make the flush succeed"
        );
        writer_state.finish_batch(failed, batch_bytes);

        assert!(writer_state.admitted.is_empty());
        assert!(writer_state.pending.saves.is_empty());
        let saved = store
            .get_async(&source, CONTENT_HASH)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.page, 11);
        assert_eq!(saved.location_offset, Some(4));
        let book_id: Option<i64> =
            sqlx::query_scalar("SELECT book_id FROM reading_state WHERE file_path = ?")
                .bind(canonical_path_key(&source))
                .fetch_one(store.pool())
                .await
                .unwrap();
        assert_eq!(book_id, None);
    }
}
