import Cocoa
import FlutterMacOS

/// The sync folder on macOS. The app is sandboxed, so the folder the user
/// picks (with file_selector's open panel) is reachable only in that launch;
/// a security-scoped bookmark (`ref`, base64) opens it again in later ones.
/// Once open, Dart reads and writes it as plain files: on macOS a provider's
/// placeholder (Dropbox, iCloud Drive) downloads when it is read.
///
/// Needs `com.apple.security.files.user-selected.read-write` and
/// `com.apple.security.files.bookmarks.app-scope` in the app's entitlements.
public class WalletBackupPlatformPlugin: NSObject, FlutterPlugin {
  /// Folders opened from a bookmark in this launch, by path.
  private var opened: [String: URL] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "org.magicgrants.wallet_backup_platform/folder",
      binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(WalletBackupPlatformPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "bookmark":
        guard let path = args["path"] as? String else { return badArgs(result, "path missing") }
        result(try bookmark(URL(fileURLWithPath: path, isDirectory: true)))
      case "open":
        guard let ref = args["ref"] as? String, let data = Data(base64Encoded: ref) else {
          return badArgs(result, "ref missing")
        }
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
          bookmarkDataIsStale: &stale)
        if url.startAccessingSecurityScopedResource() { opened[url.path] = url }
        var reply: [String: Any] = ["path": url.path]
        // Moved since: the bookmark still found it; keep a fresh one.
        if stale, let renewed = try? bookmark(url) { reply["ref"] = renewed }
        result(reply)
      case "release":
        if let path = args["path"] as? String {
          opened.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "unavailable", message: error.localizedDescription, details: nil))
    }
  }

  private func bookmark(_ url: URL) throws -> String {
    try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
    ).base64EncodedString()
  }

  private func badArgs(_ result: FlutterResult, _ message: String) {
    result(FlutterError(code: "bad_args", message: message, details: nil))
  }
}
