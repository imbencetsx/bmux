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

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.translucent = translucent
        view.blurRadius = blurRadius
        view.apply()
    }

    final class BridgeView: NSView {
        var translucent = false
        var blurRadius = 0
        private var appliedState: (Bool, Int)?
        private weak var appliedWindow: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            appliedState = nil
            apply()
        }

        func apply() {
            guard let window else { return }
            guard window.windowNumber > 0 else {
                // Not on screen yet: the blur needs a WindowServer id.
                DispatchQueue.main.async { [weak self] in self?.apply() }
                return
            }
            let state = (translucent, translucent ? max(0, blurRadius) : 0)
            if appliedWindow === window, let appliedState, appliedState == state { return }
            appliedWindow = window
            appliedState = state

            if translucent {
                window.isOpaque = false
                // Near-clear (not fully clear) keeps the window shadow and
                // hit testing in areas no SwiftUI view paints.
                window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
            } else {
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            }
            WindowBlur.set(radius: state.1, on: window)
            window.invalidateShadow()
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
