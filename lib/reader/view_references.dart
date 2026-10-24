part of 'view.dart';

/// Floats over the existing page; opening a peek never changes page layout.
class _ReaderReferenceOverlay extends StatelessWidget {
  const _ReaderReferenceOverlay({
    required this.peek,
    required this.layout,
    required this.dispatch,
  });

  final ReaderReferencePeek peek;
  final ShellLayout layout;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final phone = layout == ShellLayout.phone;
    final buttonHeight = math.max(
      ShosaiTokens.sizeTouchTarget,
      shosaiShadButtonHeight(context),
    );
    void close() => dispatch(const ReaderReferenceDismissed());
    final card = Semantics(
      key: const ValueKey('reader-reference-peek'),
      scopesRoute: true,
      namesRoute: true,
      label: l10n.readerReference,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: phone
              ? const BorderRadius.vertical(
                  top: Radius.circular(ShosaiTokens.radiusLg),
                )
              : BorderRadius.circular(ShosaiTokens.radiusMd),
          boxShadow: _readerModalShadow(palette),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phone)
              SizedBox(
                key: const ValueKey('reader-reference-drag-handle'),
                height: ShosaiTokens.sizeTouchTarget,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.lineStrong.withValues(alpha: .6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                padding: EdgeInsets.all(
                  phone ? ShosaiTokens.space4 : ShosaiTokens.space5,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.readerReference,
                      style: shellInterfaceStyle(
                        11,
                        16,
                        weight: FontWeight.w600,
                      ).copyWith(color: palette.inkMuted),
                    ),
                    const SizedBox(height: ShosaiTokens.space2),
                    Text(
                      peek.label.isEmpty
                          ? l10n.readerReferencePage(peek.unit + 1)
                          : peek.label,
                      style: shellEditorialStyle(
                        20,
                        26,
                      ).copyWith(color: palette.ink),
                    ),
                    const SizedBox(height: ShosaiTokens.space3),
                    Text(
                      peek.preview.isEmpty
                          ? l10n.readerReferenceNoPreview
                          : peek.preview,
                      key: const ValueKey('reader-reference-preview'),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: shellEditorialStyle(
                        15,
                        23,
                      ).copyWith(color: palette.ink),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                ShosaiTokens.space4,
                0,
                ShosaiTokens.space4,
                ShosaiTokens.space4,
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: ShosaiTokens.space2,
                runSpacing: ShosaiTokens.space2,
                children: [
                  ShadButton.ghost(
                    key: const ValueKey('reader-reference-close'),
                    height: buttonHeight,
                    onPressed: close,
                    child: Text(l10n.readerReferenceClose),
                  ),
                  ShadButton(
                    key: const ValueKey('reader-reference-go-to'),
                    height: buttonHeight,
                    autofocus: true,
                    onPressed: () =>
                        dispatch(const ReaderReferenceGoToRequested()),
                    child: Text(l10n.readerReferenceGoTo),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: FocusScope(
        autofocus: true,
        child: FocusTraversalGroup(
          child: Stack(
            children: [
              Positioned.fill(
                child: ModalBarrier(
                  key: const ValueKey('reader-reference-scrim'),
                  color: phone
                      ? ShosaiTokens.colorLightInverse.withValues(alpha: .28)
                      : null,
                  onDismiss: close,
                  semanticsLabel: l10n.readerReferenceClose,
                ),
              ),
              if (phone)
                Positioned.fill(
                  child: _ReaderPanelSheet(onDismiss: close, child: card),
                )
              else
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(ShosaiTokens.space4),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: card,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
