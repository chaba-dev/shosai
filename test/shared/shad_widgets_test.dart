import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';

void main() {
  Widget app(Widget child) => ShadApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('exposes an accessible tooltip and invokes its callback', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      app(
        ShadIconAction(
          tooltip: 'Refresh library',
          onPressed: () => taps += 1,
          icon: const Icon(LucideIcons.refreshCw),
        ),
      ),
    );

    expect(find.byTooltip('Refresh library'), findsOneWidget);
    await tester.tap(find.byType(ShadIconButton));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('is disabled when no callback is provided', (tester) async {
    await tester.pumpWidget(
      app(
        const ShadIconAction(
          tooltip: 'Cancel operation',
          onPressed: null,
          icon: Icon(LucideIcons.x),
        ),
      ),
    );

    expect(find.byTooltip('Cancel operation'), findsOneWidget);
    expect(
      tester.widget<ShadIconButton>(find.byType(ShadIconButton)).onPressed,
      isNull,
    );
  });
}
