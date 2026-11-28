/// Image dimensions read from an encoded image's header, without decoding.
library;

import 'dart:typed_data';

/// An image's size in pixels.
final class CbzImageSize {
  const CbzImageSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is CbzImageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// The size a JPEG, PNG, GIF, WebP or BMP header in [bytes] declares, or
/// null when [bytes] holds no recognizable header (or too little of it).
CbzImageSize? imageSizeFromHeader(Uint8List bytes) {
  final size =
      _png(bytes) ?? _gif(bytes) ?? _webp(bytes) ?? _bmp(bytes) ?? _jpeg(bytes);
  if (size == null || size.width <= 0 || size.height <= 0) return null;
  return size;
}

int _be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _le24(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);
int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _le32s(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)).toSigned(32);

bool _ascii(Uint8List b, int o, String text) {
  if (o + text.length > b.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (b[o + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

CbzImageSize? _png(Uint8List b) {
  if (b.length < 24 ||
      b[0] != 0x89 ||
      !_ascii(b, 1, 'PNG') ||
      !_ascii(b, 12, 'IHDR')) {
    return null;
  }
  return CbzImageSize(_be32(b, 16), _be32(b, 20));
}

CbzImageSize? _gif(Uint8List b) {
  if (b.length < 10 || !_ascii(b, 0, 'GIF8')) return null;
  return CbzImageSize(_le16(b, 6), _le16(b, 8));
}

CbzImageSize? _bmp(Uint8List b) {
  if (b.length < 26 || !_ascii(b, 0, 'BM')) return null;
  final header = _le32s(b, 14);
  if (header == 12) return CbzImageSize(_le16(b, 18), _le16(b, 20));
  return CbzImageSize(_le32s(b, 18).abs(), _le32s(b, 22).abs());
}

CbzImageSize? _webp(Uint8List b) {
  if (b.length < 25 || !_ascii(b, 0, 'RIFF') || !_ascii(b, 8, 'WEBP')) {
    return null;
  }
  if (_ascii(b, 12, 'VP8 ') && b.length >= 30) {
    return CbzImageSize(_le16(b, 26) & 0x3fff, _le16(b, 28) & 0x3fff);
  }
  if (_ascii(b, 12, 'VP8L')) {
    final b0 = b[21], b1 = b[22], b2 = b[23], b3 = b[24];
    return CbzImageSize(
      1 + (((b1 & 0x3f) << 8) | b0),
      1 + (((b3 & 0x0f) << 10) | (b2 << 2) | ((b1 & 0xc0) >> 6)),
    );
  }
  if (_ascii(b, 12, 'VP8X') && b.length >= 30) {
    return CbzImageSize(1 + _le24(b, 24), 1 + _le24(b, 27));
  }
  return null;
}

CbzImageSize? _jpeg(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var offset = 2;
  while (offset + 4 <= b.length) {
    if (b[offset] != 0xFF) return null;
    var marker = b[offset + 1];
    // Fill bytes before a marker.
    while (marker == 0xFF && offset + 2 < b.length) {
      offset++;
      marker = b[offset + 1];
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null;
    if (offset + 4 > b.length) return null;
    final length = _be16(b, offset + 2);
    if (length < 2) return null;
    final frame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (frame) {
      if (offset + 9 > b.length) return null;
      return CbzImageSize(_be16(b, offset + 7), _be16(b, offset + 5));
    }
    offset += 2 + length;
  }
  return null;
}
