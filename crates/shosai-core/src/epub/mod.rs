//! EPUB format support.
//!
//! An EPUB file is a ZIP archive containing:
//! - `META-INF/container.xml` — points to the OPF (package) file
//! - `*.opf` — package document with metadata, manifest, and spine
//! - XHTML content documents (chapters)
//! - CSS stylesheets, images, fonts, and other resources

mod font;
mod parser;
mod presentation;
pub mod render;
mod resource;
pub mod style;
mod types;

mod computed_style;
mod limits;

pub use font::{
    EpubFontAttempt, EpubFontBook, EpubFontFace, EpubFontFormat, EpubFontStyle, EpubFontWeight,
    EpubRejectedFontFace,
};
pub use limits::EpubLimits;
pub use parser::EpubDoc;
pub use presentation::{EpubChapterPresentation, EpubPresentation};
pub use resource::{CanonicalEpubPath, EpubReference};
pub use types::*;
