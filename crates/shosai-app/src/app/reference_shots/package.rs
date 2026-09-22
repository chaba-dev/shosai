//! Which evidence package a capture run produces.
//!
//! One runner serves both reference packages. Package 1B owns the
//! library/import/settings captures, package 1C owns the reader captures; each
//! has its own evidence directory, its own disposable data root, its own capture
//! table, its own allowed families and its own limitations. They share the
//! fixture generator, the renderer, the manifest/checksum/verify machinery and
//! the entry point ([`super::runner::ENTRY_POINT`]).
//!
//! The ownership marker and the lock of the disposable root are
//! package-neutral, so the split is not cosmetic: without separate directories a
//! 1C run would prune 1B's evidence or clear the data root 1B's captures were
//! rendered from.
//!
//! `SHOSAI_REFERENCE_SHOTS_PACKAGE` selects `1b`, `1c` or `all` (the default, so
//! the documented entry point writes every reference set in one run). The
//! directory overrides are package-specific for the same reason the defaults
//! are: `SHOSAI_REFERENCE_SHOTS_DIR`/`_DATA_DIR` stay the 1B knobs they have
//! always been, and `_DIR_1C`/`_DATA_DIR_1C` move package 1C.

use std::path::PathBuf;

use anyhow::{Context, Result};

use super::manifest;
use super::scenarios::{self, Scenario};

/// Committed evidence directory of package 1B, relative to the repository root.
pub(crate) const DEFAULT_OUTPUT_1B: &str = "rfd/0004/evidence/reference-shots-1b";

/// Committed evidence directory of package 1C, relative to the repository root.
pub(crate) const DEFAULT_OUTPUT_1C: &str = "rfd/0004/evidence/reference-shots-1c";

/// Fixed disposable data root of package 1B.
pub(crate) const DEFAULT_DATA_ROOT_1B: &str = "/tmp/shosai-reference-shots-1b";

/// Fixed disposable data root of package 1C.
///
/// A separate root is required, not a convenience: the root is cleared at the
/// start of every run, and 1B's captures render absolute paths out of it.
pub(crate) const DEFAULT_DATA_ROOT_1C: &str = "/tmp/shosai-reference-shots-1c";

/// One reference package.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Package {
    /// Library, import and settings reference captures (`1B-*`).
    OneB,
    /// Reader reference captures (`1C-*`).
    OneC,
}

impl Package {
    /// Both packages, in the order the entry point runs them.
    pub(crate) const ALL: [Package; 2] = [Package::OneB, Package::OneC];

