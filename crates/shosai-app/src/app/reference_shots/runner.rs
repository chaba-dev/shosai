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
     durable mapping is the stable `capture_code_change_id` (resolve it with `jj log -r \
     'change(<id>)'`) together with the commit that contains this evidence directory, which is \
     the capture code revision the evidence is committed at; `make reference-shots VERIFY=1` \
     re-renders this evidence byte-identically at any revision that carries the change.";

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
///
/// The override is resolved once ([`resolve_path`]), like the data root inside
/// [`DisposableRoot::prepare`]. The run keeps that resolved value: the overlap
/// check, the capture writes, the fixture mirror, the manifest writer and the
/// verifier all use it, so no step can re-read the configuration and reach a
/// different directory after preparation cleared the data root.
///
/// Resolution fails instead of falling back to the configured spelling: a
/// spelling the file system cannot traverse (a symlink loop, a dangling link, a
/// file used as a directory, a drive-relative path) must not be silently
/// replaced by a location that happens to be reachable through `..`.
pub(crate) fn output_root() -> Result<PathBuf> {
    let configured = std::env::var_os("SHOSAI_REFERENCE_SHOTS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| repository_root().join(DEFAULT_OUTPUT));
    resolve_path(&configured)
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
///
/// It is always `fixtures/` inside the *resolved* evidence directory the run
/// holds: the run never re-reads the configuration for it, so the tree it
/// mirrors is the tree the verifier and the manifest describe.
pub(crate) fn evidence_fixtures_path(output: &Path) -> PathBuf {
    output.join("fixtures")
}

/// Marker file that marks a directory as this tool's disposable data root.
pub(crate) const ROOT_MARKER_FILE: &str = ".shosai-reference-shots-root";
/// Marker file contents: the marker version and the root the marker belongs to.
///
/// The root is part of the content so that a directory can be recognised as
/// *this* root's, not merely as some other run's disposable directory.
pub(crate) fn marker_content(root: &Path) -> String {
    format!(
        "shosai reference-shots disposable root v2\nroot={}\n",
        root.display()
    )
}
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
    ///
    /// The *input* policy is enforced before the path is resolved: a relative
    /// root is refused instead of being turned into an absolute path against the
    /// process directory, and a root that names a symlink as its final component
    /// is refused instead of being silently dereferenced to whatever directory
    /// the link names (an empty unrelated directory would otherwise be adopted,
    /// locked and deleted). The final component is inspected without trailing
    /// separators or `.`, so `link/` and `link/.` cannot smuggle the link past
    /// the check. Everything after that acts on the resolved path — or fails,
    /// because [`resolve_path`] refuses a spelling the file system cannot
    /// traverse — so validation and every filesystem operation below use the
    /// same location.
    pub(crate) fn prepare(root: &Path, output: &Path) -> Result<Self> {
        let spelling = final_spelling(root);
        if !spelling.is_absolute() {
            anyhow::bail!(
                "the disposable data root must be an absolute path, not {}",
                root.display()
            );
        }
        if std::fs::symlink_metadata(&spelling)
            .is_ok_and(|metadata| metadata.file_type().is_symlink())
        {
            anyhow::bail!(
                "refusing to use {} as the disposable data root: it is a symlink",
                root.display()
            );
        }
        let root = resolve_path(root)?;
        validate_root_configuration(&root, output)?;
        if root.exists() {
            let metadata = std::fs::symlink_metadata(&root)
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
            let marker = marker_content(&root);
            let marked = std::fs::read(root.join(ROOT_MARKER_FILE))
                .is_ok_and(|content| content == marker.as_bytes());
            let mut entries =
                std::fs::read_dir(&root).with_context(|| format!("read {}", root.display()))?;
            let empty = entries.next().is_none();
            if !marked && !empty {
                anyhow::bail!(
                    "refusing to clear {}: it is not a reference-shots disposable root (no {} \
                     marker naming this root). Remove it by hand or point \
                     SHOSAI_REFERENCE_SHOTS_DATA_DIR somewhere else.",
                    root.display(),
                    ROOT_MARKER_FILE
                );
            }
        }
        std::fs::create_dir_all(&root)
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
            root: root.clone(),
            lock,
            released: false,
        };
        guard.clear()?;
        std::fs::write(root.join(ROOT_MARKER_FILE), marker_content(&root))
            .with_context(|| format!("write {} marker", ROOT_MARKER_FILE))?;
        Ok(guard)
    }

    /// The resolved root every filesystem operation must use.
    pub(crate) fn path(&self) -> &Path {
        &self.root
    }

    /// Remove the lock, and the root unless `keep` was requested.
    ///
    /// The lock is not released before the deletion: the root is first renamed
    /// aside (still locked) and the renamed directory is deleted afterwards, so a
    /// run that acquires the root name in between gets a fresh root instead of
    /// having its state deleted by this one.
    pub(crate) fn finish(mut self, keep: bool) -> Result<()> {
        if keep {
            std::fs::remove_file(&self.lock)
                .with_context(|| format!("remove {}", self.lock.display()))?;
            self.released = true;
            return Ok(());
        }
        let discard = discard_path(&self.root);
        clear_discard(&self.root, &discard)?;
        std::fs::rename(&self.root, &discard).with_context(|| {
            format!(
                "rename the disposable root {} to {}",
                self.root.display(),
                discard.display()
            )
        })?;
        // The root name is free and the lock travelled with the renamed
        // directory, so from here this run owns nothing a second run could
        // reach; the deletion below is the last thing it does.
        self.released = true;
        std::fs::remove_dir_all(&discard)
            .with_context(|| format!("remove {}", discard.display()))?;
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
            return;
        }
        // A released run may have been interrupted between renaming the root
        // aside and deleting it: finish that deletion, but only for a directory
        // that still carries this root's marker.
        let discard = discard_path(&self.root);
        if discard_is_ours(&self.root, &discard) {
            let _ = std::fs::remove_dir_all(&discard);
        }
    }
}

