extern crate self as shosai_core;

macro_rules! resource_limit {
    ($($argument:tt)*) => {
        return Err($crate::application::ResourceLimitError(format!($($argument)*)).into())
    };
}

pub(crate) use resource_limit;

#[cfg(target_arch = "wasm32")]
compile_error!(
    "shosai-core currently requires native SQLite and PDFium; use the future web adapter instead"
);

pub mod annotations;
pub mod application;
pub mod bookmarks;
pub mod bridge;
pub mod cbz;
pub mod document;
mod document_admission;
pub mod epub;
pub mod highlight;
pub mod library;
mod path_key;
mod zip_preflight;
pub use path_key::{canonical_path_key, path_from_key, path_key};
pub mod pdf;
pub mod reader;
pub mod reading_state;
pub mod search;
pub mod state_writer;
