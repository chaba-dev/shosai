//! Canonical archive paths and same-book EPUB references.

use std::borrow::Borrow;
use std::fmt;

use percent_encoding::{AsciiSet, CONTROLS, percent_decode_str, utf8_percent_encode};

const EPUB_PATH_ENCODE_SET: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'!')
    .add(b'"')
    .add(b'#')
    .add(b'$')
    .add(b'%')
    .add(b'&')
    .add(b'\'')
    .add(b'(')
    .add(b')')
    .add(b'*')
    .add(b'+')
    .add(b',')
    .add(b'/')
    .add(b':')
    .add(b';')
    .add(b'<')
    .add(b'=')
    .add(b'>')
    .add(b'?')
    .add(b'@')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CanonicalEpubPath(String);

impl CanonicalEpubPath {
    pub fn new(raw: &str) -> Result<Self, EpubPathError> {
        if raw.is_empty() || raw.starts_with('/') || raw.ends_with('/') {
            return Err(EpubPathError("archive path is empty or absolute"));
        }
        let mut components = Vec::new();
        for raw_component in raw.split('/') {
            if raw_component.is_empty() {
                return Err(EpubPathError("archive path contains an empty segment"));
            }
            if raw_component == "." || raw_component == ".." {
                return Err(EpubPathError("archive path contains a dot segment"));
            }
            if raw_component.contains(char::from(92))
                || raw_component
                    .chars()
                    .any(|character| character.is_control())
            {
                return Err(EpubPathError("archive path contains an unsafe character"));
            }
            components.push(raw_component.to_string());
        }
        Ok(Self(components.join("/")))
    }

    pub fn resolve(base_dir: &str, reference: &str) -> Result<EpubReference, EpubPathError> {
        let (raw_path, fragment) = split_reference(reference)?;
        if raw_path.is_empty() {
            return Err(EpubPathError("resource reference has no path"));
        }
        if raw_path.starts_with("//") || has_scheme(raw_path) {
            return Err(EpubPathError("resource reference has a foreign origin"));
        }

        let mut components = if raw_path.starts_with('/') || base_dir.is_empty() {
            Vec::new()
        } else {
            Self::new(base_dir)?
                .as_str()
                .split('/')
                .map(str::to_string)
                .collect()
        };
        let relative = raw_path.strip_prefix('/').unwrap_or(raw_path);
        if relative.is_empty() || relative.starts_with('/') || relative.ends_with('/') {
            return Err(EpubPathError("resource reference has a noncanonical path"));
        }
        for raw_component in relative.split('/') {
            match raw_component {
                "" => return Err(EpubPathError("resource reference has an empty segment")),
                "." => {}
                ".." => {
                    if components.pop().is_none() {
                        return Err(EpubPathError("resource reference escapes the archive"));
                    }
                }
                _ => {
                    let component = decode_component(raw_component)?;
                    if component == "." || component == ".." {
                        return Err(EpubPathError("encoded dot segments are not canonical"));
                    }
                    components.push(component);
                }
            }
        }
        if components.is_empty() {
            return Err(EpubPathError(
                "resource reference resolves to the archive root",
            ));
        }
        Ok(EpubReference {
            path: Self(components.join("/")),
            fragment,
        })
    }

