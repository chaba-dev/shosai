/// Native Dropbox app authorization, with the SDK's browser fallback.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shosai_core/shosai_core.dart';

final class DropboxAuthorization {
  const DropboxAuthorization({
    required this.cancellationTitle,
    required this.cancelAction,
    required this.keepWaitingAction,
  });

  final String cancellationTitle;
  final String cancelAction;
  final String keepWaitingAction;

  static bool get supported => Platform.isIOS || Platform.isAndroid;
  static const _channel = MethodChannel('dev.shosai/dropbox_authorization');

  Future<Map<String, dynamic>?> authorize(String clientId) async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>('authorize', {
        'clientId': clientId,
        'cancellationTitle': cancellationTitle,
        'cancelAction': cancelAction,
        'keepWaitingAction': keepWaitingAction,
      });
    } on PlatformException catch (error) {
      // Never expose SDK errors, which can contain callback URLs or tokens.
      // Expiring an unfinished setup does not revoke an existing grant.
      if (error.code == 'timeout') return null;
      throw LocationException(
        error.code == 'offline'
            ? LocationFailure.offline
            : LocationFailure.revoked,
      );
    }
  }
}
