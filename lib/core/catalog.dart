/// The shell's access to the application-owned, replaceable free-book catalog.
library;

import 'package:shosai_core/catalog.dart';
import 'bridge.dart';

export 'package:shosai_core/catalog.dart';

/// Identify catalog and source-cover requests as the sources require.
const catalogUserAgent =
    'Shosai/0.1 (+https://github.com/chaba-dev/shosai/issues)';

abstract interface class CatalogHost {
  CatalogClient get catalog;
}

typedef CatalogSaveOptions = ({
  List<({String id, String label, int generation, String? directory})>
  locations,
  String? selected,
});
typedef CatalogAddedBook = ({FlutterLibraryBook book, bool existing});

/// Acquisition is separate from reading: Add never opens a document.
abstract interface class CatalogAcquisitionHost {
  Future<CatalogSaveOptions> catalogSaveOptions();
  Future<void> selectCatalogSaveLocation(String? id);
  Future<CatalogAddedBook> addCatalogBook({
    required String bookId,
    required String sourceId,
    required String editionId,
    required String? locationId,
    required ({int generation, String? directory})? destination,
    required BigInt cancellationId,
    void Function(int received, int? total)? progress,
  });
}
