/// Natural ordering of archive paths, so `page2` comes before `page10`.
library;

/// Compares [a] and [b] by runs: digit runs by numeric value, other runs
/// case-insensitively. Ties fall back to the plain string order, so the
/// order is total and stable.
int compareNatural(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final aDigit = _isDigit(a.codeUnitAt(i));
    final bDigit = _isDigit(b.codeUnitAt(j));
    if (aDigit && bDigit) {
      final aEnd = _runEnd(a, i);
      final bEnd = _runEnd(b, j);
      final aRun = _stripZeros(a.substring(i, aEnd));
      final bRun = _stripZeros(b.substring(j, bEnd));
      if (aRun.length != bRun.length) return aRun.length - bRun.length;
      final byValue = aRun.compareTo(bRun);
      if (byValue != 0) return byValue;
      i = aEnd;
      j = bEnd;
      continue;
    }
    if (aDigit != bDigit) {
      // A digit sorts before any other character, as `1.jpg` before `a.jpg`.
      return aDigit ? -1 : 1;
    }
    final aChar = _fold(a.codeUnitAt(i));
    final bChar = _fold(b.codeUnitAt(j));
    if (aChar != bChar) return aChar - bChar;
    i++;
    j++;
  }
  final byLength = (a.length - i) - (b.length - j);
  if (byLength != 0) return byLength;
  return a.compareTo(b);
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

int _runEnd(String value, int start) {
  var end = start;
  while (end < value.length && _isDigit(value.codeUnitAt(end))) {
    end++;
  }
  return end;
}

String _stripZeros(String run) {
  var start = 0;
  while (start < run.length - 1 && run.codeUnitAt(start) == 0x30) {
    start++;
  }
  return run.substring(start);
}

int _fold(int unit) => unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit;
