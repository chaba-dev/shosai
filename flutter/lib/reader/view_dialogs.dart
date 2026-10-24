part of 'view.dart';

class _AnnotationAssociationDialog extends StatefulWidget {
  const _AnnotationAssociationDialog({required this.page});

  final AnnotationAssociationPage page;

  @override
  State<_AnnotationAssociationDialog> createState() =>
      _AnnotationAssociationDialogState();
}

class _AnnotationAssociationDialogState
    extends State<_AnnotationAssociationDialog> {
  FlutterAnnotationAssociationSource? _selected;

  @override
  Widget build(BuildContext context) {
    final contentWidth = _dialogContentWidth(context, 520);
    return ShadDialog(
      title: const Text('Associate highlights?'),
      // Large text stacks the actions; otherwise Shad lays them in a row, or
      // stacks them at full width on a phone. Forcing a row there gives the
      // full-width buttons an unbounded width and the dialog never lays out.
      actionsAxis: MediaQuery.textScalerOf(context).scale(1) > 1.3
          ? Axis.vertical
          : null,
      actions: [
        ShadButton.outline(
          height: shosaiShadButtonHeight(context),
          onPressed: () =>
              Navigator.pop(context, const AnnotationAssociationCancelled()),
          child: const Text('Cancel'),
        ),
        ShadButton(
          height: shosaiShadButtonHeight(context),
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(
                  context,
                  AnnotationAssociationSelected(_selected!),
                ),
          child: const Text('Associate'),
        ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: contentWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose the earlier document version this file replaces. '
              'Its notes and highlights will be shared with this version. '
              'Highlights whose location cannot be recovered will remain marked '
              'as ambiguous or unavailable.',
            ),
            const SizedBox(height: 12),
            ShadRadioGroup<FlutterAnnotationAssociationSource>(
              initialValue: _selected,
              axis: Axis.vertical,
              crossAxisAlignment: WrapCrossAlignment.start,
              onChanged: (value) => setState(() => _selected = value),
              items: widget.page.sources
                  .map(
                    (source) => SizedBox(
                      width: contentWidth,
                      child: ShadRadio<FlutterAnnotationAssociationSource>(
                        value: source,
                        label: Text(source.localPath),
                        sublabel: Text(
                          '${source.liveAnnotations} saved highlight'
                          '${source.liveAnnotations == BigInt.one ? '' : 's'} · '
                          '${source.fingerprintAlgorithm} '
                          '${_fingerprintLabel(source.fingerprint)}',
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
            if (widget.page.canGoBack || widget.page.canGoForward) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                children: [
                  if (widget.page.canGoBack)
                    ShadButton.ghost(
                      height: shosaiShadButtonHeight(context),
                      onPressed: () => Navigator.pop(
                        context,
                        const AnnotationAssociationPreviousPage(),
                      ),
                      child: const Text('Previous'),
                    ),
                  if (widget.page.canGoForward)
                    ShadButton.ghost(
                      height: shosaiShadButtonHeight(context),
                      onPressed: () => Navigator.pop(
                        context,
                        const AnnotationAssociationNextPage(),
                      ),
                      child: const Text('Next'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _fingerprintLabel(Uint8List fingerprint) {
  final shown = fingerprint
      .take(6)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'));
  return shown.join();
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initialValue, required this.kind});
  final String? initialValue;

  /// The page note or book note being written, or null for a highlight's
  /// note.
  final FlutterNoteKind? kind;
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.initialValue,
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ShadDialog(
      title: Text(switch (widget.kind) {
        FlutterNoteKind.page => l10n.readerPageNoteTitle,
        FlutterNoteKind.book => l10n.readerBookNoteTitle,
        null => l10n.readerHighlightNoteTitle,
      }),
      // Large text stacks the actions; otherwise Shad lays them in a row, or
      // stacks them at full width on a phone. Forcing a row there gives the
      // full-width buttons an unbounded width and the dialog never lays out.
      actionsAxis: MediaQuery.textScalerOf(context).scale(1) > 1.3
          ? Axis.vertical
          : null,
      actions: [
        ShadButton.outline(
          height: shosaiShadButtonHeight(context),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.readerNoteCancel),
        ),
        ShadButton(
          height: shosaiShadButtonHeight(context),
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(l10n.readerNoteSave),
        ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _dialogContentWidth(context, 360),
        ),
        child: ShadInput(
          key: const ValueKey('reader-note-editor-field'),
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
        ),
      ),
    );
  }
}

/// The width of a reader dialog's content, at most [max].
///
/// Shad's dialog is at most 512 px wide inside 24 px of padding on each side
/// (its defaults, which the app keeps), so the content never exceeds that.
/// Below Shad's small breakpoint the dialog stacks its actions at that full
/// width, and the content takes the same width instead of stopping short.
double _dialogContentWidth(BuildContext context, double max) {
  final width = MediaQuery.sizeOf(context).width;
  final inner = math.min(width, 512.0) - 48;
  if (width < ShadTheme.of(context).breakpoints.sm.value) return inner;
  return math.min(max, inner);
}
