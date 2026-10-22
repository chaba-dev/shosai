part of 'view.dart';

/// `ed-display`: the screen title, 40/44 on desktop, 34/38 on tablet and
/// 30/34 on phone.
TextStyle shellScreenTitleStyle(ShellLayout layout) => switch (layout) {
  ShellLayout.desktop => shellEditorialStyle(40, 44),
  ShellLayout.tablet => shellEditorialStyle(34, 38),
  ShellLayout.phone => shellEditorialStyle(30, 34),
}.copyWith(letterSpacing: -.6);

/// A library-side place other than the Library: its title and what to do.
///
/// Notes, Bookmarks and Search list across all books once RFD 6's notes
/// surface and search palette exist; until then each place says what will
/// appear there and how to make it.
class ShellPlacePage extends StatelessWidget {
  const ShellPlacePage({super.key, required this.layout, required this.place});

  final ShellLayout layout;
  final ShellPlace place;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final (heading, body) = switch (place) {
      ShellPlace.notes => (
        l10n.shellNotesEmptyHeading,
        l10n.shellNotesEmptyBody,
      ),
      ShellPlace.bookmarks => (
        l10n.shellBookmarksEmptyHeading,
        l10n.shellBookmarksEmptyBody,
      ),
      ShellPlace.search => (
        l10n.shellSearchEmptyHeading,
        l10n.shellSearchEmptyBody,
      ),
      ShellPlace.library => ('', ''),
    };
    final gutter = layout == ShellLayout.phone ? 16.0 : 48.0;
    return ColoredBox(
      color: palette.canvas,
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, gutter * .75, gutter, gutter),
          children: [
            Semantics(
              header: true,
              child: Text(
                shellPlaceLabel(l10n, place),
                style: shellScreenTitleStyle(
                  layout,
                ).copyWith(color: palette.ink),
              ),
            ),
            const SizedBox(height: 48),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  spacing: 8,
                  children: [
                    Text(
                      heading,
                      textAlign: TextAlign.center,
                      style: shellEditorialStyle(
                        22,
                        26,
                      ).copyWith(color: palette.ink),
                    ),
                    Text(
                      body,
                      textAlign: TextAlign.center,
                      style: shosaiInterfaceStyleForText(
                        shellInterfaceStyle(
                          14,
                          20,
                        ).copyWith(color: palette.inkMuted),
                        body,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