/// A sibling path used to delete an owned root without racing a run that is
/// acquiring the root name at the same time.
///
/// The name is derived from the root and the process id, so two runs deleting
/// different roots cannot collide, and it lives in the same parent directory so
/// the rename stays on one filesystem.
pub(crate) fn discard_path(root: &Path) -> PathBuf {
    let name = root
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "reference-shots-root".to_owned());
    root.with_file_name(format!(".{name}-discard-{}", std::process::id()))
}

/// Whether a directory is this root's discard directory.
///
/// The name alone is not enough: the name is derived from the root and the
/// process id, and a recycled process id must never let this tool delete
/// something it did not create. The marker has to name this root.
fn discard_is_ours(root: &Path, discard: &Path) -> bool {
    let expected = marker_content(root);
    std::fs::read(discard.join(ROOT_MARKER_FILE))
        .is_ok_and(|content| content == expected.as_bytes())
}

/// Delete a discard directory left behind by an earlier run of this process id.
///
/// Only a directory whose marker still names this root is removed.
fn clear_discard(root: &Path, discard: &Path) -> Result<()> {
    if !discard.exists() {
        return Ok(());
    }
    anyhow::ensure!(
        discard_is_ours(root, discard),
        "refusing to reuse {}: it is not this run's discard directory (no {} marker naming {})",
        discard.display(),
        ROOT_MARKER_FILE,
        root.display()
    );
    std::fs::remove_dir_all(discard).with_context(|| format!("remove {}", discard.display()))
}

/// Reject a disposable root that could delete something the capture tool does
/// not own. A spelling the file system cannot traverse is refused here, before
/// anything is created or cleared.
pub(crate) fn validate_root_configuration(root: &Path, output: &Path) -> Result<()> {
    let spelling = final_spelling(root);
    if !spelling.is_absolute() {
        anyhow::bail!(
            "the disposable data root must be an absolute path, not {}",
            root.display()
        );
    }
    let root = resolve_path(root)?;
    let output = resolve_path(output)?;
    if root.starts_with(&output) || output.starts_with(&root) {
        anyhow::bail!(
            "refusing to use {} as the disposable data root: it overlaps the evidence directory {}",
            root.display(),
            output.display()
        );
    }
    for protected in protected_paths()? {
        if root == protected || protected.starts_with(&root) {
            anyhow::bail!(
                "refusing to use {} as the disposable data root: it is, or contains, {}",
                root.display(),
                protected.display()
            );
        }
    }
    Ok(())
}

