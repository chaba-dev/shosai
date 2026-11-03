import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  let openedDocuments = OpenedDocuments()

  override func application(_ application: NSApplication, open urls: [URL]) {
    // AppKit prefers openURLs (already implemented by FlutterAppDelegate) over
    // openFiles, including Finder/Dock file events and cold launches.
    openedDocuments.receive(urls.filter(\.isFileURL))
    let other = urls.filter { !$0.isFileURL }
    if !other.isEmpty { super.application(application, open: other) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Keep granted originals native-owned until a bounded, coordinated copy is
/// ready. Only disposable copies reach the controller's managed import path.
final class OpenedDocuments {
  private var channel: FlutterMethodChannel?
  private let worker = DispatchQueue(label: "dev.shosai.opened-documents")
  private var pending: [String] = []
  private var owned: [String: URL] = [:]
  private var outstanding = 0
  private let maximumBytes = 512 * 1024 * 1024

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dev.shosai/opened_documents", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [self] call, result in
      switch call.method {
      case "takePending":
        result(pending)
        pending = []
      case "discard":
        let paths = call.arguments as? [String] ?? []
        let sessions = paths.compactMap { owned.removeValue(forKey: $0) }
        outstanding -= sessions.count
        worker.async {
          for session in sessions { try? FileManager.default.removeItem(at: session) }
          DispatchQueue.main.async { result(nil) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func receive(_ urls: [URL]) {
    for url in urls where url.isFileURL &&
      ["epub", "pdf"].contains(url.pathExtension.lowercased()) {
      guard outstanding < 256 else { break }
      outstanding += 1
      worker.async { [self] in
        let session = FileManager.default.temporaryDirectory
          .appendingPathComponent("shosai-opened-\(UUID().uuidString)", isDirectory: true)
        let destination = session.appendingPathComponent(url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                                      error: &coordinationError) { readable in
          do {
            let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumBytes else { return }
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { return }
            let input = try FileHandle(forReadingFrom: readable)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var count = 0
            while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty {
              count += bytes.count
              guard count <= maximumBytes else { return }
              try output.write(contentsOf: bytes)
            }
            copied = true
          } catch {
            // Provider errors and paths never become user-facing error text.
          }
        }
        if !copied || coordinationError != nil {
          try? FileManager.default.removeItem(at: session)
          DispatchQueue.main.async { self.outstanding -= 1 }
          return
        }
        DispatchQueue.main.async {
          self.owned[destination.path] = session
          self.pending.append(destination.path)
          // A hint only: startup's takePending also drains pre-listener events.
          self.channel?.invokeMethod("opened", arguments: nil)
        }
      }
    }
  }
}
