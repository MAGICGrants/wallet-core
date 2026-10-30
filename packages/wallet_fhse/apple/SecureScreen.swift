#if os(iOS)
import UIKit

/// Keeps the app's window out of screenshots, screen recordings and mirroring
/// while a screen that shows a secret is up (wallet_infra's SecureScreenMixin,
/// over the app's `org.magicgrants.wallet/secure_screen` channel).
///
/// iOS has no API for this. What it has is the secure text field, whose canvas
/// every capture leaves out. So the first time protection is asked for, the
/// window's layer is moved into the canvas of a text field, and from then on
/// the field's `isSecureTextEntry` turns the protection on and off. The view
/// hierarchy is untouched, so touches are unaffected.
final class SecureScreen {
  static let shared = SecureScreen()

  private let field = UITextField()
  private weak var window: UIWindow?

  private init() {
    field.isUserInteractionEnabled = false
  }

  func setSecure(_ secure: Bool) {
    if secure { install() }
    field.isSecureTextEntry = secure
  }

  /// Once, for the app's one window. It may not exist yet at launch, so this
  /// waits for the first protected screen.
  private func install() {
    guard window == nil, let window = Self.keyWindow() else { return }
    window.addSubview(field)
    guard let superlayer = window.layer.superlayer, let canvas = canvasLayer() else {
      field.removeFromSuperview()
      return
    }
    superlayer.addSublayer(field.layer)
    canvas.addSublayer(window.layer)
    self.window = window
  }

  /// The field's secure canvas: `_UITextLayoutCanvasView` on iOS 17 and later,
  /// `_UITextFieldCanvasView` before. Its layer is the field's last sublayer
  /// on current releases, which is what to fall back on if the name changes.
  private func canvasLayer() -> CALayer? {
    field.subviews.first { String(describing: type(of: $0)).hasSuffix("CanvasView") }?.layer
      ?? field.layer.sublayers?.last
  }

  private static func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    return windows.first(where: \.isKeyWindow) ?? windows.first
  }
}
#endif
