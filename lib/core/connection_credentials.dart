/// Connection credentials never enter preferences, catalogs, or book records.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class ConnectionCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain on Apple, Android Keystore-backed encryption, Secret Service on
/// Linux, and the platform credential vault on Windows. No plaintext fallback:
/// a locked or unavailable credential service must fail the connection setup.
final class PlatformConnectionCredentialStore
    implements ConnectionCredentialStore {
  const PlatformConnectionCredentialStore();

  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
