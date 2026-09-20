//! The `make reference-shots` entry point.
//!
//! One run: validates and clears its disposable data root, writes the
//! deterministic fixture tree, seeds the disposable libraries, reaches every
//! [`super::scenarios`] state through the production messages, renders each one
//! offscreen with the production view, and writes the PNGs, their checksums and
//! the provenance manifest.
//!
//! Nothing outside the output directory and the disposable data root is
//! touched: the application's real data directory is never opened, because the
//! task `boot` returns is dropped without being polled, and the root is cleared
//! only while this run holds its marker and its exclusive lock (see
//! [`DisposableRoot`]).

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use iced::Size;

use super::super::Message;
use super::harness::Harness;
use super::scenarios::{self, Base};
use super::{evidence, fixtures, manifest, render, seed};

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

/// Marker file that marks a directory as this tool's disposable data root.
pub(crate) const ROOT_MARKER_FILE: &str = ".shosai-reference-shots-root";
/// Contents of the ownership marker.
pub(crate) const ROOT_MARKER_CONTENT: &str = "shosai reference-shots disposable root v1\n";
/// Lock file that makes one run the exclusive user of the data root.
pub(crate) const ROOT_LOCK_FILE: &str = ".shosai-reference-shots-lock";

/// Exclusive ownership of the disposable data root.
///
/// The root is deleted at the start of every run, so a run may only clear a
/// directory this tool created: an existing directory without
/// [`ROOT_MARKER_FILE`] fails closed instead of being deleted, and a run whose
/// root already carries [`ROOT_LOCK_FILE`] refuses to start because another run
/// (or a crashed one) owns it. The evidence directory and the paths the root
/// would contain (the home directory, the real application data directory, the
/// repository) are rejected outright, so a misconfigured
/// `SHOSAI_REFERENCE_SHOTS_DATA_DIR` cannot delete a real library or checkout.
#[derive(Debug)]
pub(crate) struct DisposableRoot {
    root: PathBuf,
    lock: PathBuf,
    released: bool,
}

impl DisposableRoot {
    /// Validate the configuration, take the lock, and clear the owned root.
    pub(crate) fn prepare(root: &Path, output: &Path) -> Result<Self> {
        validate_root_configuration(root, output)?;
        if root.exists() {
            let metadata = std::fs::symlink_metadata(root)
                .with_context(|| format!("inspect {}", root.display()))?;
            if metadata.file_type().is_symlink() {
                anyhow::bail!(
                    "refusing to use {} as the disposable data root: it is a symlink",
                    root.display()
                );
            }
            if !metadata.is_dir() {
                anyhow::bail!(
                    "refusing to use {} as the disposable data root: it is not a directory",
                    root.display()
                );
            }
            let marked = std::fs::read(root.join(ROOT_MARKER_FILE))
                .is_ok_and(|content| content == ROOT_MARKER_CONTENT.as_bytes());
            let mut entries =
                std::fs::read_dir(root).with_context(|| format!("read {}", root.display()))?;
            let empty = entries.next().is_none();
            if !marked && !empty {
                anyhow::bail!(
                    "refusing to clear {}: it is not a reference-shots disposable root (no {} \
                     marker). Remove it by hand or point SHOSAI_REFERENCE_SHOTS_DATA_DIR \
                     somewhere else.",
                    root.display(),
                    ROOT_MARKER_FILE
                );
            }
        }
        std::fs::create_dir_all(root)
            .with_context(|| format!("create the disposable data root {}", root.display()))?;
        let lock = root.join(ROOT_LOCK_FILE);
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock)
            .map_err(|error| {
                anyhow::anyhow!(
                    "refusing to start a second reference-shots run on {}: {} ({error}). Remove \
                     {} if no run is active.",
                    root.display(),
                    ROOT_LOCK_FILE,
                    lock.display()
                )
            })?;
        let guard = Self {
            root: root.to_path_buf(),
            lock,
            released: false,
        };
        guard.clear()?;
        std::fs::write(root.join(ROOT_MARKER_FILE), ROOT_MARKER_CONTENT)
            .with_context(|| format!("write {} marker", ROOT_MARKER_FILE))?;
        Ok(guard)
    }

    /// Remove the lock, and the root unless `keep` was requested.
    pub(crate) fn finish(mut self, keep: bool) -> Result<()> {
        self.released = true;
        std::fs::remove_file(&self.lock)
            .with_context(|| format!("remove {}", self.lock.display()))?;
        if !keep {
            std::fs::remove_dir_all(&self.root)
                .with_context(|| format!("remove {}", self.root.display()))?;
        }
        Ok(())
    }

    /// Delete every entry of the owned root except the lock this run holds.
    fn clear(&self) -> Result<()> {
        for entry in std::fs::read_dir(&self.root)
            .with_context(|| format!("read {}", self.root.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            if path == self.lock {
                continue;
            }
            let file_type = entry.file_type()?;
            if file_type.is_dir() && !file_type.is_symlink() {
                std::fs::remove_dir_all(&path)
                    .with_context(|| format!("clear {}", path.display()))?;
            } else {
                std::fs::remove_file(&path).with_context(|| format!("clear {}", path.display()))?;
            }
        }
        Ok(())
    }
}

