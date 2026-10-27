import Flutter
import SwiftyDropbox
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FolderLocations") {
      _ = FolderLocations(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OpenedDocuments") {
      OpenedDocuments.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DropboxAuthorization") {
      DropboxAuthorization.register(with: registrar)
    }
  }
}

/// SDK handshake only. Per-connection vault storage and renewal remain in Dart;
/// the SDK must not create a second persistent, account-global token store.
private final class DropboxTransientStorage: SecureStorageAccess {
  func checkAccessibilityMigrationOneTime() {}
  func setAccessTokenData(for userId: String, data: Data) -> Bool { true }
  func getAllUserIds() -> [String] { [] }
  func getDropboxAccessToken(for key: String) -> DropboxAccessToken? { nil }
  func deleteInfo(for key: String) -> Bool { true }
  func deleteInfoForAllKeys() -> Bool { true }
}

/// Capture the SDK's outgoing state so stale external URLs cannot terminate a
/// newer attempt. Browser Cancel is owned by this presentation, not a URL that
/// could belong to an earlier handshake. SDK error text never reaches the UI.
private final class DropboxAuthPresentation: SharedApplication {
  let mobile: MobileSharedApplication
  var state: String?
  private let cancel: () -> Void
  private let failure: (String) -> Void

  init(mobile: MobileSharedApplication, cancel: @escaping () -> Void,
       failure: @escaping (String) -> Void) {
    self.mobile = mobile
    self.cancel = cancel
    self.failure = failure
  }

  private func capture(_ url: URL) {
    state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "state" })?.value
  }

  func presentErrorMessage(_ message: String, title: String) { failure("authorization") }
  func presentErrorMessageWithHandlers(
    _ message: String, title: String, buttonHandlers: [String: () -> Void]
  ) { failure("offline") }
  func presentPlatformSpecificAuth(_ authURL: URL) -> Bool {
    capture(authURL)
    return mobile.presentPlatformSpecificAuth(authURL)
  }
  func presentExternalApp(_ url: URL) {
    if ["dbapi-2", "dbapi-8-emm"].contains(url.scheme ?? "") { capture(url) }
    mobile.presentExternalApp(url)
  }
  func canPresentExternalApp(_ url: URL) -> Bool { mobile.canPresentExternalApp(url) }
  func presentAuthChannel(
    _ authURL: URL, tryIntercept: @escaping (URL) -> Bool,
    cancelHandler: @escaping () -> Void
  ) {
    capture(authURL)
    mobile.presentAuthChannel(authURL, tryIntercept: tryIntercept, cancelHandler: cancel)
  }
  func presentLoading() { mobile.presentLoading() }
  func dismissLoading() { mobile.dismissLoading() }
}