/// A path with symlinks, `.` and `..` resolved, so two spellings of the same
/// location compare equal and every operation acts on one location.
///
/// The walk is *physical*, component by component: an existing component is
/// canonicalized, so symlinks are followed, and a `..` then applies to the
/// resolved prefix. A lexical pass would be wrong in both directions: it would
/// read `…/link/..` as the link's own parent instead of the target's, and
/// `…/root/../tmp/x` (where `root` is a symlink to `/`) as `…/root/tmp/x`
/// instead of `/tmp/x`. A spelling whose lexical form differs from its physical
/// form could then pass the overlap check as one location and be written,
/// mirrored or deleted as another.
///
/// A component that is *genuinely absent* is appended literally and a later
/// `..` removes it again — the location `std::fs::create_dir_all` would create
/// for that spelling. Every other way traversal can fail is an error here,
/// before either directory is created, locked or cleared: a symlink loop, a
/// dangling link, a component that exists but cannot be a directory, a
/// permission error and a drive-relative spelling all fail the run instead of
/// being treated as an absent component that a following `..` erases — which
/// would make the run act on a location the configured spelling cannot reach.
///
/// Relative paths are made absolute against the current directory first: the
/// data root may not be relative, but the evidence directory it is compared
/// with may be.
pub(crate) fn resolve_path(path: &Path) -> Result<PathBuf> {
    use std::path::Component;

    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        let directory = std::env::current_dir().with_context(|| {
            format!(
                "resolve the relative path {} against the current directory",
                path.display()
            )
        })?;
        directory.join(path)
    };
    let mut resolved = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(prefix) => resolved.push(prefix.as_os_str()),
            Component::RootDir => {
                resolved.push(Component::RootDir.as_os_str());
                // Canonicalize the root itself too, so `C:\` and the verbatim
                // `\\?\C:\` a later `canonicalize` produces cannot compare as two
                // different locations.
                if let Ok(target) = std::fs::canonicalize(&resolved) {
                    resolved = target;
                }
            }
            Component::CurDir => {}
            Component::ParentDir => {
                // `..` applies to the resolved prefix, so a symlink is followed
                // before it is applied and `/` stays `/`. Applying it to an
                // existing non-directory is a traversal error, not a location.
                match std::fs::symlink_metadata(&resolved) {
                    Ok(metadata) if !metadata.is_dir() => anyhow::bail!(
                        "cannot resolve {}: {} is not a directory, so `..` cannot be applied",
                        path.display(),
                        resolved.display()
                    ),
                    _ => {}
                }
                resolved.pop();
            }
            Component::Normal(name) => {
                let candidate = resolved.join(name);
                resolved = resolve_component(&candidate, path)?;
            }
        }
    }
    anyhow::ensure!(
        resolved.is_absolute(),
        "cannot resolve {}: the result {} is not an absolute path",
        path.display(),
        resolved.display()
    );
    Ok(resolved)
}

/// Resolve one component of a walk, telling "does not exist yet" apart from
/// every other way traversal can fail.
///
/// A name that exists but resolves to nothing — a dangling link, or a link
/// whose target path is itself incomplete — is *not* an absent component: the
/// run must not treat it as one it will create later and then let a `..` erase
/// it. The same goes for every error that is not `NotFound`.
fn resolve_component(candidate: &Path, context: &Path) -> Result<PathBuf> {
    match std::fs::canonicalize(candidate) {
        Ok(target) => Ok(target),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match std::fs::symlink_metadata(candidate) {
                Ok(_) => anyhow::bail!(
                    "cannot resolve {}: {} exists but resolves to nothing ({error})",
                    context.display(),
                    candidate.display()
                ),
                Err(metadata_error) if metadata_error.kind() == std::io::ErrorKind::NotFound => {
                    // Genuinely absent: the run may create this component, and a
                    // later `..` removes it again.
                    Ok(candidate.to_path_buf())
                }
                Err(metadata_error) => anyhow::bail!(
                    "cannot resolve {}: inspect {}: {metadata_error}",
                    context.display(),
                    candidate.display()
                ),
            }
        }
        Err(error) => anyhow::bail!(
            "cannot resolve {}: {} cannot be traversed: {error}",
            context.display(),
            candidate.display()
        ),
    }
}

/// A spelling without trailing separators or `.` components, for input policy
/// checks.
///
/// `symlink_metadata("link/")` and `symlink_metadata("link/.")` report the
/// *target* of the link, while the same path without the trailing part reports
/// the link itself: a policy check that used the raw spelling would let those
/// two forms smuggle a symlinked root past the check. Only trailing `.`
/// components are removed, never `..`, because `..` must stay for the physical
/// resolution.
pub(crate) fn final_spelling(path: &Path) -> PathBuf {
    use std::path::Component;

    let mut components: Vec<Component> = path.components().collect();
    while matches!(components.last(), Some(Component::CurDir)) {
        components.pop();
    }
    components.into_iter().collect()
}

/// Paths the disposable root may never be, or contain, because it is deleted.
fn protected_paths() -> Result<Vec<PathBuf>> {
    let mut protected = vec![PathBuf::from("/"), repository_root(), output_root()?];
    if let Some(home) = std::env::var_os("HOME") {
        protected.push(PathBuf::from(home));
    }
    if let Ok(paths) = shosai_core::reading_state::ApplicationDataPaths::desktop_default() {
        protected.push(paths.data_directory);
    }
    protected
        .into_iter()
        .map(|path| resolve_path(&path))
        .collect()
}

