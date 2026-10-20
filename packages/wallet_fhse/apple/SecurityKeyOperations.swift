#if os(iOS)
import CoreNFC
import CryptoTokenKit
import ExternalAccessory
#elseif os(macOS)
import IOKit.hid
#endif
import CryptoKit
import Foundation
import YubiKit

// FIDO2 security-key operations for FHSE (vtnerd/fhse) wallet-file encryption.
//
// FHSE needs a non-discoverable credential created with the hmac-secret
// extension under a non-web relying-party id ("fhse:encryption"), and later a
// raw CTAP2 getAssertion that returns the 32-byte hmac-secret output. Platform
// passkey APIs cannot do that (domain rpIds, hashed PRF salts), so this talks
// CTAP2 directly through YubiKit's CTAP2.Session. User verification is the
// key's PIN or its built-in UV (a YubiKey Bio fingerprint): credProtect level 3
// at creation and a fresh PIN/UV token for every makeCredential/getAssertion.
// Tokens are never kept beyond one call. Both kinds of token set CTAP's UV
// flag, so the hmac-secret output is the same whichever one was used.
//
// Before CTAP2, the YubiKey serial number is read from the Management
// application on the same connection. That tells the UI which registered key
// is connected, and lets a request refuse a different key before a PIN or UV
// token request reaches it (credProtect 3 hides credentials until then).
// With several keys plugged in, each one blinks and the one the user touches
// is the one used (KeyLink.touchSelect); later requests connect to it alone,
// so no PIN can reach another. A Mac knows the device by its IORegistry entry
// id (HIDKeyConnection), new at every plugging-in, so a key swapped in after
// the touch is refused even where no serial number can be read. iOS knows a
// USB-C key by its smart card slot, and a swap there by its serial.
//
// One file for iOS and macOS, compiled into each app's Runner (see README.md
// here): only the connection to the key differs (the KeyLink section at the
// end). iOS reaches keys over NFC, USB-C (smart card) and, where the app
// declares the 5Ci's protocol, Lightning; macOS over USB HID.
//
// This file has no Flutter types; SecurityKeyChannel.swift maps it to the
// method channel. Nothing here logs PINs, salts, user ids, credential ids,
// serial numbers or hmac-secret outputs, and YubiKit's own logging is capped
// at warnings (its debug level can print credential ids).

// MARK: - Results and errors

enum SecurityKeyTransport: String, Sendable {
  case nfc
  case usb
  case lightning

  /// Plugged in (USB-C or Lightning), so a touch is a separate step. Holding
  /// a key to NFC already shows the user is there.
  var isWired: Bool { self != .nfc }
}

/// How the user is verified for enroll and getHmacSecret.
enum SecurityKeyVerification: Sendable {
  /// The key's PIN.
  case pin(String)
  /// The key's built-in user verification (a YubiKey Bio fingerprint).
  case uv

  var usesBuiltInUV: Bool {
    if case .uv = self { return true }
    return false
  }
}

/// Progress for the UI while a request runs. Never carries secrets.
enum SecurityKeyStatus: String, Sendable {
  case waitingForKey
  case keyConnected
  case processing
  case touchNeeded
  case fingerprintNeeded
}

/// Hears one request's progress, with the key's transport once connected.
/// Called on the operations actor; it must hand off to its own thread.
typealias SecurityKeyStatusHandler = @Sendable (SecurityKeyStatus, SecurityKeyTransport?) -> Void

struct SecurityKeyCapabilities: Sendable {
  let nfc: Bool
  let usb: Bool
}

struct SecurityKeyInfo: Sendable {
  let pinSet: Bool
  let pinRetries: Int?
  let hmacSecret: Bool
  let credProtect: Bool
  let aaguid: Data?
  let versions: [String]
  let transport: SecurityKeyTransport
  /// YubiKey serial number; nil when hidden, not a YubiKey, or unreadable.
  let serial: Int?
  /// Built-in UV present and configured (options.uv == true).
  let uv: Bool
  /// Built-in UV present at all, configured or not (options lists uv).
  let uvSupported: Bool
  /// Only when `uv`: UV retries left, nil if the key would not say.
  let uvRetries: Int?
  /// options.pinUvAuthToken == true; the UV path needs it.
  let pinUvAuthToken: Bool
  let minPinLength: Int
  let forcePinChange: Bool
  /// The key was touched for authenticatorSelection.
  let touched: Bool
}

/// The credential used and its 32-byte hmac-secret output. A class so the
/// output has a single owner that can zero it in place once it is delivered
/// (wiping a copy of a Data value would only zero the copy).
final class SecurityKeySecret: @unchecked Sendable {
  let credentialId: Data
  /// Serial number of the key that did the work, when it would say.
  let serial: Int?
  /// The getAssertion's authenticator data and, for an enrollment, the
  /// makeCredential's, as the key sent them. Dart checks every platform's
  /// reply the same way (wallet_fhse's key_reply.dart); the checks here stay
  /// as a first line.
  let authenticatorData: Data
  /// Set once, by `enroll`, before the secret is handed on.
  var creationAuthenticatorData: Data?
  private var hmacSecret: Data
  private let lock = NSLock()

  init(credentialId: Data, serial: Int?, hmacSecret: Data, authenticatorData: Data) {
    self.credentialId = credentialId
    self.serial = serial
    self.hmacSecret = hmacSecret
    self.authenticatorData = authenticatorData
  }

  /// Gives `body` the output; copy out what is needed, do not keep it.
  func withHmacSecret<R>(_ body: (Data) throws -> R) rethrows -> R {
    try lock.withLock { try body(hmacSecret) }
  }

  func wipe() {
    lock.withLock { hmacSecret.wipe() }
  }

  deinit {
    hmacSecret.wipe()
  }
}

/// Every failure leaves this file as one of these; `code` is the channel's
/// error code and `message` is calm, user-presentable copy (it is also what
/// the NFC sheet shows when the session closes with an error).
struct SecurityKeyError: Error, LocalizedError, Sendable {
  enum Code: String, Sendable {
    case cancelled
    case timeout
    case busy
    case pinNotSet
    case pinAlreadySet
    case pinInvalid
    case pinBlocked
    case pinAuthBlocked
    case pinPolicy
    case pinChangeRequired
    case differentKey
    case multipleKeys
    case uvInvalid
    case uvBlocked
    case uvNotConfigured
    case noCredentials
    case credentialExcluded
    case unsupported
    case transport
    case unknown
  }

  let code: Code
  let message: String
  /// Only for `pinInvalid` and `uvInvalid`: PIN or UV retries left, when the
  /// key would say.
  let retries: Int?

  init(_ code: Code, _ message: String, retries: Int? = nil) {
    self.code = code
    self.message = message
    self.retries = retries
  }

  var errorDescription: String? { message }

  static let cancelled = SecurityKeyError(.cancelled, "Cancelled.")
  static let timeout = SecurityKeyError(.timeout, "No security key was found in time.")
  static let busy = SecurityKeyError(.busy, "Another security key request is still running.")
  static let pinNotSet = SecurityKeyError(.pinNotSet, "This security key has no PIN yet.")
  static let pinAlreadySet = SecurityKeyError(.pinAlreadySet, "This security key already has a PIN.")
  static let pinChangeRequired = SecurityKeyError(
    .pinChangeRequired, "This security key needs a new PIN before it can be used.")
  static let differentKey = SecurityKeyError(
    .differentKey, "This is a different security key from the one you chose.")
  static let multipleKeys = SecurityKeyError(
    .multipleKeys, "More than one security key is plugged in. Unplug the others, then try again.")
  static let uvBlocked = SecurityKeyError(
    .uvBlocked, "Fingerprint unlock is locked on this security key. Use its PIN instead.")
  static let noCredentials = SecurityKeyError(
    .noCredentials, "This security key does not hold the key for this wallet.")

  static func unsupported(_ message: String) -> SecurityKeyError {
    SecurityKeyError(.unsupported, message)
  }

  static func unknown(_ message: String) -> SecurityKeyError {
    SecurityKeyError(.unknown, message)
  }
}

// MARK: - Operations

