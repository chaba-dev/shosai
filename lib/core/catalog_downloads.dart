/// Acquisition goes directly from the source to this device, then to the
/// selected save location. Public catalog metadata never owns personal books.
library;

import 'dart:async';
import 'dart:io';

import 'package:shosai_core/shosai_core.dart';
import 'catalog.dart';
import 'library_folders.dart';

final class CatalogDownloads {
  CatalogDownloads(
    this.catalog,
    this.folders,
    this.newPath, {
    HttpClient Function()? client,
  }) : _client = client ?? HttpClient.new;

  final CatalogClient catalog;
  final LibraryFolders folders;
  final Future<String> Function() newPath;
  final HttpClient Function() _client;

  Future<({Book book, bool existing})> add({
    required String bookId,
    required String sourceId,
    required String editionId,
    required String? locationId,
    required CancellationToken cancellation,
    void Function(int received, int? total)? progress,
  }) async {
    final details = await catalog.book(bookId, cancellation: cancellation);
    final edition = details?.editions
        .where((e) => e.sourceId == sourceId && e.editionId == editionId)
        .firstOrNull;
    final format = BookFormat.fromExtension(edition?.format ?? '');
    const sources = {
      'gutenberg': 'Project Gutenberg',
      'aozora': '青空文庫',
      'standardebooks': 'Standard Ebooks',
    };
    final source = sources[sourceId];
    if (details == null ||
        edition == null ||
        format == null ||
        source == null) {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'This catalog edition is not available for download.',
      );
    }
    final staging = Directory(await newPath());
    cancellation.throwIfCancelled();
    await staging.create();
    final name = bookFileName(
      details.book.title,
      details.book.authors.firstOrNull,
      format.name,
    );
    final file = File('${staging.path}/$name');
    try {
      await _download(
        Uri.parse(edition.acquisitionUrl),
        file,
        cancellation,
        progress,
      );
      cancellation.throwIfCancelled();
      return await folders.saveDownloadedBook(
        file.path,
        locationId: locationId,
        source: source,
        title: details.book.title,
        author: details.book.authors.firstOrNull,
        format: format,
        cancellation: cancellation,
      );
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<void> _download(
    Uri url,
    File destination,
    CancellationToken cancellation,
    void Function(int received, int? total)? progress,
  ) async {
    final client = _client()..connectionTimeout = const Duration(seconds: 30);
    var active = true;
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (active) client.close(force: true);
      }),
    );
    try {
      for (var redirect = 0; redirect <= 5; redirect++) {
        cancellation.throwIfCancelled();
        if (url.scheme != 'https' ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty) {
          throw const CoreException.invalidRequest(
            'Book downloads require HTTPS.',
          );
        }
        final request = await client.getUrl(url);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, catalogUserAgent);
        final response = await request.close().timeout(
          const Duration(seconds: 45),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw const CoreException.malformed('Missing book redirect.');
          }
          url = url.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw const LocationException(LocationFailure.offline);
        }
        final total = response.contentLength < 0
            ? null
            : response.contentLength;
        if (total != null && total > maxBookInputBytes) {
          throw const CoreException.limitExceeded(
            'The book exceeds the file limit.',
          );
        }
        final output = await destination.open(mode: FileMode.writeOnly);
        var received = 0;
        try {
          await for (final bytes in response.timeout(
            const Duration(seconds: 45),
          )) {
            cancellation.throwIfCancelled();
            received += bytes.length;
            if (received > maxBookInputBytes) {
              throw const CoreException.limitExceeded(
                'The book exceeds the file limit.',
              );
            }
            await output.writeFrom(bytes);
            progress?.call(received, total);
          }
          await output.flush();
        } finally {
          await output.close();
        }
        cancellation.throwIfCancelled();
        if (received == 0 || (total != null && received != total)) {
          throw const CoreException.malformed(
            'The book download was incomplete.',
          );
        }
        return;
      }
      throw const CoreException.malformed('Too many book redirects.');
    } on IOException {
      cancellation.throwIfCancelled();
      throw const LocationException(LocationFailure.offline);
    } on TimeoutException {
      cancellation.throwIfCancelled();
      throw const LocationException(LocationFailure.offline);
    } finally {
      active = false;
      client.close(force: true);
    }
  }
}