/// The system-language value the capture entry point must export.
///
/// A capture with no readable store boots with `LanguagePreference::System`,
/// and `I18n::new(System)` resolves that preference *immediately* from the
/// process locale, so without a pin the two no-store captures would render
/// whatever language the host machine uses while recording `EN`. `sys-locale`
/// reads `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG` in that order on the
/// platforms whose lookup honours them (Linux and the BSDs).
pub(crate) const CAPTURE_LANGUAGE: &str = "en-US";

/// Why the capture entry point has to control font discovery.
pub(crate) const FONT_DISCOVERY_NOTE: &str = "The capture entry point exports `FONTCONFIG_FILE` pointing at a fontconfig configuration \
     whose only font directory is empty, so the renderer's font database holds exactly the \
     application fonts and Iced's built-ins, all loaded from memory. Host fonts would make the \
     images depend on the machine's installed fonts.";

/// Problems with the environment the capture was started in.
///
/// Pure, so the regression test can exercise it without touching the process
/// environment: the capture never mutates the environment itself (that is not
/// safe in a process other tests share), it requires the documented entry point
/// to have done it.
pub(crate) fn capture_environment_problems(
    language: Option<&str>,
    fontconfig_file: Option<&str>,
    os: &str,
) -> Vec<String> {
    let mut problems = Vec::new();
    if os != "linux" {
        problems.push(format!(
            "the reference captures run on Linux: on {os} the system language does not follow \
             `LANGUAGE`, so the `System`-preference captures cannot be pinned"
        ));
    }
    match language {
        Some(value) if value == CAPTURE_LANGUAGE => {}
        Some(value) => problems.push(format!(
            "the capture process language is {value:?}, not {CAPTURE_LANGUAGE:?}"
        )),
        None => problems.push(format!(
            "the capture process language is unset; export `LANGUAGE={CAPTURE_LANGUAGE}`"
        )),
    }
    match fontconfig_file {
        Some(value) if !value.trim().is_empty() => {}
        _ => problems.push(
            "`FONTCONFIG_FILE` is unset or empty, so host fonts would be eligible".to_owned(),
        ),
    }
    problems
}

/// Problems with the fontconfig configuration the entry point points at.
///
/// The loader falls back to scanning the standard system font directories when
/// the configuration names no directory at all, so the entry point's
/// configuration has to declare one; combined with
/// [`super::render::assert_controlled_font_database`], which checks the database
/// the renderer actually shapes with, this keeps host fonts out.
pub(crate) fn fontconfig_problems(content: Option<&str>) -> Vec<String> {
    match content {
        None => vec![
            "the fontconfig configuration named by `FONTCONFIG_FILE` cannot be read".to_owned(),
        ],
        Some(text) if !text.contains("<dir>") => vec![
            "the fontconfig configuration names no font directory, so the font loader would fall \
             back to scanning the system font directories"
                .to_owned(),
        ],
        Some(_) => Vec::new(),
    }
}

/// Fail before rendering anything when the capture environment is not the
/// documented one.
///
/// Run through `make reference-shots` (or with the variables below exported),
/// the environment is the one the manifest records; run any other way, the run
/// stops instead of writing evidence that depends on the machine.
pub(crate) fn assert_capture_environment() -> Result<()> {
    let language = std::env::var("LANGUAGE").ok();
    let fontconfig_file = std::env::var("FONTCONFIG_FILE").ok();
    let mut problems = capture_environment_problems(
        language.as_deref(),
        fontconfig_file.as_deref(),
        std::env::consts::OS,
    );
    let config = fontconfig_file
        .as_deref()
        .and_then(|path| std::fs::read_to_string(path).ok());
    problems.extend(fontconfig_problems(config.as_deref()));
    if !problems.is_empty() {
        anyhow::bail!(
            "the capture environment is not pinned ({}). Run the documented entry point \
             `make reference-shots`, or export the variables it documents \
             (docs/reference-captures.md).",
            problems.join("; ")
        );
    }
    Ok(())
}

/// The manifest record of the pinned environment.
pub(crate) fn environment_pins() -> (String, String) {
    (
        format!(
            "{CAPTURE_LANGUAGE} via `LANGUAGE` (the `System`-preference captures resolve English)"
        ),
        "font discovery pinned: the renderer's font database holds only in-memory application and \
         Iced faces"
            .to_owned(),
    )
}

/// Best-effort identity of the native PDFium library that rasterizes PDF covers.
///
/// Iced never touches PDFium, but the library's own font substitution scans the
/// host font directories and ignores `FONTCONFIG_FILE`, so the fixture PDFs carry
/// no text (see `fixtures::pdf_font_free_problems`). The library itself still
/// decides how the artwork is rasterized, so the run records which one was
/// loaded, with its SHA-256. This is run metadata, like the rustc and cargo
/// versions; it describes the machine that produced the evidence.
pub(crate) fn pdfium_identity() -> Option<String> {
    pdfium_identity_from(&PdfiumSearch::from_environment())
}