actor SecurityKeyOperations {
  /// How long to wait for a key to be tapped or plugged in.
  static let connectTimeout: Duration = .seconds(60)

  /// FHSE's libfido2 code signs over clientdata {0x01}; CTAP gets its SHA-256.
  static let clientDataHash = Data(SHA256.hash(data: Data([0x01])))

  static let userName = "FHSE Encryption"
  static let saltLength = 32
  static let maxUserIdLength = 64
  static let defaultMaxCredentialCountInList = 8
  /// CTAP 2.1's minimum when getInfo does not report minPINLength.
  static let defaultMinPinLength = 4

  private static let holdMessage = "Keep holding your key…"
  private static let doneMessage = "Done."

  private static let configureLogging: Void = {
    // YubiKit logs credential ids at debug level; keep it to warnings.
    Logs.configure(logLevel: .warning)
  }()

  private var isRunning = false
  private var cancelRequested = false

  // Connection phase. The generation keeps a late result or a stale timer
  // from one request from touching the next one.
  private var connectGeneration = 0
  private var connectWaiter: CheckedContinuation<KeyLink, Error>?
  private var connectTask: Task<Void, Never>?
  private var connectTimer: Task<Void, Never>?

  // Set while the key waits for a touch, so cancel() can abort it on the key.
  private var ctapCancel: (@Sendable () async -> Void)?

  // Per request: who hears about progress, the transport once a key is
  // connected, and whether a wait on the key is for a fingerprint.
  private var onStatus: SecurityKeyStatusHandler?
  private var statusTransport: SecurityKeyTransport?
  private var usesBuiltInUV = false

  // The key chosen in the last touch inspect, by KeyLink.deviceID (macOS).
  // A later request connects to it, and refuses another key whose serial
  // cannot tell them apart.
  private var chosenDevice: KeyLink.DeviceID?

  init() {
    _ = Self.configureLogging
  }

  // MARK: Capabilities

  nonisolated static func capabilities() -> SecurityKeyCapabilities {
    #if os(macOS)
    // USB only: a Mac reaches keys over USB HID, and has no NFC reader to use.
    return SecurityKeyCapabilities(nfc: false, usb: true)
    #elseif targetEnvironment(simulator)
    return SecurityKeyCapabilities(nfc: false, usb: false)
    #else
    // USB-C keys use CryptoTokenKit (needs the smart card entitlement);
    // Lightning devices use the YubiKey 5Ci over External Accessory, only
    // when the app declares its protocol (see DeviceModel.lightningDeclared).
    let usb =
      DeviceModel.hasLightningPort
      ? DeviceModel.lightningDeclared : TKSmartCardSlotManager.default != nil
    return SecurityKeyCapabilities(nfc: NFCTagReaderSession.readingAvailable, usb: usb)
    #endif
  }

  // MARK: Public operations

  /// Reads the key's capabilities. With `touch`, a wired key is also asked for
  /// a touch (authenticatorSelection) so the user confirms which key it is.
  func inspect(
    prompt: String,
    touch: Bool,
    onStatus: @escaping SecurityKeyStatusHandler
  ) async throws -> SecurityKeyInfo {
    try await withKey(prompt: prompt, choosing: touch, onStatus: onStatus) { session, link, serial in
      let info = try await session.getInfo()
      try checkCancelled()
      let pinProtocol = Self.pinProtocol(for: info)
      let pinSet = info.options.clientPin == true
      var pinRetries: Int?
      if pinSet {
        pinRetries = try? await session.getPinRetries(protocol: pinProtocol).retries
      }
      let uv = info.options.userVerification == true
      var uvRetries: Int?
      if uv {
        uvRetries = try? await session.getUVRetries(protocol: pinProtocol)
      }
      try checkCancelled()

      // Last, so the answer follows the touch straight away. A key touched
      // to choose it among several is not asked again.
      var touched = link.touched
      if touch, !touched, link.transport.isWired {
        touched = try await touchToSelect(session, info: info)
      }
      return SecurityKeyInfo(
        pinSet: pinSet,
        pinRetries: pinRetries,
        hmacSecret: info.extensions.contains(.hmacSecret),
        credProtect: info.extensions.contains(.credProtect),
        aaguid: info.aaguid.rawValue,
        versions: info.versions.map(Self.versionString),
        transport: link.transport,
        serial: serial,
        uv: uv,
        uvSupported: info.options.userVerification != nil,
        uvRetries: uvRetries,
        pinUvAuthToken: info.options.pinUVAuthToken == true,
        minPinLength: info.minPinLength.map { Int($0) } ?? Self.defaultMinPinLength,
        forcePinChange: info.forcePinChange == true,
        touched: touched
      )
    }
  }

  func setPin(
    newPin: String,
    expectSerial: Int?,
    prompt: String,
    onStatus: @escaping SecurityKeyStatusHandler
  ) async throws {
    guard !newPin.isEmpty else { throw SecurityKeyError(.pinPolicy, "The PIN is empty.") }
    try await withKey(
      prompt: prompt, expectSerial: expectSerial, onStatus: onStatus
    ) { session, _, _ in
      let info = try await session.getInfo()
      guard let clientPin = info.options.clientPin else {
        throw SecurityKeyError.unsupported("This security key does not support a PIN.")
      }
      if clientPin { throw SecurityKeyError.pinAlreadySet }
      let length = newPin.precomposedStringWithCanonicalMapping.unicodeScalars.count
      if let minLength = info.minPinLength, length < Int(minLength) {
        throw SecurityKeyError(.pinPolicy, "The PIN must be at least \(minLength) characters.")
      }
      try checkCancelled()
      do {
        try await session.setPin(newPin, protocol: Self.pinProtocol(for: info))
      } catch CTAP2.SessionError.illegalArgument {
        // YubiKit's own length checks (4 code points, 63 UTF-8 bytes).
        throw SecurityKeyError(.pinPolicy, "The PIN must be 4 to 63 characters.")
      } catch CTAP2.SessionError.ctapError(.notAllowed, _) {
        throw SecurityKeyError.pinAlreadySet
      }
    }
  }

  func enroll(
    rpId: String,
    userId: Data,
    salt: Data,
    verification: SecurityKeyVerification,
    excludeCredentialIds: [Data],
    expectSerial: Int?,
    prompt: String,
    onStatus: @escaping SecurityKeyStatusHandler
  ) async throws -> SecurityKeySecret {
    try Self.validate(rpId: rpId, salt: salt, verification: verification)
    guard (1...Self.maxUserIdLength).contains(userId.count) else {
      throw SecurityKeyError.unknown("Invalid argument: userId must be 1 to 64 bytes.")
    }

    return try await withKey(
      prompt: prompt, builtInUV: verification.usesBuiltInUV, expectSerial: expectSerial,
      onStatus: onStatus
    ) { session, link, serial in
      // a. Capabilities.
      let info = try await session.getInfo()
      let missing = [CTAP2.Extension.Identifier.hmacSecret, .credProtect]
        .filter { !info.extensions.contains($0) }
        .map(\.value)
      guard missing.isEmpty else {
        throw SecurityKeyError.unsupported(
          "This security key does not support \(missing.joined(separator: " or ")).")
      }
      try Self.requireUsable(info, for: verification)
      // b. PIN/UV auth protocol.
      let pinProtocol = Self.pinProtocol(for: info)
      try checkCancelled()

      // c. PIN/UV token for makeCredential (and getAssertion), bound to rpId.
      let createToken = try await authToken(
        session, verification, permissions: [.makeCredential, .getAssertion], rpId: rpId,
        protocol: pinProtocol)
      try checkCancelled()

      // d. makeCredential: non-discoverable, hmac-secret, credProtect 3.
      let credProtect = try await CTAP2.Extension.CredProtect(
        level: .userVerificationRequired, session: session, enforce: true)
      let hmacSecret = CTAP2.Extension.HmacSecret()
      let parameters = CTAP2.MakeCredential.Parameters(
        clientDataHash: Self.clientDataHash,
        rp: WebAuthn.RelyingParty(id: rpId, name: rpId),
        user: WebAuthn.User(id: userId, name: Self.userName, displayName: Self.userName),
        pubKeyCredParams: [.es256],
        excludeList: excludeCredentialIds.isEmpty
          ? nil : excludeCredentialIds.map { WebAuthn.CredentialDescriptor(id: $0) },
        extensions: [hmacSecret.makeCredential.input(), credProtect.input()],
        rk: false
      )
      let created = try await finish(
        await session.makeCredential(parameters: parameters, token: createToken))

      guard credProtect.output(from: created) == .userVerificationRequired else {
        throw SecurityKeyError.unsupported("credProtect not applied")
      }
      guard (try? hmacSecret.makeCredential.output(from: created)) == .enabled else {
        throw SecurityKeyError.unsupported("hmac-secret not enabled on the new credential")
      }
      guard let credentialId = created.authenticatorData.attestedCredentialData?.credentialId,
        !credentialId.isEmpty
      else {
        throw SecurityKeyError.unknown("The security key did not return a credential id.")
      }
      try checkCancelled()
      await link.setStatus(Self.holdMessage)

      // e. Fresh token: CTAP 2.1 drops mc/ga permissions after makeCredential.
      let assertToken = try await authToken(
        session, verification, permissions: [.getAssertion], rpId: rpId, protocol: pinProtocol)
      try checkCancelled()

      // f. getAssertion with one hmac-secret salt.
      let secret = try await assertHmacSecret(
        session, rpId: rpId, salt: salt, allowList: [credentialId], token: assertToken,
        serial: serial)
      secret.creationAuthenticatorData = created.authenticatorData.rawData
      return secret
    }
  }

  func getHmacSecret(
    rpId: String,
    salt: Data,
    verification: SecurityKeyVerification,
    credentialIds: [Data],
    expectSerial: Int?,
    prompt: String,
    onStatus: @escaping SecurityKeyStatusHandler
  ) async throws -> SecurityKeySecret {
    try Self.validate(rpId: rpId, salt: salt, verification: verification)
    let credentialIds = credentialIds.filter { !$0.isEmpty }
    guard !credentialIds.isEmpty else { throw SecurityKeyError.noCredentials }

    return try await withKey(
      prompt: prompt, builtInUV: verification.usesBuiltInUV, expectSerial: expectSerial,
      onStatus: onStatus
    ) { session, _, serial in
      let info = try await session.getInfo()
      guard info.extensions.contains(.hmacSecret) else {
        throw SecurityKeyError.unsupported("This security key does not support hmac-secret.")
      }
      try Self.requireUsable(info, for: verification)
      let pinProtocol = Self.pinProtocol(for: info)
      let batchSize = max(
        1, Int(info.maxCredentialCountInList ?? UInt(Self.defaultMaxCredentialCountInList)))

      for start in stride(from: 0, to: credentialIds.count, by: batchSize) {
        let batch = Array(credentialIds[start..<min(start + batchSize, credentialIds.count)])
        try checkCancelled()
        // A fresh token per attempt, so a failed batch cannot leave it spent
        // (with built-in UV that is one fingerprint per batch).
        let token = try await authToken(
          session, verification, permissions: [.getAssertion], rpId: rpId, protocol: pinProtocol)
        try checkCancelled()
        do {
          return try await assertHmacSecret(
            session, rpId: rpId, salt: salt, allowList: batch, token: token, serial: serial)
        } catch CTAP2.SessionError.ctapError(.noCredentials, _) {
          continue
        }
      }
      throw SecurityKeyError.noCredentials
    }
  }

  /// Cancels whatever is in flight; that request then fails with `cancelled`.
  func cancel() async {
    guard isRunning else { return }
    cancelRequested = true
    abandonConnect(with: .cancelled)
    if let ctapCancel {
      await ctapCancel()
    }
  }

  // MARK: Request lifecycle

  /// Waits for a key, reads its serial number, opens a CTAP2 session, runs
  /// `body` with the serial, then closes the connection (with a success or
  /// failure message on the NFC sheet). With `expectSerial`, a key reporting
  /// a different serial fails with `differentKey` before `body` runs, so
  /// before any PIN or UV token request. So does a key plugged in other than
  /// the one `choosing` (a touch inspect) last connected to, unless their
  /// serials match. `onStatus` hears this request's progress until it
  /// returns; with `builtInUV` a wait on the key is reported as a
  /// fingerprint.
  private func withKey<T: Sendable>(
    prompt: String,
    builtInUV: Bool = false,
    expectSerial: Int? = nil,
    choosing: Bool = false,
    onStatus: @escaping SecurityKeyStatusHandler,
    _ body: (CTAP2.Session, KeyLink, Int?) async throws -> T
  ) async throws -> T {
    guard !isRunning else { throw SecurityKeyError.busy }
    isRunning = true
    cancelRequested = false
    self.onStatus = onStatus
    statusTransport = nil
    usesBuiltInUV = builtInUV
    defer {
      isRunning = false
      ctapCancel = nil
      self.onStatus = nil
      statusTransport = nil
      usesBuiltInUV = false
    }

    report(.waitingForKey)
    let link: KeyLink
    do {
      link = try await connect(prompt: prompt, choosing: choosing)
    } catch let error as SecurityKeyError where error.code == .differentKey {
      // The chosen key is gone; the next request starts afresh.
      chosenDevice = nil
      throw error
    }
    statusTransport = link.transport
    report(.keyConnected)
    do {
      try checkCancelled()
      await link.setStatus(Self.holdMessage)
      // A key that hides its serial (or is not a YubiKey) is let through.
      let serial = await Self.readSerial(link.connection)
      try checkCancelled()
      if let expectSerial, let serial, serial != expectSerial {
        throw SecurityKeyError.differentKey
      }
      if choosing {
        chosenDevice = link.deviceID
      } else if let chosen = chosenDevice, let device = link.deviceID, device != chosen,
        expectSerial == nil || serial != expectSerial
      {
        // The chosen key is gone; the next request starts afresh.
        chosenDevice = nil
        throw SecurityKeyError.differentKey
      }
      let session: CTAP2.Session
      do {
        session = try await CTAP2.Session.makeSession(connection: link.connection)
      } catch CTAP2.SessionError.featureNotSupported {
        #if os(iOS)
        // FIDO over USB CCID needs YubiKey firmware 5.8 or later.
        throw SecurityKeyError.unsupported(
          link.transport == .usb
            ? "This security key cannot use FIDO2 over USB-C on this device (that needs firmware 5.8 or later). Unplug it and hold it to the phone to use NFC instead."
            : "This security key does not offer FIDO2 over this connection.")
        #else
        throw SecurityKeyError.unsupported("This security key does not offer FIDO2 over USB.")
        #endif
      }
      report(.processing)
      // Once the key has done the work, a late cancel no longer undoes it.
      let result = try await body(session, link, serial)
      await link.closeSucceeded(Self.doneMessage)
      return result
    } catch {
      let failure = cancelRequested ? SecurityKeyError.cancelled : Self.map(error, builtInUV: builtInUV)
      await link.closeFailed(failure)
      throw failure
    }
  }

  private func checkCancelled() throws {
    if cancelRequested { throw SecurityKeyError.cancelled }
  }

  /// Passes progress to the current request's handler (repeats are dropped
  /// on the receiving side).
  private func report(_ status: SecurityKeyStatus) {
    onStatus?(status, statusTransport)
  }

  /// Several keys blink for the user to touch one (a Mac).
  private func touchNeededToChoose() {
    guard isRunning else { return }
    statusTransport = .usb
    report(.touchNeeded)
  }

  /// What a wait on the key asks of the user: a fingerprint in built-in UV
  /// mode (on a YubiKey Bio every touch lands on the sensor), else a touch.
  private var userWaitStatus: SecurityKeyStatus {
    usesBuiltInUV ? .fingerprintNeeded : .touchNeeded
  }

  /// Waits for a key (KeyLink.waitForKey): on a Mac, the one chosen in the
  /// last touch inspect, unless `choosing` again.
  private func connect(prompt: String, choosing: Bool) async throws -> KeyLink {
    connectGeneration &+= 1
    let generation = connectGeneration
    let chosen = choosing ? nil : chosenDevice

    let link: KeyLink
    do {
      link = try await withCheckedThrowingContinuation { continuation in
        connectWaiter = continuation
        connectTask = Task.detached { [weak self] in
          let result: Result<KeyLink, Error>
          do {
            result = .success(
              try await KeyLink.waitForKey(prompt: prompt, chosen: chosen) { [weak self] in
                Task { await self?.touchNeededToChoose() }
              })
          } catch {
            result = .failure(error)
          }
          if let self {
            await self.connectFinished(generation: generation, result: result)
          } else if case .success(let link) = result {
            await link.closeQuietly()
          }
        }
        connectTimer = Task.detached { [weak self] in
          do {
            try await Task.sleep(for: Self.connectTimeout)
          } catch {
            return
          }
          await self?.connectDeadlinePassed(generation: generation)
        }
      }
    } catch {
      if let error = error as? SecurityKeyError { throw error }
      if cancelRequested { throw SecurityKeyError.cancelled }
      throw Self.map(error)
    }

    if cancelRequested {
      await link.closeFailed(.cancelled)
      throw SecurityKeyError.cancelled
    }
    return link
  }

  private func connectFinished(generation: Int, result: Result<KeyLink, Error>) async {
    guard generation == connectGeneration, let waiter = connectWaiter else {
      // Nobody waits for this key any more (cancelled or timed out).
      if case .success(let link) = result { await link.closeQuietly() }
      return
    }
    connectWaiter = nil
    connectTask = nil
    connectTimer?.cancel()
    connectTimer = nil
    waiter.resume(with: result)
  }

  private func connectDeadlinePassed(generation: Int) {
    guard generation == connectGeneration else { return }
    abandonConnect(with: .timeout)
  }

  /// Stops waiting for a key. A key that still shows up is closed on arrival.
  private func abandonConnect(with error: SecurityKeyError) {
    guard let waiter = connectWaiter else { return }
    connectWaiter = nil
    connectTask?.cancel()  // dismisses the NFC sheet and stops wired polling
    connectTask = nil
    connectTimer?.cancel()
    connectTimer = nil
    waiter.resume(throwing: error)
  }

  /// Runs a CTAP status stream to its result, keeping the cancel handle while
  /// the key waits for a touch and reporting the waits. Never cancels the
  /// Swift task (YubiKit's streams treat that as a programming error).
  private func finish<R: Sendable>(_ stream: CTAP2.StatusStream<R>) async throws -> R {
    defer { ctapCancel = nil }
    var waited = false
    for try await status in stream {
      switch status {
      case .processing:
        report(.processing)
      case .waitingForUser(let cancel):
        ctapCancel = cancel
        waited = true
        report(userWaitStatus)
        if cancelRequested { await cancel() }
      case .finished(let response):
        if waited { report(.processing) }
        return response
      }
    }
    throw SecurityKeyError.cancelled
  }

  // MARK: Serial number

  /// The YubiKey serial number from the Management application
  /// (DeviceInfo.serialNumber), or nil when the key hides it (YubiKit reports
  /// 0), is not a YubiKey, or the read fails for any reason; it never fails
  /// the request. It must run before the CTAP2 session is made: making that
  /// session selects the FIDO applet again, so a failed or partial
  /// Management exchange cannot leave CTAP2 talking to the wrong applet.
  /// Never logged.
  private static func readSerial(_ connection: KeyLink.Connection) async -> Int? {
    guard let management = try? await Management.Session.makeSession(connection: connection),
      let info = try? await management.getDeviceInfo(),
      info.serialNumber != 0
    else { return nil }
    return Int(exactly: info.serialNumber)
  }

  // MARK: CTAP steps

  /// CTAP 2.1 authenticatorSelection: the key blinks until it is touched.
  /// Keys that only report FIDO_2_0/FIDO_2_1_PRE (YubiKey 5 firmware 5.2 to
  /// 5.4) are skipped without asking, as browsers and python-fido2 do; a key
  /// that answers "invalid command" anyway is skipped too. Returns whether
  /// the touch happened.
  private func touchToSelect(
    _ session: CTAP2.Session,
    info: CTAP2.GetInfo.Response
  ) async throws -> Bool {
    guard info.versions.contains(.fido2_1) else { return false }
    report(.touchNeeded)
    do {
      try await finish(await session.selection())
    } catch let error as CTAP2.SessionError where !cancelRequested && Self.isUnknownCommand(error) {
      report(.processing)
      return false
    }
    report(.processing)
    return true
  }

  /// A PIN or built-in UV token with `permissions`, bound to `rpId`.
  private func authToken(
    _ session: CTAP2.Session,
    _ verification: SecurityKeyVerification,
    permissions: CTAP2.ClientPin.Permission,
    rpId: String,
    protocol pinProtocol: CTAP2.ClientPin.ProtocolVersion
  ) async throws -> CTAP2.Token {
    switch verification {
    case .pin(let pin):
      return try await pinToken(
        session, pin: pin, permissions: permissions, rpId: rpId, protocol: pinProtocol)
    case .uv:
      return try await uvToken(
        session, permissions: permissions, rpId: rpId, protocol: pinProtocol)
    }
  }

  /// getPinUvAuthTokenUsingUvWithPermissions: the key waits for a matching
  /// fingerprint. YubiKit 1.4.0 only exposes this call without keepalive
  /// updates (getPinUVTokenUpdates is internal), so the wait is reported
  /// around it, and cancel() cannot abort it on the key: a cancelled request
  /// ends once the key stops waiting.
  private func uvToken(
    _ session: CTAP2.Session,
    permissions: CTAP2.ClientPin.Permission,
    rpId: String,
    protocol pinProtocol: CTAP2.ClientPin.ProtocolVersion
  ) async throws -> CTAP2.Token {
    report(.fingerprintNeeded)
    do {
      let token = try await session.getPinUVToken(
        using: .uv, permissions: permissions, rpId: rpId, protocol: pinProtocol)
      report(.processing)
      return token
    } catch CTAP2.SessionError.ctapError(.uvInvalid, _) {
      let retries = try? await session.getUVRetries(protocol: pinProtocol)
      throw SecurityKeyError(.uvInvalid, "Fingerprint not recognized.", retries: retries)
    } catch CTAP2.SessionError.ctapError(.uvBlocked, _),
      CTAP2.SessionError.ctapError(.puatRequired, _)
    {
      throw SecurityKeyError.uvBlocked
    } catch CTAP2.SessionError.featureNotSupported,
      CTAP2.SessionError.ctapError(.notAllowed, _),
      CTAP2.SessionError.ctapError(.invalidSubcommand, _)
    {
      // YubiKit's own check (no pinUvAuthToken), or the key turning down
      // built-in UV that it has not got or has not set up.
      throw SecurityKeyError(
        .uvNotConfigured, "This security key cannot use a fingerprint for this.")
    }
  }

  private func pinToken(
    _ session: CTAP2.Session,
    pin: String,
    permissions: CTAP2.ClientPin.Permission,
    rpId: String,
    protocol pinProtocol: CTAP2.ClientPin.ProtocolVersion
  ) async throws -> CTAP2.Token {
    // getPinUVToken uses getPinUvAuthTokenUsingPinWithPermissions when the key
    // reports options.pinUvAuthToken, otherwise the legacy getPinToken.
    do {
      return try await session.getPinUVToken(
        using: .pin(pin), permissions: permissions, rpId: rpId, protocol: pinProtocol)
    } catch CTAP2.SessionError.ctapError(.pinInvalid, _) {
      let retries = try? await session.getPinRetries(protocol: pinProtocol).retries
      throw SecurityKeyError(.pinInvalid, "Wrong PIN.", retries: retries)
    }
  }

  /// getAssertion with the hmac-secret extension and one 32-byte salt.
  ///
  /// HmacSecret(session:) does the CTAP 2.1 §12.5 work: getKeyAgreement,
  /// encapsulate with the session's PIN protocol, saltEnc = encrypt(salt),
  /// saltAuth = authenticate(saltEnc); output() decrypts the result.
  private func assertHmacSecret(
    _ session: CTAP2.Session,
    rpId: String,
    salt: Data,
    allowList: [Data],
    token: CTAP2.Token,
    serial: Int?
  ) async throws -> SecurityKeySecret {
    let hmacSecret = try await CTAP2.Extension.HmacSecret(session: session)
    let parameters = CTAP2.GetAssertion.Parameters(
      rpId: rpId,
      clientDataHash: Self.clientDataHash,
      allowList: allowList.map { WebAuthn.CredentialDescriptor(id: $0) },
      extensions: [try hmacSecret.getAssertion.input(salt1: salt)]
    )
    let response = try await finish(
      await session.getAssertion(parameters: parameters, token: token))

    let secrets: CTAP2.Extension.HmacSecret.Secrets?
    do {
      secrets = try hmacSecret.getAssertion.output(from: response)
    } catch {
      throw SecurityKeyError.unsupported("The security key returned an unreadable hmac-secret.")
    }
    guard let secrets, secrets.second == nil, secrets.first.count == Self.saltLength else {
      throw SecurityKeyError.unsupported("The security key did not return a 32-byte hmac-secret.")
    }

    let credentialId: Data
    if let id = response.credential?.id {
      guard allowList.contains(id) else {
        throw SecurityKeyError.unknown("The security key answered for an unexpected credential.")
      }
      credentialId = id
    } else if allowList.count == 1 {
      credentialId = allowList[0]
    } else {
      throw SecurityKeyError.unknown("The security key did not say which credential it used.")
    }
    return SecurityKeySecret(
      credentialId: credentialId, serial: serial, hmacSecret: secrets.first,
      authenticatorData: response.authenticatorData.rawData)
  }

  // MARK: Helpers

  private static func validate(
    rpId: String,
    salt: Data,
    verification: SecurityKeyVerification
  ) throws {
    guard !rpId.isEmpty else { throw SecurityKeyError.unknown("Invalid argument: rpId is empty.") }
    guard salt.count == saltLength else {
      throw SecurityKeyError.unknown("Invalid argument: salt must be 32 bytes.")
    }
    if case .pin(let pin) = verification, pin.isEmpty {
      throw SecurityKeyError(.pinInvalid, "The PIN is empty.")
    }
  }

  /// Checks, before any token is asked for, that the key can verify the user
  /// the way `verification` says.
  private static func requireUsable(
    _ info: CTAP2.GetInfo.Response,
    for verification: SecurityKeyVerification
  ) throws {
    switch verification {
    case .pin:
      guard info.options.clientPin == true else { throw SecurityKeyError.pinNotSet }
      if info.forcePinChange == true { throw SecurityKeyError.pinChangeRequired }
      if info.options.noMcGaPermissionsWithClientPin == true {
        throw SecurityKeyError.unsupported("This security key does not accept a PIN for this.")
      }
    case .uv:
      switch info.options.userVerification {
      case .none:
        throw SecurityKeyError(.uvNotConfigured, "This security key has no fingerprint reader.")
      case .some(false):
        throw SecurityKeyError(
          .uvNotConfigured, "This security key has no fingerprint set up yet.")
      case .some(true):
        break
      }
      guard info.options.pinUVAuthToken == true else {
        throw SecurityKeyError(
          .uvNotConfigured, "This security key cannot use a fingerprint for this.")
      }
    }
  }

  /// The key does not know the command: CTAP1_ERR_INVALID_COMMAND, YubiKit's
  /// own feature check, or ISO 7816 "instruction not supported" from the
  /// smart card layer.
  private static func isUnknownCommand(_ error: CTAP2.SessionError) -> Bool {
    switch error {
    case .ctapError(.invalidCommand, _), .featureNotSupported:
      return true
    case .failedResponse(let response, _):
      return response.status == .invalidInstruction
    default:
      return false
    }
  }

  private static func pinProtocol(for info: CTAP2.GetInfo.Response)
    -> CTAP2.ClientPin.ProtocolVersion
  {
    info.pinUVAuthProtocols.contains(.v2) ? .v2 : .v1
  }

  private static func versionString(_ version: CTAP2.GetInfo.AuthenticatorVersion) -> String {
    switch version {
    case .u2fV2: return "U2F_V2"
    case .fido2_0: return "FIDO_2_0"
    case .fido2_1Pre: return "FIDO_2_1_PRE"
    case .fido2_1: return "FIDO_2_1"
    case .unknown(let value): return value
    }
  }

  // MARK: Error mapping

  /// `builtInUV`: the request verifies with built-in UV, so PUAT_REQUIRED
  /// means that UV is no longer usable.
  static func map(_ error: Error, builtInUV: Bool = false) -> SecurityKeyError {
    switch error {
    case let error as SecurityKeyError:
      return error
    case let error as CTAP2.SessionError:
      return map(session: error, builtInUV: builtInUV)
    case let error as SmartCardConnectionError:
      return map(connection: error)
    case let error as FIDOConnectionError:
      return map(fido: error)
    case is CancellationError:
      return .cancelled
    default:
      return .unknown(error.localizedDescription)
    }
  }

  private static func map(session error: CTAP2.SessionError, builtInUV: Bool) -> SecurityKeyError {
    switch error {
    case .ctapError(let ctap, _):
      return map(ctap: ctap, builtInUV: builtInUV)
    case .connectionError(let connection, _):
      return map(connection: connection)
    case .extensionNotSupported(let identifier, _):
      return .unsupported("This security key does not support \(identifier.value).")
    case .featureNotSupported:
      return .unsupported("This security key does not support this.")
    case .timeout:
      return .timeout
    case .failedResponse(let response, _):
      return SecurityKeyError(
        .transport,
        "The security key returned status \(String(format: "%04X", response.rawStatus)).")
    case .hidError, .fidoConnectionError, .initializationFailed:
      return SecurityKeyError(.transport, "Lost the connection to the security key.")
    case .responseParseError(let message, _), .illegalArgument(let message, _),
      .dataProcessingError(let message, _), .cryptoError(let message, _, _):
      return .unknown(message)
    default:
      return .unknown("The security key request failed.")
    }
  }

  private static func map(ctap error: CTAP2.Error, builtInUV: Bool) -> SecurityKeyError {
    switch error {
    case .pinInvalid:
      return SecurityKeyError(.pinInvalid, "Wrong PIN.")
    case .pinBlocked:
      return SecurityKeyError(.pinBlocked, "This security key's PIN is blocked.")
    case .pinAuthBlocked:
      return SecurityKeyError(
        .pinAuthBlocked, "Too many wrong PINs. Remove or lift the key, then try again.")
    case .pinPolicyViolation:
      return SecurityKeyError(.pinPolicy, "The PIN does not meet this security key's rules.")
    case .pinNotSet:
      return .pinNotSet
    case .uvInvalid:
      return SecurityKeyError(.uvInvalid, "Fingerprint not recognized.")
    case .uvBlocked:
      return .uvBlocked
    case .puatRequired where builtInUV:
      return .uvBlocked
    case .noCredentials:
      return .noCredentials
    case .credentialExcluded:
      return SecurityKeyError(
        .credentialExcluded, "This security key is already set up for this wallet.")
    case .keepaliveCancel:
      return .cancelled
    case .userActionTimeout, .actionTimeout:
      return SecurityKeyError(.timeout, "The security key was not touched in time.")
    case .unsupportedExtension, .unsupportedAlgorithm, .unsupportedOption:
      return .unsupported("This security key does not support this request.")
    default:
      return .unknown("The security key reported an error (\(error)).")
    }
  }

  private static func map(connection error: SmartCardConnectionError) -> SecurityKeyError {
    switch error {
    case .cancelled, .cancelledByUser:
      return .cancelled
    case .busy:
      return SecurityKeyError(.busy, "The security key is busy with another request.")
    case .unsupported:
      return .unsupported("This device cannot reach a security key this way.")
    case .setupFailed(_, let underlying?), .transmitFailed(_, let underlying?):
      #if os(iOS)
      if let nfcError = underlying as? NFCReaderError { return map(nfc: nfcError) }
      #else
      _ = underlying
      #endif
      return SecurityKeyError(.transport, "Lost the connection to the security key.")
    default:
      return SecurityKeyError(
        .transport, "Lost the connection to the security key. Hold it still and try again.")
    }
  }

  /// USB HID (macOS).
  private static func map(fido error: FIDOConnectionError) -> SecurityKeyError {
    switch error {
    case .busy:
      return SecurityKeyError(.busy, "The security key is busy with another request.")
    case .unsupported:
      return .unsupported("This device cannot reach a security key this way.")
    default:
      return SecurityKeyError(
        .transport, "Lost the connection to the security key. Check it is plugged in and try again.")
    }
  }

  #if os(iOS)
  private static func map(nfc error: NFCReaderError) -> SecurityKeyError {
    switch error.code {
    case .readerSessionInvalidationErrorUserCanceled, .readerTransceiveErrorSessionInvalidated:
      return .cancelled
    case .readerSessionInvalidationErrorSessionTimeout:
      return .timeout
    case .readerErrorUnsupportedFeature:
      return .unsupported("NFC is not available on this device.")
    case .readerErrorSecurityViolation:
      return .unsupported("This app is not allowed to use NFC.")
    default:
      return SecurityKeyError(
        .transport, "Lost the connection to the security key. Hold it still and try again.")
    }
  }
  #endif
}

