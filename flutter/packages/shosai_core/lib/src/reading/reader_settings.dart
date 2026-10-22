/// Reader appearance and layout settings, stored as preferences.
library;

import '../errors.dart';
import '../preferences.dart';
import '../store/store.dart';

enum ReaderTheme { light, sepia, dark }

/// The reader's settings.
///
/// [pdfZoom] is a scale from [minPdfZoom] to [maxPdfZoom], or one of the
/// fitting modes [pdfZoomFitPage] and [pdfZoomFitWidth].
final class ReaderSettings {
  const ReaderSettings({
    this.continuous = false,
    this.theme = ReaderTheme.light,
    this.epubFontSize = 16,
    this.epubLineSpacing = 1.6,
    this.pdfZoom = pdfZoomFitPage,
  });

  static const pdfZoomFitPage = 0.0;
  static const pdfZoomFitWidth = -1.0;
  static const minPdfZoom = 0.25;
  static const maxPdfZoom = 8.0;
  static const minEpubFontSize = 8.0;
  static const maxEpubFontSize = 72.0;
  static const minEpubLineSpacing = 1.0;
  static const maxEpubLineSpacing = 3.0;

  /// Scroll through the book rather than turn pages.
  final bool continuous;
  final ReaderTheme theme;
  final double epubFontSize;
  final double epubLineSpacing;
  final double pdfZoom;

  /// Whether every value is within its supported range.
  bool get isValid =>
      _within(epubFontSize, minEpubFontSize, maxEpubFontSize) &&
      _within(epubLineSpacing, minEpubLineSpacing, maxEpubLineSpacing) &&
      (pdfZoom == pdfZoomFitPage ||
          pdfZoom == pdfZoomFitWidth ||
          _within(pdfZoom, minPdfZoom, maxPdfZoom));

  @override
  bool operator ==(Object other) =>
      other is ReaderSettings &&
      other.continuous == continuous &&
      other.theme == theme &&
      other.epubFontSize == epubFontSize &&
      other.epubLineSpacing == epubLineSpacing &&
      other.pdfZoom == pdfZoom;

  @override
  int get hashCode =>
      Object.hash(continuous, theme, epubFontSize, epubLineSpacing, pdfZoom);

  @override
  String toString() =>
      'ReaderSettings(continuous: $continuous, theme: ${theme.name}, '
      'epubFontSize: $epubFontSize, epubLineSpacing: $epubLineSpacing, '
      'pdfZoom: $pdfZoom)';
}

bool _within(double value, double min, double max) =>
    value >= min && value <= max;

const _modeKey = 'reader.mode';
const _themeKey = 'reader.theme';
const _epubFontSizeKey = 'reader.epub_font_size';
const _epubLineSpacingKey = 'reader.epub_line_spacing';
const _pdfZoomKey = 'reader.pdf_zoom';

/// Loads and saves [ReaderSettings].
final class ReaderSettingsStore {
  ReaderSettingsStore(Store store) : _preferences = Preferences(store);

  final Preferences _preferences;

  /// The saved settings. A missing or unreadable value takes its default, so
  /// a damaged preference never blocks the reader.
  Future<ReaderSettings> load() async {
    final stored = await _preferences.getAll();
    const defaults = ReaderSettings();
    double number(String key, double fallback, bool Function(double) valid) {
      final value = double.tryParse(stored[key] ?? '');
      return value != null && valid(value) ? value : fallback;
    }

    final loaded = ReaderSettings(
      continuous: stored[_modeKey] == 'continuous',
      theme:
          ReaderTheme.values.asNameMap()[stored[_themeKey]] ?? defaults.theme,
      epubFontSize: number(
        _epubFontSizeKey,
        defaults.epubFontSize,
        (v) => _within(
          v,
          ReaderSettings.minEpubFontSize,
          ReaderSettings.maxEpubFontSize,
        ),
      ),
      epubLineSpacing: number(
        _epubLineSpacingKey,
        defaults.epubLineSpacing,
        (v) => _within(
          v,
          ReaderSettings.minEpubLineSpacing,
          ReaderSettings.maxEpubLineSpacing,
        ),
      ),
      pdfZoom: number(
        _pdfZoomKey,
        defaults.pdfZoom,
        (v) => ReaderSettings(pdfZoom: v).isValid,
      ),
    );
    return loaded;
  }

  /// Save every setting atomically.
  Future<void> save(ReaderSettings settings) async {
    if (!settings.isValid) {
      throw const CoreException.invalidRequest(
        'Reader settings are outside their supported ranges.',
      );
    }
    return _preferences.setAll({
      _modeKey: settings.continuous ? 'continuous' : 'paginated',
      _themeKey: settings.theme.name,
      _epubFontSizeKey: '${settings.epubFontSize}',
      _epubLineSpacingKey: '${settings.epubLineSpacing}',
      _pdfZoomKey: '${settings.pdfZoom}',
    });
  }
}
