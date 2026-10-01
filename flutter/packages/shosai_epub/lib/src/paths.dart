/// Canonical archive paths and same-book reference resolution.
///
/// Port of the production `CanonicalEpubPath`/`EpubReference` rules: no empty
/// segments, no dot segments, no backslashes or control characters, no leading
/// slash in the stored path, no foreign origin, and no escape above the archive
/// root. Reference resolution decodes each path component and the fragment
/// separately, so an encoded separator, dot segment or query cannot smuggle a
/// different target past the same rules.
library;

import 'dart:convert';

class EpubPathError implements Exception {
  const EpubPathError(this.message);

  final String message;

  @override
  String toString() => 'EpubPathError($message)';
}

/// Validate and normalize a stored archive path.
String canonicalEpubPath(String raw) {
  if (raw.isEmpty || raw.startsWith('/') || raw.endsWith('/')) {
    throw const EpubPathError('archive path is empty or absolute');
  }
  final components = <String>[];
  for (final component in raw.split('/')) {
    if (component.isEmpty) {
      throw const EpubPathError('archive path contains an empty segment');
    }
    if (component == '.' || component == '..') {
      throw const EpubPathError('archive path contains a dot segment');
    }
    if (component.contains(r'\') || _hasControlCharacter(component)) {
      throw const EpubPathError('archive path contains an unsafe character');
    }
    components.add(component);
  }
  return components.join('/');
}

/// Resolve a same-book reference against a canonical base directory.
///
/// Returns the canonical target path and its fragment, or throws when the
/// reference has a query, multiple fragments, a foreign origin, an encoded
/// separator or dot segment, an empty segment, a trailing slash, or escapes
/// above the archive root. This is the production `CanonicalEpubPath::resolve`
/// rule set; a caller that cannot resolve a reference treats it as
/// unresolvable rather than guessing a target.
({String path, String? fragment}) resolveEpubReference(
  String baseDirectory,
  String reference,
) {
  final split = _splitReference(reference);
  final raw = split.path;
  if (raw.isEmpty) {
    throw const EpubPathError('resource reference has no path');
  }
  if (raw.startsWith('//') || _hasScheme(raw)) {
    throw const EpubPathError('resource reference has a foreign origin');
  }
  final components = <String>[];
  final absolute = raw.startsWith('/');
  if (!absolute && baseDirectory.isNotEmpty) {
    // The production resolver validates the base like any canonical archive
    // path before resolving against it; an invalid base is unresolvable
    // rather than silently tolerated.
    components.addAll(canonicalEpubPath(baseDirectory).split('/'));
  }
  final relative = absolute ? raw.substring(1) : raw;
  if (relative.isEmpty || relative.endsWith('/')) {
    throw const EpubPathError('resource reference has a noncanonical path');
  }
  for (final rawComponent in relative.split('/')) {
    if (rawComponent.isEmpty) {
      throw const EpubPathError('resource reference has an empty segment');
    }
    if (rawComponent == '.') continue;
    if (rawComponent == '..') {
      if (components.isEmpty) {
        throw const EpubPathError('resource reference escapes the archive');
      }
      components.removeLast();
      continue;
    }
    final component = decodeEpubComponent(rawComponent);
    if (component == '.' || component == '..') {
      throw const EpubPathError('encoded dot segments are not canonical');
    }
    components.add(component);
  }
  if (components.isEmpty) {
    throw const EpubPathError(
      'resource reference resolves to the archive root',
    );
  }
  return (path: components.join('/'), fragment: split.fragment);
}

/// Decode one percent-encoded archive path component.
///
/// Rejects malformed escapes, invalid UTF-8, an empty component and any decoded
/// `/`, backslash or control character, so an encoded separator cannot become a
/// path boundary.
String decodeEpubComponent(String raw) {
  final decoded = _percentDecode(raw, 'resource reference has a bad escape');
  if (decoded.isEmpty ||
      decoded.contains('/') ||
      decoded.contains(r'\') ||
      _hasControlCharacter(decoded)) {
    throw const EpubPathError('resource reference has an unsafe character');
  }
  return decoded;
}

/// Decode one percent-encoded fragment identifier.
///
/// The engine's anchors are stored decoded, so a fragment must be decoded once
/// before it is looked up; control characters are rejected.
String decodeEpubFragment(String raw) {
  final decoded = _percentDecode(raw, 'EPUB fragment has a bad escape');
  if (_hasControlCharacter(decoded)) {
    throw const EpubPathError('EPUB fragment contains a control character');
  }
  return decoded;
}

/// Split a reference at its first `#` and decode the fragment.
({String path, String? fragment}) _splitReference(String reference) {
  if (reference.contains('?')) {
    throw const EpubPathError('resource reference has a query');
  }
  final hash = reference.indexOf('#');
  if (hash < 0) return (path: reference, fragment: null);
  final fragment = reference.substring(hash + 1);
  if (fragment.contains('#')) {
    throw const EpubPathError('resource reference has multiple fragments');
  }
  return (
    path: reference.substring(0, hash),
    fragment: decodeEpubFragment(fragment),
  );
}

/// Whether the reference starts with a URI scheme, the production
/// `has_scheme` rule: a colon before any `/`, `?` or `#`.
bool _hasScheme(String reference) {
  final colon = reference.indexOf(':');
  if (colon < 0) return false;
  return !reference.substring(0, colon).contains('/');
}

/// Decode percent escapes, preserving literal characters as their UTF-8 bytes.
String _percentDecode(String raw, String escapeError) {
  if (!raw.contains('%')) return raw;
  final bytes = <int>[];
  final literal = StringBuffer();
  void flushLiteral() {
    if (literal.isEmpty) return;
    bytes.addAll(utf8.encode(literal.toString()));
    literal.clear();
  }

  var index = 0;
  while (index < raw.length) {
    final unit = raw.codeUnitAt(index);
    if (unit == 0x25) {
      if (index + 2 >= raw.length) {
        throw EpubPathError(escapeError);
      }
      final code = int.tryParse(raw.substring(index + 1, index + 3), radix: 16);
      if (code == null) {
        throw EpubPathError(escapeError);
      }
      flushLiteral();
      bytes.add(code);
      index += 3;
      continue;
    }
    literal.writeCharCode(unit);
    index += 1;
  }
  flushLiteral();
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const EpubPathError('EPUB reference is not valid UTF-8');
  }
}

/// Whether [value] contains a Unicode control character (C0, DEL or C1).
bool _hasControlCharacter(String value) =>
    value.runes.any((rune) => rune < 0x20 || (rune >= 0x7F && rune <= 0x9F));

/// Directory part of a canonical path ('' for a root-level file).
String directoryOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}
