import AppKit
import SwiftUI

struct LibraryKeyboardActions {
    var moveUp: () -> Void
    var moveDown: () -> Void
    var togglePlayback: () -> Void
    var toggleFavorite: () -> Void
    var skipBackward: () -> Void
    var skipForward: () -> Void
    var focusSearch: () -> Void
    var refreshLibrary: () -> Void
    var showHealth: () -> Void
    var showHelp: () -> Void
}

/// A local event monitor is used because Space/J/K/L are creator-workflow keys, not menu
/// commands. Text entry always wins, so typing a filename never starts or seeks audio.
struct LibraryKeyboardShortcuts: NSViewRepresentable {
    let actions: LibraryKeyboardActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.hostView = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var actions: LibraryKeyboardActions
        weak var hostView: NSView?
        private var monitor: Any?

        init(actions: LibraryKeyboardActions) {
            self.actions = actions
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let hostWindow = self.hostView?.window,
                      event.window === hostWindow else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandF = modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "f"
            if isCommandF {
                actions.focusSearch()
                return true
            }
            let character = event.charactersIgnoringModifiers?.lowercased()
            if modifiers == .command && character == "r" {
                actions.refreshLibrary()
                return true
            }
            if modifiers == [.command, .shift] && character == "h" {
                actions.showHealth()
                return true
            }
            if modifiers == [.command, .shift] && character == "/" {
                actions.showHelp()
                return true
            }

            // Never steal ordinary keys from search, alias, tag, or save-panel text fields.
            if hostView?.window?.firstResponder is NSTextView { return false }
            guard modifiers.isEmpty else { return false }

            switch event.keyCode {
            case 126:
                actions.moveUp()
            case 125:
                actions.moveDown()
            case 49:
                guard !event.isARepeat else { return true }
                actions.togglePlayback()
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "f":
                    guard !event.isARepeat else { return true }
                    actions.toggleFavorite()
                case "j":
                    actions.skipBackward()
                case "k":
                    guard !event.isARepeat else { return true }
                    actions.togglePlayback()
                case "l":
                    actions.skipForward()
                default:
                    return false
                }
            }
            return true
        }
    }
}