private final class DropboxAuthorization: NSObject, FlutterSceneLifeCycleDelegate {
  private var pending: FlutterResult?
  private var manager: DropboxMobileOAuthManager?
  private var application: DropboxAuthPresentation?
  private var deadline: Timer?
  private var callbackScheme: String?
  private var operation: UUID?
  private var exchanging = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DropboxAuthorization()
    let channel = FlutterMethodChannel(
      name: "dev.shosai/dropbox_authorization", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler(instance.handle)
    registrar.addSceneDelegate(instance)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "authorize" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pending == nil else {
      result(FlutterError(code: "busy", message: nil, details: nil))
      return
    }
    guard let args = call.arguments as? [String: Any],
      let key = args["clientId"] as? String, !key.isEmpty,
      key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
      let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
      types.contains(where: { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains("db-\(key)") })
    else {
      result(FlutterError(code: "configuration", message: nil, details: nil))
      return
    }
    let attempt = UUID()
    let mobile = MobileSharedApplication(
      sharedApplication: UIApplication.shared, controller: nil,
      openURL: { [weak self] url in
        UIApplication.shared.open(url, options: [:]) { opened in
          if !opened && self?.operation == attempt {
            self?.finish(FlutterError(code: "authorization", message: nil, details: nil))
          }
        }
      })
    let presentation = DropboxAuthPresentation(
      mobile: mobile,
      cancel: { [weak self] in
        if self?.operation == attempt { self?.finish(nil) }
      }, failure: { [weak self] code in
        if self?.operation == attempt {
          self?.finish(FlutterError(code: code, message: nil, details: nil))
        }
      })
    let oauth = DropboxMobileOAuthManager(
      appKey: key, secureStorageAccess: DropboxTransientStorage(),
      dismissSharedAppAuthController: { [weak mobile] in mobile?.dismissAuthController() })
    pending = result
    operation = attempt
    callbackScheme = "db-\(key)"
    application = presentation
    manager = oauth
    deadline = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
      if self?.operation == attempt {
        self?.finish(FlutterError(code: "timeout", message: nil, details: nil))
      }
    }
    oauth.authorizeFromSharedApplication(
      presentation, usePKCE: true,
      scopeRequest: ScopeRequest(
        scopeType: .user,
        scopes: ["files.metadata.read", "files.content.read", "files.content.write"],
        includeGrantedScopes: false))
  }

  private func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {
    guard let manager = manager, pending != nil, !exchanging,
      let url = contexts.map(\.url).first(where: {
        let states = URLComponents(url: $0, resolvingAgainstBaseURL: false)?
          .queryItems?.filter { $0.name == "state" } ?? []
        return $0.scheme == callbackScheme &&
          states.count == 1 && states.first?.value == application?.state &&
          application?.state != nil &&
          (($0.host == "1" && ["/connect", "/cancel"].contains($0.path)) ||
            ($0.host == "2" && ["/token", "/cancel"].contains($0.path)))
      })
    else { return false }
    exchanging = true
    return manager.handleRedirectURL(url) { [weak self, weak manager] response in
      DispatchQueue.main.async {
        guard let self = self, self.manager === manager else { return }
        switch response {
        case .success(let token):
          guard let refresh = token.refreshToken, !refresh.isEmpty,
            let expires = token.tokenExpirationTimestamp,
            !token.accessToken.isEmpty, expires > Date().timeIntervalSince1970
          else {
            self.finish(FlutterError(code: "incomplete", message: nil, details: nil))
            return
          }
          self.finish([
            "access_token": token.accessToken,
            "refresh_token": refresh,
            "expires_in": Int(expires - Date().timeIntervalSince1970),
          ])
        case .cancel:
          self.finish(nil)
        default:
          // Raw SDK descriptions may contain callback details; never forward.
          self.finish(FlutterError(code: "authorization", message: nil, details: nil))
        }
      }
    }
  }

  private func finish(_ value: Any?) {
    let result = pending
    pending = nil
    deadline?.invalidate()
    deadline = nil
    application?.mobile.dismissAuthController()
    application = nil
    manager = nil
    callbackScheme = nil
    operation = nil
    exchanging = false
    result?(value)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    receive(URLContexts)
  }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    receive(connectionOptions?.urlContexts ?? [])
  }
}

/// Books another app hands Shōsai: "Open in Shōsai" in the share sheet, or
/// Share from Files. With LSSupportsOpeningDocumentsInPlace off, iOS copies
/// each book into Documents/Inbox before the scene hears of it, so Dart gets
/// a plain path it can import and then delete.
final class OpenedDocuments: NSObject, FlutterSceneLifeCycleDelegate {
  private let channel: FlutterMethodChannel
  /// Native owns every arrival until Dart takes it, even between listeners.
  private var pending: [String] = []

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
    for path in paths where !pending.contains(path) {
      pending.append(path)
    }
    // This is only a wake-up hint. If Dart has no handler, the paths remain
    // pending and its next listener takes them during startup.
    channel.invokeMethod("opened", arguments: nil)
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
