/// Protection metadata shared by full and ranged EPUB admission.
library;

import 'dart:convert';

import 'package:xml/xml.dart';

import 'paths.dart';

/// The book needs a decryption scheme this reader does not implement.
final class EpubProtectedError implements Exception {
  const EpubProtectedError();
}

/// Inspect bounded metadata, not chapter bytes. Font obfuscation is not DRM.
bool epubHasProtection({
  List<int>? encryption,
  List<int>? rights,
  List<int>? license,
}) {
  if (license != null) {
    try {
      final value = jsonDecode(utf8.decode(license));
      if (value is Map && value['encryption'] is Map) return true;
    } on FormatException {
      // A filename alone does not establish that a license protects the book.
    }
  }
  final rightsXml = _protectionXml(rights);
  if (rightsXml != null &&
      rightsXml.descendants.whereType<XmlElement>().any(
        (element) => element.namespaceUri == 'http://ns.adobe.com/adept',
      )) {
    return true;
  }
  final encryptionXml = _protectionXml(encryption);
  if (encryptionXml == null) return false;
  for (final data in encryptionXml.descendants.whereType<XmlElement>()) {
    if (data.name.local != 'EncryptedData') continue;
    final methods = data.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'EncryptionMethod',
    );
    // Missing/unknown methods on encrypted data cannot be opened either.
    if (methods.isEmpty) return true;
    for (final method in methods) {
      final algorithm = method.getAttribute('Algorithm');
      if (algorithm != 'http://www.idpf.org/2008/embedding' &&
          algorithm != 'http://ns.adobe.com/pdf/enc#RC') {
        return true;
      }
    }
  }
  return false;
}

/// Encryption references are rooted at the archive, not META-INF or the OPF.
bool epubResourceIsEncrypted(List<int>? encryption, String path) {
  final xml = _protectionXml(encryption);
  if (xml == null) return false;
  for (final element in xml.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'CipherReference') continue;
    final uri = element.getAttribute('URI');
    if (uri == null) continue;
    try {
      if (resolveEpubReference('', uri).path == path) return true;
    } on EpubPathError {
      // An invalid reference does not name this admitted resource.
    }
  }
  return false;
}

XmlDocument? _protectionXml(List<int>? bytes) {
  if (bytes == null) return null;
  try {
    return XmlDocument.parse(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
}
