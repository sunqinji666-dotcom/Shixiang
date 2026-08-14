import AppKit
import SwiftUI

/// Publishes only the two edges of a macOS live resize. The content can temporarily choose a
/// cheap representation while AppKit is continuously changing the window's geometry.
struct WindowLiveResizeMonitor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll(keepingCapacity: true)
            guard let window else { return }

            // Keep AppKit's hosting surface on its native live-resize redraw path. SwiftUI still
            // receives the final geometry, but the window server can reuse the backing surface
            // between pointer events instead of forcing a full view-tree redraw on every edge or
            // corner drag. No layer is created here, so this remains safe for the existing
            // SwiftUI materials and accessibility hierarchy.
            window.animationBehavior = .none
            // SwiftUI's virtualized List/DisclosureGroup hierarchy does not expose the
            // rectangle-preservation hooks that AppKit requires for safe stale-content reuse.
            // Let AppKit redraw the hosting view during the gesture so rows cannot be painted in
            // their former positions. Waveforms still use the separate lightweight resize path.
            window.preservesContentDuringLiveResize = false
            window.contentView?.layerContentsRedrawPolicy = .duringViewResize

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSWindow.willStartLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onChange?(true)
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onChange?(false)
                }
            )
            onChange?(window.inLiveResize)
        }

        override func removeFromSuperview() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll(keepingCapacity: true)
            super.removeFromSuperview()
        }
    }
}

private struct WindowLiveResizeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWindowLiveResizing: Bool {
        get { self[WindowLiveResizeKey.self] }
        set { self[WindowLiveResizeKey.self] = newValue }
    }
}