// MARK: - Connections

#if os(iOS)
/// An open connection to a key and how it is attached.
private struct KeyLink: Sendable {
  typealias Connection = any SmartCardConnection
  /// A USB-C key's smart card slot name.
  typealias DeviceID = String
  let connection: Connection
  let transport: SecurityKeyTransport
  /// The USB-C slot the key is in; nil over NFC and Lightning.
  var deviceID: DeviceID? = nil
  /// The user touched this key to choose it among several.
  var touched = false

  /// Updates the NFC sheet; wired keys have no system UI.
  func setStatus(_ message: String) async {
    if let nfc = connection.nfcConnection {
      await nfc.setAlertMessage(message)
    }
  }

  func closeSucceeded(_ message: String) async {
    if let nfc = connection.nfcConnection {
      await nfc.close(message: message)
    } else {
      await connection.close(error: nil)
    }
  }

  func closeFailed(_ error: SecurityKeyError) async {
    // On NFC the sheet shows error.localizedDescription.
    await connection.close(error: error)
  }

  func closeQuietly() async {
    if let nfc = connection.nfcConnection {
      await nfc.close(message: nil)
    } else {
      await connection.close(error: nil)
    }
  }

  /// A wired key that is already attached wins; otherwise the NFC sheet shows
  /// `prompt` while wired keys are still watched for. Without NFC, waits for a
  /// wired key. Cancelling the calling task dismisses the sheet. Of several
  /// USB-C keys (through a hub), `chosen` is used while it is plugged in, else
  /// the one the user touches (`onTouchNeeded` says they all blink).
  static func waitForKey(
    prompt: String,
    chosen: DeviceID?,
    onTouchNeeded: @escaping @Sendable () -> Void
  ) async throws -> KeyLink {
    if let wired = try await attachWired(chosen: chosen, onTouchNeeded: onTouchNeeded) {
      return wired
    }
    guard NFCTagReaderSession.readingAvailable else {
      return try await pollWired(chosen: chosen, onTouchNeeded: onTouchNeeded)
    }

    return try await withThrowingTaskGroup(of: KeyLink.self, returning: KeyLink.self) { group in
      group.addTask {
        let nfc = try await NFCSmartCardConnection(alertMessage: prompt)
        return KeyLink(connection: nfc, transport: .nfc)
      }
      group.addTask {
        try await pollWired(chosen: chosen, onTouchNeeded: onTouchNeeded)
      }

      var winner: KeyLink?
      var failure: Error?
      do {
        winner = try await group.next()
      } catch {
        failure = error
      }
      group.cancelAll()
      // Both could connect at once; keep the first and release the other.
      while !group.isEmpty {
        do {
          if let late = try await group.next() {
            if winner == nil && failure == nil {
              winner = late
            } else {
              await late.closeQuietly()
            }
          }
        } catch {}
      }
      if let winner { return winner }
      throw failure ?? CancellationError()
    }
  }

