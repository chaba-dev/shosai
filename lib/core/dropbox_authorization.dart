/// Native Dropbox app authorization, with the SDK's browser fallback.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shosai_core/shosai_core.dart';

final class DropboxAuthorization {
  const DropboxAuthorization();

  static bool get supported => Platform.isIOS || Platform.isAndroid;
  static const _channel = MethodChannel('dev.shosai/dropbox_authorization');

  Future<Map<String, dynamic>?> authorize(String clientId) async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>('authorize', {
        'clientId': clientId,
      });
    } on PlatformException catch (error) {
      // Never expose SDK errors, which can contain callback URLs or tokens.
      throw LocationException(
        error.code == 'offline'
            ? LocationFailure.offline
            : LocationFailure.revoked,
      );
    }
  }
}
