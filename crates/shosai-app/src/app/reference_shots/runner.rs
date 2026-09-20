//! The `make reference-shots` entry point.
//!
//! One run: writes the deterministic fixture tree, seeds the disposable
//! libraries, reaches every [`super::scenarios`] state through the production
//! messages, renders each one offscreen with the production view, and writes
//! the PNGs, their checksums and the provenance manifest.
//!
//! Nothing outside the output directory and the disposable data root is
//! touched: the application's real data directory is never opened, because the
//! task `boot` returns is dropped without being polled.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use iced::Size;

use super::super::{Message, initialized_state_from_preferences};
use super::harness::Harness;
use super::scenarios::{self, Base};
use super::{fixtures, manifest, render, seed};

/// Committed evidence directory, relative to the repository root.
pub(crate) const DEFAULT_OUTPUT: &str = "rfd/0004/evidence/reference-shots-1b";

/// Fixed disposable data root. It is removed at the start and the end of a run,
/// and it is deliberately not the platform's user data directory: captures must
/// never read or write a real library.
pub(crate) const DEFAULT_DATA_ROOT: &str = "/tmp/shosai-reference-shots-1b";

/// The documented entry point.
pub(crate) const ENTRY_POINT: &str = "make reference-shots";

/// How the manifest's revision fields should be read.
pub(crate) const REVISION_NOTE: &str = "`capture_code_revision` is the working-copy commit id at \
     render time. Jujutsu rewrites a commit id when its change is described or committed, so the \
     stable `capture_code_change_id` plus the committed evidence change is the durable mapping; \
     `make reference-shots VERIFY=1` re-renders this evidence byte-identically at any revision \
     that carries the change.";

/// The command the Makefile target runs.
pub(crate) const DEFAULT_COMMAND: &str = "cargo test --package shosai-app --bin shosai \
     reference_shots_capture -- --ignored --nocapture";

/// Repository root, derived from the crate location.
pub(crate) fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Disposable data root; `SHOSAI_REFERENCE_SHOTS_DATA_DIR` overrides it.
pub(crate) fn data_root() -> PathBuf {
    std::env::var_os("SHOSAI_REFERENCE_SHOTS_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_DATA_ROOT))
}

/// Evidence output directory; `SHOSAI_REFERENCE_SHOTS_DIR` overrides it.
pub(crate) fn output_root() -> PathBuf {
    match std::env::var_os("SHOSAI_REFERENCE_SHOTS_DIR") {
        Some(path) => PathBuf::from(path),
        None => repository_root().join(DEFAULT_OUTPUT),
    }
}

/// Where the reference fixture tree is generated and read from.
///
/// It is always inside the disposable data root, never inside the evidence
/// directory: the application renders real absolute paths (the discovery-failure
/// rows), so a capture taken from a checkout path would embed a machine-specific
/// path and would not reproduce elsewhere. With the default data root the path is
/// fixed, and `SHOSAI_REFERENCE_SHOTS_DATA_DIR` is the documented way to move it.
pub(crate) fn fixtures_root() -> PathBuf {
    data_root().join("fixtures")
}

/// Where the committed copy of the generated fixture tree lives.
pub(crate) fn evidence_fixtures_root() -> PathBuf {
    output_root().join("fixtures")
}

/// The capture run. Marked `#[ignore]` so an ordinary `cargo test` never
/// renders or writes evidence.
#[test]
#[ignore = "capture tool: run it through `make reference-shots`"]
fn reference_shots_capture() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("capture runtime");
    runtime.block_on(async {
        run().await.expect("reference capture run");
    });
}

