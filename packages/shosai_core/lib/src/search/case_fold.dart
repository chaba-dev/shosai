/// Unicode full case folding, as `str.casefold` and Rust's
/// `unicode-casefold` apply it.
library;

import 'dart:typed_data';

part 'case_fold_table.dart';

/// The Unicode version of the folding table.
const caseFoldUnicodeVersion = _unicodeVersion;

final Int32List _simpleFrom = Int32List.fromList([
  for (var index = 0; index < _simpleFolds.length; index += 2)
    _simpleFolds[index],
]);

final Int32List _simpleTo = Int32List.fromList([
  for (var index = 1; index < _simpleFolds.length; index += 2)
    _simpleFolds[index],
]);

/// The folding of [scalar] when it is one code point, or -1 when it folds to
/// several (see [fullCaseFold]).
int simpleCaseFold(int scalar) {
  if (scalar < 0x80) {
    return scalar >= 0x41 && scalar <= 0x5A ? scalar + 0x20 : scalar;
  }
  var low = 0;
  var high = _simpleFrom.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final key = _simpleFrom[middle];
    if (key < scalar) {
      low = middle + 1;
    } else if (key > scalar) {
      high = middle - 1;
    } else {
      return _simpleTo[middle];
    }
  }
  return _fullFolds.containsKey(scalar) ? -1 : scalar;
}

/// The code points [scalar] folds to.
List<int> fullCaseFold(int scalar) {
  final simple = simpleCaseFold(scalar);
  return simple < 0 ? _fullFolds[scalar]! : [simple];
}

/// [text] case folded.
String caseFold(String text) => String.fromCharCodes([
  for (final scalar in text.runes) ...fullCaseFold(scalar),
]);
