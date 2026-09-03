use std::fmt::Write;
use std::path::{Path, PathBuf};

pub(crate) fn path_key(path: &Path) -> String {
    if let Some(path) = path.to_str() {
        return path.to_owned();
    }

    #[cfg(unix)]
    let (prefix, units) = {
        use std::os::unix::ffi::OsStrExt;
        ("\0unix-path-v1:", path.as_os_str().as_bytes().to_vec())
    };
    #[cfg(windows)]
    let (prefix, units) = {
        use std::os::windows::ffi::OsStrExt;
        let units = path
            .as_os_str()
            .encode_wide()
            .flat_map(|unit| unit.to_be_bytes())
            .collect();
        ("\0windows-path-v1:", units)
    };
    #[cfg(not(any(unix, windows)))]
    let (prefix, units) = (
        "\0encoded-path-v1:",
        path.as_os_str().as_encoded_bytes().to_vec(),
    );
    let mut key = String::from(prefix);
    for byte in units {
        write!(key, "{byte:02x}").expect("writing to a String cannot fail");
    }
    key
}

pub(crate) fn canonical_path_key(path: &Path) -> String {
    path_key(&path.canonicalize().unwrap_or_else(|_| PathBuf::from(path)))
}

#[cfg(all(test, unix))]
mod tests {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    use super::*;

    #[test]
    fn encoded_non_unicode_paths_cannot_collide_with_utf8_paths() {
        let raw = Path::new(OsStr::from_bytes(b"book-\x80.epub"));
        let encoded = path_key(raw);
        let literal = Path::new(encoded.trim_start_matches('\0'));

        assert_ne!(path_key(raw), path_key(literal));
        assert!(encoded.starts_with("\0unix-path-v1:"));
    }
}
