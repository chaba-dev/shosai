import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.shosai/library_folders');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final source = Uint8List.fromList(
    List.generate(140003, (index) => (index * 19 + index ~/ 13) % 256),
  );
  const location = PlatformFolderLocation('test', 'opaque-bookmark');
  int? offset;
  List<int>? writing;
  List<int> published = [31, 9];
  String? failure;
  int largestChunk = 0;
  final metadata = <String, Object>{
    'key': 'opaque-id',
    'name': 'Book.epub',
    'isDirectory': false,
    'size': source.length,
  };

  setUp(() {
    offset = null;
    writing = null;
    published = [31, 9];
    failure = null;
    largestChunk = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map).cast<String, dynamic>();
      if (call.method == 'close') {
        offset = null;
        writing = null;
        return null;
      }
      if (failure != null) throw PlatformException(code: failure!);
      switch (call.method) {
        case 'openRead':
          offset = args['start'] as int;
          return 'reader';
        case 'read':
          final count = args['count'] as int;
          largestChunk = count > largestChunk ? count : largestChunk;
          final start = offset! > source.length ? source.length : offset!;
          final stop = start + count > source.length
              ? source.length
              : start + count;
          offset = stop;
          return source.sublist(start, stop);
        case 'openWrite':
          writing = [];
          return 'writer';
        case 'write':
          final bytes = args['bytes'] as Uint8List;
          largestChunk = bytes.length > largestChunk
              ? bytes.length
              : largestChunk;
          writing!.addAll(bytes);
          return null;
        case 'commit':
          published = writing!;
          writing = null;
          return metadata;
        case 'stat':
          return metadata;
        case 'list':
          return {
            'entries': [metadata],
            'nextCursor': '101',
          };
        default:
          throw StateError('Unexpected operation ${call.method}');
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native grants retain opaque keys and range reads release resources',
    () async {
      final page = await location.list(cursor: '100');
      expect(page.entries.single.key, 'opaque-id');
      expect(page.nextCursor, '101');
      final bytes = await location
          .read('opaque-id', start: 7, end: 70003)
          .expand((bytes) => bytes)
          .toList();
      expect(bytes, source.sublist(7, 70003));
      expect(largestChunk, lessThanOrEqualTo(65536));
      expect(offset, isNull);
      expect(
        await location.read('opaque-id', start: source.length + 7).toList(),
        isEmpty,
      );
      final cancellation = CancellationToken();
      await expectLater(
        location.read('opaque-id', cancellation: cancellation).map((chunk) {
          cancellation.cancel();
          return chunk;
        }).drain<void>(),
        throwsA(isA<CoreException>()),
      );
      expect(
        offset,
        isNull,
        reason: 'cancellation releases the native scope/stream',
      );
    },
  );

  test(
    'writes bound chunks and interrupted input cannot publish partial books',
    () async {
      final result = await location.write('Book.epub', Stream.value(source));
      expect(result.key, 'opaque-id');
      expect(published, source);
      expect(largestChunk, lessThanOrEqualTo(65536));
      expect(writing, isNull);
      Stream<List<int>> interrupted() async* {
        yield [1, 7];
        throw StateError('interrupted');
      }

      await expectLater(
        location.write('Book.epub', interrupted()),
        throwsStateError,
      );
      expect(published, source);
      expect(writing, isNull);
    },
  );

  test(
    'expected provider failures are typed and invalid ranges never open resources',
    () async {
      for (final value in LocationFailure.values) {
        failure = value.name;
        await expectLater(
          location.stat('opaque-id'),
          throwsA(
            isA<LocationException>().having(
              (error) => error.failure,
              'failure',
              value,
            ),
          ),
        );
      }
      await expectLater(
        location.read('opaque-id', start: 9, end: 3).drain<void>(),
        throwsA(isA<CoreException>()),
      );
      expect(offset, isNull);
    },
  );
}
