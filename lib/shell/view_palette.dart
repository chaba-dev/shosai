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
  // Japanese sets in the set's Japanese editorial face, as the CSS stack
  // `Literata, "Shippori Mincho"` does; the symbols and rarer ideographs
  // neither carries (circled and squared forms, Kangxi radicals, halfwidth
  // kana) still find the bundled Japanese interface face.
  fontFamilyFallback: const [
    ShosaiTokens.typeFamilyEditorialJapaneseFlutter,
    shosaiJapaneseInterfaceFontFamily,
  ],
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
    required this.controlRaised,
    required this.hover,
    required this.line,
    required this.lineStrong,
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
    controlRaised: ShosaiTokens.colorLightControlRaised,
    hover: ShosaiTokens.colorLightHover,
    line: ShosaiTokens.colorLightLine,
    lineStrong: ShosaiTokens.colorLightLineStrong,
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
    controlRaised: ShosaiTokens.colorDarkControlRaised,
    hover: ShosaiTokens.colorDarkHover,
    line: ShosaiTokens.colorDarkLine,
    lineStrong: ShosaiTokens.colorDarkLineStrong,
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

  /// The chosen segment of a segmented control.
  final Color controlRaised;
  final Color hover;

  /// Decorative hairlines.
  final Color line;

  /// Secondary buttons' borders.
  final Color lineStrong;

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

  /// `shadow-menu`: capsules and the chosen segment of a segmented control.
  List<BoxShadow> get menu => [
    BoxShadow(
      color: shadowBase.withValues(alpha: dark ? .7 : .35),
      offset: Offset(0, dark ? 12 : 8),
      blurRadius: dark ? 32 : 24,
      spreadRadius: dark ? -12 : -10,
    ),
    BoxShadow(
      color: (dark ? ink : shadowBase).withValues(alpha: .06),
      spreadRadius: 1,
    ),
  ];

  /// The ink of a generated cover's title and author, on every ground.
  static const Color coverInk = ShosaiTokens.colorLightOnInverse;

  /// The generated cover's sheen: a faint light from the spine, a faint shade
  /// at the fore-edge.
  static final List<Color> coverSheen = [
    ShosaiTokens.colorLightOnInverse.withValues(alpha: .12),
    ShosaiTokens.colorLightOnInverse.withValues(alpha: 0),
    ShosaiTokens.colorDarkShelf.withValues(alpha: .08),
  ];

  /// `shadow-cover` on the shelf: the covers stand off the paper.
  List<BoxShadow> get shelfCoverShadow => [
    BoxShadow(
      color: shadowBase.withValues(alpha: .6),
      offset: const Offset(0, 18),
      blurRadius: 22,
      spreadRadius: -16,
    ),
    BoxShadow(
      color: shadowBase.withValues(alpha: .35),
      offset: const Offset(0, 4),
      blurRadius: 8,
      spreadRadius: -5,
    ),
  ];

  /// The deep shadow under the Continue reading hero's cover.
  List<BoxShadow> get heroCoverShadow => [
    BoxShadow(
      color: shadowBase.withValues(alpha: .55),
      offset: const Offset(0, 24),
      blurRadius: 30,
      spreadRadius: -20,
    ),
    BoxShadow(
      color: shadowBase.withValues(alpha: .35),
      offset: const Offset(0, 6),
      blurRadius: 12,
      spreadRadius: -8,
    ),
  ];

  /// The hero: `shadow-raised` under a soft ambient shadow, the one lifted
  /// card on the library canvas.
  List<BoxShadow> get hero => [
    ...raised,
    BoxShadow(
      color: shadowBase.withValues(alpha: .35),
      offset: const Offset(0, 12),
      blurRadius: 30,
      spreadRadius: -24,
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
