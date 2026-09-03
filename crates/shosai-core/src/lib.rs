extern crate self as shosai_core;

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
pub mod epub;
pub mod highlight;
pub mod library;
mod path_key;
pub mod pdf;
pub mod reader;
pub mod reading_state;
pub mod search;
pub mod state_writer;
