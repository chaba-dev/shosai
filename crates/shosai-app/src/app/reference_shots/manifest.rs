//! Provenance manifest for the reference captures (evidence code `G8`,
//! specification row `XA-10`).
//!
//! The manifest records, for every capture, the exact capture-code revision,
//! the pinned design base it was rendered against, the command that produced
//! it, the fixture and font hashes, the state derivation, the client and image
//! dimensions, the DPR, the locale and the settings that were persisted. It
//! also carries the seeded library inventory and the covered/pending matrix
//! rows, so an accepting package can cite a capture without guessing what it
//! contains.

use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use super::fixtures::FixtureRecord;
use super::seed::SeededBook;

/// The pinned Iced design base the captures are rendered against.
pub(crate) const PINNED_DESIGN_BASE: &str = "1e54270a6bb24f15630ece336a0575bdbe5be113";

/// What the pinned base is.
pub(crate) const PINNED_DESIGN_BASE_SUBJECT: &str =
    "main@origin #108 (refactor(flutter): organize the frontend into Elm modules mirroring Iced)";

/// The evidence families package 1B is assigned by the reference
/// specification (§4.1 library, §4.4 import, §4.5 settings). A capture may not
/// claim a family outside this set, and reader (`1C-*`) rows belong to 1C.
pub(crate) const PACKAGE_1B_FAMILIES: [&str; 6] = [
    "1B-LIB-WIDE",
    "1B-LIB-COMPACT",
    "1B-LIB-STATE",
    "1B-LIB-META",
    "1B-IMPORT",
    "1B-SETTINGS",
];

/// One manifest capture entry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct CaptureEntry {
    /// Evidence id, unique inside the run.
    pub(crate) id: String,
    /// Evidence family from the reference specification (`1B-LIB-WIDE`, …).
    pub(crate) family: String,
    /// Stable state identifier inside the family (`library`,
    /// `library+import-dialog`, `settings`).
    pub(crate) state: String,
    /// Path of the PNG relative to the manifest.
    pub(crate) image: String,
    pub(crate) sha256: String,
    pub(crate) bytes: u64,
    /// Client size in logical pixels.
    pub(crate) client_width: f32,
    pub(crate) client_height: f32,
    /// Rendered image size in physical pixels.
    pub(crate) image_width: u32,
    pub(crate) image_height: u32,
    pub(crate) dpr: f32,
    /// Locale code (`EN`, `JA`, `MIX`, `—`).
    pub(crate) locale: String,
    /// Seeded fixtures the state is built from.
    pub(crate) fixture: String,
    /// How the state was reached (production messages dispatched or the
    /// documented normalization).
    pub(crate) state_derivation: String,
    /// Persisted settings that differ from the harness defaults.
    pub(crate) settings: Vec<String>,
    /// Specification matrix rows this capture is reference evidence for.
    pub(crate) rows: Vec<String>,
    /// Notes about intentional gaps (for example native pickers).
    pub(crate) notes: Vec<String>,
}

/// One pair of captures that deliberately share pixels, with the reason.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct PixelAliasRecord {
    pub(crate) left: String,
    pub(crate) right: String,
    pub(crate) reason: String,
}

