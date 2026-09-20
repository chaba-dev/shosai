//! Validation of the committed evidence directory.
//!
//! One validator is shared by the ordinary regression tests (an unrendered
//! `cargo test` must fail when the committed evidence stops agreeing with the
//! code) and by `make reference-shots VERIFY=1`, which feeds it a freshly
//! rendered manifest and additionally compares pixels. It only reads files: no
//! rendering, no database and no network.
//!
//! The comparison separates three kinds of field:
//!
//! - **code and fixture derivation** (capture table, state, rows, settings,
//!   seeded inventory, fixture and font hashes, matrix, limitations, aliases):
//!   must match exactly, because they describe what the current code renders;
//! - **pixels** (`sha256`, `bytes`): only a rendering run can produce them, so
//!   they are compared when the caller rendered (`fresh_pixels`) and the
//!   committed files are always hashed against the committed manifest;
//! - **run metadata** (capture revision, command, output path, OS/arch/rustc
//!   and cargo versions): recorded for provenance, deliberately exempt, because
//!   it describes the machine that produced the evidence rather than the code.
//!
//! Missing artifacts are errors, never silent skips: the evidence directory is
//! committed, so a checkout without it is broken rather than "not generated
//! yet".

use std::collections::BTreeSet;
use std::path::Path;

use anyhow::{Context, Result};

use super::manifest::{CaptureEntry, Manifest};
use super::{fixtures, manifest};

/// Non-directory files the evidence directory contains.
pub(crate) const EVIDENCE_FILES: [&str; 4] = [
    "README.md",
    "captures.sha256",
    "fixtures.sha256",
    "manifest.json",
];

/// Directory holding the capture images.
pub(crate) const CAPTURE_DIRECTORY: &str = "captures";

/// Directory holding the committed copy of the generated fixture tree.
pub(crate) const FIXTURE_DIRECTORY: &str = "fixtures";

/// Validate the committed evidence at `directory` against `fresh`.
///
/// `fresh` is a manifest built from the current code, either by re-rendering
/// (verify mode) or by the tests' unrendered expectation. `fresh_pixels` says
/// whether `fresh`'s per-capture `sha256`/`bytes` are real renders.
///
/// Every problem is printed and reported in the failure message. A missing
/// directory or manifest is a hard error, because nothing can be compared.
pub(crate) fn validate(directory: &Path, fresh: &Manifest, fresh_pixels: bool) -> Result<()> {
    let problems = problems(directory, fresh, fresh_pixels)?;
    if problems.is_empty() {
        return Ok(());
    }
    for problem in &problems {
        eprintln!("reference-shots: MISMATCH: {problem}");
    }
    anyhow::bail!(
        "the committed evidence no longer matches the current code ({} problem(s)): {}",
        problems.len(),
        problems.join("; ")
    )
}

/// Every disagreement between `directory` and `fresh`.
pub(crate) fn problems(
    directory: &Path,
    fresh: &Manifest,
    fresh_pixels: bool,
) -> Result<Vec<String>> {
    let mut problems: Vec<String> = Vec::new();

    inventory(directory, &mut problems);

    let manifest_path = directory.join("manifest.json");
    let committed_text = std::fs::read_to_string(&manifest_path).with_context(|| {
        format!(
            "read the committed manifest {} (the evidence must be committed, not missing)",
            manifest_path.display()
        )
    })?;
    let committed: Manifest =
        serde_json::from_str(&committed_text).context("parse the committed manifest.json")?;

    capture_files(directory, &committed, &mut problems);
    checksum_file(
        &directory.join("captures.sha256"),
        committed
            .captures
            .iter()
            .map(|capture| (capture.sha256.clone(), capture.image.clone()))
            .collect(),
        "captures.sha256",
        &mut problems,
    );
    readme_file(directory, &committed, &mut problems);
    fixture_tree(directory, &committed, fresh, &mut problems);
    checksum_file(
        &directory.join("fixtures.sha256"),
        committed
            .fixtures
            .files
            .iter()
            .map(|file| {
                (
                    file.sha256.clone(),
                    format!("{FIXTURE_DIRECTORY}/{}", file.relative_path),
                )
            })
            .collect(),
        "fixtures.sha256",
        &mut problems,
    );
    compare_manifests(&committed, fresh, fresh_pixels, &mut problems);

    Ok(problems)
}

/// The evidence directory must hold exactly the four files and two directories.
fn inventory(directory: &Path, problems: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        problems.push(format!(
            "the evidence directory {} is missing",
            directory.display()
        ));
        return;
    };
    let mut seen = BTreeSet::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_dir = entry.file_type().is_ok_and(|file_type| file_type.is_dir());
        if is_dir {
            if name != CAPTURE_DIRECTORY && name != FIXTURE_DIRECTORY {
                problems.push(format!("unexpected directory {name}/ in the evidence"));
            }
            continue;
        }
        if EVIDENCE_FILES.contains(&name.as_str()) {
            seen.insert(name);
        } else {
            problems.push(format!("unexpected file {name} in the evidence"));
        }
    }
    for expected in EVIDENCE_FILES {
        if !seen.contains(expected) {
            problems.push(format!("the evidence is missing {expected}"));
        }
    }
    for name in [CAPTURE_DIRECTORY, FIXTURE_DIRECTORY] {
        if !directory.join(name).is_dir() {
            problems.push(format!("the evidence is missing the {name}/ directory"));
        }
    }
}

