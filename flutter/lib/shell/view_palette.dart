part of 'view.dart';

/// The editorial face of the default type set (`docs/typography.md`).
const String shellEditorialFontFamily =
    ShosaiTokens.typeFamilyEditorialLatinFlutter;

/// The face that holds only the mark's 書.
const String shellMarkFontFamily = 'Shosai Mark';

/// An editorial style: the serif reserved for what names or quotes a book and
/// for the titles of screens, sections and panels.
///
/// The weight is set on the variable axis as well as the style, so the engine
/// draws the face's own 600 instead of synthesizing bold.
TextStyle shellEditorialStyle(
  double size,
  double lineHeight, {
  FontWeight weight = FontWeight.w600,
}) => TextStyle(
  fontFamily: shellEditorialFontFamily,
  // Shippori Mincho, the set's Japanese editorial face, is not bundled yet,
  // so Japanese titles fall back to the bundled interface face.
  fontFamilyFallback: const [shosaiJapaneseInterfaceFontFamily],
  fontSize: size,
  height: lineHeight / size,
  fontWeight: weight,
  fontVariations: [FontVariation.weight(weight.value.toDouble())],
);

/// An interface style in the current theme's ink.
TextStyle shellInterfaceStyle(
  double size,
  double lineHeight, {
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: shosaiInterfaceFontFamily,
  fontFamilyFallback: shosaiInterfaceFontFallback,
  fontSize: size,
  height: lineHeight / size,
  fontWeight: weight,
  fontVariations: [FontVariation.weight(weight.value.toDouble())],
);

/// The shell's chrome colours for the current app theme: the D1 "paper"
/// roles of `docs/design-system.md` (Colour), from [ShosaiTokens]. The
/// layered shadows are composed here from the tokens' shadow ink, because the
/// token source carries colours and sizes only.
final class ShellPalette {
  const ShellPalette._({
    required this.canvas,
    required this.chrome,
    required this.surface,
    required this.surfaceSunken,
    required this.hover,
    required this.line,
    required this.ink,
    required this.inkMuted,
    required this.accent,
    required this.brandMark,
    required this.brandGold,
    required this.coverGrounds,
    required this.shadowBase,
    required this.dark,
  });

  static ShellPalette of(BuildContext context) =>
      ShadTheme.of(context).brightness == Brightness.dark ? _dark : _light;

  static const _light = ShellPalette._(
    canvas: ShosaiTokens.colorLightCanvas,
    chrome: ShosaiTokens.colorLightChrome,
    surface: ShosaiTokens.colorLightSurface,
    surfaceSunken: ShosaiTokens.colorLightSurfaceSunken,
    hover: ShosaiTokens.colorLightHover,
    line: ShosaiTokens.colorLightLine,
    ink: ShosaiTokens.colorLightInk,
    inkMuted: ShosaiTokens.colorLightInkMuted,
    accent: ShosaiTokens.colorLightAccent,
    brandMark: ShosaiTokens.colorLightBrandMark,
    brandGold: ShosaiTokens.colorBrandGold,
    coverGrounds: _coverGrounds,
    shadowBase: ShosaiTokens.colorLightInk,
    dark: false,
  );

  static const _dark = ShellPalette._(
    canvas: ShosaiTokens.colorDarkCanvas,
    chrome: ShosaiTokens.colorDarkChrome,
    surface: ShosaiTokens.colorDarkSurface,
    surfaceSunken: ShosaiTokens.colorDarkSurfaceSunken,
    hover: ShosaiTokens.colorDarkHover,
    line: ShosaiTokens.colorDarkLine,
    ink: ShosaiTokens.colorDarkInk,
    inkMuted: ShosaiTokens.colorDarkInkMuted,
    accent: ShosaiTokens.colorDarkAccent,
    brandMark: ShosaiTokens.colorDarkBrandMark,
    brandGold: ShosaiTokens.colorBrandGold,
    coverGrounds: _coverGrounds,
    shadowBase: ShosaiTokens.colorDarkShelf,
    dark: true,
  );

  /// The five fixed grounds of generated covers; they never change with the
  /// app theme.
  static const _coverGrounds = [
    ShosaiTokens.colorBrandNavy,
    ShosaiTokens.colorBrandCharcoal,
    ShosaiTokens.colorLightVermilion,
    ShosaiTokens.colorLightAccent,
    ShosaiTokens.colorLightSuccess,
  ];

  /// The library's ground.
  final Color canvas;

  /// The sidebar, rail and bottom bar: a shade deeper than [canvas].
  final Color chrome;

  /// Cards and the current sidebar entry.
  final Color surface;

  /// Progress tracks.
  final Color surfaceSunken;
  final Color hover;

  /// Decorative hairlines.
  final Color line;
  final Color ink;
  final Color inkMuted;

  /// The one interactive colour: the current place, focus rings, progress.
  final Color accent;
  final Color brandMark;
  final Color brandGold;
  final List<Color> coverGrounds;
  final Color shadowBase;
  final bool dark;

  /// The generated cover's ground for [title], stable across launches.
  Color coverGround(String title) {
    var hash = 0;
    for (final unit in title.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return coverGrounds[hash % coverGrounds.length];
  }

  /// `shadow-raised`: a card a millimetre off the paper.
  List<BoxShadow> get raised => [
    BoxShadow(
      color: shadowBase.withValues(alpha: dark ? .5 : .12),
      offset: const Offset(0, 1),
      blurRadius: 2,
    ),
    BoxShadow(
      color: (dark ? ink : shadowBase).withValues(alpha: .06),
      spreadRadius: 1,
    ),
  ];

  /// The small covers' shadow in Reading now and the rail.
  List<BoxShadow> get thumbShadow => [
    BoxShadow(
      color: shadowBase.withValues(alpha: .5),
      offset: const Offset(0, 2),
      blurRadius: 4,
      spreadRadius: -2,
    ),
  ];
}
