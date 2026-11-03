import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rescans the library the way a person would: Control+R on the shelf, which
/// every layout answers (touch layouts also pull the shelf down).
Future<void> refreshLibrary(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}
