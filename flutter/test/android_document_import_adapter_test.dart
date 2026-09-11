import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';

final class FakeChannel implements AndroidDocumentImportChannel {
  final Map<String, Object?> replies = {};
  final List<(String, Map<String, Object?>?)> calls = [];
  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add((method, arguments));
    final reply = replies[method];
    if (reply is Exception) throw reply;
    return reply;
  }
}

void main() {
  test('reports provider limitations honestly', () async {
    final channel = FakeChannel()
      ..replies['capabilities'] = <String, Object?>{
        'files': true,
        'multipleFiles': true,
        'folders': false,
        'referencedImports': false,
        'managedImports': true,
        'maximumAcquisitions': 2,
        'maximumBytesPerFile': 536870912,
      };
    final value = await AndroidDocumentImportAdapter(
      channel: channel,
    ).capabilities();
    expect(value.folders, isFalse);
    expect(value.referencedImports, isFalse);
    expect(value.managedImports, isTrue);
    expect(value.maximumAcquisitions, 2);
  });

  test('acquisition has explicit managed-only cleanup ownership', () async {
    final channel = FakeChannel()
      ..replies['acquire'] = <String, Object?>{
        'path': '/cache/import',
        'releaseToken': 'release-1',
      }
      ..replies['release'] = null;
    final adapter = AndroidDocumentImportAdapter(channel: channel);
    final result = await adapter.acquire(
      document: const SelectedProviderDocument(token: 'selection', name: 'a'),
      operationId: 'operation',
    );
    final acquired = result as AcquiredProviderDocument;
    expect(acquired.managedOnly, isTrue);
    await adapter.release(acquired.releaseToken);
    expect(channel.calls.last.$1, 'release');
    expect(channel.calls.last.$2, containsPair('releaseToken', 'release-1'));
  });

  test('unacquired provider selections can be explicitly discarded', () async {
    final channel = FakeChannel()..replies['discardSelection'] = null;
    final adapter = AndroidDocumentImportAdapter(channel: channel);

    await adapter.discardSelection('selection-1');

    expect(channel.calls.single.$1, 'discardSelection');
    expect(channel.calls.single.$2, containsPair('token', 'selection-1'));
  });

  test('allowlists native errors and forwards cancellation', () async {
    final channel = FakeChannel()
      ..replies['acquire'] = PlatformException(
        code: 'provider-secret-error',
        message: 'content://private',
      )
      ..replies['cancel'] = null;
    final adapter = AndroidDocumentImportAdapter(channel: channel);
    final result = await adapter.acquire(
      document: const SelectedProviderDocument(token: 'x', name: 'x'),
      operationId: 'op',
    );
    expect(
      (result as DocumentAcquisitionFailure).error,
      DocumentImportError.unavailable,
    );
    await adapter.cancel('op');
    expect(channel.calls.last.$1, 'cancel');
    expect(channel.calls.last.$2, containsPair('operationId', 'op'));
  });

  test('failed release ownership is retained and retried', () async {
    final channel = FakeChannel()
      ..replies['release'] = PlatformException(code: 'read_failed');
    final adapter = AndroidDocumentImportAdapter(channel: channel);

    await expectLater(
      adapter.release('release-1'),
      throwsA(isA<PlatformException>()),
    );
    channel.replies['release'] = null;
    await adapter.retryPendingReleases();

    expect(channel.calls.where((call) => call.$1 == 'release').length, 2);
  });
}
