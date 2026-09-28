/// Dart-owned EPUB parsing, normalization, canonical text and durable
/// addresses for the Shōsai reader.
///
/// This is the production engine module adopted on 2026-09-28
/// (`docs/dart-document-stack-evaluation-plan.md`). It is not yet wired into
/// the reader: the content-service slice that serves EPUB chapters from this
/// engine is separate, and the API is frozen only when that slice lands.
library;

export 'src/address.dart';
export 'src/archive.dart';
export 'src/canonical.dart';
export 'src/css.dart';
export 'src/limits.dart';
export 'src/model.dart';
export 'src/normalize.dart';
export 'src/paths.dart';
