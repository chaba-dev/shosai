/// The shell's access to the application-owned, replaceable free-book catalog.
library;

import 'package:shosai_core/catalog.dart';

export 'package:shosai_core/catalog.dart';

/// Identify catalog and source-cover requests as the sources require.
const catalogUserAgent =
    'Shosai/0.1 (+https://github.com/chaba-dev/shosai/issues)';

abstract interface class CatalogHost {
  CatalogClient get catalog;
}