async fn run() -> Result<()> {
    let revision = capture_revision();
    let verify = std::env::var("SHOSAI_REFERENCE_SHOTS_VERIFY")
        .is_ok_and(|value| !value.is_empty() && value != "0");
    let output = output_root();
    // Captures always read the fixture tree from the disposable data root, and
    // verify mode writes nothing outside it: the fresh captures are compared
    // with the committed checksums instead, and a capture run then mirrors the
    // tree it rendered from into the evidence directory.
    let fixtures_root = fixtures_root();
    let data = data_root();
    if data.exists() {
        std::fs::remove_dir_all(&data)
            .with_context(|| format!("clear disposable root {}", data.display()))?;
    }

    println!(
        "reference-shots: {} mode, fixtures -> {}",
        if verify { "verify" } else { "capture" },
        fixtures_root.display()
    );
    let fixture_records = fixtures::write_reference_fixtures(&fixtures_root)?;
    let broken_symlinks_available = fixtures::broken_symlinks_available(&fixtures_root);

    let seeded = seed::seed_library(&data.join("seeded"), &fixtures_root).await?;
    let empty = seed::seed_empty_library(&data.join("empty")).await?;
    println!(
        "reference-shots: seeded {} books, {} fixtures",
        seeded.books.len(),
        fixture_records.len()
    );

    let mut import_bases: HashMap<Base, seed::SeededLibrary> = HashMap::new();
    let mut captures: Vec<manifest::CaptureEntry> = Vec::new();
    let scenarios = scenarios::scenarios();
    println!("reference-shots: {} captures", scenarios.len());

    for scenario in &scenarios {
        // Every capture starts from a fresh harness: the base seeds are built
        // once, but each capture re-runs the real initialization path against
        // its base store, so no capture can observe another's state.
        let base_seed: Option<&seed::SeededLibrary> = match scenario.base {
            Base::Seeded => Some(&seeded),
            Base::Empty => Some(&empty),
            Base::NoStore => None,
            Base::Import | Base::ImportRemoval | Base::ImportCompleted => {
                if let std::collections::hash_map::Entry::Vacant(entry) =
                    import_bases.entry(scenario.base)
                {
                    let profile = match scenario.base {
                        Base::ImportRemoval => "import-removal",
                        Base::ImportCompleted => "import-completed",
                        _ => "import",
                    };
                    let library = seed::seed_library(&data.join(profile), &fixtures_root).await?;
                    entry.insert(library);
                }
                Some(
                    import_bases
                        .get(&scenario.base)
                        .expect("import base seeded above"),
                )
            }
        };

        let mut harness = base_harness(base_seed).await?;
        scenarios::apply(scenario, &mut harness, &fixtures_root).await;
        scenarios::assert_reached(scenario, &harness.state);

        let (width, height) = scenario.client;
        harness.state.window_size = Size::new(width, height);
        harness.state.window_scale_factor = scenario.dpr;

        let image = harness.render_image(width, height, scenario.dpr).await;
        let image_name = format!("captures/{}.png", scenario.id);
        if !verify {
            let path = output.join(&image_name);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&path, &image.png)
                .with_context(|| format!("write {}", path.display()))?;
        }

        captures.push(manifest::CaptureEntry {
            id: scenario.id.to_owned(),
            family: scenario.family.to_owned(),
            state: scenarios::state_id(scenario).to_owned(),
            image: image_name.clone(),
            sha256: fixtures::sha256_hex(&image.png),
            bytes: image.png.len() as u64,
            client_width: width,
            client_height: height,
            image_width: image.physical_width,
            image_height: image.physical_height,
            dpr: scenario.dpr,
            locale: scenario.locale.code().to_owned(),
            fixture: scenario.fixture.to_owned(),
            state_derivation: scenario.derivation(),
            settings: scenario.settings(),
            rows: scenario.rows.iter().map(|row| (*row).to_owned()).collect(),
            notes: scenario
                .notes
                .iter()
                .map(|note| (*note).to_owned())
                .collect(),
        });
        println!(
            "  {} [{}] {}x{} dpr {} -> {} ({} bytes, {} messages settled)",
            scenario.id,
            scenario.family,
            width as u32,
            height as u32,
            scenario.dpr,
            image_name,
            image.png.len(),
            harness.settled
        );
    }

    let matrix = matrix();
    reject_duplicate_pixels(&captures)?;
    if verify {
        verify_against_committed(&output, &captures, &fixture_records, &matrix)?;
    } else {
        prune_stale_evidence(&output, &captures)?;
        let mirrored = fixtures::mirror_reference_fixtures(
            &fixtures_root,
            &evidence_fixtures_root(),
            &fixture_records,
        )
        .context("mirror the generated fixture tree into the evidence directory")?;
        if mirrored != fixture_records {
            anyhow::bail!("the committed fixture copy does not match the generated fixture tree");
        }
    }
    let manifest = manifest::Manifest {
        schema: 1,
        package: "1B".to_owned(),
        entry_point: ENTRY_POINT.to_owned(),
        command: std::env::var("SHOSAI_REFERENCE_SHOTS_COMMAND")
            .unwrap_or_else(|_| DEFAULT_COMMAND.to_owned()),
        capture_code_revision: revision.revision.clone(),
        capture_code_revision_source: revision.source.clone(),
        capture_code_change_id: revision.change_id.clone(),
        capture_code_bookmark: revision.bookmark.clone(),
        capture_code_note: REVISION_NOTE.to_owned(),
        pinned_design_base: manifest::PINNED_DESIGN_BASE.to_owned(),
        pinned_design_base_subject: manifest::PINNED_DESIGN_BASE_SUBJECT.to_owned(),
        output_directory: output.display().to_string(),
        preferences: manifest::preference_baseline(),
        environment: manifest::environment(),
        fonts: render::font_identities()
            .into_iter()
            .map(|(role, sha256)| manifest::FontRecord {
                role: role.to_owned(),
                sha256,
            })
            .collect(),
        fixtures: manifest::fixture_inventory(&fixture_records, broken_symlinks_available)?,
        seeded_library: manifest::SeededLibraryRecord {
            profile: "G1 library seed: 14 featured books (incl. one reused conformance book and \
                      two without covers) + 32 filler books, one continue-reading entry"
                .to_owned(),
            count: seeded.books.len(),
            page_size: super::super::LIBRARY_PAGE_SIZE,
            order: "last_read DESC NULLS LAST, date_added DESC, id DESC".to_owned(),
            continue_reading: seeded.continue_reading().map(|book| {
                format!(
                    "{} ({}) at {:.0}%",
                    book.title,
                    book.fixture,
                    book.progress * 100.0
                )
            }),
            books: seeded.books.clone(),
        },
        captures,
        pixel_aliases: scenarios::PIXEL_ALIASES
            .iter()
            .map(|(left, right, reason)| manifest::PixelAliasRecord {
                left: (*left).to_owned(),
                right: (*right).to_owned(),
                reason: (*reason).to_owned(),
            })
            .collect(),
        matrix: matrix.clone(),
        limitations: limitations(broken_symlinks_available),
    };
    if verify {
        println!(
            "reference-shots: {} captures re-rendered byte-identically to the committed evidence",
            manifest.captures.len()
        );
    } else {
        manifest::write_all(&output, &manifest)?;
        println!(
            "reference-shots: manifest, checksums and README written to {}",
            output.display()
        );
    }

    if std::env::var_os("SHOSAI_REFERENCE_SHOTS_KEEP_DATA").is_none() {
        let _ = std::fs::remove_dir_all(&data);
    }
    Ok(())
}