  private static func pollWired(
    chosen: DeviceID?,
    onTouchNeeded: @escaping @Sendable () -> Void
  ) async throws -> KeyLink {
    while true {
      try Task.checkCancellation()
      if let link = try await attachWired(chosen: chosen, onTouchNeeded: onTouchNeeded) {
        return link
      }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  /// Connects to a key that is plugged in right now, or returns nil. A failed
  /// attempt (say, a key pulled out mid-connect) counts as no key yet.
  ///
  /// Of several USB-C keys: `chosen` while it is there. When it is gone, one
  /// key left is connected to and withKey's serial check decides; of several,
  /// none is surely the chosen one (`differentKey`). Without `chosen`, the one
  /// the user touches ([touchSelect]).
  private static func attachWired(
    chosen: DeviceID?,
    onTouchNeeded: @escaping @Sendable () -> Void
  ) async throws -> KeyLink? {
    // Only connect over Lightning once a 5Ci is attached: YubiKit's
    // Lightning connect otherwise waits indefinitely and ignores cancellation.
    // Without the protocol in Info.plist iOS lists no 5Ci, so this is skipped.
    if await lightningKeyAttached(),
      let connection = try? await LightningSmartCardConnection()
    {
      return KeyLink(connection: connection, transport: .lightning)
    }
    // Without a slot manager (no smart card entitlement, or the simulator)
    // YubiKit asserts in debug builds, so check first.
    guard TKSmartCardSlotManager.default != nil,
      let slots = try? await USBSmartCardConnection.availableDevices(),
      !slots.isEmpty
    else { return nil }
    if let chosen, let slot = slots.first(where: { $0.name == chosen }) {
      return await open(slot)
    }
    if chosen != nil, slots.count > 1 { throw SecurityKeyError.differentKey }
    if slots.count == 1 { return await open(slots[0]) }
    onTouchNeeded()
    return try await touchSelect(slots)
  }

  private static func open(_ slot: USBSmartCard.YubiKeyDevice) async -> KeyLink? {
    guard let connection = try? await USBSmartCardConnection(slot: slot) else { return nil }
    return KeyLink(connection: connection, transport: .usb, deviceID: slot.name)
  }

  private enum Choice: Sendable {
    case touched(Int)
    case cannotAsk
    case lookAgain
  }

  /// Has every USB-C key in `slots` wait for a touch (CTAP 2.1
  /// authenticatorSelection: FIDO over USB-C needs firmware 5.8, which has
  /// it) and keeps the one touched connected; the others are told to stop.
  /// Nil when keys came or went meanwhile, so the caller looks again. Fails
  /// with `multipleKeys` when none of them can be asked.
  private static func touchSelect(_ slots: [USBSmartCard.YubiKeyDevice]) async throws -> KeyLink? {
    // YubiKit opens one slot at a time.
    var connections: [USBSmartCardConnection] = []
    for slot in slots {
      guard let connection = try? await USBSmartCardConnection(slot: slot) else { break }
      connections.append(connection)
    }
    var winner: Int?
    do {
      if connections.count == slots.count {
        winner = try await waitForTouch(connections, slots: slots)
      } else {
        // One could not be opened (pulled out, or still closing).
        try await Task.sleep(for: .milliseconds(500))
      }
    } catch {
      for connection in connections { await connection.close(error: nil) }
      throw error
    }
    for (index, connection) in connections.enumerated() where index != winner {
      await connection.close(error: nil)
    }
    guard let winner else { return nil }
    return KeyLink(
      connection: connections[winner], transport: .usb, deviceID: slots[winner].name, touched: true)
  }

  /// The index of the key touched, or nil to look again. Never cancels a
  /// YubiKit stream's task to stop a key: each key's own cancel handle does
  /// ([TouchStopper]).
  private static func waitForTouch(
    _ connections: [USBSmartCardConnection],
    slots: [USBSmartCard.YubiKeyDevice]
  ) async throws -> Int? {
    let stopper = TouchStopper()
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Choice.self, returning: Int?.self) { group in
        for (index, connection) in connections.enumerated() {
          group.addTask {
            guard let session = try? await CTAP2.Session.makeSession(connection: connection) else {
              return .cannotAsk
            }
            var everWaited = false
            while true {
              var waited = false
              do {
                for try await status in await session.selection() {
                  switch status {
                  case .processing:
                    break
                  case .waitingForUser(let cancel):
                    waited = true
                    everWaited = true
                    await stopper.add(index, cancel)
                  case .finished:
                    return .touched(index)
                  }
                }
              } catch {
                if !everWaited { return .cannotAsk }
              }
              // A key that waited, then gave up (its own timeout), is asked
              // again; anything else is a change.
              let stopped = await stopper.isStopped
              if !waited || stopped || Task.isCancelled { return .lookAgain }
            }
          }
        }
        group.addTask {
          while !(await stopper.isStopped), !Task.isCancelled {
            guard let now = try? await USBSmartCardConnection.availableDevices(),
              Set(now) == Set(slots)
            else { return .lookAgain }
            try? await Task.sleep(for: .milliseconds(500))
          }
          return .lookAgain
        }
        var unable = 0
        while let choice = try await group.next() {
          switch choice {
          case .touched(let index):
            await stopper.stop(except: index)
            return index
          case .lookAgain:
            await stopper.stop(except: nil)
            return nil
          case .cannotAsk:
            unable += 1
            if unable == connections.count {
              await stopper.stop(except: nil)
              throw SecurityKeyError.multipleKeys
            }
          }
        }
        return nil
      }
    } onCancel: {
      Task { await stopper.stop(except: nil) }
    }
  }

