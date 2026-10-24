/// Dart-owned EPUB parsing, normalization, canonical text and durable
/// addresses for the Shōsai reader.
///
/// This is the production engine module adopted on 2026-09-28
/// (`docs/dart-document-stack-evaluation-plan.md`). The reader serves paginated
/// EPUB chapters, the Contents panel and painted internal links from it behind
/// the retained UI; PDF/CBZ and the Rust-owned stores are separate and
/// unchanged.
library;

export 'src/address.dart';
export 'src/archive.dart';
export 'src/canonical.dart';
export 'src/css.dart';
export 'src/limits.dart';
export 'src/model.dart';
export 'src/normalize.dart';
export 'src/paths.dart';
