import Flutter
import UIKit
import UniformTypeIdentifiers

/// The sync folder on iOS: a folder the user picks in the Files picker, kept
/// as a bookmark (`ref`, base64). It can belong to another app's file
/// provider (a Syncthing app, Dropbox, a server added in Files), so every
/// read and write is coordinated, which also brings a file down when the
/// provider has only a placeholder for it. Each wallet's files sit in a
/// subfolder of it.
///
/// A folder opened in this launch stays open (security-scoped access on)
/// until it is released or the app quits. All file work runs on one serial
/// queue; results return on the main thread.
final class SyncFolder: NSObject, FlutterStreamHandler, UIDocumentPickerDelegate {
  private let queue = DispatchQueue(label: "org.magicgrants.wallet_backup_platform.folder")

  /// Folders opened in this launch, by bookmark. Touched on [queue] only.
  private var opened: [String: URL] = [:]

  private var picking: FlutterResult?
  private var watcher: DispatchSourceFileSystemObject?

  /// The largest backup file there is (wallet_backup's `maxFileSize`).
  private static let maxFileBytes = 64 * 1024

  static func register(with registrar: FlutterPluginRegistrar) {
    let folder = SyncFolder()
    FlutterMethodChannel(
      name: "org.magicgrants.wallet_backup_platform/folder",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in folder.handle(call, result) }
    FlutterEventChannel(
      name: "org.magicgrants.wallet_backup_platform/folder_changes",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(folder)
  }

  private enum FolderError: Error {
    case unavailable(String)
    case conflict(String)
    case tooLarge(String)
    case badArgs(String)

    var flutterError: FlutterError {
      switch self {
      case .unavailable(let message):
        return FlutterError(code: "unavailable", message: message, details: nil)
      case .conflict(let name):
        return FlutterError(code: "conflict", message: name, details: nil)
      case .tooLarge(let name):
        return FlutterError(code: "too_large", message: name, details: nil)
      case .badArgs(let message):
        return FlutterError(code: "bad_args", message: message, details: nil)
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "choose" {
      choose(current: args["current"] as? String, result)
      return
    }
    queue.async {
      let reply: Any?
      do {
        guard let ref = args["ref"] as? String else { throw FolderError.badArgs("ref missing") }
        switch call.method {
        case "available":
          reply = self.available(ref)
        case "list":
          reply = try self.list(ref, try self.require(args["folder"]))
        case "read":
          reply = try self.read(ref, try self.require(args["folder"]), try self.require(args["name"]))
            .map { FlutterStandardTypedData(bytes: $0) }
        case "create":
          guard let data = args["data"] as? FlutterStandardTypedData else {
            throw FolderError.badArgs("data missing")
          }
          try self.create(
            ref, try self.require(args["folder"]), try self.require(args["name"]), data.data)
          reply = nil
        case "deleteFolder":
          try self.deleteFolder(ref, try self.require(args["folder"]))
          reply = nil
        case "release":
          self.opened.removeValue(forKey: ref)?.stopAccessingSecurityScopedResource()
          reply = nil
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
      } catch let error as FolderError {
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

  private func require(_ value: Any?) throws -> String {
    guard let value = value as? String, !value.isEmpty, !value.contains("/"),
      !value.hasPrefix(".")
    else { throw FolderError.badArgs("bad name") }
    return value
  }

  // MARK: - Choosing

  private func choose(current: String?, _ result: @escaping FlutterResult) {
    guard picking == nil else {
      result(FlutterError(code: "busy", message: "The folder picker is already open", details: nil))
      return
    }
    guard #available(iOS 14.0, *), let presenter = Self.topController() else {
      result(FlutterError(code: "unavailable", message: "No folder picker", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    if let current = current { picker.directoryURL = queue.sync { opened[current] } }
    picking = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = picking else { return }
    picking = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    queue.async {
      do {
        _ = url.startAccessingSecurityScopedResource()
        let ref = try url.bookmarkData(
          options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
        ).base64EncodedString()
        self.opened[ref] = url
        let name = FileManager.default.displayName(atPath: url.path)
        DispatchQueue.main.async { result(["ref": ref, "name": name]) }
      } catch {
        url.stopAccessingSecurityScopedResource()
        DispatchQueue.main.async {
          result(FlutterError(code: "unavailable", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    picking?(nil)
    picking = nil
  }

  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  // MARK: - The folder

  /// The folder of [ref], opened once per launch. A stale bookmark (the
  /// folder moved) still resolves; the new one is returned as `renewed`.
  private func resolve(_ ref: String) throws -> (url: URL, renewed: String?) {
    if let url = opened[ref] { return (url, nil) }
    guard let data = Data(base64Encoded: ref) else { throw FolderError.badArgs("bad ref") }
    var stale = false
    let url: URL
    do {
      url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    } catch {
      throw FolderError.unavailable(error.localizedDescription)
    }
    _ = url.startAccessingSecurityScopedResource()
    var renewed: String?
    if stale {
      renewed = try? url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
      ).base64EncodedString()
    }
    opened[renewed ?? ref] = url
    return (url, renewed)
  }

  private func available(_ ref: String) -> [String: Any] {
    guard let resolved = try? resolve(ref) else { return ["available": false] }
    var isDir: ObjCBool = false
    let there =
      FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDir)
      && isDir.boolValue
    var reply: [String: Any] = ["available": there]
    if let renewed = resolved.renewed { reply["ref"] = renewed }
    return reply
  }

  private func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
    var coordinatorError: NSError?
    var bodyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: [], error: &coordinatorError
    ) { readURL in
      do { try body(readURL) } catch { bodyError = error }
    }
    if let error = coordinatorError ?? bodyError { throw error }
  }

  private func coordinate(
    writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
  ) throws {
    var coordinatorError: NSError?
    var bodyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: options, error: &coordinatorError
    ) { writeURL in
      do { try body(writeURL) } catch { bodyError = error }
    }
    if let error = coordinatorError ?? bodyError { throw error }
  }

  private func list(_ ref: String, _ folder: String) throws -> [String] {
    let dir = try resolve(ref).url.appendingPathComponent(folder, isDirectory: true)
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    var names: [String] = []
    try coordinate(reading: dir) { readURL in
      let entries = try FileManager.default.contentsOfDirectory(
        at: readURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])
      for entry in entries {
        let name = entry.lastPathComponent
        // A provider's placeholder for a file not downloaded yet.
        if name.hasPrefix(".") && name.hasSuffix(".icloud") {
          names.append(String(name.dropFirst().dropLast(".icloud".count)))
        } else if !name.hasPrefix("."),
          (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        {
          names.append(name)
        }
      }
    }
    return names
  }

  /// Never past [maxFileBytes]; nil when gone since the listing.
  private func read(_ ref: String, _ folder: String, _ name: String) throws -> Data? {
    let url = try resolve(ref).url.appendingPathComponent(folder, isDirectory: true)
      .appendingPathComponent(name)
    let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(name).icloud")
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) || fm.fileExists(atPath: placeholder.path) else {
      return nil
    }
    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
      size > Self.maxFileBytes
    {
      throw FolderError.tooLarge(name)
    }
    var data: Data?
    do {
      try coordinate(reading: url) { readURL in
        let handle = try FileHandle(forReadingFrom: readURL)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
        if bytes.count > Self.maxFileBytes { throw FolderError.tooLarge(name) }
        data = bytes
      }
    } catch let error as FolderError {
      throw error
    } catch {
      // Removed since the listing (another device's sync): not an error.
      if !fm.fileExists(atPath: url.path) { return nil }
      throw error
    }
    return data
  }

  /// Create-only: the same bytes already there is a safe retry, different
  /// bytes are a conflict, never overwritten. The one exception is a start
  /// of these very bytes (an empty file, or a copy cut short), completed.
  private func create(_ ref: String, _ folder: String, _ name: String, _ data: Data) throws {
    let dir = try resolve(ref).url.appendingPathComponent(folder, isDirectory: true)
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir.path) {
      try coordinate(writing: dir, options: []) { writeURL in
        try fm.createDirectory(at: writeURL, withIntermediateDirectories: true)
      }
    }
    let url = dir.appendingPathComponent(name)
    if fm.fileExists(atPath: url.path) {
      let there = try read(ref, folder, name) ?? Data()
      if there == data { return }
      if there.count >= data.count || data.prefix(there.count) != there {
        throw FolderError.conflict(name)
      }
    }
    try coordinate(writing: url, options: .forReplacing) { writeURL in
      try data.write(to: writeURL, options: .atomic)
    }
  }

  private func deleteFolder(_ ref: String, _ folder: String) throws {
    let dir = try resolve(ref).url.appendingPathComponent(folder, isDirectory: true)
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    try coordinate(writing: dir, options: .forDeleting) { url in
      try FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - Watching

  /// Reports changes to the wallet's subfolder (a file added, removed or
  /// renamed in it) while listened to. Covers folders on this device, where
  /// a Syncthing app writes; a provider that downloads on demand may not
  /// report, and the backup also checks on a timer.
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    let args = arguments as? [String: Any] ?? [:]
    queue.async {
      self.stopWatching()
      do {
        guard let ref = args["ref"] as? String else { throw FolderError.badArgs("ref missing") }
        let dir = try self.resolve(ref).url.appendingPathComponent(
          try self.require(args["folder"]), isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { throw FolderError.unavailable("The folder could not be watched") }
        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { events(nil) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.watcher = source
      } catch let error as FolderError {
        DispatchQueue.main.async { events(error.flutterError) }
      } catch {
        DispatchQueue.main.async {
          events(FlutterError(code: "unavailable", message: error.localizedDescription, details: nil))
        }
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    queue.async { self.stopWatching() }
    return nil
  }

  private func stopWatching() {
    watcher?.cancel()
    watcher = nil
  }
}
