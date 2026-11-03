import 'package:shosai_flutter/core/bridge.dart';

import 'app_localizations.dart';

/// Engine messages are diagnostics, not translated UI copy. Present their
/// structured kind without leaking raw provider responses or platform paths.
String localizedErrorText(Object error, AppLocalizations l10n) =>
    switch (error) {
      FlutterBridgeError(:final kind) => switch (kind) {
        FlutterBridgeErrorKind.cancelled => l10n.errorCancelled,
        FlutterBridgeErrorKind.notFound => l10n.errorNotFound,
        FlutterBridgeErrorKind.inaccessible => l10n.errorInaccessible,
        FlutterBridgeErrorKind.unsupported => l10n.importUnsupported,
        FlutterBridgeErrorKind.invalidRequest => l10n.errorInvalidRequest,
        FlutterBridgeErrorKind.malformed => l10n.errorMalformed,
        FlutterBridgeErrorKind.limitExceeded => l10n.importTooLarge,
        FlutterBridgeErrorKind.backendUnavailable =>
          l10n.errorBackendUnavailable,
        FlutterBridgeErrorKind.renderFailed => l10n.errorRenderFailed,
      },
      _ => l10n.importOperationFailed,
    };