/// A boot state with the initialize task dropped: the real user data directory
/// is never opened, and every field starts where the application starts it.
fn fresh_state() -> super::super::State {
    let (state, initialize) = super::super::boot();
    drop(initialize);
    state
}

/// Remove evidence a previous run left behind.
///
/// The capture set and the generated fixture tree are the source of truth for
/// the committed evidence, so a renamed or dropped capture must not leave an
/// orphaned PNG (or fixture file) behind for an accepting reviewer to find. The
/// fixture tree is deleted and rewritten by every capture run; only stale
/// captures need pruning here, because the fixture writer overwrites in place.
pub(crate) fn prune_stale_evidence(
    output: &Path,
    captures: &[manifest::CaptureEntry],
) -> Result<()> {
    let directory = output.join("captures");
    let Ok(entries) = std::fs::read_dir(&directory) else {
        return Ok(());
    };
    let expected: Vec<&str> = captures
        .iter()
        .filter_map(|capture| capture.image.rsplit('/').next())
        .collect();
    for entry in entries {
        let entry = entry.with_context(|| format!("read {}", directory.display()))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !expected.contains(&name.as_ref()) {
            let path = entry.path();
            println!(
                "reference-shots: removing stale evidence file {}",
                path.display()
            );
            std::fs::remove_file(&path).with_context(|| format!("remove {}", path.display()))?;
        }
    }
    Ok(())
}

