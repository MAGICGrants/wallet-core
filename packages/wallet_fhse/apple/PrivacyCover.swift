#if os(iOS)
import UIKit

/// Covers the app with its launch screen whenever its scene is not active:
/// the app switcher's snapshot, Control Center and Notification Center over
/// it, and the Face ID prompt App Lock raises on the way back. That prompt
/// comes up before the app has drawn App Lock, so without this it shows over
/// the screen the user left. The cover goes as soon as the scene is active
/// again, by which time App Lock is drawn if it is due.
///
/// Native rather than Flutter: while the scene is inactive the app's own
/// frames do not reach the screen. Driven by UIScene's notifications, since
/// the apps use the scene lifecycle and UIKit no longer calls the app
/// delegate's resign- and become-active methods there.
final class PrivacyCover {
  static let shared = PrivacyCover()

  private var observers: [NSObjectProtocol] = []

  /// Per scene: the launch screen's view controller, kept so its view stays
  /// owned while it is shown.
  private var covers: [ObjectIdentifier: UIViewController] = [:]

  private init() {}

  /// Call once, at launch. Not on a Mac running the iOS build: its scene goes
  /// inactive whenever another app is in front, which would cover the window
  /// the user is still looking at, and the Mac has no app switcher snapshot.
  func install() {
    guard observers.isEmpty, !ProcessInfo.processInfo.isiOSAppOnMac else { return }
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIScene.willDeactivateNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let scene = note.object as? UIWindowScene else { return }
        self?.cover(scene)
      },
      center.addObserver(
        forName: UIScene.didActivateNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let scene = note.object as? UIWindowScene else { return }
        self?.uncover(scene)
      },
      // A scene the system lets go of while covered: forget it, so a later
      // scene at the same address is covered too.
      center.addObserver(
        forName: UIScene.didDisconnectNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let scene = note.object as? UIWindowScene else { return }
        self?.uncover(scene)
      },
    ]
  }

  private func cover(_ scene: UIWindowScene) {
    let key = ObjectIdentifier(scene)
    guard covers[key] == nil,
      let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    else { return }
    let controller = Self.launchScreen()
    let view = controller.view!
    view.frame = window.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(view)
    covers[key] = controller
  }

  private func uncover(_ scene: UIWindowScene) {
    covers.removeValue(forKey: ObjectIdentifier(scene))?.view.removeFromSuperview()
  }

  /// The app's launch screen (Info.plist's UILaunchStoryboardName), or a
  /// plain one in the system background colour.
  private static func launchScreen() -> UIViewController {
    if let name = Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String,
      Bundle.main.path(forResource: name, ofType: "storyboardc") != nil,
      let controller = UIStoryboard(name: name, bundle: nil).instantiateInitialViewController()
    {
      return controller
    }
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    return controller
  }
}
#endif