/// The inputs of the PDFium search, so discovery can be exercised with known
/// files instead of whatever the host happens to have installed.
pub(crate) struct PdfiumSearch {
    /// A shared object this process already mapped.
    pub(crate) mapped: Option<PathBuf>,
    /// `SHOSAI_PDFIUM_LIBRARY`.
    pub(crate) configured: Option<PathBuf>,
    /// Directories to scan: the executable's own directory and the
    /// `LD_LIBRARY_PATH` entries the process was started with.
    pub(crate) directories: Vec<PathBuf>,
}

impl PdfiumSearch {
    /// The search inputs of this process.
    fn from_environment() -> Self {
        let mut directories: Vec<PathBuf> = Vec::new();
        if let Ok(executable) = std::env::current_exe()
            && let Some(directory) = executable.parent()
        {
            directories.push(directory.to_path_buf());
        }
        if let Some(search) = std::env::var_os("LD_LIBRARY_PATH") {
            directories.extend(std::env::split_paths(&search));
        }
        Self {
            mapped: mapped_pdfium_library(),
            configured: std::env::var_os("SHOSAI_PDFIUM_LIBRARY").map(PathBuf::from),
            directories,
        }
    }

    /// Where the native PDFium library is expected to live, in precedence
    /// order: the mapped object, then `SHOSAI_PDFIUM_LIBRARY`, then the
    /// scanned directories (a plain library name first, then any
    /// `libpdfium.*` object, which is how a Nix build can install a
    /// versioned one).
    ///
    /// The search is best-effort: a build that loads PDFium from a path this
    /// cannot see records `unknown` instead of guessing.
    fn library(&self) -> Option<PathBuf> {
        if let Some(mapped) = &self.mapped {
            return Some(mapped.clone());
        }
        if let Some(configured) = &self.configured
            && configured.is_file()
        {
            return Some(configured.clone());
        }
        for directory in &self.directories {
            for name in ["libpdfium.so", "libpdfium.so.1", "pdfium.dll"] {
                let candidate = directory.join(name);
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
            let Ok(entries) = std::fs::read_dir(directory) else {
                continue;
            };
            let mut candidates: Vec<PathBuf> = entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.starts_with("libpdfium."))
                })
                .collect();
            candidates.sort();
            if let Some(candidate) = candidates.into_iter().next() {
                return Some(candidate);
            }
        }
        None
    }
}

/// The identity of the library a search finds, with the SHA-256 of its bytes.
///
/// A found library whose bytes cannot be read is reported as `unreadable`
/// rather than dropped: the run must name the library it rasterized with, even
/// when it cannot hash it.
pub(crate) fn pdfium_identity_from(search: &PdfiumSearch) -> Option<String> {
    let path = search.library()?;
    let hash = std::fs::read(&path)
        .ok()
        .map(|bytes| super::fixtures::sha256_hex(&bytes));
    Some(match hash {
        Some(hash) => format!("{} (sha256 {hash})", path.display()),
        None => format!("{} (unreadable)", path.display()),
    })
}

/// The shared object named `pdfium` that this process has mapped, if any.
///
/// `/proc/self/maps` is Linux-only, like the capture entry point itself.
fn mapped_pdfium_library() -> Option<PathBuf> {
    let maps = std::fs::read_to_string("/proc/self/maps").ok()?;
    for line in maps.lines() {
        let Some(path) = line.split_whitespace().nth(5) else {
            continue;
        };
        let name = path.rsplit('/').next().unwrap_or(path);
        if name.starts_with("libpdfium.") || name.starts_with("pdfium.") {
            let path = PathBuf::from(path.replace("\\040", " "));
            if path.is_file() {
                return Some(path);
            }
        }
    }
    None
}

/// The capture run. Marked `#[ignore]` so an ordinary `cargo test` never
/// renders or writes evidence.
#[test]
#[ignore = "capture tool: run it through `make reference-shots`"]
fn reference_shots_capture() {
    // Before the runtime exists: the no-store captures resolve the system
    // language while the very first state is built.
    assert_capture_environment().expect("pinned capture environment");
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("capture runtime");
    runtime.block_on(async {
        run().await.expect("reference capture run");
    });
}

