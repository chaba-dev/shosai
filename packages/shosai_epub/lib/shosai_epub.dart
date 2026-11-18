/// Dart-owned EPUB parsing, normalization, canonical text and durable
/// addresses for the Shōsai reader.
///
/// This is the production engine module adopted on 2026-09-28
/// (`docs/dart-document-stack-evaluation-plan.md`). The reader serves paginated
/// and continuous EPUB chapters, the Contents panel and painted internal links
/// from it. The Dart application core owns records over this canonical stream;
/// the Dart PDF engine handles PDF separately. There is no Rust fallback.
library;

export 'src/address.dart';
export 'src/archive.dart';
export 'src/canonical.dart';
export 'src/css.dart';
export 'src/limits.dart';
export 'src/model.dart';
export 'src/normalize.dart';
export 'src/paths.dart';
export 'src/protection.dart' show EpubProtectedError;
export 'src/ranged.dart';