    /// The package id recorded in the manifest and used in the README title.
    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::OneB => "1B",
            Self::OneC => "1C",
        }
    }

    /// The capture families this package is allowed to claim.
    pub(crate) fn families(self) -> &'static [&'static str] {
        match self {
            Self::OneB => &manifest::PACKAGE_1B_FAMILIES,
            Self::OneC => &super::reader::PACKAGE_1C_FAMILIES,
        }
    }

    /// The default evidence directory, relative to the repository root.
    pub(crate) fn default_output(self) -> &'static str {
        match self {
            Self::OneB => DEFAULT_OUTPUT_1B,
            Self::OneC => DEFAULT_OUTPUT_1C,
        }
    }

    /// The environment variable that overrides this package's evidence directory.
    fn output_override(self) -> &'static str {
        match self {
            Self::OneB => "SHOSAI_REFERENCE_SHOTS_DIR",
            Self::OneC => "SHOSAI_REFERENCE_SHOTS_DIR_1C",
        }
    }

    /// The environment variable that overrides this package's data root.
    fn data_override(self) -> &'static str {
        match self {
            Self::OneB => "SHOSAI_REFERENCE_SHOTS_DATA_DIR",
            Self::OneC => "SHOSAI_REFERENCE_SHOTS_DATA_DIR_1C",
        }
    }

    /// The default disposable data root.
    pub(crate) fn default_data_root(self) -> &'static str {
        match self {
            Self::OneB => DEFAULT_DATA_ROOT_1B,
            Self::OneC => DEFAULT_DATA_ROOT_1C,
        }
    }

    /// The capture table of this package.
    pub(crate) fn scenarios(self) -> Vec<Scenario> {
        match self {
            Self::OneB => scenarios::scenarios(),
            Self::OneC => super::reader::scenarios(),
        }
    }

    /// The capture pairs that deliberately share pixels, with their reasons.
    pub(crate) fn pixel_aliases(self) -> &'static [(&'static str, &'static str, &'static str)] {
        match self {
            Self::OneB => &scenarios::PIXEL_ALIASES,
            Self::OneC => &super::reader::PIXEL_ALIASES,
        }
    }

    /// The matrix rows this package satisfies, satisfies by provenance, or
    /// deliberately leaves open.
    pub(crate) fn matrix_rows(
        self,
    ) -> (
        Vec<&'static str>,
        Vec<&'static str>,
        Vec<(&'static str, &'static str)>,
    ) {
        match self {
            Self::OneB => scenarios::matrix_rows(),
            Self::OneC => super::reader::matrix_rows(),
        }
    }

    /// What this package deliberately does not capture, with the owner.
    pub(crate) fn limitations(self, broken_symlinks_available: bool) -> Vec<String> {
        match self {
            Self::OneB => super::runner::library_limitations(broken_symlinks_available),
            Self::OneC => super::reader::limitations(broken_symlinks_available),
        }
    }

    /// Whether this package's captures write durable reader state (reading
    /// positions and bookmarks) that the next capture must not inherit.
    pub(crate) fn resets_reader_state(self) -> bool {
        match self {
            Self::OneB => false,
            Self::OneC => true,
        }
    }

    /// The default disposable data root for a package.
    pub(crate) fn data_root(self) -> PathBuf {
        std::env::var_os(self.data_override())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(self.default_data_root()))
    }

    /// The evidence output directory of a package.
    ///
    /// Resolution fails instead of falling back to the configured spelling: a
    /// spelling the file system cannot traverse (a symlink loop, a dangling
    /// link, a file used as a directory, a drive-relative path) must not be
    /// silently replaced by a location that happens to be reachable through
    /// `..`.
    pub(crate) fn output_root(self) -> Result<PathBuf> {
        let configured = std::env::var_os(self.output_override())
            .map(PathBuf::from)
            .unwrap_or_else(|| super::runner::repository_root().join(self.default_output()));
        super::runner::resolve_path(&configured)
    }

    /// The packages this run produces.
    ///
    /// An unknown value is refused rather than ignored: a typo that silently
    /// rendered both sets (or none) would make the run's own log the only record
    /// of what it wrote.
    pub(crate) fn selected() -> Result<Vec<Package>> {
        let Some(value) = std::env::var_os("SHOSAI_REFERENCE_SHOTS_PACKAGE") else {
            return Ok(Package::ALL.to_vec());
        };
        let value = value.to_string_lossy().trim().to_ascii_lowercase();
        match value.as_str() {
            "" | "all" => Ok(Package::ALL.to_vec()),
            "1b" => Ok(vec![Package::OneB]),
            "1c" => Ok(vec![Package::OneC]),
            other => anyhow::bail!(
                "SHOSAI_REFERENCE_SHOTS_PACKAGE must be `1b`, `1c` or `all`, not {other:?}"
            ),
        }
    }

    /// The command this package records.
    ///
    /// Both packages run through the same entry point, so the default is the
    /// same command; a run that restricted itself with
    /// `SHOSAI_REFERENCE_SHOTS_PACKAGE` is recorded through the operator
    /// override the Makefile exports.
    pub(crate) fn command(self) -> String {
        std::env::var("SHOSAI_REFERENCE_SHOTS_COMMAND")
            .unwrap_or_else(|_| super::runner::DEFAULT_COMMAND.to_owned())
    }

    /// Rows this package deliberately does not capture because Iced has no
    /// counterpart, with the authority that owns them instead.
    pub(crate) fn non_iced_authority(self) -> Vec<String> {
        match self {
            Self::OneB => Vec::new(),
            Self::OneC => super::reader::non_iced_authority(),
        }
    }

    /// Captured rows whose reference coverage is deliberately partial, with what
    /// is missing.
    ///
    /// A row is `captured` when a capture renders that state; it does not mean
    /// the row is fully referenced. These records say which part of a captured
    /// row no image covers, so an accepting package does not read the row id
    /// alone as complete coverage.
    pub(crate) fn captured_reasons(self) -> &'static [(&'static str, &'static str)] {
        match self {
            Self::OneB => &[],
            Self::OneC => &super::reader::CAPTURED_PARTIAL,
        }
    }
}

/// Resolve the package list, reporting the selection in the run log.
pub(crate) fn selected() -> Result<Vec<Package>> {
    let packages = Package::selected().context("select the reference-shots packages")?;
    anyhow::ensure!(
        !packages.is_empty(),
        "no reference-shots package selected, so the run would render nothing"
    );
    Ok(packages)
}

/// One package's roots, as the entry point resolved and cross-checked them.
///
/// The spelling is kept next to the resolved path because the data root's input
/// policy is enforced on the configured spelling, while every filesystem
/// operation must use the resolved path the cross-package checks approved.
#[derive(Debug, Clone)]
pub(crate) struct PackageRoots {
    pub(crate) package: Package,
    /// The configured disposable data root, before resolution.
    pub(crate) data_spelling: PathBuf,
    /// The resolved evidence directory.
    pub(crate) output: PathBuf,
    /// The resolved disposable data root.
    pub(crate) data: PathBuf,
}

