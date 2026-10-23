import 'dart:io';

import 'package:shosai_epub/shosai_epub.dart';

/// Times [openEpubBytes] on each EPUB named on the command line.
///
/// ```sh
/// dart run tool/bench_open.dart book.epub [more.epub ...]
/// ```
///
/// Each book is parsed five times; the median and the slowest run are printed
/// in milliseconds. Compile it (`dart compile exe`) for times close to the
/// app's release build.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/bench_open.dart <book.epub>...');
    exitCode = 64;
    return;
  }
  for (final path in args) {
    final bytes = File(path).readAsBytesSync();
    final times = <int>[];
    late EpubBook book;
    for (var run = 0; run < 5; run++) {
      final watch = Stopwatch()..start();
      book = openEpubBytes(bytes);
      times.add(watch.elapsedMilliseconds);
    }
    times.sort();
    stdout.writeln(
      '${File(path).uri.pathSegments.last}: ${bytes.length} bytes, '
      '${book.chapters.length} chapters, '
      'median ${times[2]} ms, max ${times.last} ms',
    );
  }
}
