/// Dart application core for the Shōsai reader.
///
/// Owns the SQLite store and the records kept in it. Replaces the Rust core
/// and its Flutter bridge (RFD 4, milestone M3.0); the package is independent
/// of Flutter widgets so its behaviour is tested with `dart test`.
library;

export 'src/annotations/quote.dart';
export 'src/annotations/resolution.dart';
export 'src/cancellation.dart';
export 'src/errors.dart';
export 'src/library/book.dart';
export 'src/library/files.dart';
export 'src/library/inspection.dart';
export 'src/library/library.dart';
export 'src/preferences.dart';
export 'src/reading/bookmarks.dart';
export 'src/reading/reader_settings.dart';
export 'src/reading/reading_state.dart';
export 'src/store/schema.dart';
export 'src/store/store.dart';