async fn run() -> Result<()> {
    // The renderer must not be able to see host fonts: the entry point pins font
    // discovery, and this refuses to render if it did not.
    render::assert_controlled_font_database()?;
    let (in_memory_faces, file_backed_faces) = render::font_database_faces();
    println!(
        "reference-shots: renderer font database: {in_memory_faces} in-memory face(s), \
         {file_backed_faces} file-backed face(s)"
    );
    let verify = std::env::var("SHOSAI_REFERENCE_SHOTS_VERIFY")
        .is_ok_and(|value| !value.is_empty() && value != "0");
    // Resolved once: every step below — capture writes, mirroring, manifest,
    // verification — uses this value, never the configuration again.
    let output = output_root()?;
    let scenarios = scenarios::scenarios();
    // The evidence entries themselves must be the regular files and real
    // directories this run owns. Validating the two roots is not enough: a
    // symlink among the entries would redirect a capture write, the fixture
    // mirror or the stale-evidence prune outside the evidence directory — into
    // the disposable root, which this run deletes at the end, or into an
    // unrelated directory. This runs before anything is created or cleared.
    let capture_images: Vec<String> = scenarios
        .iter()
        .map(|scenario| format!("{}/{}.png", evidence::CAPTURE_DIRECTORY, scenario.id))
        .collect();
    preflight_evidence_destinations(&output, &capture_images)?;
    // Provenance is acquired before anything is rendered: a capture run that
    // cannot state the exact revision its code was rendered from must not write
    // evidence that claims to be reproducible.
    let revision = capture_revision()?;
    // Captures always read the fixture tree from the disposable data root, and
    // verify mode writes nothing outside it: the fresh captures are compared
    // with the committed evidence instead, and a capture run then mirrors the
    // tree it rendered from into the evidence directory.
    let data = data_root();
    let keep_data = std::env::var_os("SHOSAI_REFERENCE_SHOTS_KEEP_DATA").is_some();
    let root = DisposableRoot::prepare(&data, &output)?;
    // Everything below works on the resolved root, so the fixtures and stores it
    // creates are the ones the ownership checks and the teardown act on.
    let data = root.path().to_path_buf();
    let fixtures_root = data.join("fixtures");
    let pdfium = pdfium_identity();
    println!(
        "reference-shots: native PDFium: {}",
        pdfium
            .as_deref()
            .unwrap_or("unknown (no library named pdfium is mapped)")
    );

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
        scenarios::apply(scenario, &mut harness, &fixtures_root, &data).await?;
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
            write_evidence_file(&output.join(&image_name), &image.png)?;
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
        &revision,
        &output,
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
            &evidence_fixtures_path(&output),
            &fixture_records,
        )
        .context("mirror the generated fixture tree into the evidence directory")?;
        if mirrored != fixture_records {
            anyhow::bail!("the committed fixture copy does not match the generated fixture tree");
        }
        // The preflight ran before the first capture; the metadata files are
        // written last, so their destinations are checked again here. A name
        // that became a link or a multiply-linked file during the run would
        // otherwise be written through.
        preflight_evidence_destinations(&output, &capture_images)
            .context("re-check the evidence destinations before writing the manifest")?;
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
/// [`evidence::validate`]. `revision` is resolved by the caller
/// ([`capture_revision`]), so a run that cannot state the revision its code was
/// rendered from fails before it writes anything.
pub(crate) fn build_manifest(
    fixture_records: &[fixtures::FixtureRecord],
    broken_symlinks_available: bool,
    seeded: &seed::SeededLibrary,
    captures: Vec<manifest::CaptureEntry>,
    matrix: manifest::MatrixCoverage,
    revision: &CaptureRevision,
    output: &Path,
) -> Result<manifest::Manifest> {
    Ok(manifest::Manifest {
        schema: 2,
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
///
/// Its only caller is the committed-evidence test, which is gated to platforms
/// whose checkouts can carry the committed dangling-symlink fixture, so on a
/// platform where that test does not compile this is dead code rather than a
/// missing check.
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) async fn expected_manifest(
    fixtures_root: &Path,
    seeded: &seed::SeededLibrary,
    revision: &CaptureRevision,
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
        revision,
        &output_root()?,
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
            // Only a regular file can be evidence this tool wrote. Anything
            // else (a symlink, a directory, a socket) is not pruned: following
            // it could remove something outside the evidence directory.
            let file_type = entry
                .file_type()
                .with_context(|| format!("inspect {}", path.display()))?;
            anyhow::ensure!(
                file_type.is_file(),
                "refusing to prune {}: it is not a regular file",
                path.display()
            );
            println!(
                "reference-shots: removing stale evidence file {}",
                path.display()
            );
            std::fs::remove_file(&path).with_context(|| format!("remove {}", path.display()))?;
        }
    }
    Ok(())
}

