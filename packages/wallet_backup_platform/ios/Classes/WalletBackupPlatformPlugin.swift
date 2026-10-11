import Flutter
import Foundation

/// The iCloud location for the metadata backup (plan §2.4, §13.5).
///
/// Files live in the app's own iCloud container, outside its Documents folder
/// (`<container>/<folder>/<name>`), so they never show in the Files app.
/// Every read, write and delete goes through `NSFileCoordinator`. Listing uses
/// `NSMetadataQuery` as well as the directory, because files from other
/// devices may exist here only as placeholders until they are downloaded.
///
/// All file work runs on one serial queue; results return on the main thread.
public class WalletBackupPlatformPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "org.magicgrants.wallet_backup_platform.icloud")

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "org.magicgrants.wallet_backup_platform/icloud",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(WalletBackupPlatformPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let container = args["container"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "container missing", details: nil))
      return
    }
    let folder = args["folder"] as? String
    let name = args["name"] as? String

    queue.async {
      let reply: Any?
      do {
        switch call.method {
        case "available":
          reply = self.containerURL(container) != nil
        case "list":
          reply = try self.list(container, try self.require(folder))
        case "read":
          reply = try self.read(container, try self.require(folder), try self.require(name))
        case "create":
          guard let data = args["data"] as? FlutterStandardTypedData else {
            throw PluginError.badArgs("data missing")
          }
          try self.create(container, try self.require(folder), try self.require(name), data.data)
          reply = nil
        case "deleteFolder":
          try self.deleteFolder(container, try self.require(folder))
          reply = nil
        case "isUploaded":
          reply = try self.isUploaded(container, try self.require(folder), try self.require(name))
        case "excludeFromBackup":
          guard let path = args["path"] as? String, path.hasPrefix("/") else {
            throw PluginError.badArgs("path missing")
          }
          var url = URL(fileURLWithPath: path, isDirectory: true)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          reply = nil
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
      } catch let error as PluginError {
        DispatchQueue.main.async { result(error.flutterError) }
        return
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "io", message: error.localizedDescription, details: nil))
        }
        return
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  // MARK: - Container

  private enum PluginError: Error {
    case unavailable
    case conflict(String)
    case badArgs(String)
    case timeout

    var flutterError: FlutterError {
      switch self {
      case .unavailable:
        return FlutterError(
          code: "unavailable", message: "iCloud Drive is off or not signed in", details: nil)
      case .conflict(let name):
        return FlutterError(code: "conflict", message: name, details: nil)
      case .badArgs(let message):
        return FlutterError(code: "bad_args", message: message, details: nil)
      case .timeout:
        return FlutterError(code: "timeout", message: "iCloud did not answer in time", details: nil)
      }
    }
  }

  private func require(_ value: String?) throws -> String {
    guard let value = value, !value.isEmpty, !value.contains("/"), !value.hasPrefix(".") else {
      throw PluginError.badArgs("bad name")
    }
    return value
  }

  /// Off the main thread, as Apple requires: the first call can take a while.
  private func containerURL(_ container: String) -> URL? {
    guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
    return FileManager.default.url(forUbiquityContainerIdentifier: container)
  }

  private func folderURL(_ container: String, _ folder: String) throws -> URL {
    guard let root = containerURL(container) else { throw PluginError.unavailable }
    return root.appendingPathComponent(folder, isDirectory: true)
  }

  // MARK: - Operations

  private func list(_ container: String, _ folder: String) throws -> [String] {
    let dir = try folderURL(container, folder)
    var names = Set<String>()

    // Local entries, with download placeholders (".name.icloud") mapped back.
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
      for entry in entries {
        if entry.hasPrefix(".") && entry.hasSuffix(".icloud") {
          names.insert(String(entry.dropFirst().dropLast(".icloud".count)))
        } else if !entry.hasPrefix(".") {
          names.insert(entry)
        }
      }
    }
    // What iCloud knows of, including files not yet on this device.
    for name in try metadataQuery(dir) {
      names.insert(name)
    }
    return Array(names)
  }

  private func metadataQuery(_ dir: URL) throws -> [String] {
    let semaphore = DispatchSemaphore(value: 0)
    var found: [String] = []
    var observer: NSObjectProtocol?
    let query = NSMetadataQuery()

    DispatchQueue.main.async {
      query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
      query.predicate = NSPredicate(
        format: "%K BEGINSWITH %@", NSMetadataItemPathKey, dir.path + "/")
      observer = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
      ) { _ in
        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
          guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
            continue
          }
          let url = URL(fileURLWithPath: path)
          if url.deletingLastPathComponent().standardizedFileURL.path
            == dir.standardizedFileURL.path
          {
            found.append(url.lastPathComponent)
          }
        }
        query.stop()
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        semaphore.signal()
      }
      if !query.start() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        semaphore.signal()
      }
    }
    if semaphore.wait(timeout: .now() + 30) == .timedOut {
      DispatchQueue.main.async {
        query.stop()
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
      }
      throw PluginError.timeout
    }
    return found
  }

  private func read(_ container: String, _ folder: String, _ name: String) throws
    -> FlutterStandardTypedData?
  {
    let url = try folderURL(container, folder).appendingPathComponent(name)
    let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(name).icloud")
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) || fm.fileExists(atPath: placeholder.path)
        || isUbiquitous(url)
    else { return nil }

    try ensureDownloaded(url)

    var data: Data?
    var readError: Error?
    var coordinatorError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: [], error: &coordinatorError
    ) { readURL in
      do { data = try Data(contentsOf: readURL) } catch { readError = error }
    }
    if let error = coordinatorError ?? readError {
      // Removed since the listing (another device compacted): not an error.
      if !fm.fileExists(atPath: url.path) { return nil }
      throw error
    }
    return data.map { FlutterStandardTypedData(bytes: $0) }
  }

  private func isUbiquitous(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
  }

  private func ensureDownloaded(_ url: URL) throws {
    let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
    func isCurrent() -> Bool {
      var u = url
      u.removeAllCachedResourceValues()
      guard let status = (try? u.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus
      else {
        // Not an iCloud item at all: a plain local file.
        return FileManager.default.fileExists(atPath: url.path)
      }
      return status == .current
    }
    if isCurrent() { return }
    try FileManager.default.startDownloadingUbiquitousItem(at: url)
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
      if isCurrent() { return }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw PluginError.timeout
  }

  private func create(_ container: String, _ folder: String, _ name: String, _ data: Data) throws {
    let dir = try folderURL(container, folder)
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir.path) {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let url = dir.appendingPathComponent(name)

    // Create-only: the same bytes already there is a safe retry; different
    // bytes are a conflict, never overwritten.
    let placeholder = dir.appendingPathComponent(".\(name).icloud")
    if fm.fileExists(atPath: url.path) || fm.fileExists(atPath: placeholder.path) {
      if let existing = try read(container, folder, name), existing.data == data { return }
      throw PluginError.conflict(name)
    }

    var writeError: Error?
    var coordinatorError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: .forReplacing, error: &coordinatorError
    ) { writeURL in
      do { try data.write(to: writeURL, options: .atomic) } catch {
        writeError = error
      }
    }
    if let error = coordinatorError ?? writeError { throw error }
  }

  private func deleteFolder(_ container: String, _ folder: String) throws {
    let dir = try folderURL(container, folder)
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    var deleteError: Error?
    var coordinatorError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: dir, options: .forDeleting, error: &coordinatorError
    ) { url in
      do { try FileManager.default.removeItem(at: url) } catch { deleteError = error }
    }
    if let error = coordinatorError ?? deleteError { throw error }
  }

  private func isUploaded(_ container: String, _ folder: String, _ name: String) throws -> Bool? {
    var url = try folderURL(container, folder).appendingPathComponent(name)
    url.removeAllCachedResourceValues()
    return (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?
      .ubiquitousItemIsUploaded
  }
}