/// Every committed capture must exist, hash to its manifest entry, and the
/// directory must contain no image the manifest does not list.
fn capture_files(directory: &Path, committed: &Manifest, problems: &mut Vec<String>) {
    let captures = directory.join(CAPTURE_DIRECTORY);
    let mut found = BTreeSet::new();
    match std::fs::read_dir(&captures) {
        Ok(entries) => {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if !entry.file_type().is_ok_and(|file_type| file_type.is_file()) {
                    problems.push(format!("captures/{name} is not a regular file"));
                    continue;
                }
                found.insert(name);
            }
        }
        Err(error) => {
            problems.push(format!("captures/ cannot be read: {error}"));
            return;
        }
    }

    let expected: BTreeSet<String> = committed
        .captures
        .iter()
        .filter_map(|capture| capture.image.rsplit('/').next().map(str::to_owned))
        .collect();
    for missing in expected.difference(&found) {
        problems.push(format!(
            "captures/{missing} is listed by the manifest but not committed"
        ));
    }
    for orphan in found.difference(&expected) {
        problems.push(format!(
            "captures/{orphan} is committed but not listed by the manifest"
        ));
    }

    for capture in &committed.captures {
        let path = directory.join(&capture.image);
        let Ok(bytes) = std::fs::read(&path) else {
            problems.push(format!("{} cannot be read", capture.image));
            continue;
        };
        if fixtures::sha256_hex(&bytes) != capture.sha256 {
            problems.push(format!(
                "{} does not hash to the manifest entry ({} bytes on disk)",
                capture.image,
                bytes.len()
            ));
        }
        if bytes.len() as u64 != capture.bytes {
            problems.push(format!(
                "{} is {} bytes, the manifest records {}",
                capture.image,
                bytes.len(),
                capture.bytes
            ));
        }
    }
}

/// A checksum file must list exactly the expected entries, in sorted order.
fn checksum_file(
    path: &Path,
    mut expected: Vec<(String, String)>,
    label: &str,
    problems: &mut Vec<String>,
) {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) => {
            problems.push(format!("{label} cannot be read: {error}"));
            return;
        }
    };
    expected.sort_by(|left, right| left.1.cmp(&right.1));
    if parse_checksums(&text) != expected {
        problems.push(format!(
            "{label} does not match the manifest ({} line(s) on disk, {} expected)",
            text.lines().filter(|line| !line.trim().is_empty()).count(),
            expected.len()
        ));
    }
}

fn parse_checksums(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| match line.split_once("  ") {
            Some((sha256, path)) => (sha256.to_owned(), path.to_owned()),
            None => (String::new(), line.to_owned()),
        })
        .collect()
}

/// The committed README must be the rendering of the committed manifest.
fn readme_file(directory: &Path, committed: &Manifest, problems: &mut Vec<String>) {
    let path = directory.join("README.md");
    match std::fs::read_to_string(&path) {
        Ok(text) if text == manifest::readme(committed) => {}
        Ok(_) => problems.push(
            "README.md is stale: it is not the rendering of the committed manifest.json".to_owned(),
        ),
        Err(error) => problems.push(format!("README.md cannot be read: {error}")),
    }
}

/// The committed fixture tree must be the generated tree, with exactly the
/// declared dangling symlink.
fn fixture_tree(
    directory: &Path,
    committed: &Manifest,
    fresh: &Manifest,
    problems: &mut Vec<String>,
) {
    let root = directory.join(FIXTURE_DIRECTORY);
    match fixtures::read_reference_fixtures(&root) {
        Ok(records) => {
            let expected: Vec<fixtures::FixtureRecord> = fresh
                .fixtures
                .files
                .iter()
                .map(|file| fixtures::FixtureRecord {
                    relative_path: file.relative_path.clone(),
                    sha256: file.sha256.clone(),
                    bytes: file.bytes,
                })
                .collect();
            if records != expected {
                problems.push(format!(
                    "the committed fixture tree ({} file(s)) is not the generated tree ({} \
                     file(s))",
                    records.len(),
                    expected.len()
                ));
            }
        }
        Err(error) => problems.push(format!(
            "the committed fixture tree cannot be read: {error}"
        )),
    }
    let defects = fixtures::symlink_defects(&root);
    if !defects.is_empty() {
        problems.push(format!(
            "the committed fixture tree has symlink defects: {}",
            defects.join("; ")
        ));
    }
    if fixtures::broken_symlinks_available(&root) != committed.fixtures.broken_symlinks_available {
        problems.push(format!(
            "the committed fixture tree reports broken_symlinks_available={}, the manifest records \
             {}",
            fixtures::broken_symlinks_available(&root),
            committed.fixtures.broken_symlinks_available
        ));
    }
}

