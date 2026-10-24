import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OpenedDocuments") {
      OpenedDocuments.register(with: registrar)
    }
  }
}

/// Books another app hands Shōsai: "Open in Shōsai" in the share sheet, or
/// Share from Files. With LSSupportsOpeningDocumentsInPlace off, iOS copies
/// each book into Documents/Inbox before the scene hears of it, so Dart gets
/// a plain path it can import and then delete.
final class OpenedDocuments: NSObject, FlutterSceneLifeCycleDelegate {
  private let channel: FlutterMethodChannel
  /// Paths that arrived before Dart asked for them.
  private var pending: [String] = []
  private var listening = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = OpenedDocuments(
      channel: FlutterMethodChannel(
        name: "dev.shosai/opened_documents",
        binaryMessenger: registrar.messenger()))
    instance.channel.setMethodCallHandler(instance.handle)
    registrar.addSceneDelegate(instance)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takePending":
      listening = true
      result(pending)
      pending = []
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Takes the books among [contexts]; anything else is left to others.
  private func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {
    let paths = contexts.map(\.url).filter { url in
      url.isFileURL && ["epub", "pdf"].contains(url.pathExtension.lowercased())
    }.map(\.path)
    if paths.isEmpty { return false }
    if listening {
      channel.invokeMethod("opened", arguments: paths)
    } else {
      pending.append(contentsOf: paths)
    }
    return true
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    return receive(connectionOptions?.urlContexts ?? [])
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return receive(URLContexts)
  }
}