/// One row of the acceptance matrix with its capture coverage.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct RowCoverage {
    pub(crate) row: String,
    pub(crate) status: String,
    pub(crate) captures: Vec<String>,
    pub(crate) reason: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct MatrixCoverage {
    /// Rows a capture renders.
    pub(crate) captured: Vec<RowCoverage>,
    /// Rows the manifest itself satisfies (provenance).
    pub(crate) manifest: Vec<RowCoverage>,
    /// Rows this package deliberately leaves open.
    pub(crate) pending: Vec<RowCoverage>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct FixtureInventory {
    pub(crate) generator: String,
    pub(crate) redistribution: String,
    pub(crate) files: Vec<FixtureRecord>,
    pub(crate) reused: Vec<ReusedFixtureEntry>,
    pub(crate) broken_symlinks_available: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct ReusedFixtureEntry {
    pub(crate) path: String,
    pub(crate) sha256: String,
    pub(crate) provenance: String,
    pub(crate) purpose: String,
    /// Recomputed from disk during the run.
    pub(crate) verified_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct FontRecord {
    pub(crate) role: String,
    pub(crate) sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct SeededLibraryRecord {
    pub(crate) profile: String,
    pub(crate) count: usize,
    pub(crate) page_size: u32,
    pub(crate) order: String,
    pub(crate) continue_reading: Option<String>,
    pub(crate) books: Vec<SeededBook>,
}

/// One persisted preference the capture baseline sets.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct PreferenceRecord {
    pub(crate) key: String,
    pub(crate) value: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct Environment {
    pub(crate) os: String,
    pub(crate) arch: String,
    pub(crate) rustc: String,
    pub(crate) cargo: String,
    pub(crate) renderer: String,
    pub(crate) theme: String,
    pub(crate) default_font: String,
    pub(crate) default_text_size: f32,
    pub(crate) note: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Manifest {
    pub(crate) schema: u32,
    pub(crate) package: String,
    pub(crate) entry_point: String,
    pub(crate) command: String,
    pub(crate) capture_code_revision: String,
    /// How the revision was determined (`jj @ working-copy commit`, an
    /// environment variable, or `git HEAD`).
    pub(crate) capture_code_revision_source: String,
    /// Jujutsu change id, stable across `describe`/`commit`, so the manifest can
    /// be mapped back to the change that produced it.
    pub(crate) capture_code_change_id: String,
    pub(crate) capture_code_bookmark: String,
    /// Why the revision is recorded this way: a Jujutsu commit id is rewritten
    /// when its change is described or committed, so the stable change id plus
    /// the committed evidence change is the durable mapping.
    pub(crate) capture_code_note: String,
    pub(crate) pinned_design_base: String,
    pub(crate) pinned_design_base_subject: String,
    pub(crate) output_directory: String,
    /// The preference baseline every capture state is built from, before any
    /// capture dispatches a message that changes it.
    pub(crate) preferences: Vec<PreferenceRecord>,
    pub(crate) environment: Environment,
    pub(crate) fonts: Vec<FontRecord>,
    pub(crate) fixtures: FixtureInventory,
    pub(crate) seeded_library: SeededLibraryRecord,
    pub(crate) captures: Vec<CaptureEntry>,
    /// Capture pairs that intentionally render identical pixels.
    pub(crate) pixel_aliases: Vec<PixelAliasRecord>,
    pub(crate) matrix: MatrixCoverage,
    pub(crate) limitations: Vec<String>,
}

fn version_of(program: &str) -> String {
    let Ok(output) = std::process::Command::new(program)
        .arg("--version")
        .output()
    else {
        return "unknown".to_owned();
    };
    if !output.status.success() {
        return "unknown".to_owned();
    }
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// The capture preference baseline, as `key = value` pairs.
pub(crate) fn preference_baseline() -> Vec<PreferenceRecord> {
    super::seed::CAPTURE_PREFS
        .iter()
        .map(|(key, value)| PreferenceRecord {
            key: (*key).to_owned(),
            value: (*value).to_owned(),
        })
        .collect()
}

/// Environment block describing what produced the images.
pub(crate) fn environment() -> Environment {
    Environment {
        os: std::env::consts::OS.to_owned(),
        arch: std::env::consts::ARCH.to_owned(),
        rustc: version_of(&std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_owned())),
        cargo: version_of("cargo"),
        renderer: "iced_tiny_skia 0.14 (software, in-process)".to_owned(),
        theme: "theme::application() — iced::Theme::custom(APP_BACKGROUND #F4F2ED)".to_owned(),
        default_font: format!(
            "{} (bundled InterVariable.ttf)",
            super::render::DEFAULT_FONT_NAME
        ),
        default_text_size: super::render::DEFAULT_TEXT_SIZE,
        note: "No window, compositor, X server or GPU is involved: the production view is laid \
               out and drawn offscreen with the same software renderer Iced falls back to, and \
               the bundled fonts are loaded into Iced's global font system exactly like \
               `iced::application(..).font(..)`."
            .to_owned(),
    }
}

/// Fixture inventory for the manifest.
pub(crate) fn fixture_inventory(
    records: &[FixtureRecord],
    broken_symlinks_available: bool,
) -> Result<FixtureInventory> {
    let reused = super::fixtures::REUSED_FIXTURES
        .iter()
        .map(|fixture| {
            let path = super::fixtures::repository_fixture_path(fixture.path);
            let bytes =
                std::fs::read(&path).with_context(|| format!("reused fixture {}", fixture.path))?;
            Ok(ReusedFixtureEntry {
                path: fixture.path.to_owned(),
                sha256: fixture.sha256.to_owned(),
                provenance: fixture.provenance.to_owned(),
                purpose: fixture.purpose.to_owned(),
                verified_sha256: super::fixtures::sha256_hex(&bytes),
            })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(FixtureInventory {
        generator: "crates/shosai-app/src/app/reference_shots/fixtures.rs".to_owned(),
        redistribution: "Generated in-repo: every archive and image is produced by the \
                         deterministic generator above, no third-party content is embedded, and \
                         the generator reads no clock, locale or random source. The reused \
                         conformance book keeps its own documented redistribution statement."
            .to_owned(),
        files: records.to_vec(),
        reused,
        broken_symlinks_available,
    })
}

/// Writes `manifest.json`, `README.md`, `captures.sha256` and
/// `fixtures.sha256`.
pub(crate) fn write_all(directory: &Path, manifest: &Manifest) -> Result<()> {
    std::fs::create_dir_all(directory)
        .with_context(|| format!("create {}", directory.display()))?;
    let json = serde_json::to_string_pretty(manifest).context("serialize manifest")?;
    std::fs::write(directory.join("manifest.json"), format!("{json}\n"))
        .context("write manifest.json")?;

    let mut captures: Vec<(String, String)> = manifest
        .captures
        .iter()
        .map(|capture| (capture.sha256.clone(), capture.image.clone()))
        .collect();
    captures.sort_by(|left, right| left.1.cmp(&right.1));
    std::fs::write(directory.join("captures.sha256"), checksum_file(&captures))
        .context("write captures.sha256")?;

    let mut fixtures: Vec<(String, String)> = manifest
        .fixtures
        .files
        .iter()
        .map(|file| {
            (
                file.sha256.clone(),
                format!("fixtures/{}", file.relative_path),
            )
        })
        .collect();
    fixtures.sort_by(|left, right| left.1.cmp(&right.1));
    std::fs::write(directory.join("fixtures.sha256"), checksum_file(&fixtures))
        .context("write fixtures.sha256")?;

    std::fs::write(directory.join("README.md"), readme(manifest)).context("write README.md")?;
    Ok(())
}

fn checksum_file(entries: &[(String, String)]) -> String {
    let mut out = String::new();
    for (sha256, relative) in entries {
        out.push_str(sha256);
        out.push_str("  ");
        out.push_str(relative);
        out.push('\n');
    }
    out
}

pub(crate) fn readme(manifest: &Manifest) -> String {
    let mut out = String::new();
    out.push_str("# 1B reference captures (Iced, package 1B)\n\n");
    out.push_str(
        "Generated evidence for the `1B-LIB-*`, `1B-IMPORT` and `1B-SETTINGS` families of the\n\
         Flutter UI reference specification. These images are the **Iced reference**, not\n\
         acceptance evidence for the Flutter restoration: each accepting package still produces\n\
         and inspects its own renders (specification §4.0).\n\n",
    );
    out.push_str(&format!("- Entry point: `{}`\n", manifest.entry_point));
    out.push_str(&format!("- Command: `{}`\n", manifest.command));
    out.push_str(&format!(
        "- Capture-code revision: `{}` (from {}, Jujutsu change `{}`, bookmark `{}`)\n",
        manifest.capture_code_revision,
        manifest.capture_code_revision_source,
        manifest.capture_code_change_id,
        manifest.capture_code_bookmark
    ));
    out.push_str(&format!(
        "- Revision note: {}\n",
        manifest.capture_code_note
    ));
    out.push_str(&format!(
        "- Pinned design base: `{}` — {}\n",
        manifest.pinned_design_base, manifest.pinned_design_base_subject
    ));
    out.push_str(&format!(
        "- Preference baseline: {}\n",
        manifest
            .preferences
            .iter()
            .map(|preference| format!("`{}={}`", preference.key, preference.value))
            .collect::<Vec<_>>()
            .join(", ")
    ));
    out.push_str(&format!(
        "- Renderer: {} · theme {} · default font {} at {} px\n",
        manifest.environment.renderer,
        manifest.environment.theme,
        manifest.environment.default_font,
        manifest.environment.default_text_size
    ));
    out.push_str(&format!(
        "- Generated: {} · {} (rustc {})\n",
        manifest.environment.os, manifest.environment.arch, manifest.environment.rustc
    ));
    out.push_str(&format!(
        "- Seeded library: {} books (`{}`), page size {}, order `{}`\n",
        manifest.seeded_library.count,
        manifest.seeded_library.profile,
        manifest.seeded_library.page_size,
        manifest.seeded_library.order
    ));
    if let Some(continue_reading) = &manifest.seeded_library.continue_reading {
        out.push_str(&format!("- Continue-reading seed: {continue_reading}\n"));
    }
    out.push_str(&format!("- Captures: {}\n\n", manifest.captures.len()));

    out.push_str("## Files\n\n");
    out.push_str(
        "- `captures/*.png` — one image per capture; `captures.sha256` verifies them\n  (`sha256sum -c captures.sha256` from this directory).\n\
         - `manifest.json` — machine-readable provenance: revision, base, commands, fixture and\n  font hashes, seeded inventory, per-capture state, sizes, DPR, locale, settings and rows.\n\
         - `fixtures/` — the generated reference fixture tree, committed so the library/import\n  states can be reproduced without running the generator; `fixtures.sha256` verifies it.\n  The generator remains the source of truth: a test in `crates/shosai-app` regenerates the\n  tree and fails if any byte differs.\n\n",
    );

    out.push_str("## Captures\n\n");
    out.push_str(
        "| Evidence id | Family | State | Rows | Client | Image | DPR | Locale | Fixture | SHA-256 (12) |\n\
         | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n",
    );
    for capture in &manifest.captures {
        out.push_str(&format!(
            "| `{}` | {} | {} | {} | {}×{} | {}×{} | {} | {} | {} | `{}` |\n",
            capture.id,
            capture.family,
            capture.state,
            capture.rows.join(" "),
            capture.client_width as u32,
            capture.client_height as u32,
            capture.image_width,
            capture.image_height,
            capture.dpr,
            capture.locale,
            capture.fixture,
            &capture.sha256[..12]
        ));
    }

    out.push_str("\n## State derivation and settings\n\n");
    for capture in &manifest.captures {
        out.push_str(&format!("### `{}`\n\n", capture.id));
        out.push_str(&format!(
            "- Family: {} · state: {}\n",
            capture.family, capture.state
        ));
        out.push_str(&format!("- State: {}\n", capture.state_derivation));
        out.push_str(&format!(
            "- Settings: {}\n",
            if capture.settings.is_empty() {
                "harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)".to_owned()
            } else {
                capture.settings.join("; ")
            }
        ));
        for note in &capture.notes {
            out.push_str(&format!("- Note: {note}\n"));
        }
        out.push('\n');
    }

    out.push_str("## Matrix coverage\n\n");
    out.push_str("Covered by a capture in this set:\n\n");
    out.push_str("| Row | Captures |\n| --- | --- |\n");
    for row in &manifest.matrix.captured {
        out.push_str(&format!(
            "| {} | {} |\n",
            row.row,
            row.captures
                .iter()
                .map(|capture| format!("`{capture}`"))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }
    out.push_str("\nCovered by the manifest itself (provenance, no image):\n\n");
    out.push_str("| Row | Satisfied by |\n| --- | --- |\n");
    for row in &manifest.matrix.manifest {
        out.push_str(&format!(
            "| {} | {} |\n",
            row.row,
            if row.reason.is_empty() {
                "manifest.json".to_owned()
            } else {
                row.reason.clone()
            }
        ));
    }
    out.push_str("\nPending, not covered by Iced captures (with owner and reason):\n\n");
    out.push_str("| Row | Owner | Reason |\n| --- | --- | --- |\n");
    for row in &manifest.matrix.pending {
        out.push_str(&format!(
            "| {} | {} | {} |\n",
            row.row, row.status, row.reason
        ));
    }

    out.push_str("\n## Captures that intentionally share pixels\n\n");
    if manifest.pixel_aliases.is_empty() {
        out.push_str(
            "None: every capture in this set renders a different image, and the capture run fails\n\
             when two captures are byte-identical without a declared alias.\n",
        );
    } else {
        out.push_str("| Capture | Identical to | Reason |\n| --- | --- | --- |\n");
        for alias in &manifest.pixel_aliases {
            out.push_str(&format!(
                "| `{}` | `{}` | {} |\n",
                alias.left, alias.right, alias.reason
            ));
        }
    }

    out.push_str("\n## Fixtures\n\n");
    out.push_str(&format!("{}\n\n", manifest.fixtures.redistribution));
    out.push_str(&format!(
        "Generated files: {} (all hashed in `fixtures.sha256` and in `manifest.json`). The\n\
         dangling-symlink discovery-failure fixture could be created on this platform: {}.\n\n",
        manifest.fixtures.files.len(),
        manifest.fixtures.broken_symlinks_available
    ));
    out.push_str(
        "| Reused fixture | SHA-256 | Provenance | Purpose |\n| --- | --- | --- | --- |\n",
    );
    for reused in &manifest.fixtures.reused {
        let verified = if reused.verified_sha256 == reused.sha256 {
            "verified".to_owned()
        } else {
            format!("MISMATCH: {}", reused.verified_sha256)
        };
        out.push_str(&format!(
            "| `{}` | `{}` ({}) | {} | {} |\n",
            reused.path,
            &reused.sha256[..12],
            verified,
            reused.provenance,
            reused.purpose
        ));
    }

    out.push_str("\n## Fonts\n\n| Role | SHA-256 |\n| --- | --- |\n");
    for font in &manifest.fonts {
        out.push_str(&format!("| {} | `{}` |\n", font.role, font.sha256));
    }

    out.push_str("\n## Known limitations\n\n");
    for limitation in &manifest.limitations {
        out.push_str(&format!("- {limitation}\n"));
    }
    out
}
