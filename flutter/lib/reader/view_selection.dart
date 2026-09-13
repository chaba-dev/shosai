part of 'view.dart';

class _SelectionActions extends StatelessWidget {
  const _SelectionActions({
    required this.model,
    required this.dispatch,
    required this.focusNode,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final copyEnabled = model.selectedText != null;
    final persistenceEnabled =
        !model.busy &&
        !model.relayoutBusy &&
        model.annotationsReady &&
        model.annotationOperations.isEmpty;
    return Semantics(
      key: const ValueKey('selection-actions'),
      label: 'Selection actions',
      container: true,
      child: ShadCard(
        padding: const EdgeInsets.all(8),
        child: SingleChildScrollView(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              ShadButton.ghost(
                focusNode: copyEnabled ? focusNode : null,
                onPressed: !copyEnabled
                    ? null
                    : () => dispatch(const ReaderSelectionCopyRequested()),
                child: const Text('Copy'),
              ),
              for (final color in FlutterHighlightColor.values)
                ShadButton(
                  focusNode:
                      !copyEnabled &&
                          persistenceEnabled &&
                          color == FlutterHighlightColor.yellow
                      ? focusNode
                      : null,
                  onPressed: !persistenceEnabled
                      ? null
                      : () => dispatch(ReaderSelectionCommitted(color: color)),
                  child: Text(_colorName(color)),
                ),
              ShadButton.ghost(
                onPressed: !persistenceEnabled
                    ? null
                    : () => dispatch(const ReaderSelectionNoteRequested()),
                child: const Text('Add note'),
              ),
              ShadButton.ghost(
                focusNode: !copyEnabled && !persistenceEnabled
                    ? focusNode
                    : null,
                onPressed: () => dispatch(const ReaderSelectionCancelled()),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Rect _selectionActionTarget(
  FlutterSelectionSurface surface,
  ReaderModel model,
  Size viewport,
  BoxFit fit,
) {
  final first = model.anchor!;
  final second = model.focus!;
  final start = first < second ? first : second;
  final end = first < second ? second : first;
  Rect? selected;
  for (final endpoint in surface.endpoints) {
    final rangeStart = endpoint.rangeStart.toInt();
    final rangeEnd = endpoint.rangeEnd.toInt();
    final focusedOffset = second == end ? end - 1 : start;
    final include = model.keyboardActionInvocation
        ? rangeStart <= focusedOffset && focusedOffset < rangeEnd
        : rangeStart < end && start < rangeEnd;
    if (!include) {
      continue;
    }
    final rect = endpoint.rect;
    final area = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
    selected = selected?.expandToInclude(area) ?? area;
  }
  if (selected == null) return Offset.zero & Size.zero;
  final transform = SurfaceTransform.create(
    fit,
    Size(surface.width, surface.height),
    viewport,
  );
  return transform.toDestinationRect(selected);
}

class _SelectionActionsLayout extends SingleChildLayoutDelegate {
  const _SelectionActionsLayout({required this.target});

  static const _gap = 8.0;
  final Rect target;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - _gap * 2),
        maxHeight: math.max(0, constraints.maxHeight - _gap * 2),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = math.max(_gap, size.width - childSize.width - _gap);
    final left = (target.center.dx - childSize.width / 2).clamp(_gap, maxLeft);
    final above = target.top - childSize.height - _gap;
    final below = target.bottom + _gap;
    final maxTop = math.max(_gap, size.height - childSize.height - _gap);
    final top = (above >= _gap ? above : below).clamp(_gap, maxTop);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_SelectionActionsLayout oldDelegate) =>
      target != oldDelegate.target;
}

class _ReachableSelectableSurface extends StatelessWidget {
  const _ReachableSelectableSurface({
    required this.presentationKey,
    required this.document,
    required this.settings,
    required this.surface,
    required this.image,
    required this.model,
    required this.dispatch,
  });

  final Key presentationKey;
  final FlutterDocumentSummary document;
  final FlutterReaderSettings? settings;
  final FlutterSelectionSurface surface;
  final ui.Image? image;
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final fit = _readerFit(document.format, settings);
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget content(Size size) => SizedBox.fromSize(
          size: size,
          child: _SelectableSurface(
            key: ValueKey((
              model.generation,
              model.unit,
              surface.handle.registry,
              surface.handle.id,
            )),
            surface: surface,
            image: image,
            model: model,
            fit: fit,
            dispatch: dispatch,
          ),
        );
        if (document.format == FlutterBookFormat.epub &&
            settings?.continuous == true) {
          return KeyedSubtree(
            key: presentationKey,
            child: SingleChildScrollView(
              key: ValueKey(
                'reader-vertical-scroll-${model.generation}-${model.unit}',
              ),
              child: content(
                Size(
                  constraints.maxWidth,
                  math.max(constraints.maxHeight, surface.height),
                ),
              ),
            ),
          );
        }
        if (document.format == FlutterBookFormat.epub ||
            fit == BoxFit.contain) {
          return KeyedSubtree(
            key: presentationKey,
            child: content(constraints.biggest),
          );
        }
        final natural = fit == BoxFit.fitWidth
            ? Size(
                constraints.maxWidth,
                constraints.maxWidth * surface.height / surface.width,
              )
            : Size(surface.width, surface.height);
        final reachable = Size(
          math.max(constraints.maxWidth, natural.width),
          math.max(constraints.maxHeight, natural.height),
        );
        final vertical = SingleChildScrollView(
          key: ValueKey(
            'reader-vertical-scroll-${model.generation}-${model.unit}',
          ),
          child: content(reachable),
        );
        if (fit == BoxFit.fitWidth) {
          return KeyedSubtree(key: presentationKey, child: vertical);
        }
        return KeyedSubtree(
          key: presentationKey,
          child: SingleChildScrollView(
            key: ValueKey(
              'reader-horizontal-scroll-${model.generation}-${model.unit}',
            ),
            scrollDirection: Axis.horizontal,
            child: vertical,
          ),
        );
      },
    );
  }
}

class _SelectableSurface extends StatefulWidget {
  const _SelectableSurface({
    super.key,
    required this.surface,
    required this.image,
    required this.model,
    required this.fit,
    required this.dispatch,
  });

  final FlutterSelectionSurface surface;
  final ui.Image? image;
  final ReaderModel model;
  final BoxFit fit;
  final void Function(ReaderMessage) dispatch;

  @override
  State<_SelectableSurface> createState() => _SelectableSurfaceState();
}

class _SelectableSurfaceState extends State<_SelectableSurface> {
  int? _touchPointer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final transform = SurfaceTransform.create(
          widget.fit,
          Size(widget.surface.width, widget.surface.height),
          constraints.biggest,
        );
        FlutterSelectionEndpoint? endpoint(
          Offset position, {
          bool nearest = false,
        }) {
          if (!nearest && !transform.destination.contains(position)) {
            return null;
          }
          final source = transform.toSource(position, clamp: nearest);
          for (final endpoint in widget.surface.endpoints) {
            final rect = endpoint.rect;
            if (Rect.fromLTRB(
              rect.left,
              rect.top,
              rect.right,
              rect.bottom,
            ).contains(source)) {
              return endpoint;
            }
          }
          if (!nearest || widget.surface.endpoints.isEmpty) return null;
          FlutterSelectionEndpoint? closest;
          double? distance;
          for (final endpoint in widget.surface.endpoints) {
            final rect = endpoint.rect;
            final dx = source.dx.clamp(rect.left, rect.right) - source.dx;
            final dy = source.dy.clamp(rect.top, rect.bottom) - source.dy;
            final candidate = dx * dx + dy * dy;
            if (distance == null || candidate < distance) {
              closest = endpoint;
              distance = candidate;
            }
          }
          return closest;
        }

        return Listener(
          key: const ValueKey('reader-selection-surface'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (event.kind == ui.PointerDeviceKind.touch) {
              _touchPointer ??= event.pointer;
              return;
            }
            final primary =
                event.kind != ui.PointerDeviceKind.mouse ||
                (event.buttons & 1) != 0;
            if (!primary) return;
            final value = endpoint(event.localPosition);
            if (value == null) {
              widget.dispatch(
                ReaderSelectionPointerPressedOutside(event.pointer),
              );
            } else {
              final source = transform.toSource(event.localPosition);
              widget.dispatch(
                ReaderSelectionPointerStarted(
                  event.pointer,
                  value.offset.toInt(),
                  rangeStart: value.rangeStart.toInt(),
                  rangeEnd: value.rangeEnd.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            }
          },
          onPointerMove: (event) {
            if (event.kind == ui.PointerDeviceKind.touch) return;
            final value = endpoint(event.localPosition, nearest: true);
            if (value != null) {
              final source = transform.toSource(
                event.localPosition,
                clamp: true,
              );
              widget.dispatch(
                ReaderSelectionPointerMoved(
                  event.pointer,
                  value.offset.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            }
          },
          onPointerUp: (event) {
            if (event.kind != ui.PointerDeviceKind.touch) {
              widget.dispatch(ReaderSelectionPointerEnded(event.pointer));
            }
          },
          onPointerCancel: (event) {
            if (event.kind != ui.PointerDeviceKind.touch ||
                _touchPointer == event.pointer) {
              widget.dispatch(ReaderSelectionPointerCancelled(event.pointer));
            }
            if (_touchPointer == event.pointer) _touchPointer = null;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (details) {
              final pointer = _touchPointer;
              final value = endpoint(details.localPosition);
              if (pointer == null || value == null) return;
              final source = transform.toSource(details.localPosition);
              widget.dispatch(
                ReaderSelectionPointerStarted(
                  pointer,
                  value.offset.toInt(),
                  rangeStart: value.rangeStart.toInt(),
                  rangeEnd: value.rangeEnd.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            },
            onLongPressMoveUpdate: (details) {
              final pointer = _touchPointer;
              final value = endpoint(details.localPosition, nearest: true);
              if (pointer == null || value == null) return;
              final source = transform.toSource(
                details.localPosition,
                clamp: true,
              );
              widget.dispatch(
                ReaderSelectionPointerMoved(
                  pointer,
                  value.offset.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            },
            onLongPressEnd: (_) {
              final pointer = _touchPointer;
              if (pointer != null) {
                widget.dispatch(ReaderSelectionPointerEnded(pointer));
              }
              _touchPointer = null;
            },
            onLongPressCancel: () {
              final pointer = _touchPointer;
              if (pointer != null) {
                widget.dispatch(ReaderSelectionPointerCancelled(pointer));
              }
              _touchPointer = null;
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  key: const ValueKey('reader-page-paint'),
                  child: KeyedSubtree(
                    key: ValueKey('reader-fit-${widget.fit.name}'),
                    child: CustomPaint(
                      painter: _PageContentPainter(
                        image: widget.image,
                        surface: widget.surface,
                        backgroundColor: pageColors(
                          ShadTheme.of(context).colorScheme,
                        ).background,
                        foregroundColor: pageColors(
                          ShadTheme.of(context).colorScheme,
                        ).foreground,
                        recolorImage:
                            widget.model.document?.format ==
                            FlutterBookFormat.epub,
                        fit: widget.fit,
                      ),
                    ),
                  ),
                ),
                CustomPaint(
                  painter: PagePainter(
                    image: widget.image,
                    surface: widget.surface,
                    backgroundColor: pageColors(
                      ShadTheme.of(context).colorScheme,
                    ).background,
                    foregroundColor: pageColors(
                      ShadTheme.of(context).colorScheme,
                    ).foreground,
                    recolorImage:
                        widget.model.document?.format == FlutterBookFormat.epub,
                    fit: widget.fit,
                    anchor: widget.model.anchor,
                    focus: widget.model.focus,
                    savedSelections: widget.model.savedSelections,
                    annotations: widget.model.annotations
                        .where((item) => item.unit.toInt() == widget.model.unit)
                        .toList(growable: false),
                    currentUnit: widget.model.unit,
                    paintContent: false,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
