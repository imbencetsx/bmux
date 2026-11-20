import AppKit
import SwiftUI

// MARK: - Making the Window See-Through

/// Turns the hosting window non-opaque (and back) and applies a backdrop
/// blur behind it, like Terminal.app's "Background" opacity/blur. SwiftUI
/// fills paint the tint; this only makes the window itself let the desktop
/// through.
///
/// The blur uses the same WindowServer call Ghostty's macOS app uses
/// (`CGSSetWindowBackgroundBlurRadius`), resolved at runtime so a missing
/// symbol simply means "no blur" rather than a launch failure.
struct WindowTransparency: NSViewRepresentable {
    let translucent: Bool
    let blurRadius: Int
    var hideChromePlatters: Bool = false

    private static var translucentWindows: Set<ObjectIdentifier> = []

    static func isTranslucent(window: NSWindow) -> Bool {
        translucentWindows.contains(ObjectIdentifier(window))
    }

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.translucent = translucent
        view.blurRadius = blurRadius
        view.hideChromePlatters = hideChromePlatters
        view.apply()
    }

    final class BridgeView: NSView {
        var translucent = false
        var blurRadius = 0
        var hideChromePlatters = false
        private var appliedState: (Bool, Int, Bool)?
        private weak var appliedWindow: NSWindow?
        private var observers: [AnyObject] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            appliedState = nil
            setupObservers()
            apply()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                clearObservers()
                if let window {
                    WindowTransparency.translucentWindows.remove(ObjectIdentifier(window))
                }
            }
        }

        private func setupObservers() {
            clearObservers()
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyPlatterPolicy()
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyPlatterPolicy()
                }
            })
        }

        private func clearObservers() {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
            observers.removeAll()
        }

        func apply() {
            guard let window else { return }
            guard window.windowNumber > 0 else {
                // Not on screen yet: the blur needs a WindowServer id.
                DispatchQueue.main.async { [weak self] in self?.apply() }
                return
            }
            let state = (translucent, translucent ? max(0, blurRadius) : 0, hideChromePlatters)
            if appliedWindow === window, let appliedState, appliedState == state { return }
            appliedWindow = window
            appliedState = state

            if translucent {
                WindowTransparency.translucentWindows.insert(ObjectIdentifier(window))
                window.isOpaque = false
                // Near-clear (not fully clear) keeps the window shadow and
                // hit testing in areas no SwiftUI view paints.
                window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
            } else {
                WindowTransparency.translucentWindows.remove(ObjectIdentifier(window))
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            }
            WindowBlur.set(radius: state.1, on: window)
            window.invalidateShadow()

            applyPlatterPolicy()
        }

        func applyPlatterPolicy() {
            guard let window, hideChromePlatters else { return }
            ToolbarPlatterCleaner.hidePlatters(in: window)
        }
    }
}

/// Private WindowServer backdrop blur, looked up once.
@MainActor
enum WindowBlur {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetBlur = @convention(c) (Int32, Int, Int32) -> Int32

    private static let symbols: (MainConnection, SetBlur)? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let conn = dlsym(handle, "CGSMainConnectionID"),
              let blur = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (
            unsafeBitCast(conn, to: MainConnection.self),
            unsafeBitCast(blur, to: SetBlur.self)
        )
    }()

    static func set(radius: Int, on window: NSWindow) {
        guard let (connection, setBlur) = symbols else { return }
        _ = setBlur(connection(), window.windowNumber, Int32(clamping: radius))
    }
}
