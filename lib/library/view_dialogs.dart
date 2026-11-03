part of 'view.dart';

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.layout,
    required this.model,
    required this.onChanged,
    required this.onConnections,
    required this.onRetry,
  });

  final ShellLayout layout;
  final LibraryModel model;
  final ValueChanged<FlutterReaderSettings> onChanged;
  final VoidCallback? onConnections;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final value = model.settings;
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final gutter = layout == ShellLayout.phone ? 16.0 : 48.0;
    return ColoredBox(
      color: palette.canvas,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, gutter * .75, gutter, gutter),
          children: [
            Semantics(
              header: true,
              child: Text(
                AppLocalizations.of(context).filterSettings,
                style: shellScreenTitleStyle(
                  layout,
                ).copyWith(color: palette.ink),
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (model.failure == LibraryFailure.settings)
                      ShadAlert.destructive(
                        title: Text(
                          AppLocalizations.of(context).noticeSettingsSaveFailed,
                        ),
                        description: ShadButton.outline(
                          onPressed: onRetry,
                          child: Text(
                            AppLocalizations.of(context).libraryRetry,
                          ),
                        ),
                      ),
                    if (onConnections != null)
                      _SettingField(
                        label: AppLocalizations.of(context).libraryConnections,
                        child: ShadButton.outline(
                          height: shosaiShadButtonHeight(context),
                          onPressed: model.busy ? null : onConnections,
                          child: Text(
                            AppLocalizations.of(context).manageConnections,
                          ),
                        ),
                      ),
                    if (value == null)
                      const Center(child: CircularProgressIndicator())
                    else ...[
                      _SettingField(
                        label: l10n.settingsReaderTheme,
                        child: ShadSelect<String>(
                          initialValue: value.theme,
                          options: [
                            ShadOption(
                              value: 'light',
                              child: Text(l10n.readerThemeLight),
                            ),
                            ShadOption(
                              value: 'sepia',
                              child: Text(l10n.readerThemeSepia),
                            ),
                            ShadOption(
                              value: 'dark',
                              child: Text(l10n.readerThemeDark),
                            ),
                          ],
                          selectedOptionBuilder: (context, theme) =>
                              Text(switch (theme) {
                                'sepia' => l10n.readerThemeSepia,
                                'dark' => l10n.readerThemeDark,
                                _ => l10n.readerThemeLight,
                              }),
                          onChanged: (theme) {
                            if (theme != null) {
                              onChanged(value.copyWith(theme: theme));
                            }
                          },
                        ),
                      ),
                      _SettingSwitch(
                        title: l10n.settingsContinuousReading,
                        // A vertical chapter's columns would scroll sideways, so it
                        // reads in pages whatever this says.
                        subtitle: l10n.settingsContinuousReadingHint,
                        value: value.continuous,
                        onChanged: (continuous) =>
                            onChanged(value.copyWith(continuous: continuous)),
                      ),
                      _SettingField(
                        label: l10n.settingsEpubTextSize,
                        child: ShadSlider(
                          min: 12,
                          max: 32,
                          divisions: 10,
                          initialValue: value.epubFontSize.clamp(12, 32),
                          label: value.epubFontSize.round().toString(),
                          onChanged: (fontSize) =>
                              onChanged(value.copyWith(epubFontSize: fontSize)),
                        ),
                      ),
                      _SettingField(
                        label: l10n.settingsEpubLineSpacing,
                        child: ShadSlider(
                          min: 1,
                          max: 3,
                          divisions: 8,
                          initialValue: value.epubLineSpacing.clamp(1, 3),
                          label: value.epubLineSpacing.toStringAsFixed(2),
                          onChanged: (lineSpacing) => onChanged(
                            value.copyWith(epubLineSpacing: lineSpacing),
                          ),
                        ),
                      ),
                      _SettingField(
                        label: l10n.settingsPdfZoom,
                        child: ShadSelect<double>(
                          initialValue: value.pdfZoom,
                          options: [
                            ShadOption(
                              value: 0,
                              child: Text(l10n.readerFitPage),
                            ),
                            ShadOption(
                              value: -1,
                              child: Text(l10n.readerFitWidth),
                            ),
                            const ShadOption(value: 1, child: Text('100%')),
                            const ShadOption(value: 1.5, child: Text('150%')),
                            const ShadOption(value: 2, child: Text('200%')),
                            if (!const [
                              0.0,
                              -1.0,
                              1.0,
                              1.5,
                              2.0,
                            ].contains(value.pdfZoom))
                              ShadOption(
                                value: value.pdfZoom,
                                child: Text(
                                  l10n.settingsCustomZoom(
                                    (value.pdfZoom * 100).round(),
                                  ),
                                ),
                              ),
                          ],
                          selectedOptionBuilder: (context, pdfZoom) =>
                              Text(_pdfZoomLabel(pdfZoom, l10n)),
                          onChanged: (pdfZoom) {
                            if (pdfZoom != null) {
                              onChanged(value.copyWith(pdfZoom: pdfZoom));
                            }
                          },
                        ),
                      ),
                    ],
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

String _pdfZoomLabel(double pdfZoom, AppLocalizations l10n) =>
    switch (pdfZoom) {
      0 => l10n.readerFitPage,
      -1 => l10n.readerFitWidth,
      1 => '100%',
      1.5 => '150%',
      2 => '200%',
      _ => l10n.settingsCustomZoom((pdfZoom * 100).round()),
    };

class _SettingField extends StatelessWidget {
  const _SettingField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ShadTheme.of(context).textTheme.small),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onChanged == null ? null : () => onChanged!(!value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: theme.textTheme.muted.fallback(
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          ShadSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// A full-width dialog choice that behaves like a button.
///
/// It is a [ShadCard] rather than a `ShadButton` because [ShadDialog] measures
/// its content with unbounded width: a button's fixed height and infinite
/// minimum width clip and overflow the two-line label. The card carries the
/// icon, title and subtitle, while the surrounding [Semantics] and
/// [FocusableActionDetector] supply the button role, the enabled state, a
/// visible focus ring and Enter/Space activation through [ActivateIntent].
class _DialogActionTile extends StatefulWidget {
  const _DialogActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;

  @override
  State<_DialogActionTile> createState() => _DialogActionTileState();
}

class _DialogActionTileState extends State<_DialogActionTile> {
  bool _focused = false;

  void _activate() => widget.onPressed();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final radius = theme.cardTheme.radius ?? theme.radius;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        container: true,
        button: true,
        enabled: true,
        onTap: _activate,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (focused) => setState(() => _focused = focused),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _activate();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: _activate,
            child: Container(
              foregroundDecoration: _focused
                  ? BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.ring,
                        width: 2,
                      ),
                      borderRadius: radius,
                    )
                  : null,
              child: ShadCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(widget.icon),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title),
                          Text(
                            widget.subtitle,
                            style: theme.textTheme.muted.fallback(
                              color: theme.colorScheme.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
