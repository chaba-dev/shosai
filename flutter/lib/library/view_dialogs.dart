part of 'view.dart';

Future<FlutterReaderSettings?> _settingsDialog(
  BuildContext context,
  FlutterReaderSettings initial, {
  required Future<T?> Function<T>(WidgetBuilder builder) showOwnedDialog,
}) async {
  var value = initial;
  final result = await showOwnedDialog<FlutterReaderSettings>(
    (context) => StatefulBuilder(
      builder: (context, setState) => ShadDialog(
        title: const Text('Reader settings'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ShadButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Save'),
          ),
        ],
        child: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingField(
                  label: 'Reader theme',
                  child: ShadSelect<String>(
                    initialValue: value.theme,
                    options: const [
                      ShadOption(value: 'light', child: Text('Light')),
                      ShadOption(value: 'sepia', child: Text('Sepia')),
                      ShadOption(value: 'dark', child: Text('Dark')),
                    ],
                    selectedOptionBuilder: (context, theme) =>
                        Text(switch (theme) {
                          'light' => 'Light',
                          'sepia' => 'Sepia',
                          'dark' => 'Dark',
                          _ => theme,
                        }),
                    onChanged: (theme) {
                      if (theme != null) {
                        setState(
                          () => value = FlutterReaderSettings(
                            continuous: value.continuous,
                            theme: theme,
                            epubFontSize: value.epubFontSize,
                            epubLineSpacing: value.epubLineSpacing,
                            pdfZoom: value.pdfZoom,
                          ),
                        );
                      }
                    },
                  ),
                ),
                _SettingSwitch(
                  title: 'Continuous reading',
                  value: value.continuous,
                  onChanged: (continuous) => setState(
                    () => value = FlutterReaderSettings(
                      continuous: continuous,
                      theme: value.theme,
                      epubFontSize: value.epubFontSize,
                      epubLineSpacing: value.epubLineSpacing,
                      pdfZoom: value.pdfZoom,
                    ),
                  ),
                ),
                _SettingField(
                  label: 'EPUB text size',
                  child: ShadSlider(
                    min: 12,
                    max: 32,
                    divisions: 10,
                    initialValue: value.epubFontSize.clamp(12, 32),
                    label: value.epubFontSize.round().toString(),
                    onChanged: (fontSize) => setState(
                      () => value = FlutterReaderSettings(
                        continuous: value.continuous,
                        theme: value.theme,
                        epubFontSize: fontSize,
                        epubLineSpacing: value.epubLineSpacing,
                        pdfZoom: value.pdfZoom,
                      ),
                    ),
                  ),
                ),
                _SettingField(
                  label: 'EPUB line spacing',
                  child: ShadSlider(
                    min: 1,
                    max: 3,
                    divisions: 8,
                    initialValue: value.epubLineSpacing.clamp(1, 3),
                    label: value.epubLineSpacing.toStringAsFixed(2),
                    onChanged: (lineSpacing) => setState(
                      () => value = FlutterReaderSettings(
                        continuous: value.continuous,
                        theme: value.theme,
                        epubFontSize: value.epubFontSize,
                        epubLineSpacing: lineSpacing,
                        pdfZoom: value.pdfZoom,
                      ),
                    ),
                  ),
                ),
                _SettingField(
                  label: 'PDF zoom',
                  child: ShadSelect<double>(
                    initialValue: value.pdfZoom,
                    options: [
                      const ShadOption(value: 0, child: Text('Fit page')),
                      const ShadOption(value: -1, child: Text('Fit width')),
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
                            '${(value.pdfZoom * 100).round()}% (custom)',
                          ),
                        ),
                    ],
                    selectedOptionBuilder: (context, pdfZoom) =>
                        Text(_pdfZoomLabel(pdfZoom)),
                    onChanged: (pdfZoom) {
                      if (pdfZoom != null) {
                        setState(
                          () => value = FlutterReaderSettings(
                            continuous: value.continuous,
                            theme: value.theme,
                            epubFontSize: value.epubFontSize,
                            epubLineSpacing: value.epubLineSpacing,
                            pdfZoom: pdfZoom,
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return result;
}

String _pdfZoomLabel(double pdfZoom) => switch (pdfZoom) {
  0 => 'Fit page',
  -1 => 'Fit width',
  1 => '100%',
  1.5 => '150%',
  2 => '200%',
  _ => '${(pdfZoom * 100).round()}% (custom)',
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

class _DialogActionTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: ShadCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title),
                      Text(
                        subtitle,
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
    );
  }
}