/// Fail when two captures rendered the same pixels.
///
/// Two states of the application almost never look identical. When they do, one
/// of the captures is silently showing the other's state, which is how a
/// wrong-surface capture is caught before it becomes evidence. Aliases have to
/// be declared in [`scenarios::PIXEL_ALIASES`] with a reason.
pub(crate) fn reject_duplicate_pixels(captures: &[manifest::CaptureEntry]) -> Result<()> {
    let mut duplicates: Vec<String> = Vec::new();
    for (index, capture) in captures.iter().enumerate() {
        for other in &captures[index + 1..] {
            if capture.sha256 != other.sha256 {
                continue;
            }
            let aliased = scenarios::PIXEL_ALIASES.iter().any(|(left, right, _)| {
                (*left == capture.id && *right == other.id)
                    || (*left == other.id && *right == capture.id)
            });
            if !aliased {
                duplicates.push(format!("{} and {}", capture.id, other.id));
            }
        }
    }
    // The declaration is checked in the other direction too: an alias that no
    // longer shares pixels means one of the two captures changed state, and the
    // recorded reason is stale.
    let mut stale: Vec<String> = Vec::new();
    for (left, right, _) in scenarios::PIXEL_ALIASES {
        let left_sha = captures
            .iter()
            .find(|capture| capture.id == left)
            .map(|capture| capture.sha256.as_str());
        let right_sha = captures
            .iter()
            .find(|capture| capture.id == right)
            .map(|capture| capture.sha256.as_str());
        match (left_sha, right_sha) {
            (Some(left_sha), Some(right_sha)) if left_sha == right_sha => {}
            (Some(_), Some(_)) => stale.push(format!("{left} and {right}")),
            _ => stale.push(format!("{left} and {right} (no such capture)")),
        }
    }
    if duplicates.is_empty() && stale.is_empty() {
        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "pixel aliases: not declared but identical: {}; declared but different: {}",
            duplicates.join(", "),
            stale.join(", ")
        ))
    }
}

/// Compare a fresh capture run with the committed evidence.
///
/// This is the reproducibility check an accepting package can rerun: it renders
/// every capture again from the current code and fails when an image, a capture
/// field, a fixture byte or a matrix row no longer matches what is committed.
fn verify_against_committed(
    output: &Path,
    captures: &[manifest::CaptureEntry],
    fixture_records: &[fixtures::FixtureRecord],
    matrix: &manifest::MatrixCoverage,
) -> Result<()> {
    let manifest_path = output.join("manifest.json");
    let committed: manifest::Manifest =
        serde_json::from_str(&std::fs::read_to_string(&manifest_path).with_context(|| {
            format!(
                "verify mode needs committed evidence at {}",
                manifest_path.display()
            )
        })?)
        .context("read committed manifest.json")?;

    let mut mismatches: Vec<String> = Vec::new();
    if committed.captures.len() != captures.len() {
        mismatches.push(format!(
            "committed {} captures, this run produced {}",
            committed.captures.len(),
            captures.len()
        ));
    }
    for capture in captures {
        let Some(previous) = committed
            .captures
            .iter()
            .find(|previous| previous.id == capture.id)
        else {
            mismatches.push(format!(
                "{} is new (not in the committed evidence)",
                capture.id
            ));
            continue;
        };
        if previous.sha256 != capture.sha256 {
            mismatches.push(format!(
                "{} re-rendered to a different image ({} -> {})",
                capture.id, previous.sha256, capture.sha256
            ));
        }
        if serde_json::to_value(previous)? != serde_json::to_value(capture)? {
            mismatches.push(format!(
                "{} changed outside its pixels (state, sizes, locale, settings or rows)",
                capture.id
            ));
        }
    }
    for previous in &committed.captures {
        if !captures.iter().any(|capture| capture.id == previous.id) {
            mismatches.push(format!("{} is no longer captured", previous.id));
        }
    }

    let committed_fixtures: Vec<fixtures::FixtureRecord> = committed
        .fixtures
        .files
        .iter()
        .map(|record| fixtures::FixtureRecord {
            relative_path: record.relative_path.clone(),
            sha256: record.sha256.clone(),
            bytes: record.bytes,
        })
        .collect();
    if committed_fixtures != fixture_records {
        mismatches.push("the generated fixture tree changed".to_owned());
    }
    // The committed tree itself, not just the manifest that describes it: an
    // edited or truncated fixture file must fail verification.
    match fixtures::read_reference_fixtures(&evidence_fixtures_root()) {
        Ok(committed_tree) if committed_tree == fixture_records => {}
        Ok(_) => {
            mismatches.push("the committed fixture tree does not match its manifest".to_owned())
        }
        Err(error) => mismatches.push(format!(
            "the committed fixture tree could not be read: {error}"
        )),
    }
    if !fixtures::broken_symlinks_available(&evidence_fixtures_root()) {
        mismatches.push("the committed fixture tree is missing its dangling symlink".to_owned());
    }
    if committed.matrix.captured != matrix.captured
        || committed.matrix.manifest != matrix.manifest
        || committed.matrix.pending != matrix.pending
    {
        mismatches.push("the covered/pending matrix changed".to_owned());
    }
    if committed.pinned_design_base != manifest::PINNED_DESIGN_BASE {
        mismatches.push(format!(
            "the committed evidence pins {} but this code pins {}",
            committed.pinned_design_base,
            manifest::PINNED_DESIGN_BASE
        ));
    }
    if committed.fonts
        != render::font_identities()
            .into_iter()
            .map(|(role, sha256)| manifest::FontRecord {
                role: role.to_owned(),
                sha256,
            })
            .collect::<Vec<_>>()
    {
        mismatches.push("a recorded font hash changed".to_owned());
    }

    if mismatches.is_empty() {
        Ok(())
    } else {
        for mismatch in &mismatches {
            eprintln!("reference-shots: MISMATCH: {mismatch}");
        }
        Err(anyhow::anyhow!(
            "{} capture(s) no longer match the committed evidence",
            mismatches.len()
        ))
    }
}

