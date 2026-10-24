import Foundation
import Darwin
#if os(iOS)
import Flutter
import UIKit
import UniformTypeIdentifiers
#else
import Cocoa
import FlutterMacOS
#endif

/// Shared Apple folder capability. A bookmark, not a container path, survives
/// relaunch. Each live file handle owns one balanced security-scope access.
final class FolderLocations: NSObject {
  private let channel: FlutterMethodChannel
  private let worker = DispatchQueue(label: "dev.shosai.library-folders")
  private var pickerResult: FlutterResult?
  private var handles: [String: Handle] = [:] // worker-owned

  private struct Handle {
    let file: FileHandle
    let root: URL
    let scoped: Bool
    let temporary: URL?
    let destination: URL?
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.shosai/library_folders", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [self] call, result in
      if call.method == "pick" { pick(result); return }
      worker.async {
        do {
          let value = try self.perform(call)
          DispatchQueue.main.async { result(value) }
        } catch {
          let failure = error as NSError
          let code: String
          if failure.domain == "shosai.folders" { code = failure.localizedDescription }
          else if failure.domain == NSCocoaErrorDomain &&
            [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(failure.code) { code = "revoked" }
          else if failure.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { code = "missing" }
          else if failure.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(failure.code) { code = "revoked" }
          else if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) { code = "missing" }
          else { code = "offline" }
          DispatchQueue.main.async { result(FlutterError(code: code, message: "The folder could not be accessed.", details: nil)) }
        }
      }
    }
  }

  private func failure(_ code: String) -> NSError {
    NSError(domain: "shosai.folders", code: 1, userInfo: [NSLocalizedDescriptionKey: code])
  }

  private func bookmark(_ url: URL) throws -> String {
    #if os(iOS)
    let options: URL.BookmarkCreationOptions = .minimalBookmark
    #else
    let options: URL.BookmarkCreationOptions = .withSecurityScope
    #endif
    return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
  }

  private func resolve(_ grant: String) throws -> URL {
    guard let data = Data(base64Encoded: grant) else { throw failure("revoked") }
    var stale = false
    #if os(iOS)
    let options: URL.BookmarkResolutionOptions = .withoutUI
    #else
    let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #endif
    do {
      // Stale bookmarks can still resolve after a move. Operations use the
      // resolved URL, never the obsolete absolute path in a book record.
      return try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
    } catch { throw failure("revoked") }
  }

  private func scoped<T>(_ grant: String, _ body: (URL, Bool) throws -> T) throws -> T {
    let root = try resolve(grant)
    let started = root.startAccessingSecurityScopedResource()
    defer { if started { root.stopAccessingSecurityScopedResource() } }
    return try body(root, started)
  }

  private func child(_ root: URL, _ key: String?) throws -> URL {
    guard let key = key else { return root.resolvingSymlinksInPath() }
    let parts = key.split(separator: "/", omittingEmptySubsequences: false)
    guard !key.isEmpty, !key.contains("\\"), !key.contains("\0"),
      !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw failure("revoked") }
    let resolvedRoot = root.resolvingSymlinksInPath()
    let url = root.appendingPathComponent(key).resolvingSymlinksInPath()
    guard url.path.hasPrefix(resolvedRoot.path + "/") else { throw failure("revoked") }
    return url
  }

  private func entry(_ url: URL, root: URL) throws -> [String: Any] {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
    let base = root.resolvingSymlinksInPath().path + "/"
    guard url.path.hasPrefix(base) else { throw failure("revoked") }
    var result: [String: Any] = ["key": String(url.path.dropFirst(base.count)), "name": url.lastPathComponent,
                               "isDirectory": values.isDirectory ?? false]
    if let size = values.fileSize { result["size"] = size }
    if let modified = values.contentModificationDate { result["revision"] = String(modified.timeIntervalSince1970) }
    return result
  }

  private func perform(_ call: FlutterMethodCall) throws -> Any? {
    guard let args = call.arguments as? [String: Any] else { throw failure("unsupported") }
    let token = args["token"] as? String ?? ""
    if call.method == "close" {
      if let handle = handles.removeValue(forKey: token) { try close(handle, abort: true) }
      return nil
    }
    if call.method == "read" {
      guard let handle = handles[token], handle.temporary == nil,
        let count = args["count"] as? Int, (1...65536).contains(count) else { throw failure("unsupported") }
      // The throwing Foundation read/write APIs require iOS 13.4/macOS
      // 10.15.4. POSIX keeps the app's existing 13.0/10.15 minimum and reports
      // I/O errors without the legacy FileHandle APIs' Objective-C exceptions.
      var bytes = [UInt8](repeating: 0, count: count)
      var length: Int
      repeat {
        length = bytes.withUnsafeMutableBytes { Darwin.read(handle.file.fileDescriptor, $0.baseAddress, count) }
      } while length < 0 && errno == EINTR
      if length < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      return FlutterStandardTypedData(bytes: Data(bytes.prefix(length)))
    }
    if call.method == "write" {
      guard let handle = handles[token], handle.temporary != nil,
        let bytes = args["bytes"] as? FlutterStandardTypedData, bytes.data.count <= 65536 else { throw failure("unsupported") }
      try bytes.data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let written = Darwin.write(handle.file.fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
          if written < 0 && errno == EINTR { continue }
          if written <= 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(written == 0 ? EIO : errno)) }
          offset += written
        }
      }
      return nil
    }
    if call.method == "commit" {
      guard let handle = handles.removeValue(forKey: token),
        let temporary = handle.temporary, let destination = handle.destination else { throw failure("unsupported") }
      defer { if handle.scoped { handle.root.stopAccessingSecurityScopedResource() } }
      do {
        try handle.file.synchronize()
        try handle.file.close()
        var coordinationError: NSError?
        var publicationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: temporary, options: .forMoving,
          writingItemAt: destination, options: .forReplacing, error: &coordinationError) { source, target in
            do {
              if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
              } else { try FileManager.default.moveItem(at: source, to: target) }
            } catch { publicationError = error }
          }
        if let error = coordinationError ?? publicationError as NSError? { throw error }
      } catch {
        try? handle.file.close()
        try? FileManager.default.removeItem(at: temporary)
        throw error
      }
      return try entry(destination, root: handle.root)
    }
    guard let grant = args["grant"] as? String else { throw failure("revoked") }
    // Apple bookmark access is reference counted per handle, not a global
    // permission to revoke. Forgetting the saved bookmark releases the grant.
    if call.method == "release" { return nil }
    if call.method == "openRead" || call.method == "openWrite" {
      guard handles.count < 8 else { throw failure("unsupported") }
      let root = try resolve(grant)
      let started = root.startAccessingSecurityScopedResource()
      do {
        let file: FileHandle
        var temporary: URL?
        var destination: URL?
        if call.method == "openRead" {
          guard let key = args["key"] as? String, let start = args["start"] as? Int64, start >= 0 else { throw failure("unsupported") }
          let url = try child(root, key)
          var coordinationError: NSError?
          var opened: FileHandle?
          var openError: Error?
          NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            do { opened = try FileHandle(forReadingFrom: coordinated) } catch { openError = error }
          }
          if let error = coordinationError ?? openError as NSError? { throw error }
          guard let input = opened else { throw failure("missing") }
          do { try input.seek(toOffset: UInt64(start)) } catch { try? input.close(); throw error }
          file = input
        } else {
          guard let name = args["name"] as? String, !name.isEmpty,
            name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw failure("unsupported") }
          let parent = try child(root, args["directory"] as? String)
          let temp = parent.appendingPathComponent(".shosai-write-" + UUID().uuidString)
          guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw failure("revoked") }
          do { file = try FileHandle(forWritingTo: temp) }
          catch { try? FileManager.default.removeItem(at: temp); throw error }
          temporary = temp
          destination = parent.appendingPathComponent(name)
        }
        let id = UUID().uuidString
        handles[id] = Handle(file: file, root: root, scoped: started, temporary: temporary, destination: destination)
        return id
      } catch {
        if started { root.stopAccessingSecurityScopedResource() }
        throw error
      }
    }
    return try scoped(grant) { root, _ in
      switch call.method {
      case "refresh": return try bookmark(root)
      case "stat":
        guard let key = args["key"] as? String else { throw failure("unsupported") }
        return try entry(child(root, key), root: root)
      case "list":
        let directory = try child(root, args["directory"] as? String)
        guard let offset = args["offset"] as? Int, offset >= 0,
          let limit = args["limit"] as? Int, (1...500).contains(limit) else { throw failure("unsupported") }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory,
          includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants],
          errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("missing") }
        var entries: [[String: Any]] = []
        var seen = 0
        for case let url as URL in enumerator {
          if url.lastPathComponent.hasPrefix(".shosai-write-") ||
            (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { continue }
          seen += 1
          if seen <= offset { continue }
          if entries.count == limit { return ["entries": entries, "nextCursor": String(offset + limit)] }
          entries.append(try entry(url, root: root))
        }
        if let error = enumerationError { throw error }
        return ["entries": entries]
      default: throw failure("unsupported")
      }
    }
  }

  private func close(_ handle: Handle, abort: Bool) throws {
    defer {
      if abort, let temp = handle.temporary { try? FileManager.default.removeItem(at: temp) }
      if handle.scoped { handle.root.stopAccessingSecurityScopedResource() }
    }
    try handle.file.close()
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pickerResult == nil else { result(FlutterError(code: "busy", message: "A folder picker is open.", details: nil)); return }
    pickerResult = result
    #if os(iOS)
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    }
    picker.delegate = self
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
      var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
        pickerResult = nil; result(FlutterError(code: "unsupported", message: "No picker host.", details: nil)); return
      }
    while let presented = presenter.presentedViewController { presenter = presented }
    presenter.present(picker, animated: true)
    #else
    let picker = NSOpenPanel()
    picker.canChooseDirectories = true
    picker.canChooseFiles = false
    picker.allowsMultipleSelection = false
    picker.prompt = "Use this folder"
    picker.begin { response in self.selected(response == .OK ? picker.url : nil) }
    #endif
  }

  private func selected(_ url: URL?) {
    guard let result = pickerResult else { return }
    pickerResult = nil
    guard let url = url else { result(nil); return }
    let started = url.startAccessingSecurityScopedResource()
    defer { if started { url.stopAccessingSecurityScopedResource() } }
    do { result(["grant": try bookmark(url), "label": url.lastPathComponent]) }
    catch { result(FlutterError(code: "revoked", message: "Lasting access was not granted.", details: nil)) }
  }
}

#if os(iOS)
extension FolderLocations: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls.first) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
}
#endif
