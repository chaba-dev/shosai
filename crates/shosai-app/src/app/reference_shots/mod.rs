//! Reference capture harness for the frozen Iced design values.
//!
//! Package 1B owns this module: it generates the deterministic library/import
//! fixtures, seeds a *disposable* library database from them, drives the real
//! `update`/`view` pair to the states the reference specification assigns to
//! `1B-*` evidence, renders each state offscreen with the production Iced view
//! and the software (`iced_tiny_skia`) renderer, and writes a provenance
//! manifest next to the images. Package 1C reuses the same runner for reader
//! captures instead of building a second harness.
//!
//! Everything here is behind `#[cfg(test)]`: it is a capture tool, not
//! application code, so the shipped binary is unchanged.
//!
//! - [`fixtures`] generates the deterministic fixture tree and its hashes.
//! - [`seed`] imports that tree into a temporary `XDG`-free data directory and
//!   normalizes the clock-dependent columns.
//! - [`scenarios`] lists the library/import/settings capture states and how each
//!   is reached.
//! - [`reader`] lists the package 1C reader capture states and how each is
//!   reached.
//! - [`package`] separates the two evidence sets (directories, data roots,
//!   families, capture tables and limitations).
//! - [`render`] rasterizes the production view.
//! - [`manifest`] serializes the provenance record.
//! - [`evidence`] validates the committed evidence directory without rendering.
//! - [`runner`] is the `make reference-shots` entry point.
//! - [`tests`] are the always-on regression checks (determinism, fixture
//!   metadata, PDF offsets, committed-evidence consistency).

pub(crate) mod evidence;
pub(crate) mod fixtures;
pub(crate) mod harness;
pub(crate) mod manifest;
pub(crate) mod package;
pub(crate) mod reader;
pub(crate) mod render;
pub(crate) mod runner;
pub(crate) mod scenarios;
pub(crate) mod seed;

#[cfg(test)]
mod tests;