  @MainActor
  private static func lightningKeyAttached() -> Bool {
    EAAccessoryManager.shared().connectedAccessories.contains {
      $0.manufacturer == "Yubico" && $0.protocolStrings.contains("com.yubico.ylp")
    }
  }
}

/// The cancel handles of the keys waiting for a touch, by key, so all but the
/// one touched can be told to stop. A handle that comes after the stop is
/// used at once.
private actor TouchStopper {
  private(set) var isStopped = false
  private var cancels: [(key: Int, cancel: @Sendable () async -> Void)] = []

  func add(_ key: Int, _ cancel: @escaping @Sendable () async -> Void) async {
    if isStopped {
      await cancel()
    } else {
      cancels.append((key, cancel))
    }
  }

  func stop(except kept: Int?) async {
    isStopped = true
    let cancels = self.cancels
    self.cancels = []
    for (key, cancel) in cancels where key != kept {
      await cancel()
    }
  }
}
#elseif os(macOS)
/// An open connection to a key: on a Mac, FIDO over USB HID, which every
/// FIDO2 YubiKey offers (the smart card route needs firmware 5.8 or later for
/// FIDO2), to one device chosen by its IORegistry entry id. The serial number
/// is read over it too.
private struct KeyLink: Sendable {
  typealias Connection = HIDKeyConnection
  /// A key's IORegistry entry id, new each time a key is plugged in: tells a
  /// key from another where no serial number can be read.
  typealias DeviceID = UInt64
  let connection: Connection
  let transport: SecurityKeyTransport
  var deviceID: DeviceID? = nil
  /// The user touched this key to choose it among several.
  var touched = false