/// Reject evidence destinations that are not the regular files and real
/// directories this run owns.
///
/// Checking the two roots (overlap, ownership, markers) and resolving the
/// evidence directory once is not enough: a symlink among the entries
/// themselves would redirect a write that the root checks already approved.
/// `manifest.json` — or any of the other three metadata files — could be a link
/// into the disposable data root, which this run deletes at the end, so the run
/// would "succeed" and leave a dangling link behind; `captures/` could be a link
/// to an unrelated directory, which the capture writes would overwrite and the
/// stale-evidence prune would then clean; a single capture image could be a link
/// to an unrelated file. Every destination is therefore inspected by its own
/// type before anything is created or cleared, and [`super::evidence::problems`]
/// enforces the same types when the evidence is read back, so a redirected
/// destination cannot pass the run's own validation either.
pub(crate) fn preflight_evidence_destinations(
    output: &Path,
    capture_images: &[String],
) -> Result<()> {
    for name in super::evidence::EVIDENCE_FILES {
        destination_type(output, name, DestinationType::File)?;
    }
    for name in [
        super::evidence::CAPTURE_DIRECTORY,
        super::evidence::FIXTURE_DIRECTORY,
    ] {
        destination_type(output, name, DestinationType::Directory)?;
    }
    for image in capture_images {
        destination_type(output, image, DestinationType::File)?;
    }
    Ok(())
}

/// The kind of filesystem entry a destination has to be.
#[derive(Clone, Copy, PartialEq, Eq)]
enum DestinationType {
    File,
    Directory,
}

/// Inspect one destination, refusing every other kind of entry.
///
/// A missing destination is fine — the run creates it — but an entry that
/// cannot be inspected at all is a failure, not an absence.
///
/// A file is only writable when it is the evidence's own: a symlink is refused
/// because the write would land on its target, and a file that is reachable
/// under more than one name is refused because truncating it would modify a
/// file outside the evidence directory.
fn destination_type(output: &Path, name: &str, expected: DestinationType) -> Result<()> {
    let path = output.join(name);
    let metadata = match std::fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            anyhow::bail!(
                "cannot inspect the evidence destination {}: {error}",
                path.display()
            )
        }
    };
    let matches = match expected {
        DestinationType::File => metadata.is_file() && !multiply_linked(&metadata),
        DestinationType::Directory => metadata.is_dir() && !metadata.file_type().is_symlink(),
    };
    if matches {
        return Ok(());
    }
    if expected == DestinationType::File && multiply_linked(&metadata) {
        anyhow::bail!("{}", hard_link_refusal(&path));
    }
    let wanted = match expected {
        DestinationType::File => "a regular file",
        DestinationType::Directory => "a directory",
    };
    anyhow::bail!(
        "refusing to write {}: it is {}, not {wanted}. The evidence directory must contain only the \
         files and directories this tool writes.",
        path.display(),
        describe_entry(&metadata)
    )
}

/// Whether an entry is reachable under more than one name.
///
/// [`super::evidence::multiply_linked`] is the same rule the validator applies,
/// so a capture run refuses exactly the destinations a committed evidence check
/// would reject.
fn multiply_linked(metadata: &std::fs::Metadata) -> bool {
    super::evidence::multiply_linked(metadata)
}

/// The refusal for a destination that another name already owns.
fn hard_link_refusal(path: &Path) -> String {
    format!(
        "refusing to write {}: it is hard-linked to another name, so writing it would modify a \
         file outside the evidence directory. Remove the extra link (the evidence must be the only \
         name of its files).",
        path.display()
    )
}

/// Write one file of the evidence directory, re-checking its destination.
///
/// The preflight inspects every destination before the run starts, but a run
/// takes minutes and writes later; a name that became a symlink or a
/// multiply-linked file in between must not be written through.
pub(crate) fn write_evidence_file(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if multiply_linked(&metadata) => anyhow::bail!("{}", hard_link_refusal(path)),
        Ok(metadata) if !metadata.is_file() => anyhow::bail!(
            "refusing to write {}: it is {}, not a regular file",
            path.display(),
            describe_entry(&metadata)
        ),
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => anyhow::bail!(
            "cannot inspect the evidence destination {}: {error}",
            path.display()
        ),
    }
    std::fs::write(path, bytes).with_context(|| format!("write {}", path.display()))
}

/// How to name a filesystem entry in a refusal.
fn describe_entry(metadata: &std::fs::Metadata) -> &'static str {
    let file_type = metadata.file_type();
    if file_type.is_symlink() {
        "a symlink"
    } else if metadata.is_dir() {
        "a directory"
    } else if metadata.is_file() {
        "a regular file"
    } else {
        "a special file"
    }
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