impl Drop for DisposableRoot {
    fn drop(&mut self) {
        if !self.released {
            let _ = std::fs::remove_file(&self.lock);
        }
    }
}

/// Reject a disposable root that could delete something the capture tool does
/// not own.
pub(crate) fn validate_root_configuration(root: &Path, output: &Path) -> Result<()> {
    if !root.is_absolute() {
        anyhow::bail!(
            "the disposable data root must be an absolute path, not {}",
            root.display()
        );
    }
    if root.starts_with(output) || output.starts_with(root) {
        anyhow::bail!(
            "refusing to use {} as the disposable data root: it overlaps the evidence directory {}",
            root.display(),
            output.display()
        );
    }
    for protected in protected_paths() {
        if root == protected || protected.starts_with(root) {
            anyhow::bail!(
                "refusing to use {} as the disposable data root: it is, or contains, {}",
                root.display(),
                protected.display()
            );
        }
    }
    Ok(())
}

/// Paths the disposable root may never be, or contain, because it is deleted.
fn protected_paths() -> Vec<PathBuf> {
    let mut protected = vec![PathBuf::from("/"), repository_root(), output_root()];
    if let Some(home) = std::env::var_os("HOME") {
        protected.push(PathBuf::from(home));
    }
    if let Ok(paths) = shosai_core::reading_state::ApplicationDataPaths::desktop_default() {
        protected.push(paths.data_directory);
    }
    protected
}

/// Pin the system locale the no-store captures resolve.
///
/// A capture with no readable store boots with `LanguagePreference::System`,
/// and `I18n::new(System)` resolves that preference *immediately* from the
/// process locale, so without this the two no-store captures would render
/// whatever language the host machine uses while recording `EN`. `sys-locale`
/// reads `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG` in that order, so
/// pinning `LANGUAGE` pins the resolved language on every platform.
///
/// The capture entry point calls this before it creates its runtime, in the
/// dedicated single-test process `make reference-shots` starts;
/// [`assert_system_locale_pinned`] makes a run that skipped it fail instead of
/// writing host-dependent evidence.
pub(crate) fn pin_system_locale() {
    // SAFETY: the capture entry point is a dedicated process, and this runs
    // before it creates a runtime or any other thread that could read the
    // environment. The environment is only mutated so the application's locale
    // lookup is deterministic.
    unsafe {
        std::env::set_var("LANGUAGE", "en-US");
    }
}

/// Whether the process locale is pinned to English.
fn assert_system_locale_pinned() -> Result<()> {
    if std::env::var("LANGUAGE").as_deref() != Ok("en-US") {
        anyhow::bail!(
            "the capture process locale is not pinned to English; \
             `runner::pin_system_locale` must run before the first state exists, because the \
             no-store captures resolve `LanguagePreference::System` immediately"
        );
    }
    Ok(())
}

/// The capture run. Marked `#[ignore]` so an ordinary `cargo test` never
/// renders or writes evidence.
#[test]
#[ignore = "capture tool: run it through `make reference-shots`"]
fn reference_shots_capture() {
    // Before the runtime exists: the no-store captures resolve the system
    // locale while the very first state is built.
    pin_system_locale();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("capture runtime");
    runtime.block_on(async {
        run().await.expect("reference capture run");
    });
}

