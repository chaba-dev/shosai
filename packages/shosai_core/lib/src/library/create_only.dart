/// Atomic publication without replacing any existing directory entry.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../errors.dart';

void publishNewFile(String source, String destination) {
  final library = Platform.isWindows
      ? DynamicLibrary.open('kernel32.dll')
      : DynamicLibrary.process();
  int result;
  int error;
  if (Platform.isWindows) {
    final from = source.toNativeUtf16();
    final to = destination.toNativeUtf16();
    try {
      result = library
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Utf16>, int)
          >('MoveFileExW')(from, to, 0);
      if (result != 0) return;
      error = library.lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
      )();
    } finally {
      malloc.free(from);
      malloc.free(to);
    }
  } else {
    final from = source.toNativeUtf8();
    final to = destination.toNativeUtf8();
    try {
      if (Platform.isLinux) {
        // AT_FDCWD; RENAME_NOREPLACE. No check-then-rename race or placeholder.
        result = library
            .lookupFunction<
              Int32 Function(
                Int32,
                Pointer<Utf8>,
                Int32,
                Pointer<Utf8>,
                Uint32,
              ),
              int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
            >('renameat2')(-100, from, -100, to, 1);
      } else if (Platform.isMacOS || Platform.isIOS) {
        result = library
            .lookupFunction<
              Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
              int Function(Pointer<Utf8>, Pointer<Utf8>, int)
            >('renamex_np')(from, to, 4); // RENAME_EXCL
      } else {
        throw const CoreException(
          CoreErrorKind.unsupported,
          'This filesystem cannot safely create a new book.',
        );
      }
      if (result == 0) return;
      error = library
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            Platform.isLinux ? '__errno_location' : '__error',
          )()
          .value;
    } finally {
      malloc.free(from);
      malloc.free(to);
    }
  }
  if (Platform.isWindows ? error == 80 || error == 183 : error == 17) {
    throw const CoreException.conflict('The destination name is taken.');
  }
  throw const CoreException(
    CoreErrorKind.inaccessible,
    'The book could not be published without replacing a file.',
  );
}
