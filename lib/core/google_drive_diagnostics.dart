/// Local failure diagnostics with no credentials, identifiers or raw errors.
library;

import 'package:flutter/foundation.dart';

enum GoogleDriveDiagnosticStage {
  connection,
  credentialRead,
  credentialDecode,
  credentialWrite,
  credentialDelete,
  tokenRenewal,
  tokenEndpoint,
  driveRequest,
  driveMetadata,
  driveListing,
}

enum GoogleDriveDiagnosticReason {
  invalidReference,
  released,
  missing,
  malformed,
  unavailable,
  timeout,
  nativeAuthorization,
  registrationMismatch,
  rejected,
  renewalRequired,
  unauthorized,
  forbidden,
  rateLimited,
  redirected,
  network,
  notOwned,
  incomplete,
}

/// Failure-only console output, including in Release. No app-managed log file
/// or telemetry is created. Only fixed names, bounded statuses and allowlisted
/// OAuth codes are emitted; arbitrary error text is never forwarded.
void reportGoogleDriveDiagnostic(
  GoogleDriveDiagnosticStage stage,
  GoogleDriveDiagnosticReason reason, {
  int? httpStatus,
  String? oauthError,
}) {
  final safeOAuth = switch (oauthError) {
    'invalid_client' ||
    'invalid_grant' ||
    'invalid_request' ||
    'unauthorized_client' ||
    'unsupported_grant_type' ||
    'invalid_scope' ||
    'access_denied' ||
    'missing_client_secret' => oauthError,
    _ => 'unknown_error',
  };
  try {
    debugPrintSynchronously(
      '[shosai.google_drive] stage=${stage.name} reason=${reason.name}'
      '${httpStatus != null && httpStatus >= 100 && httpStatus <= 599 ? ' status=$httpStatus' : ''}'
      '${oauthError != null ? ' oauth=$safeOAuth' : ''}',
    );
  } catch (_) {
    // A diagnostic sink must never change access, retry or persistence behavior.
  }
}
