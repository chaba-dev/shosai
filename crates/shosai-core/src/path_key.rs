use std::fmt::Write;
use std::path::{Path, PathBuf};

pub(crate) fn path_key(path: &Path) -> String {
    if let Some(path) = path.to_str() {
        return path.to_owned();
    }

    let mut key = String::from("os-path-v1:");
    for byte in path.as_os_str().as_encoded_bytes() {
        write!(key, "{byte:02x}").expect("writing to a String cannot fail");
    }
    key
}

pub(crate) fn canonical_path_key(path: &Path) -> String {
    path_key(&path.canonicalize().unwrap_or_else(|_| PathBuf::from(path)))
}
