//! Reader-session policy and bounded renderer-neutral caches.

use std::collections::VecDeque;

use crate::application::{DeviceFileLocator, OpenDocument};
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
        let location = ReaderLocation::restored(saved, document.page_count());
        Self {
            book_id,
            locator,
            document,
            location,
            preferences,
        }
    }

    pub fn replace_document(&mut self, locator: DeviceFileLocator, document: OpenDocument) {
        self.location = self.location.clamped(document.page_count());
        self.locator = locator;
        self.document = document;
    }
}

/// A deterministic least-recently-inserted cache with a fixed entry bound.
#[derive(Debug, Clone)]
pub struct BoundedCache<K, V> {
    capacity: usize,
    entries: VecDeque<(K, V)>,
}

impl<K: PartialEq, V> BoundedCache<K, V> {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            entries: VecDeque::with_capacity(capacity),
        }
    }

    pub fn insert(&mut self, key: K, value: V) {
        if let Some(position) = self
            .entries
            .iter()
            .position(|(candidate, _)| candidate == &key)
        {
            self.entries.remove(position);
        }
        if self.capacity == 0 {
            return;
        }
        self.entries.push_back((key, value));
        while self.entries.len() > self.capacity {
            self.entries.pop_front();
        }
    }

    pub fn iter(&self) -> impl DoubleEndedIterator<Item = &(K, V)> {
        self.entries.iter()
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
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
}