    pub fn from_protocol_uri(uri: &str) -> Result<EpubReference, EpubPathError> {
        let reference = uri
            .strip_prefix("shosai://book/")
            .ok_or(EpubPathError("URI is outside the EPUB origin"))?;
        let (raw_path, fragment) = split_reference(reference)?;
        Ok(EpubReference {
            path: canonical_uri_path(raw_path)?,
            fragment,
        })
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn to_protocol_uri(&self) -> String {
        let encoded = self
            .0
            .split('/')
            .map(encode_component)
            .collect::<Vec<_>>()
            .join("/");
        format!("shosai://book/{encoded}")
    }

    /// Attach and validate a raw URI fragment without reparsing this decoded path.
    pub fn with_fragment(&self, raw_fragment: &str) -> Result<EpubReference, EpubPathError> {
        Ok(EpubReference {
            path: self.clone(),
            fragment: Some(decode_fragment(raw_fragment)?),
        })
    }
}

impl Borrow<str> for CanonicalEpubPath {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EpubReference {
    pub path: CanonicalEpubPath,
    pub fragment: Option<String>,
}

impl EpubReference {
    /// Serialize this reference as a canonical URI within the isolated book origin.
    pub fn to_protocol_uri(&self) -> String {
        let mut uri = self.path.to_protocol_uri();
        if let Some(fragment) = &self.fragment {
            uri.push('#');
            uri.push_str(&encode_component(fragment));
        }
        uri
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EpubPathError(&'static str);

impl fmt::Display for EpubPathError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for EpubPathError {}

fn split_reference(reference: &str) -> Result<(&str, Option<String>), EpubPathError> {
    if reference.contains('?') {
        return Err(EpubPathError("EPUB resource queries are not supported"));
    }
    let (path, fragment) = match reference.split_once('#') {
        Some((path, fragment)) if !fragment.contains('#') => {
            (path, Some(decode_fragment(fragment)?))
        }
        Some(_) => return Err(EpubPathError("EPUB reference has multiple fragments")),
        None => (reference, None),
    };
    Ok((path, fragment))
}

fn has_scheme(reference: &str) -> bool {
    reference
        .find(':')
        .is_some_and(|colon| !reference[..colon].contains('/'))
}

fn decode_component(raw: &str) -> Result<String, EpubPathError> {
    validate_percent_encoding(raw)?;
    let decoded = percent_decode_str(raw)
        .decode_utf8()
        .map_err(|_| EpubPathError("EPUB path is not valid UTF-8"))?
        .into_owned();
    if decoded.is_empty()
        || decoded.contains('/')
        || decoded.contains(char::from(92))
        || decoded.chars().any(|character| character.is_control())
    {
        return Err(EpubPathError("EPUB path contains an unsafe character"));
    }
    Ok(decoded)
}

fn canonical_uri_path(raw: &str) -> Result<CanonicalEpubPath, EpubPathError> {
    if raw.is_empty() || raw.starts_with('/') || raw.ends_with('/') {
        return Err(EpubPathError("URI path is empty or absolute"));
    }
    let mut components = Vec::new();
    for raw_component in raw.split('/') {
        if raw_component.is_empty() {
            return Err(EpubPathError("URI path contains an empty segment"));
        }
        let component = decode_component(raw_component)?;
        if component == "." || component == ".." {
            return Err(EpubPathError("URI path contains a dot segment"));
        }
        if raw_component != encode_component(&component) {
            return Err(EpubPathError("URI path is not canonically encoded"));
        }
        components.push(component);
    }
    Ok(CanonicalEpubPath(components.join("/")))
}

fn encode_component(component: &str) -> String {
    utf8_percent_encode(component, EPUB_PATH_ENCODE_SET).to_string()
}

fn decode_fragment(raw: &str) -> Result<String, EpubPathError> {
    validate_percent_encoding(raw)?;
    let decoded = percent_decode_str(raw)
        .decode_utf8()
        .map_err(|_| EpubPathError("EPUB fragment is not valid UTF-8"))?
        .into_owned();
    if decoded.chars().any(|character| character.is_control()) {
        return Err(EpubPathError("EPUB fragment contains a control character"));
    }
    Ok(decoded)
}

fn validate_percent_encoding(raw: &str) -> Result<(), EpubPathError> {
    let bytes = raw.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len()
                || !bytes[index + 1].is_ascii_hexdigit()
                || !bytes[index + 2].is_ascii_hexdigit()
            {
                return Err(EpubPathError("EPUB path has malformed percent encoding"));
            }
            index += 3;
        } else {
            index += 1;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path(raw: &str) -> CanonicalEpubPath {
        CanonicalEpubPath::new(raw).unwrap()
    }

    #[test]
    fn archive_paths_preserve_literal_percent_sequences() {
        assert_eq!(
            path("OEBPS/Text/My%20Chapter.xhtml").as_str(),
            "OEBPS/Text/My%20Chapter.xhtml"
        );
    }

    #[test]
    fn archive_paths_reject_aliases_and_unsafe_segments() {
        for invalid in [
            "",
            "/OEBPS/chapter.xhtml",
            "OEBPS//chapter.xhtml",
            "OEBPS/./chapter.xhtml",
            "OEBPS/../chapter.xhtml",
            "OEBPS\\chapter.xhtml",
        ] {
            assert!(
                CanonicalEpubPath::new(invalid).is_err(),
                "accepted {invalid}"
            );
        }
    }

    #[test]
    fn relative_references_resolve_with_fragments_without_escaping_root() {
        let resolved =
            CanonicalEpubPath::resolve("OEBPS/Text", "../Images/diagram%201.png#figure%201")
                .unwrap();
        assert_eq!(resolved.path.as_str(), "OEBPS/Images/diagram 1.png");
        assert_eq!(resolved.fragment.as_deref(), Some("figure 1"));

        assert!(CanonicalEpubPath::resolve("OEBPS", "../../outside.png").is_err());
    }

    #[test]
    fn relative_references_reject_foreign_origins_and_queries() {
        for invalid in [
            "https://example.com/image.png",
            "//example.com/image.png",
            "image.png?variant=2",
            "data:image/png;base64,AAAA",
        ] {
            assert!(
                CanonicalEpubPath::resolve("OEBPS", invalid).is_err(),
                "accepted {invalid}"
            );
        }
    }

    #[test]
    fn protocol_uris_require_one_canonical_book_origin_and_path() {
        let valid = CanonicalEpubPath::from_protocol_uri(
            "shosai://book/OEBPS/Text/My%20Chapter.xhtml#section%201",
        )
        .unwrap();
        assert_eq!(valid.path.as_str(), "OEBPS/Text/My Chapter.xhtml");
        assert_eq!(valid.fragment.as_deref(), Some("section 1"));

        for invalid in [
            "shosai://other/OEBPS/chapter.xhtml",
            "shosai://book//OEBPS/chapter.xhtml",
            "shosai://book/OEBPS/./chapter.xhtml",
            "shosai://book/OEBPS/../chapter.xhtml",
            "shosai://book/OEBPS/%2e%2e/chapter.xhtml",
            "shosai://book/OEBPS/%2Fchapter.xhtml",
            "shosai://book/OEBPS/%63hapter.xhtml",
            "shosai://book/OEBPS/chapter%2Exhtml",
            "shosai://book/OEBPS/chapter%zz.xhtml",
            "shosai://book/OEBPS/chapter%00.xhtml",
            "shosai://book/OEBPS/chapter.xhtml?variant=2",
            "SHOSAI://book/OEBPS/chapter.xhtml",
            "shosai://book:80/OEBPS/chapter.xhtml",
            "shosai://user@book/OEBPS/chapter.xhtml",
        ] {
            assert!(
                CanonicalEpubPath::from_protocol_uri(invalid).is_err(),
                "accepted {invalid}"
            );
        }
    }

    #[test]
    fn protocol_uris_round_trip_archive_percent_and_unicode_characters() {
        for raw in [
            "OEBPS/My Chapter.xhtml",
            "OEBPS/100%.xhtml",
            "OEBPS/日本語.xhtml",
        ] {
            let archive_path = path(raw);
            let uri = archive_path.to_protocol_uri();
            assert_eq!(
                CanonicalEpubPath::from_protocol_uri(&uri).unwrap().path,
                archive_path
            );
        }

        let reference =
            CanonicalEpubPath::resolve("OEBPS/Text", "../Images/My%20Image.svg#figure%201")
                .unwrap();
        let uri = reference.to_protocol_uri();
        assert_eq!(
            CanonicalEpubPath::from_protocol_uri(&uri).unwrap(),
            reference
        );
    }
}
