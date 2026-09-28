/// Canonical archive paths and same-book reference resolution.
///
/// Port of the production `CanonicalEpubPath`/`EpubReference` rules: no empty
/// segments, no dot segments, no backslashes or control characters, no leading
/// slash in the stored path, no foreign origin, and no escape above the archive
/// root.
library;

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
    if (component.contains(r'\') ||
        component.runes.any((rune) => rune < 0x20 || rune == 0x7F)) {
      throw const EpubPathError('archive path contains an unsafe character');
    }
    components.add(component);
  }
  return components.join('/');
}

/// Resolve a same-book reference against a canonical base directory.
///
/// Returns the canonical target path and its fragment, or throws when the
/// reference has a foreign origin or escapes the archive.
({String path, String? fragment}) resolveEpubReference(
  String baseDirectory,
  String reference,
) {
  var raw = reference.trim();
  if (raw.isEmpty) {
    throw const EpubPathError('resource reference has no path');
  }
  String? fragment;
  final hash = raw.indexOf('#');
  if (hash >= 0) {
    fragment = raw.substring(hash + 1);
    raw = raw.substring(0, hash);
  }
  final query = raw.indexOf('?');
  if (query >= 0) {
    throw const EpubPathError('resource reference has a query');
  }
  if (raw.isEmpty) {
    throw const EpubPathError('resource reference has no path');
  }
  if (raw.startsWith('//') ||
      RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(raw)) {
    throw const EpubPathError('resource reference has a foreign origin');
  }
  final decoded = percentDecodePath(raw);
  final components = <String>[];
  if (!decoded.startsWith('/')) {
    for (final component in baseDirectory.split('/')) {
      if (component.isNotEmpty) components.add(component);
    }
  }
  for (final component in decoded.split('/')) {
    if (component.isEmpty || component == '.') continue;
    if (component == '..') {
      if (components.isEmpty) {
        throw const EpubPathError('resource reference escapes the archive');
      }
      components.removeLast();
      continue;
    }
    components.add(component);
  }
  if (components.isEmpty) {
    throw const EpubPathError('resource reference has no path');
  }
  return (path: components.join('/'), fragment: fragment);
}

/// Decode percent escapes; returns the input when there are none.
String percentDecodePath(String value) {
  if (!value.contains('%')) return value;
  final out = StringBuffer();
  var index = 0;
  while (index < value.length) {
    final char = value[index];
    if (char == '%' && index + 2 < value.length) {
      final code = int.tryParse(
        value.substring(index + 1, index + 3),
        radix: 16,
      );
      if (code == null) {
        throw const EpubPathError('resource reference has a bad escape');
      }
      out.writeCharCode(code);
      index += 3;
      continue;
    }
    out.write(char);
    index++;
  }
  return out.toString();
}

/// Directory part of a canonical path ('' for a root-level file).
String directoryOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}
