/// Dart-owned CBZ reading for the Shōsai reader: a bounded archive index
/// read in parts, natural page order, ComicInfo.xml metadata and image sizes
/// from their headers. The host decodes pixels.
library;

export 'src/archive.dart';
export 'src/comic_info.dart';
export 'src/image_size.dart';
export 'src/limits.dart';
export 'src/natural_order.dart';
