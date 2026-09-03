//! Reader-session policy and bounded renderer-neutral caches.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::application::{DeviceFileLocator, FormatCapabilities, OpenDocument};
use crate::reading_state::FileReadingState;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ReadingMode {
    #[default]
    Paginated,
    Continuous,
}

impl ReadingMode {
    pub fn from_stored(value: Option<&str>) -> Self {
        match value {
            Some("continuous") => Self::Continuous,
            _ => Self::Paginated,
        }
    }

    pub fn stored(self) -> &'static str {
        match self {
            Self::Paginated => "paginated",
            Self::Continuous => "continuous",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ZoomMode {
    Manual(f32),
    FitWidth,
    FitPage,
}

impl ZoomMode {
    pub fn scale(self) -> f32 {
        match self {
            Self::Manual(scale) => scale,
            Self::FitWidth | Self::FitPage => 1.0,
        }
    }
}

impl Default for ZoomMode {
    fn default() -> Self {
        Self::Manual(1.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ReaderLocation {
    pub page: usize,
    pub offset: Option<usize>,
}

impl ReaderLocation {
    pub fn restored(state: Option<&FileReadingState>, total_pages: usize) -> Self {
        state.map_or_else(Self::default, |state| Self {
            page: state.page.min(total_pages.saturating_sub(1)),
            offset: state.location_offset,
        })
    }

    pub fn clamped(self, total_pages: usize) -> Self {
        Self {
            page: self.page.min(total_pages.saturating_sub(1)),
            ..self
        }
    }

    pub fn clamped_for(self, document: &OpenDocument) -> Self {
        let page = self.page.min(document.page_count().saturating_sub(1));
        Self {
            page,
            offset: document
                .max_location_offset(page)
                .map(|maximum| self.offset.unwrap_or_default().min(maximum)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReaderPreferences {
    pub reading_mode: ReadingMode,
    pub epub_font_size: f32,
    pub epub_line_spacing: f32,
    pub pdf_zoom: ZoomMode,
}

impl Default for ReaderPreferences {
    fn default() -> Self {
        Self {
            reading_mode: ReadingMode::Paginated,
            epub_font_size: 16.0,
            epub_line_spacing: 1.6,
            pdf_zoom: ZoomMode::FitPage,
        }
    }
}

/// Platform-neutral state retained when a document is replaced or a tab is inactive.
#[derive(Debug, Clone)]
pub struct ReaderSession {
    pub book_id: Option<i64>,
    pub locator: DeviceFileLocator,
    pub document: OpenDocument,
    pub location: ReaderLocation,
    pub preferences: ReaderPreferences,
}

impl ReaderSession {
    pub fn new(
        book_id: Option<i64>,
        locator: DeviceFileLocator,
        document: OpenDocument,
        saved: Option<&FileReadingState>,
        preferences: ReaderPreferences,
    ) -> Self {
        let location =
            ReaderLocation::restored(saved, document.page_count()).clamped_for(&document);
        Self {
            book_id,
            locator,
            document,
            location,
            preferences,
        }
    }

    pub fn replace_document(&mut self, locator: DeviceFileLocator, document: OpenDocument) {
        self.location = self.location.clamped_for(&document);
        self.locator = locator;
        self.document = document;
    }

    pub fn capabilities(&self) -> FormatCapabilities {
        self.document.capabilities()
    }
}

#[derive(Debug)]
struct CacheBudgetInner {
    limit: usize,
    used: AtomicUsize,
}

#[derive(Debug, Clone)]
pub struct CacheBudget(Arc<CacheBudgetInner>);

#[derive(Debug, Clone)]
pub struct CachePermit(Arc<CacheReservation>);

impl CacheBudget {
    pub fn new(limit: usize) -> Self {
        Self(Arc::new(CacheBudgetInner {
            limit,
            used: AtomicUsize::new(0),
        }))
    }

    pub fn used(&self) -> usize {
        self.0.used.load(Ordering::Acquire)
    }

    pub fn try_reserve(&self, weight: usize) -> Option<CachePermit> {
        let result = self
            .0
            .used
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                used.checked_add(weight)
                    .filter(|total| *total <= self.0.limit)
            });
        result.ok().map(|_| {
            CachePermit(Arc::new(CacheReservation {
                budget: Arc::clone(&self.0),
                weight,
            }))
        })
    }
}

impl CachePermit {
    pub fn weight(&self) -> usize {
        self.0.weight
    }
}

#[derive(Debug)]
struct CacheReservation {
    budget: Arc<CacheBudgetInner>,
    weight: usize,
}

impl Drop for CacheReservation {
    fn drop(&mut self) {
        self.budget.used.fetch_sub(self.weight, Ordering::AcqRel);
    }
}

/// A deterministic least-recently-inserted cache with shared entry and byte bounds.
#[derive(Debug)]
pub struct BoundedCache<K, V> {
    capacity: usize,
    budget: CacheBudget,
    entries: VecDeque<((K, V), CachePermit)>,
}

impl<K: Clone, V: Clone> Clone for BoundedCache<K, V> {
    fn clone(&self) -> Self {
        Self {
            capacity: self.capacity,
            budget: self.budget.clone(),
            entries: self.entries.clone(),
        }
    }
}

impl<K: PartialEq, V> BoundedCache<K, V> {
    pub fn new(capacity: usize) -> Self {
        Self::with_budget(capacity, CacheBudget::new(usize::MAX))
    }

    pub fn with_weight_limit(capacity: usize, weight_limit: usize) -> Self {
        Self::with_budget(capacity, CacheBudget::new(weight_limit))
    }

    pub fn with_budget(capacity: usize, budget: CacheBudget) -> Self {
        Self {
            capacity,
            budget,
            entries: VecDeque::with_capacity(capacity),
        }
    }

    pub fn insert(&mut self, key: K, value: V) {
        let _ = self.insert_weighted(key, value, 0);
    }

    pub fn insert_weighted(&mut self, key: K, value: V, weight: usize) -> bool {
        if let Some(position) = self
            .entries
            .iter()
            .position(|((candidate, _), _)| candidate == &key)
        {
            self.entries.remove(position);
        }
        if self.capacity == 0 {
            return false;
        }
        let reservation = loop {
            if let Some(reservation) = self.budget.try_reserve(weight) {
                break reservation;
            }
            if self.entries.pop_front().is_none() {
                return false;
            }
        };
        self.entries.push_back(((key, value), reservation));
        while self.entries.len() > self.capacity {
            self.entries.pop_front();
        }
        true
    }

    pub fn iter(&self) -> impl DoubleEndedIterator<Item = &(K, V)> {
        self.entries.iter().map(|(entry, _)| entry)
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    pub fn pop_oldest(&mut self) -> Option<(K, V)> {
        self.entries.pop_front().map(|(entry, _)| entry)
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn retained_weight(&self) -> usize {
        self.budget.used()
    }
}

/// Prioritize visible pages nearest the logical reading position within a
/// shared rendered-page budget.
pub fn prioritized_pages(
    visible: impl IntoIterator<Item = usize>,
    current: usize,
    total: usize,
    capacity: usize,
) -> Vec<usize> {
    let mut pages = visible
        .into_iter()
        .filter(|page| *page < total)
        .collect::<Vec<_>>();
    if current < total && !pages.contains(&current) {
        pages.push(current);
    }
    pages.sort_unstable();
    pages.dedup();
    pages.sort_by_key(|page| (page.abs_diff(current), *page));
    pages.truncate(capacity);
    pages
}

/// Chapters whose resources should remain warm around the current location.
pub fn nearby_chapters(current: usize, total: usize, radius: usize) -> std::ops::Range<usize> {
    if total == 0 {
        return 0..0;
    }
    let current = current.min(total - 1);
    current.saturating_sub(radius)..current.saturating_add(radius).saturating_add(1).min(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restored_locations_are_logical_and_clamped() {
        let saved = FileReadingState {
            page: 12,
            location_offset: Some(37),
            zoom: 2.0,
        };

        assert_eq!(
            ReaderLocation::restored(Some(&saved), 4),
            ReaderLocation {
                page: 3,
                offset: Some(37)
            }
        );
    }

    #[test]
    fn bounded_cache_replaces_duplicates_and_evicts_oldest_entries() {
        let mut cache = BoundedCache::new(2);
        cache.insert(1, "old");
        cache.insert(2, "second");
        cache.insert(1, "new");
        cache.insert(3, "third");

        assert_eq!(
            cache.iter().copied().collect::<Vec<_>>(),
            vec![(1, "new"), (3, "third")]
        );
    }

    #[test]
    fn weighted_cache_shares_reservations_across_clones() {
        let mut first = BoundedCache::with_weight_limit(4, 6);
        assert!(first.insert_weighted(1, "first", 4));
        let clone = first.clone();
        first.clear();
        assert_eq!(first.retained_weight(), 4);
        assert!(!first.insert_weighted(2, "too large", 3));
        drop(clone);
        assert!(first.insert_weighted(2, "fits", 3));
        assert_eq!(first.retained_weight(), 3);
    }

    #[test]
    fn prefetch_prioritizes_current_then_nearest_visible_pages() {
        assert_eq!(prioritized_pages([9, 3, 7, 3], 6, 10, 3), vec![6, 7, 3]);
        assert_eq!(nearby_chapters(0, 3, 1), 0..2);
        assert_eq!(nearby_chapters(0, 0, 1), 0..0);
    }

    #[test]
    fn session_clamps_epub_offsets_and_clears_them_for_fixed_pages() {
        let epub = crate::epub::EpubDoc::from_bytes(
            include_bytes!("../tests/fixtures/sample.epub").to_vec(),
        )
        .unwrap();
        let saved = FileReadingState {
            page: 0,
            location_offset: Some(usize::MAX),
            zoom: 1.0,
        };
        let mut session = ReaderSession::new(
            None,
            DeviceFileLocator::from_path("book.epub"),
            OpenDocument::Epub(std::sync::Arc::new(epub)),
            Some(&saved),
            ReaderPreferences::default(),
        );
        assert_ne!(session.location.offset, Some(usize::MAX));

        let cbz =
            crate::cbz::CbzDoc::from_bytes(include_bytes!("../tests/fixtures/sample.cbz").to_vec())
                .unwrap();
        session.replace_document(
            DeviceFileLocator::from_path("book.cbz"),
            OpenDocument::Cbz(std::sync::Arc::new(cbz)),
        );

        assert_eq!(session.location.offset, None);
    }
}