  /// Wired keys have no system sheet to update.
  func setStatus(_ message: String) async {}

  func closeSucceeded(_ message: String) async {
    await connection.close(error: nil)
  }

  func closeFailed(_ error: SecurityKeyError) async {
    await connection.close(error: error)
  }

  func closeQuietly() async {
    await connection.close(error: nil)
  }

  /// Waits for a key to be plugged in and connects to it: `chosen` while it
  /// is plugged in, else the only key, else the one the user touches among
  /// several (`onTouchNeeded` says they all blink). Cancelling the calling
  /// task stops the wait. A failed attempt (one pulled out mid-connect, say)
  /// counts as no key yet.
  ///
  /// When `chosen` is gone: one key left is connected to, and withKey's
  /// serial check decides; of several, none is surely the chosen one, so the
  /// request fails with `differentKey`.
  static func waitForKey(
    prompt: String,
    chosen: DeviceID?,
    onTouchNeeded: @escaping @Sendable () -> Void
  ) async throws -> KeyLink {
    while true {
      try Task.checkCancellation()
      let devices = fidoDevices()
      if let chosen, !devices.contains(chosen), devices.count > 1 {
        throw SecurityKeyError.differentKey
      }
      if let chosen, devices.contains(chosen) {
        if let link = open(chosen) { return link }
      } else if devices.count == 1 {
        if let link = open(devices[0]) { return link }
      } else if devices.count > 1 {
        onTouchNeeded()
        if let connection = try await touchSelect(devices) {
          return KeyLink(
            connection: connection, transport: .usb, deviceID: connection.deviceID, touched: true)
        }
        continue
      }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  private static func open(_ device: UInt64) -> KeyLink? {
    guard let connection = try? HIDKeyConnection(deviceID: device) else { return nil }
    return KeyLink(connection: connection, transport: .usb, deviceID: device)
  }

  private enum Choice: Sendable {
    case touched(HIDKeyConnection)
    case cannotAsk
    case lookAgain
  }

  /// Has every key in `devices` wait for a touch (HIDKeyConnection's touch
  /// probe, as libfido2 does it), keeps the one touched open and tells the
  /// others to stop. Nil when keys came or went meanwhile, so the caller looks
  /// again. Fails with `multipleKeys` when none of them can be asked.
  private static func touchSelect(_ devices: [UInt64]) async throws -> HIDKeyConnection? {
    var connections: [HIDKeyConnection] = []
    for device in devices {
      guard let connection = try? HIDKeyConnection(deviceID: device) else { break }
      connections.append(connection)
    }
    var winner: HIDKeyConnection?
    defer {
      let others = connections.filter { $0 !== winner }
      Task { for connection in others { await connection.close(error: nil) } }
    }
    // One could not be opened (pulled out, or held by another app).
    guard connections.count == devices.count else {
      try await Task.sleep(for: .milliseconds(500))
      return nil
    }

    winner = try await withThrowingTaskGroup(of: Choice.self, returning: HIDKeyConnection?.self) {
      group in
      for connection in connections {
        group.addTask {
          do {
            // A key that gives up waiting (its own timeout) is asked again.
            while true {
              switch try await connection.waitForTouch() {
              case .touched: return .touched(connection)
              case .gaveUp: continue
              case .refused: return .cannotAsk
              }
            }
          } catch {
            // Pulled out, or told to stop because another was touched.
            return .lookAgain
          }
        }
      }
      group.addTask {
        while fidoDevices() == devices {
          do {
            try await Task.sleep(for: .milliseconds(500))
          } catch {
            break
          }
        }
        return .lookAgain
      }
      var unable = 0
      while let choice = try await group.next() {
        switch choice {
        case .touched(let connection):
          group.cancelAll()
          return connection
        case .lookAgain:
          group.cancelAll()
          return nil
        case .cannotAsk:
          unable += 1
          if unable == connections.count {
            group.cancelAll()
            throw SecurityKeyError.multipleKeys
          }
        }
      }
      return nil
    }
    return winner
  }

  /// The FIDO HID devices plugged in, by IORegistry entry id. YubiKit's own
  /// filter (usage page 0xF1D0, any vendor), so every key it could connect to
  /// counts. Enumerates without opening any of them.
  static func fidoDevices() -> [UInt64] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let filter: [String: Any] = [
      kIOHIDDeviceUsagePageKey as String: 0xF1D0,
      kIOHIDDeviceUsageKey as String: 0x01,
    ]
    IOHIDManagerSetDeviceMatching(manager, filter as CFDictionary)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    return devices.map { device in
      var id: UInt64 = 0
      IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
      return id
    }.sorted()
  }
}

/// A FIDO HID connection to one device, named by its IORegistry entry id.
/// YubiKit's HIDFIDOConnection connects to whichever FIDO device it lists
/// first; this one reaches the key the user chose, so a PIN cannot go to
/// another. It moves raw 64-byte reports, as YubiKit's does: YubiKit's CTAP2
/// and Management sessions frame CTAPHID on top. The touch probe used to
/// choose a key frames its own ([waitForTouch]).
///
/// Reports arrive on a dispatch queue of its own. The device is seized while
/// open; close waits until it is released, so the next request can open it.
final class HIDKeyConnection: FIDOConnection, @unchecked Sendable {
  static let reportSize = 64
  let mtu = HIDKeyConnection.reportSize
  let deviceID: UInt64

