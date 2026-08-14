import AppKit
import SwiftUI

@main
struct ShixiangApp: App {
    // Keep the first app frame lightweight. The production library snapshot is restored from
    // SQLite after the branded launch surface is visible; tests and explicit maintenance paths
    // still use LibraryStore's normal eager initializer.
    @StateObject private var library = LibraryStore(deferInitialLoad: true)
    @StateObject private var player = AudioPlayerController()
    @StateObject private var pitchPreview = PitchPreviewController()
    @StateObject private var license = ShixiangLicenseStore()
    @StateObject private var updates = ShixiangUpdateStore()

    var body: some Scene {
        WindowGroup("拾响") {
            AppRootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(pitchPreview)
                .environmentObject(license)
                .environmentObject(updates)
                .environment(\.stopPitchPreview) { pitchPreview.stop() }
                // This is a desktop production tool, not a compact utility. Below this point
                // the sidebar, sound columns, and persistent player compete for the same space
                // and information starts to disappear instead of reflowing. Keep resizing fully
                // flexible above the threshold, but stop at the smallest useful working canvas.
                .frame(minWidth: 1_180, minHeight: 720)
                .preferredColorScheme(.dark)
                .toolbar(.hidden, for: .windowToolbar)
                .background(WindowChromeConfigurator())
        }
        .defaultSize(width: 1_360, height: 820)
        // Keep the native traffic lights, but let the app's first control row share their
        // surface. The title remains hidden, so the system never creates a second "拾响" row.
        .windowStyle(.hiddenTitleBar)

        Settings {
            AppSettingsView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(license)
                .environmentObject(updates)
        }
    }
}

/// Makes the native title-bar material transparent without removing the traffic lights. SwiftUI
/// still owns all app content; this tiny host view only configures the containing NSWindow once
/// it exists, so the command row is visible rather than being painted underneath an opaque bar.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeConfigurationView {
        WindowChromeConfigurationView()
    }

    func updateNSView(_ view: WindowChromeConfigurationView, context: Context) {}
}

private final class WindowChromeConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Keep the native window constraint in sync with the SwiftUI content constraint. This
        // prevents a user dragging the frame below the readable desktop layout and clipping the
        // sidebar, list columns, or persistent player bar.
        window.contentMinSize = NSSize(width: 1_180, height: 720)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Player controls and sliders must always win mouse events. The app has a hidden title
        // bar, but macOS traffic-light/title-bar space remains available for moving the window.
        window.isMovableByWindowBackground = false
    }
}

private struct AppRootView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var hasCompletedMinimumLaunchTime = false
    @State private var hasReachedMaximumLaunchTime = false
    @State private var isLibraryPresentationReady = false
    @State private var isSplashVisible = true

    var body: some View {
        ZStack {
            // Build the real workspace from the first frame. Its async result snapshot and
            // sidebar counts warm up behind the branded launch surface, so the first revealed
            // frame is the usable library rather than a second loading state.
            LocalLibraryView {
                isLibraryPresentationReady = true
                finishLaunchIfReady()
            }

            if isSplashVisible {
                ModeSelectionView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(10)
            }
        }
        .task {
            // Keep the identity moment long enough to read, while the readiness gate below
            // still lets a fast machine leave early only after its first usable library frame.
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            hasCompletedMinimumLaunchTime = true
            finishLaunchIfReady()
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            hasReachedMaximumLaunchTime = true
            finishLaunchIfReady()
        }
        .task {
            // Wait until the initial identity moment has yielded a real interactive window, then
            // let the store restore the existing sound package in a utility-priority task.
            try? await Task.sleep(for: .seconds(3.7))
            guard !Task.isCancelled else { return }
            library.startDeferredStartupWork()
        }
    }

    private func finishLaunchIfReady() {
        guard hasCompletedMinimumLaunchTime,
              isLibraryPresentationReady || hasReachedMaximumLaunchTime,
              isSplashVisible else {
            return
        }
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.62)) {
            isSplashVisible = false
        }
    }
}
