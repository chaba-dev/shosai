# Open in Shōsai

EPUB and PDF arrivals enter the same controller-owned, managed import as iOS.
The controller queues arrivals while loading or reading and releases temporary
copies after import or disposal. It does not open an untracked external path in
the reader or retain a provider grant as the library's source of truth.

- **Android:** `VIEW` (`content:`/`file:`) and `SEND` (`EXTRA_STREAM`, or one
  `ClipData` URI) for `application/epub+zip` and `application/pdf`. Cold launches
  and `singleTask` deliveries use the process-owned provider copier. The copier
  bounds each file to 512 MiB, reads off the UI thread, and keeps native cleanup
  ownership until the controller releases the copy. Activity recreation does
  not replay the launch intent. The existing provider cleanup retries recover
  staging sessions after a process dies.
- **macOS:** Finder **Open With** and dropping books onto the Dock icon deliver
  open-file events, including at startup. Document types advertise Viewer /
  Alternate for EPUB and PDF; EPUB's imported UTI declares its extension and
  MIME type. A serial worker makes coordinated, security-scoped, bounded copies
  in the temporary directory before handing paths to Dart. Releasing a copy
  removes only its recorded staging directory, never the original.
- **iOS:** existing copy-to-Inbox delivery is unchanged.

## Why iOS Files sharing stays off

`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are explicitly
false. Turning both on publishes the app's Documents directory in Files and
allows editing documents in place. Today's intake deliberately deletes its
disposable Inbox paths after managed import; it must not receive an external
original under that contract.

The database, managed books, and application caches remain in the private
application-support tree (`applicationCoreOwner` in `lib/main.dart` and
`ShosaiCore.open` in `lib/core/core_records.dart`). Managed books are
recorded by path and content hash, and the library sweeps unowned files
(`packages/shosai_core/lib/src/library/library.dart`). Publishing that tree as a
Files library would allow renaming, replacing, or deleting tracked content;
untracked files placed there could also be swept. Do not move it into Documents
or expose it with links.

A future Files surface should be a separate import/export folder with an
explicit copy/validation contract, not the managed library or database. This
change does not introduce that separate product feature.

References: [Apple: UIFileSharingEnabled](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled),
[Apple: LSSupportsOpeningDocumentsInPlace](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsopeningdocumentsinplace),
[Android: receiving shared data](https://developer.android.com/training/sharing/receive).