  private let device: IOHIDDevice
  private let report: UnsafeMutablePointer<UInt8>
  private let queue = DispatchQueue(label: "org.magicgrants.fhse.hid")
  private let lock = NSLock()
  private var frames: [Data] = []
  private var receiver: CheckedContinuation<Data, Error>?
  private var closed = false
  private var closeError: Error?
  private var closeWaiters: [CheckedContinuation<Error?, Never>] = []
  private var released = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  // The channel of a running touch probe, for CTAPHID_CANCEL.
  private var probeChannel: UInt32?

  /// FIDOConnection asks for these; a key is opened by id instead.
  init() async throws(FIDOConnectionError) {
    throw .noDevicesFound
  }

  static func makeConnection() async throws(FIDOConnectionError) -> HIDKeyConnection {
    throw .noDevicesFound
  }

  init(deviceID: UInt64) throws(FIDOConnectionError) {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(deviceID))
    guard service != IO_OBJECT_NULL else { throw .noDevicesFound }
    defer { IOObjectRelease(service) }
    guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
      throw .setupFailed("Could not reach the security key")
    }
    let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    guard opened == kIOReturnSuccess else {
      throw opened == kIOReturnExclusiveAccess ? .busy : .setupFailed("Could not open the security key")
    }
    self.deviceID = deviceID
    self.device = device
    self.report = .allocate(capacity: Self.reportSize)