/// The provenance the manifest records: the exact revision or nothing.
///
/// The revision is run metadata, so [`super::evidence::problems`] exempts it
/// from the freshness comparison — which is why it must not be guessed. Either
/// the Jujutsu working copy can name itself, or the operator asserted a commit
/// id through `SHOSAI_REFERENCE_SHOTS_REVISION`; a missing `jj`, a `jj` failure
/// or a placeholder value fails the run *before* any capture is written, instead
/// of publishing evidence whose provenance claims to be exact but is not.
pub(crate) fn capture_revision() -> Result<CaptureRevision> {
    capture_revision_from(
        jj_revision(),
        std::env::var("SHOSAI_REFERENCE_SHOTS_REVISION").ok(),
        std::env::var("SHOSAI_REFERENCE_SHOTS_CHANGE_ID").ok(),
        std::env::var("SHOSAI_REFERENCE_SHOTS_BOOKMARK").ok(),
    )
}

/// The decision behind [`capture_revision`], with its inputs passed in.
///
/// The probe result and the exported overrides are parameters so the failure
/// paths can be tested without a broken working copy or a hostile environment.
pub(crate) fn capture_revision_from(
    jj: Option<String>,
    explicit_revision: Option<String>,
    explicit_change_id: Option<String>,
    explicit_bookmark: Option<String>,
) -> Result<CaptureRevision> {
    if let Some(revision) = explicit_revision {
        return Ok(CaptureRevision {
            revision: manifest::validated_capture_revision(
                &revision,
                "SHOSAI_REFERENCE_SHOTS_REVISION",
            )?,
            change_id: optional_label(explicit_change_id, "SHOSAI_REFERENCE_SHOTS_CHANGE_ID")?,
            bookmark: optional_label(explicit_bookmark, "SHOSAI_REFERENCE_SHOTS_BOOKMARK")?,
            source: manifest::OVERRIDE_REVISION_SOURCE.to_owned(),
        });
    }
    let Some(output) = jj else {
        anyhow::bail!(
            "cannot record the capture-code revision: `jj log -r @` did not run successfully, so \
             the evidence would not name the code it was rendered from. Run the capture inside the \
             Jujutsu workspace, or export SHOSAI_REFERENCE_SHOTS_REVISION with the commit id."
        );
    };
    let mut fields = output.split_whitespace();
    let revision = fields
        .next()
        .ok_or_else(|| anyhow::anyhow!("`jj log -r @` printed no commit id"))?
        .to_owned();
    let revision = manifest::validated_capture_revision(&revision, "jj log -r @ commit id")?;
    let change_id = fields
        .next()
        .ok_or_else(|| anyhow::anyhow!("`jj log -r @` printed no change id"))?
        .to_owned();
    let bookmark = fields.collect::<Vec<_>>().join(" ");
    Ok(CaptureRevision {
        revision,
        change_id,
        bookmark: if bookmark.is_empty() {
            "none".to_owned()
        } else {
            bookmark
        },
        source: manifest::JJ_REVISION_SOURCE.to_owned(),
    })
}

/// An override value for a descriptive provenance field.
///
/// The revision is what makes the evidence reproducible; the change id and
/// bookmark are the durable mapping to it, so an override that omits them is
/// allowed but recorded as unknown rather than invented.
fn optional_label(value: Option<String>, variable: &str) -> Result<String> {
    match value {
        None => Ok("unknown".to_owned()),
        Some(value) => {
            anyhow::ensure!(
                !value.trim().is_empty() && !value.trim().eq_ignore_ascii_case("unknown"),
                "{variable} must name a value when it is exported, not {value:?}"
            );
            Ok(value)
        }
    }
}

/// The raw output of the Jujutsu probe, or `None` when it is unavailable.
fn jj_revision() -> Option<String> {
    command_stdout(
        "jj",
        &[
            "log",
            "--no-graph",
            "-r",
            "@",
            "-T",
            "commit_id ++ \" \" ++ change_id ++ \" \" ++ bookmarks",
        ],
    )
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
        "Every capture needs a viewport the page fits in, because the renderer has no scroll \
         interaction and the application exposes no message that scrolls the settings or library \
         column: `settings-wide-*`, `settings-changed-*` and `settings-error-*` use `W900_TALL` \
         (900×1200) and the `LB-22` paging pair uses `W1280_TALL` (1280×3250). The layout rules, \
         the theme and the composition are unchanged; only the window is tall enough for the \
         column."
            .to_owned(),
        "The generated PDF fixtures draw shapes only: PDFium resolves fonts for unembedded PDF \
         text itself by scanning the host font directories and does not follow `FONTCONFIG_FILE`, \
         so a text run would make a rendered cover depend on the machine's installed fonts. The \
         native PDFium that rasterized the covers is recorded in `environment.pdfium`; a PDF \
         reference with real typography needs an embedded, pinned font and belongs to the reader \
         packages."
            .to_owned(),
        "The capture entry point runs on Linux with a pinned environment (`LANGUAGE=en-US`, \
         `FONTCONFIG_FILE` naming an empty font directory, see docs/reference-captures.md). \
         Another platform or an unpinned environment refuses to render rather than write images \
         that depend on the machine."
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
