part of 'view.dart';

/// How a typographic cover sets its text at one size
/// (`docs/design-system.md`, LibraryBook; `sh-cover` in the components).
final class ShellCoverType {
  const ShellCoverType({
    required this.titleSize,
    required this.titleLineHeight,
    required this.padding,
    this.showAuthor = true,
  });

  /// A cover on the shelf.
  static const shelf = ShellCoverType(
    titleSize: 13,
    titleLineHeight: 17,
    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
  );

  /// A cover on a phone's three-column shelf.
  static const phoneShelf = ShellCoverType(
    titleSize: 11,
    titleLineHeight: 14,
    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
  );

  /// The Continue reading hero's 168 px cover.
  static const hero = ShellCoverType(
    titleSize: 17,
    titleLineHeight: 22,
    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
  );

  /// The hero's cover on a tablet.
  static const heroTablet = ShellCoverType(
    titleSize: 14,
    titleLineHeight: 18,
    padding: EdgeInsets.symmetric(horizontal: 11, vertical: 12),
  );

  /// The compact hero's 72 px cover, which drops the author.
  static const heroCompact = ShellCoverType(
    titleSize: 8,
    titleLineHeight: 10,
    padding: EdgeInsets.symmetric(horizontal: 7, vertical: 8),
    showAuthor: false,
  );

  final double titleSize;
  final double titleLineHeight;
  final EdgeInsets padding;
  final bool showAuthor;
}

/// A typographic cover for a book without its own: the title in the editorial
/// face and the author in small capitals on one of five fixed grounds chosen
/// by the title, under a `brand-gold` band, with a faint sheen.
///
/// Generated covers never change with the app theme. The text is decoration:
/// the book's title and author are always printed beside or under the cover,
/// so it is excluded from semantics and does not scale with the text size,
/// which would only push it out of the cover.
class ShellGeneratedCover extends StatelessWidget {
  const ShellGeneratedCover({
    super.key,
    required this.title,
    required this.author,
    required this.type,
  });

  static const double radius = 3;
  static const double bandWidth = 3;

  final String title;
  final String? author;
  final ShellCoverType type;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final author = this.author;
    return ExcludeSemantics(
      child: MediaQuery.withNoTextScaling(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.coverGround(title),
            borderRadius: BorderRadius.circular(radius),
            border: Border(
              top: BorderSide(color: palette.brandGold, width: bandWidth),
            ),
          ),
          position: DecorationPosition.background,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                // CSS's 100deg: from the spine towards the fore-edge.
                begin: const Alignment(-1, -.18),
                end: const Alignment(1, .18),
                colors: ShellPalette.coverSheen,
                stops: const [0, .3, 1],
              ),
            ),
            child: Padding(
              padding: type.padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      // A cover sets its text flush left whatever button it
                      // sits in.
                      textAlign: TextAlign.start,
                      overflow: TextOverflow.fade,
                      style: shellEditorialStyle(
                        type.titleSize,
                        type.titleLineHeight,
                      ).copyWith(color: ShellPalette.coverInk),
                    ),
                  ),
                  if (type.showAuthor && author != null)
                    Text(
                      author,
                      textAlign: TextAlign.start,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: shosaiInterfaceStyleForText(
                        shellInterfaceStyle(
                          10,
                          13,
                          weight: FontWeight.w500,
                        ).copyWith(
                          letterSpacing: .6,
                          color: ShellPalette.coverInk.withValues(alpha: .85),
                        ),
                        author,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A book's cover at 2:3 under [shadow]: its own image, or a
/// [ShellGeneratedCover] while it has none, is loading or failed to decode.
class ShellBookCoverFace extends StatelessWidget {
  const ShellBookCoverFace({
    super.key,
    required this.book,
    required this.cover,
    required this.type,
    required this.shadow,
    this.semanticLabel,
  });

  final FlutterLibraryBook book;
  final Uint8List? cover;
  final ShellCoverType type;
  final List<BoxShadow> shadow;

  /// The image's label when the book's own cover is shown.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bytes = cover;
    final radius = BorderRadius.circular(ShellGeneratedCover.radius);
    final generated = ShellGeneratedCover(
      title: book.title,
      author: book.author,
      type: type,
    );
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: radius, boxShadow: shadow),
        child: ClipRRect(
          borderRadius: radius,
          child: bytes == null || bytes.isEmpty
              ? generated
              : Semantics(
                  container: true,
                  image: true,
                  label: semanticLabel,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => generated,
                  ),
                ),
        ),
      ),
    );
  }
}

/// A format badge: `EPUB` or `PDF` in 10 px small capitals on
/// `surface-sunken`.
class ShellFormatBadge extends StatelessWidget {
  const ShellFormatBadge({super.key, required this.format});

  final FlutterBookFormat format;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: palette.surfaceSunken,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        format.name.toUpperCase(),
        maxLines: 1,
        style: shellInterfaceStyle(
          10,
          12,
          weight: FontWeight.w600,
        ).copyWith(letterSpacing: .4, color: palette.inkMuted),
      ),
    );
  }
}
