import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/shared/notice.dart';

/// Presents controller [Notice]s as non-blocking Sonner toasts.
///
/// This is the view-layer adapter for the Elm boundary: it observes immutable
/// model state, performs the transient presentation effect, and reports back by
/// dispatching consumption. It does not mutate model state.
class SonnerBridge extends StatefulWidget {
  const SonnerBridge({
    super.key,
    required this.notice,
    required this.onConsumed,
    required this.child,
  });

  final Notice? notice;
  final ValueChanged<int> onConsumed;
  final Widget child;

  @override
  State<SonnerBridge> createState() => _SonnerBridgeState();
}

class _SonnerBridgeState extends State<SonnerBridge> {
  int? _presentedId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _present();
  }

  @override
  void didUpdateWidget(SonnerBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.notice?.id != oldWidget.notice?.id) {
      _present();
    }
  }

  void _present() {
    final notice = widget.notice;
    if (notice == null || notice.id == _presentedId) return;
    final sonner = ShadSonner.maybeOf(context);
    if (sonner == null) return;
    _presentedId = notice.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      sonner.show(switch (notice.kind) {
        NoticeKind.destructive => ShadToast.destructive(
          title: Text(notice.message),
        ),
        NoticeKind.info ||
        NoticeKind.success => ShadToast(title: Text(notice.message)),
      });
      widget.onConsumed(notice.id);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
