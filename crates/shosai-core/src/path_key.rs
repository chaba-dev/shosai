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

pub fn path_from_key(key: &str) -> PathBuf {
    #[cfg(unix)]
    if let Some(encoded) = key.strip_prefix("\0unix-path-v1:") {
        use std::ffi::OsString;
        use std::os::unix::ffi::OsStringExt;
        if let Some(bytes) = decode_hex(encoded) {
            return PathBuf::from(OsString::from_vec(bytes));
        }
    }
    #[cfg(windows)]
    if let Some(encoded) = key.strip_prefix("\0windows-path-v1:") {
        use std::ffi::OsString;
        use std::os::windows::ffi::OsStringExt;
        if let Some(bytes) = decode_hex(encoded)
            && bytes.len() % 2 == 0
        {
            let units = bytes
                .chunks_exact(2)
                .map(|unit| u16::from_be_bytes([unit[0], unit[1]]));
            return PathBuf::from(OsString::from_wide(&units.collect::<Vec<_>>()));
        }
    }
    PathBuf::from(key)
}

fn decode_hex(encoded: &str) -> Option<Vec<u8>> {
    if !encoded.len().is_multiple_of(2) {
        return None;
    }
    encoded
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).ok()?;
            u8::from_str_radix(text, 16).ok()
        })
        .collect()
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
        assert_eq!(path_from_key(&encoded), raw);
    }
}
