//! Iced adapters for the renderer-neutral EPUB pagination engine.

pub(crate) use shosai_core::epub::pagination::*;

pub(crate) mod math_widget;
pub(crate) mod native_text;

#[cfg(test)]
pub(crate) mod text_shaping;