/// The state a capture set starts from.
///
/// With a seeded library this is the *real* startup path: the disposable
/// store's preferences are parsed by the same function `boot`'s initialize task
/// calls, and the resulting `InitializedState` is delivered through
/// `Message::Initialized(Ok(..))`, which loads the first library page and
/// decodes its covers. Without a store it is a bare boot state, which is what a
/// machine with no readable data directory has when initialization fails.
async fn base_harness(seeded: Option<&seed::SeededLibrary>) -> Result<Harness> {
    let Some(seeded) = seeded else {
        return Ok(Harness::new(fresh_state()));
    };
    // Captures share one disposable store per base, so preferences an earlier
    // capture persisted (`SelectLanguage`, the settings controls) would
    // otherwise leak into the next one and make the set order-dependent. Every
    // capture therefore starts from the documented preference baseline.
    seed::reset_capture_preferences(&seeded.store).await?;
    let initialized = initialized_state_from_preferences(seeded.store.clone())
        .await
        .map_err(anyhow::Error::msg)
        .context("capture preferences")?;
    let mut harness = Harness::new(fresh_state());
    harness
        .dispatch(Message::Initialized(Ok(initialized)))
        .await;
    Ok(harness)
}

/// Where the capture code revision came from.
pub(crate) struct CaptureRevision {
    /// Exact commit id the capture code was rendered from.
    pub(crate) revision: String,
    /// Jujutsu change id, which stays stable when the change is described and
    /// committed, so an accepting package can map the manifest back to the
    /// change even though the manifest cannot name its own commit.
    pub(crate) change_id: String,
    pub(crate) bookmark: String,
    pub(crate) source: String,
}

fn capture_revision() -> CaptureRevision {
    if let Ok(revision) = std::env::var("SHOSAI_REFERENCE_SHOTS_REVISION") {
        return CaptureRevision {
            revision,
            change_id: std::env::var("SHOSAI_REFERENCE_SHOTS_CHANGE_ID")
                .unwrap_or_else(|_| "unknown".to_owned()),
            bookmark: std::env::var("SHOSAI_REFERENCE_SHOTS_BOOKMARK")
                .unwrap_or_else(|_| "unknown".to_owned()),
            source: "SHOSAI_REFERENCE_SHOTS_REVISION".to_owned(),
        };
    }
    if let Some(revision) = jj_revision() {
        return revision;
    }
    CaptureRevision {
        revision: command_stdout("git", &["rev-parse", "HEAD"])
            .unwrap_or_else(|| "unknown (set SHOSAI_REFERENCE_SHOTS_REVISION)".to_owned()),
        change_id: "unknown".to_owned(),
        bookmark: "unknown".to_owned(),
        source: "git HEAD (no Jujutsu binary on PATH)".to_owned(),
    }
}