/// Compare the committed manifest with the manifest the current code produces.
fn compare_manifests(
    committed: &Manifest,
    fresh: &Manifest,
    fresh_pixels: bool,
    problems: &mut Vec<String>,
) {
    // Run metadata: recorded for provenance, exempt from comparison.
    if committed.schema != fresh.schema {
        problems.push(format!(
            "the manifest schema changed ({} -> {})",
            committed.schema, fresh.schema
        ));
    }
    field(problems, "package", &committed.package, &fresh.package);
    field(
        problems,
        "entry_point",
        &committed.entry_point,
        &fresh.entry_point,
    );
    field(
        problems,
        "capture_code_note",
        &committed.capture_code_note,
        &fresh.capture_code_note,
    );
    field(
        problems,
        "pinned_design_base",
        &committed.pinned_design_base,
        &fresh.pinned_design_base,
    );
    field(
        problems,
        "pinned_design_base_subject",
        &committed.pinned_design_base_subject,
        &fresh.pinned_design_base_subject,
    );
    field(
        problems,
        "preferences",
        &committed.preferences,
        &fresh.preferences,
    );
    field(problems, "fonts", &committed.fonts, &fresh.fonts);
    field(problems, "fixtures", &committed.fixtures, &fresh.fixtures);
    field(
        problems,
        "seeded_library",
        &committed.seeded_library,
        &fresh.seeded_library,
    );
    field(
        problems,
        "pixel_aliases",
        &committed.pixel_aliases,
        &fresh.pixel_aliases,
    );
    field(problems, "matrix", &committed.matrix, &fresh.matrix);
    field(
        problems,
        "limitations",
        &committed.limitations,
        &fresh.limitations,
    );

    // The environment block mixes run metadata (OS, arch, tool versions) with
    // the renderer setup the images depend on, so the deterministic half is
    // compared field by field.
    field(
        problems,
        "environment.renderer",
        &committed.environment.renderer,
        &fresh.environment.renderer,
    );
    field(
        problems,
        "environment.theme",
        &committed.environment.theme,
        &fresh.environment.theme,
    );
    field(
        problems,
        "environment.default_font",
        &committed.environment.default_font,
        &fresh.environment.default_font,
    );
    if committed.environment.default_text_size != fresh.environment.default_text_size {
        problems.push(format!(
            "environment.default_text_size changed ({} -> {})",
            committed.environment.default_text_size, fresh.environment.default_text_size
        ));
    }
    field(
        problems,
        "environment.note",
        &committed.environment.note,
        &fresh.environment.note,
    );

    if committed.captures.len() != fresh.captures.len() {
        problems.push(format!(
            "the capture set changed: {} committed, {} in the table",
            committed.captures.len(),
            fresh.captures.len()
        ));
    }
    for (index, capture) in fresh.captures.iter().enumerate() {
        match committed.captures.get(index) {
            Some(committed_capture) => {
                capture_differences(committed_capture, capture, fresh_pixels, problems)
            }
            None => problems.push(format!(
                "capture {} is not in position {index} of the committed manifest",
                capture.id
            )),
        }
    }
}

fn field<T: PartialEq + std::fmt::Debug>(
    problems: &mut Vec<String>,
    name: &str,
    committed: &T,
    fresh: &T,
) {
    if committed != fresh {
        problems.push(format!(
            "manifest {name} changed: committed {committed:?}, current {fresh:?}"
        ));
    }
}

fn capture_differences(
    committed: &CaptureEntry,
    fresh: &CaptureEntry,
    fresh_pixels: bool,
    problems: &mut Vec<String>,
) {
    if committed.id != fresh.id {
        problems.push(format!(
            "capture at this position changed id ({} -> {})",
            committed.id, fresh.id
        ));
        return;
    }
    if fresh_pixels {
        if committed.sha256 != fresh.sha256 {
            problems.push(format!(
                "{} re-rendered to a different image ({} -> {})",
                committed.id, committed.sha256, fresh.sha256
            ));
        }
        if committed.bytes != fresh.bytes {
            problems.push(format!(
                "{} re-rendered to a different size ({} -> {} bytes)",
                committed.id, committed.bytes, fresh.bytes
            ));
        }
    }
    let mut committed = committed.clone();
    let mut fresh = fresh.clone();
    committed.sha256.clear();
    fresh.sha256.clear();
    committed.bytes = 0;
    fresh.bytes = 0;
    if committed != fresh {
        problems.push(format!(
            "{} describes a different state or size than the capture table: committed {committed:?}, \
             current {fresh:?}",
            fresh.id
        ));
    }
}
