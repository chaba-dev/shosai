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
    final contentWidth = math.min(520.0, MediaQuery.sizeOf(context).width - 96);
    return ShadDialog(
      title: const Text('Associate highlights?'),
      actionsAxis: MediaQuery.textScalerOf(context).scale(1) > 1.3
          ? Axis.vertical
          : Axis.horizontal,
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
  const _NoteDialog({required this.initialValue, required this.title});
  final String? initialValue;
  final String title;
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
  Widget build(BuildContext context) => ShadDialog(
    title: Text(widget.title),
    actionsAxis: MediaQuery.textScalerOf(context).scale(1) > 1.3
        ? Axis.vertical
        : Axis.horizontal,
    actions: [
      ShadButton.outline(
        height: shosaiShadButtonHeight(context),
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      ShadButton(
        height: shosaiShadButtonHeight(context),
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('Save'),
      ),
    ],
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: math.min(360, MediaQuery.sizeOf(context).width - 96),
      ),
      child: ShadInput(
        controller: controller,
        autofocus: true,
        minLines: 3,
        maxLines: 6,
      ),
    ),
  );
}