async fn run() -> Result<()> {
    assert_system_locale_pinned()?;
    let verify = std::env::var("SHOSAI_REFERENCE_SHOTS_VERIFY")
        .is_ok_and(|value| !value.is_empty() && value != "0");
    let output = output_root();
    // Captures always read the fixture tree from the disposable data root, and
    // verify mode writes nothing outside it: the fresh captures are compared
    // with the committed evidence instead, and a capture run then mirrors the
    // tree it rendered from into the evidence directory.
    let fixtures_root = fixtures_root();
    let data = data_root();
    let keep_data = std::env::var_os("SHOSAI_REFERENCE_SHOTS_KEEP_DATA").is_some();
    let root = DisposableRoot::prepare(&data, &output)?;

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
        apply_window(scenario, &mut harness);
        scenarios::apply(scenario, &mut harness, &fixtures_root, &data).await;
        scenarios::assert_reached(scenario, &harness.state);
        assert_window(scenario, &harness.state);

        let (width, height) = scenario.client;
        let image = harness.render_image(width, height, scenario.dpr).await;
        assert_window(scenario, &harness.state);
        // Fence this capture's persisted writes before the next capture resets
        // the shared store: dropping a writer only signals shutdown, so a
        // queued preference write could otherwise land after the next baseline
        // reset and leak into the next capture's state.
        fence_capture_writes(&mut harness).await?;
        let image_name = format!("captures/{}.png", scenario.id);
        if !verify {
            let path = output.join(&image_name);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&path, &image.png)
                .with_context(|| format!("write {}", path.display()))?;
        }

        let mut capture = scenario.expected_capture();
        capture.sha256 = fixtures::sha256_hex(&image.png);
        capture.bytes = image.png.len() as u64;
        // The manifest must describe the raster that was produced, not a
        // separately computed size.
        assert_eq!(
            (capture.image_width, capture.image_height),
            (image.physical_width, image.physical_height),
            "{}: the manifest image size does not match the rendered raster",
            scenario.id
        );
        captures.push(capture);
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
    let manifest = build_manifest(
        &fixture_records,
        broken_symlinks_available,
        &seeded,
        captures,
        matrix,
    )?;
    if verify {
        evidence::validate(&output, &manifest, true)
            .context("verify the committed evidence against a fresh render")?;
        println!(
            "reference-shots: {} captures re-rendered byte-identically to the committed evidence",
            manifest.captures.len()
        );
    } else {
        prune_stale_evidence(&output, &manifest.captures)?;
        let mirrored = fixtures::mirror_reference_fixtures(
            &fixtures_root,
            &evidence_fixtures_root(),
            &fixture_records,
        )
        .context("mirror the generated fixture tree into the evidence directory")?;
        if mirrored != fixture_records {
            anyhow::bail!("the committed fixture copy does not match the generated fixture tree");
        }
        manifest::write_all(&output, &manifest)?;
        // Self-check: the tree this run just wrote must validate, so a capture
        // run cannot produce evidence that `VERIFY=1` would reject.
        evidence::validate(&output, &manifest, true)
            .context("validate the evidence this run wrote")?;
        println!(
            "reference-shots: manifest, checksums and README written and validated in {}",
            output.display()
        );
    }

    root.finish(keep_data)?;
    Ok(())
}

/// Assemble the provenance manifest for a capture set.
///
/// `captures` holds rendered entries during a capture run and unrendered
/// expectations ([`scenarios::Scenario::expected_capture`]) in the tests; the
/// difference is exactly the `sha256`/`bytes` pair, which the caller flags to
/// [`evidence::validate`].
pub(crate) fn build_manifest(
    fixture_records: &[fixtures::FixtureRecord],
    broken_symlinks_available: bool,
    seeded: &seed::SeededLibrary,
    captures: Vec<manifest::CaptureEntry>,
    matrix: manifest::MatrixCoverage,
) -> Result<manifest::Manifest> {
    let revision = capture_revision();
    Ok(manifest::Manifest {
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
        output_directory: output_root().display().to_string(),
        preferences: manifest::preference_baseline(),
        environment: manifest::environment(),
        fonts: render::font_identities()
            .into_iter()
            .map(|(role, sha256)| manifest::FontRecord {
                role: role.to_owned(),
                sha256,
            })
            .collect(),
        fixtures: manifest::fixture_inventory(fixture_records, broken_symlinks_available)?,
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
        matrix,
        limitations: limitations(broken_symlinks_available),
    })
}

