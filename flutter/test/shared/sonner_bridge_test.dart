import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/shared/notice.dart';
import 'package:shosai_flutter/shared/sonner_bridge.dart';

void main() {
  testWidgets('presents a notice once and reports consumption', (tester) async {
    final consumed = <int>[];
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: SonnerBridge(
            notice: const Notice(
              id: 1,
              message: 'Reader settings saved.',
              kind: NoticeKind.success,
            ),
            onConsumed: consumed.add,
            child: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('Reader settings saved.'), findsOneWidget);
    expect(consumed, [1]);
  });

  testWidgets('does nothing without a notice', (tester) async {
    final consumed = <int>[];
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: SonnerBridge(
            notice: null,
            onConsumed: consumed.add,
            child: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('Reader settings saved.'), findsNothing);
    expect(consumed, isEmpty);
  });
}
