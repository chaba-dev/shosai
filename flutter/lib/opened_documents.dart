import 'package:flutter/services.dart';

/// Books another app hands Shōsai on iOS: "Open in Shōsai" in the share
/// sheet, or Share from Files. iOS copies each book into the app's inbox
/// before the app hears of it, so only those copies' paths cross here.
class OpenedDocuments {
  const OpenedDocuments();

  static const MethodChannel _channel = MethodChannel(
    'dev.shosai/opened_documents',
  );

  /// Delivers each batch of opened books' paths to [onOpened], starting
  /// with the books that opened the app before Dart was listening.
  Future<void> listen(void Function(List<String> paths) onOpened) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') {
        final paths = (call.arguments as List).cast<String>();
        if (paths.isNotEmpty) onOpened(paths);
      }
    });
    final List<String>? pending;
    try {
      pending = await _channel.invokeListMethod<String>('takePending');
    } on MissingPluginException {
      // A host without the channel, such as a widget test, opens no books.
      return;
    }
    if (pending != null && pending.isNotEmpty) onOpened(pending);
  }

  /// Stops delivery; books opened later wait for the next [listen].
  void cancel() => _channel.setMethodCallHandler(null);
}