/// Put the capture's client size and DPR into the model the way a real window
/// does: through `Message::WindowEvent(..)`, never by writing the fields.
///
/// The production handlers also invalidate layout and bump the scale
/// generation, so assigning `window_size`/`window_scale_factor` directly would
/// skip part of what the state carries. The tasks the handlers return are the
/// window's own background effects (a debounced geometry persist, a reader
/// layout notification); the capture leaves them pending exactly like the
/// in-flight captures leave their task unsettled.
pub(crate) fn apply_window(scenario: &scenarios::Scenario, harness: &mut Harness) {
    let (width, height) = scenario.client;
    let id = iced::window::Id::unique();
    let _pending = harness.start(Message::WindowEvent(
        id,
        iced::window::Event::Resized(Size::new(width, height)),
    ));
    let _pending = harness.start(Message::WindowEvent(
        id,
        iced::window::Event::Rescaled(scenario.dpr),
    ));
    assert_window(scenario, &harness.state);
}

/// The state must carry the capture's client size and DPR, before and after the
/// scenario: the committed image size and DPR are claims about this state.
fn assert_window(scenario: &scenarios::Scenario, state: &super::super::State) {
    let (width, height) = scenario.client;
    assert_eq!(
        state.window_size,
        Size::new(width, height),
        "{}: the window size is not the capture's client size",
        scenario.id
    );
    assert_eq!(
        state.window_scale_factor, scenario.dpr,
        "{}: the window scale factor is not the capture's DPR",
        scenario.id
    );
}

/// Fence the capture's persisted writes.
///
/// The application writes preferences through a separate state writer, and
/// dropping the writer only *signals* shutdown: its worker can still execute a
/// queued write after the next capture has reset the shared store, which would
/// let one capture's language or settings leak into the next one.
/// `quiesce_and_shutdown` is the fence that waits for the queue to drain, so the
/// next baseline reset is ordered after everything this capture persisted.
pub(crate) async fn fence_capture_writes(harness: &mut Harness) -> Result<()> {
    let Some(saves) = harness.state.reading_state_saves.clone() else {
        return Ok(());
    };
    saves
        .quiesce_and_shutdown()
        .await
        .context("flush the capture's queued preference writes")?;
    Ok(())
}

/// The manifest the current code produces without rendering.
///
/// The non-rendering evidence test builds this from a fresh disposable seed and
/// compares it with the committed `manifest.json`. The per-capture `sha256` and
/// `bytes` fields are empty because nothing was rendered, so the comparison
/// passes `fresh_pixels = false` and checks those two fields against the
/// committed files instead.
pub(crate) async fn expected_manifest(
    fixtures_root: &Path,
    seeded: &seed::SeededLibrary,
) -> Result<manifest::Manifest> {
    let records = fixtures::write_reference_fixtures(fixtures_root)?;
    let captures = scenarios::scenarios()
        .iter()
        .map(|scenario| scenario.expected_capture())
        .collect();
    build_manifest(
        &records,
        fixtures::broken_symlinks_available(fixtures_root),
        seeded,
        captures,
        matrix(),
    )
}

/// A boot state with the initialize task dropped: the real user data directory
/// is never opened, and every field starts where the application starts it.
pub(crate) fn fresh_state() -> super::super::State {
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

/// The state a capture set starts from.
///
/// With a seeded library this is the real startup payload: the disposable
/// store's preferences are parsed by the harness copy of `boot`'s initialize
/// task ([`seed::capture_initialized_state`], pinned by tests against the
/// application defaults and against persisted non-default values), and the
/// result is delivered through `Message::Initialized(Ok(..))`, which loads the
/// first library page and decodes its covers. Without a store it is a bare boot
/// state, which is what a machine with no readable data directory has when
/// initialization fails.
async fn base_harness(seeded: Option<&seed::SeededLibrary>) -> Result<Harness> {
    let Some(seeded) = seeded else {
        return Ok(Harness::new(fresh_state()));
    };
    // Captures share one disposable store per base, so preferences an earlier
    // capture persisted (`SelectLanguage`, the settings controls) would
    // otherwise leak into the next one and make the set order-dependent. Every
    // capture therefore starts from the documented preference baseline.
    seed::reset_capture_preferences(&seeded.store).await?;
    let initialized = seed::capture_initialized_state(seeded.store.clone())
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

pub(crate) fn matrix() -> manifest::MatrixCoverage {
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
