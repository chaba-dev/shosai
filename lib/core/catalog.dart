/// The shell's access to the application-owned, replaceable free-book catalog.
library;

import 'package:shosai_core/catalog.dart';

export 'package:shosai_core/catalog.dart';

abstract interface class CatalogHost {
  CatalogClient get catalog;
}