/// Resolve every package's evidence directory and disposable data root.
///
/// Both packages are resolved whether or not this run produces both, because the
/// overrides are configuration, not a selection: a `_DIR_1C` that points at 1B's
/// evidence directory is a misconfiguration even in a run that only produces 1C.
pub(crate) fn resolved_roots() -> Result<Vec<PackageRoots>> {
    let mut roots = Vec::new();
    for package in Package::ALL {
        let output = package.output_root()?;
        let data_spelling = package.data_root();
        let data = super::runner::resolve_path(&data_spelling)
            .with_context(|| format!("resolve package {}'s data root", package.id()))?;
        roots.push(PackageRoots {
            package,
            data_spelling,
            output,
            data,
        });
    }
    Ok(roots)
}

/// Refuse a configuration where one package could write or clear another's state.
///
/// The disposable root is deleted at the start of a run and the evidence
/// directory is pruned, so two packages that resolve to the same (or nested)
/// location would destroy each other's evidence. The defaults are separate; this
/// is what keeps a misconfigured override from silently doing the same.
pub(crate) fn assert_roots_disjoint(roots: &[PackageRoots]) -> Result<()> {
    let overlaps = |left: &PathBuf, right: &PathBuf| {
        left == right || left.starts_with(right) || right.starts_with(left)
    };
    for (index, left) in roots.iter().enumerate() {
        for right in &roots[index + 1..] {
            anyhow::ensure!(
                !overlaps(&left.output, &right.output),
                "packages {} and {} resolve to the same evidence directory ({} / {}); each package \
                 owns its own directory because a run prunes the captures it no longer produces",
                left.package.id(),
                right.package.id(),
                left.output.display(),
                right.output.display()
            );
            anyhow::ensure!(
                !overlaps(&left.data, &right.data),
                "packages {} and {} resolve to the same disposable data root ({} / {}); the root is \
                 cleared at the start of every run",
                left.package.id(),
                right.package.id(),
                left.data.display(),
                right.data.display()
            );
            anyhow::ensure!(
                !overlaps(&left.output, &right.data) && !overlaps(&left.data, &right.output),
                "packages {} and {} have overlapping evidence and data roots ({} / {}); the data \
                 root is cleared at the start of every run",
                left.package.id(),
                right.package.id(),
                left.output.display(),
                right.data.display()
            );
        }
    }
    Ok(())
}

/// Refuse to write a package's evidence into a directory that holds another's.
///
/// An evidence directory is identified by the `package` field of the manifest it
/// already contains. Pruning and overwriting are scoped to the package that owns
/// the directory, so a run pointed at the wrong one must fail before it writes.
///
/// The check runs before anything is created, cleared or written, so it must not
/// open an entry the writer would never have produced: a FIFO with no writer
/// would block the run, a symlink would read whatever it points at, and a hard
/// link shares its inode with another name. A manifest that exists but cannot be
/// inspected, read, parsed or attributed is a refusal too — a damaged ownership
/// marker is not permission to overwrite the directory. Only a genuinely absent
/// manifest (a fresh evidence directory) passes.
pub(crate) fn assert_evidence_belongs_to(roots: &[PackageRoots]) -> Result<()> {
    for roots in roots {
        let (package, output) = (&roots.package, &roots.output);
        let manifest = output.join("manifest.json");
        let metadata = match std::fs::symlink_metadata(&manifest) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => anyhow::bail!(
                "the existing {} cannot be inspected, so the evidence directory {} cannot be \
                 attributed to a package: {error}; point the override somewhere else",
                manifest.display(),
                output.display()
            ),
        };
        anyhow::ensure!(
            metadata.is_file(),
            "the existing {} is {}, so it is not opened to check the evidence directory's owner; \
             point the override somewhere else",
            manifest.display(),
            if metadata.file_type().is_symlink() {
                "a symlink"
            } else {
                "not a regular file"
            }
        );
        anyhow::ensure!(
            !super::evidence::multiply_linked(&metadata),
            "the existing {} is hard-linked to another name, so it is not opened to check the \
             evidence directory's owner; point the override somewhere else",
            manifest.display()
        );
        let text = std::fs::read_to_string(&manifest).with_context(|| {
            format!(
                "read the existing {} to check which package owns {}",
                manifest.display(),
                output.display()
            )
        })?;
        let committed: serde_json::Value = serde_json::from_str(&text).with_context(|| {
            format!(
                "parse the existing {} to check which package owns {}",
                manifest.display(),
                output.display()
            )
        })?;
        let Some(owner) = committed.get("package").and_then(|value| value.as_str()) else {
            anyhow::bail!(
                "the existing {} has no `package` field, so the owner of {} cannot be established; \
                 point the override somewhere else",
                manifest.display(),
                output.display()
            );
        };
        anyhow::ensure!(
            owner == package.id(),
            "the evidence directory {} already holds package {owner}'s evidence, not package {}'s; \
             point the override somewhere else",
            output.display(),
            package.id()
        );
    }
    Ok(())
}