    // Held until the cancel handler, which runs once the queue delivers
    // nothing more (after close).
    let context = Unmanaged.passRetained(self).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(
      device, report, Self.reportSize,
      { context, result, _, type, _, data, length in
        guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput else { return }
        Unmanaged<HIDKeyConnection>.fromOpaque(context).takeUnretainedValue()
          .deliver(Data(bytes: data, count: length))
      }, context)
    IOHIDDeviceRegisterRemovalCallback(
      device,
      { context, _, _ in
        guard let context else { return }
        Unmanaged<HIDKeyConnection>.fromOpaque(context).takeUnretainedValue()
          .shut(FIDOConnectionError.connectionLost)
      }, context)
    IOHIDDeviceSetDispatchQueue(device, queue)
    let report = self.report
    IOHIDDeviceSetCancelHandler(device) {
      IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
      report.deallocate()
      let connection = Unmanaged<HIDKeyConnection>.fromOpaque(context)
      connection.takeUnretainedValue().didRelease()
      connection.release()
    }
    IOHIDDeviceActivate(device)
  }

  // MARK: FIDOConnection

  func send(_ packet: Data) async throws(FIDOConnectionError) {
    guard packet.count <= mtu else { throw .transmitFailed("A HID report is at most 64 bytes") }
    guard !isClosed else { throw .connectionLost }
    guard write(packet) else { throw .transmitFailed("HID transmit failed") }
  }

  /// The next report. Cancelling the task gives up the wait (YubiKit's frame
  /// timeout does); a report that comes later is kept for the next call.
  func receive() async throws(FIDOConnectionError) -> Data {
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
          lock.lock()
          if !frames.isEmpty {
            let frame = frames.removeFirst()
            lock.unlock()
            continuation.resume(returning: frame)
          } else if closed || Task.isCancelled {
            let closed = self.closed
            lock.unlock()
            continuation.resume(
              throwing: closed
                ? FIDOConnectionError.connectionLost : FIDOConnectionError.receiveFailed("Cancelled"))
          } else {
            receiver = continuation
            lock.unlock()
          }
        }
      } onCancel: {
        takeReceiver()?.resume(throwing: FIDOConnectionError.receiveFailed("Cancelled"))
      }
    } catch let error as FIDOConnectionError {
      throw error
    } catch {
      throw .receiveFailed(nil, error)
    }
  }

  func close(error: Error?) async {
    shut(error)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
      } else {
        releaseWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func waitUntilClosed() async -> Error? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
      lock.lock()
      if closed {
        let error = closeError
        lock.unlock()
        continuation.resume(returning: error)
      } else {
        closeWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  // MARK: Reports

  private var isClosed: Bool {
    lock.withLock { closed }
  }

  /// One output report, zero-padded to 64 bytes as CTAPHID expects.
  private func write(_ packet: Data) -> Bool {
    var bytes = [UInt8](repeating: 0, count: Self.reportSize)
    bytes.replaceSubrange(0..<packet.count, with: packet)
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bytes, bytes.count)
      == kIOReturnSuccess
  }

  private func deliver(_ frame: Data) {
    lock.lock()
    if let receiver {
      self.receiver = nil
      lock.unlock()
      receiver.resume(returning: frame)
    } else {
      frames.append(frame)
      lock.unlock()
    }
  }

  private func takeReceiver() -> CheckedContinuation<Data, Error>? {
    lock.withLock {
      let receiver = self.receiver
      self.receiver = nil
      return receiver
    }
  }

  /// Stops it: a waiting receive fails, and the device is let go (the cancel
  /// handler closes it). Also when the key is pulled out.
  private func shut(_ error: Error?) {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    closeError = error
    let receiver = self.receiver
    self.receiver = nil
    let waiters = closeWaiters
    closeWaiters = []
    lock.unlock()
    receiver?.resume(throwing: FIDOConnectionError.connectionLost)
    waiters.forEach { $0.resume(returning: error) }
    IOHIDDeviceCancel(device)
  }

  private func didRelease() {
    lock.lock()
    released = true
    let waiters = releaseWaiters
    releaseWaiters = []
    lock.unlock()
    waiters.forEach { $0.resume() }
  }

  // MARK: Touch probe

  enum TouchOutcome: Sendable {
    case touched
    /// The key waited, then gave up (its own timeout).
    case gaveUp
    /// The key cannot be asked this way.
    case refused
  }

  /// Has the key wait for a touch the way libfido2 does
  /// (fido_dev_get_touch_begin): an authenticatorMakeCredential with an
  /// empty pinUvAuthParam, which a FIDO2 key answers once touched with
  /// PIN_NOT_SET or PIN_INVALID, making nothing. A key that verifies no PIN
  /// at all makes a credential no one keeps; it is not discoverable, so the
  /// key stores nothing. Cancelling the task tells the key to stop
  /// (CTAPHID_CANCEL).
  func waitForTouch() async throws -> TouchOutcome {
    let channel = try await openChannel()
    try await sendMessage(channel: channel, command: Self.cbor, payload: Self.touchProbe)
    lock.withLock { probeChannel = channel }
    defer { lock.withLock { probeChannel = nil } }
    return try await withTaskCancellationHandler {
      var waited = false
      while true {
        let (command, payload) = try await receiveMessage(channel: channel)
        switch command {
        case Self.keepalive:
          waited = waited || payload.first == Self.keepaliveUserPresenceNeeded
        case Self.cbor:
          if let status = payload.first, Self.touchedStatuses.contains(status) { return .touched }
          return waited ? .gaveUp : .refused
        default:
          return waited ? .gaveUp : .refused
        }
      }
    } onCancel: {
      if let channel = lock.withLock({ probeChannel }) {
        _ = write(Self.frame(channel: channel, command: Self.cancel, payload: []))
      }
    }
  }

  // CTAPHID (CTAP 2.1, section 11.2).
  private static let broadcast: UInt32 = 0xFFFF_FFFF
  private static let initCommand: UInt8 = 0x86
  private static let cbor: UInt8 = 0x90
  private static let cancel: UInt8 = 0x91
  private static let keepalive: UInt8 = 0xBB
  private static let keepaliveUserPresenceNeeded: UInt8 = 0x02
  /// CTAP2_OK, PIN_INVALID, PIN_AUTH_INVALID, PIN_NOT_SET: what libfido2
  /// counts as touched.
  private static let touchedStatuses: Set<UInt8> = [0x00, 0x31, 0x33, 0x35]

  /// authenticatorMakeCredential (0x01) with libfido2's dummy request, keys
  /// in CTAP's canonical order: {1: 32 zero bytes, 2: {"id": ".dummy"},
  /// 3: {"id": h'00', "name": "dummy"}, 4: [{"alg": -7, "type": "public-key"}],
  /// 8: h'' (the empty pinUvAuthParam), 9: 1}.
  private static let touchProbe: [UInt8] =
    [0x01, 0xA6, 0x01, 0x58, 0x20] + [UInt8](repeating: 0, count: 32)
    + [0x02, 0xA1, 0x62] + Array("id".utf8) + [0x66] + Array(".dummy".utf8)
    + [0x03, 0xA2, 0x62] + Array("id".utf8) + [0x41, 0x00, 0x64] + Array("name".utf8)
    + [0x65] + Array("dummy".utf8)
    + [0x04, 0x81, 0xA2, 0x63] + Array("alg".utf8) + [0x26, 0x64] + Array("type".utf8)
    + [0x6A] + Array("public-key".utf8)
    + [0x08, 0x40, 0x09, 0x01]

  /// A channel of its own (CTAPHID_INIT on the broadcast channel).
  private func openChannel() async throws -> UInt32 {
    var nonce = [UInt8](repeating: 0, count: 8)
    guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
      throw FIDOConnectionError.setupFailed("No randomness for CTAPHID_INIT")
    }
    try await sendMessage(channel: Self.broadcast, command: Self.initCommand, payload: nonce)
    while true {
      let (command, payload) = try await receiveMessage(channel: Self.broadcast)
      guard command == Self.initCommand, payload.count >= 12, Array(payload.prefix(8)) == nonce
      else { continue }
      return payload[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
    }
  }

  private func sendMessage(channel: UInt32, command: UInt8, payload: [UInt8]) async throws {
    for packet in Self.frames(channel: channel, command: command, payload: payload) {
      guard write(packet) else { throw FIDOConnectionError.transmitFailed("HID transmit failed") }
    }
  }

  /// The next whole message on `channel`; reports for other channels are
  /// skipped.
  private func receiveMessage(channel: UInt32) async throws -> (UInt8, [UInt8]) {
    while true {
      let first = [UInt8](try await receive())
      guard first.count >= 7, Self.channel(of: first) == channel, first[4] & 0x80 != 0 else {
        continue
      }
      let length = Int(first[5]) << 8 | Int(first[6])
      var payload = Array(first[7...].prefix(length))
      var sequence: UInt8 = 0
      while payload.count < length {
        let next = [UInt8](try await receive())
        guard next.count >= 5, Self.channel(of: next) == channel, next[4] == sequence else {
          throw FIDOConnectionError.receiveFailed("CTAPHID continuation out of order")
        }
        payload += next[5...].prefix(length - payload.count)
        sequence &+= 1
      }
      return (first[4], payload)
    }
  }

  private static func channel(of report: [UInt8]) -> UInt32 {
    report.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
  }

  /// One message as reports: an initialization packet (channel, command,
  /// length, 57 bytes) and continuation packets (channel, sequence, 59 bytes).
  static func frames(channel: UInt32, command: UInt8, payload: [UInt8]) -> [Data] {
    let cid = withUnsafeBytes(of: channel.bigEndian) { Array($0) }
    var packets = [
      Data(
        cid + [command, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
          + payload.prefix(reportSize - 7))
    ]
    var offset = reportSize - 7
    var sequence: UInt8 = 0
    while offset < payload.count {
      let chunk = payload[offset..<min(offset + reportSize - 5, payload.count)]
      packets.append(Data(cid + [sequence] + chunk))
      offset += reportSize - 5
      sequence += 1
    }
    return packets
  }

  private static func frame(channel: UInt32, command: UInt8, payload: [UInt8]) -> Data {
    frames(channel: channel, command: command, payload: payload)[0]
  }
}
#endif

// MARK: - Device and buffer helpers

#if os(iOS)
private enum DeviceModel {
  /// iPhones before the iPhone 15 family have a Lightning port (iPhone15,2
  /// and iPhone15,3 are the iPhone 14 Pro models). iPads fall back to the
  /// smart card check in capabilities().
  static var hasLightningPort: Bool {
    var system = utsname()
    uname(&system)
    let identifier = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    guard identifier.hasPrefix("iPhone") else { return false }
    let numbers = identifier.dropFirst("iPhone".count).split(separator: ",").compactMap { Int($0) }
    guard numbers.count == 2 else { return false }
    return numbers[0] < 15 || (numbers[0] == 15 && numbers[1] <= 3)
  }

  /// Whether Info.plist lists the 5Ci's protocol (com.yubico.ylp) in
  /// UISupportedExternalAccessoryProtocols. App Review accepts that only for
  /// apps registered with Yubico's MFi program, so the store builds leave it
  /// out and Lightning keys are not offered.
  static var lightningDeclared: Bool {
    let protocols = Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols")
    return (protocols as? [String])?.contains("com.yubico.ylp") ?? false
  }
}
#endif

extension Data {
  /// Overwrites this buffer with zeros (best effort: copies made elsewhere,
  /// including inside YubiKit, are not reached).
  mutating func wipe() {
    guard !isEmpty else { return }
    resetBytes(in: startIndex..<endIndex)
  }
}
