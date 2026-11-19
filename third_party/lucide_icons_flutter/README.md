# Lucide icons, standard weight only

Shōsai resolves [lucide_icons_flutter 3.1.19](https://pub.dev/packages/lucide_icons_flutter/versions/3.1.19)
to this local copy for all builds. The package name, standard font, and standard
icon definitions are unchanged, including their right-to-left variants. The
six unused weighted fonts and their Dart constants are omitted, so a future
reference to a removed icon fails at compile time instead of rendering a
missing glyph.

To update the pin, start from the published package. Copy `assets/lucide.ttf`
unchanged and update its version and checksum in `assets/fonts/README.md`.
Copy the wrapper's `LICENSE`, then append the complete [Lucide license](https://github.com/lucide-icons/lucide/blob/1.41.0/LICENSE)
for the bundled icon version, including its Feather notice. From
`lib/lucide_icons.dart`, keep the
`@staticIconProvider` class and only definitions whose `fontFamily` is
`'Lucide'`; drop the inline SVG preview comments. Keep the font declaration
for `Lucide` and no other families. Update the version here and in the local
pubspec, then run `flutter pub get` and verify the wrapper, Lucide, and Feather
notices in a packaged bundle's `NOTICES.Z`.

Upstream 3.1.19 archive SHA-256:
`3d06144ccc67c29fd080704ee59b6e1927f67654a848443eceb130b2e425e080`.
