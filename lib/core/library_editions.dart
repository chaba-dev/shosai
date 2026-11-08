library;

import 'package:shosai_core/shosai_core.dart';
import 'bridge.dart';

/// The production shelf's core, alongside the file-based reader records.
abstract interface class LibraryEditionsHost {
  LibraryEditions get editions;
  FlutterLibraryBook editionBook(Book book);
}

enum EditionAction { read, separate, group, remove, keep }

final class EditionChoice {
  const EditionChoice(this.action, [this.fileKey]);
  final EditionAction action;
  final String? fileKey;
}

typedef LibraryEditionPicker =
    Future<EditionChoice?> Function(
      BookEdition edition,
      FlutterBookFormat? format,
    );
typedef LibraryEditionGrouper =
    Future<String?> Function(BookEdition edition, List<BookEdition> choices);