fn jj_revision() -> Option<CaptureRevision> {
    let output = command_stdout(
        "jj",
        &[
            "log",
            "--no-graph",
            "-r",
            "@",
            "-T",
            "commit_id ++ \" \" ++ change_id ++ \" \" ++ bookmarks",
        ],
    )?;
    let mut fields = output.split_whitespace();
    let revision = fields.next()?.to_owned();
    let change_id = fields.next().unwrap_or("unknown").to_owned();
    let bookmark = fields.collect::<Vec<_>>().join(" ");
    Some(CaptureRevision {
        revision,
        change_id,
        bookmark: if bookmark.is_empty() {
            "none".to_owned()
        } else {
            bookmark
        },
        source: "jj @ working-copy commit".to_owned(),
    })
}

fn command_stdout(program: &str, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new(program)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!text.is_empty()).then_some(text)
}

fn matrix() -> manifest::MatrixCoverage {
    let captures = scenarios::scenarios();
    let (captured_rows, manifest_rows, pending_rows) = scenarios::matrix_rows();
    let captured = captured_rows
        .iter()
        .map(|row| manifest::RowCoverage {
            row: (*row).to_owned(),
            status: "capture".to_owned(),
            captures: captures
                .iter()
                .filter(|scenario| scenario.rows.contains(row))
                .map(|scenario| scenario.id.to_owned())
                .collect(),
            reason: String::new(),
        })
        .collect();
    let from_manifest = manifest_rows
        .iter()
        .map(|row| manifest::RowCoverage {
            row: (*row).to_owned(),
            status: "manifest".to_owned(),
            captures: Vec::new(),
            reason: "satisfied by `manifest.json` with `captures.sha256`, `fixtures.sha256` and \
                     the README rather than by an image"
                .to_owned(),
        })
        .collect();
    let pending = pending_rows
        .iter()
        .map(|(row, reason)| manifest::RowCoverage {
            row: (*row).to_owned(),
            status: "pending".to_owned(),
            captures: Vec::new(),
            reason: (*reason).to_owned(),
        })
        .collect();
    manifest::MatrixCoverage {
        captured,
        manifest: from_manifest,
        pending,
    }
}

fn limitations(broken_symlinks_available: bool) -> Vec<String> {
    let mut limitations = vec![
        "Iced has no text scaling (`T200`), no CBZ filter entry, no tiled continuous render and \
         no decision-11 tab overflow: those rows have no Iced counterpart and are not fabricated \
         here; they stay with the Flutter/renderer packages."
            .to_owned(),
        "The native file/folder pickers (IM-02, ST-02's change-location flow) cannot run \
         in-process; captures start from the discovered/reviewed state that follows a pick, and \
         the move dialog uses the real storage summary with a fixed destination path."
            .to_owned(),
        "Covers are decoded by the real batch decode path during seeding, and the per-card \
         `sensor().on_show` cover request is exercised too: the capture delivers the frame's \
         redraw event, dispatches what the view asks for and draws the settled frame. Books \
         with no cover blob keep the placeholder card."
            .to_owned(),
        "The capture renders in-process from the disposable data root, so application text that \
         names a real path (discovery-failure rows, the managed-library path) shows \
         `/tmp/shosai-reference-shots-1b/…`. That root is fixed by default and \
         `SHOSAI_REFERENCE_SHOTS_DATA_DIR` moves it; a run with a different data root renders \
         different bytes, which verification reports instead of hiding."
            .to_owned(),
        "Import progress counters are captured at their deterministic point: the in-flight \
         capture shows the header action with `0/N` while the copy tasks are undelivered. \
         Mid-import numbers are not captured because the parallel prepare/copy tasks complete \
         in a scheduling-dependent order, so a partial progress reading is not reproducible."
            .to_owned(),
        "The import discovery 'reading' phase is a race between the hashing worker and the \
         polling tick and is not deterministically capturable in-process; the enumerating and \
         checking phases are captured with real counts."
            .to_owned(),
        "Rendering is in-process software rasterization, not a compositor screenshot: window \
         decorations, native menus, toasts and animations are outside the capture."
            .to_owned(),
    ];
    if !broken_symlinks_available {
        limitations.push(
            "The dangling-symlink discovery-failure fixture could not be created on this \
             platform, so the discovery-failure capture would be empty."
                .to_owned(),
        );
    }
    limitations
}
