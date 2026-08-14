import AppKit
import ZephyrKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = FanIcon.appIcon(size: 512)

        let state = AppState()
        self.state = state
        statusController = StatusItemController(state: state)

        // Menu bar managers (Ice, Bartender…) can hide a brand new status item,
        // which makes the app look broken on first launch. This escape hatch
        // opens the panel without needing to find the icon.
        switch ProcessInfo.processInfo.environment["ZEPHYR_SHOW_PANEL"] {
        case "1": statusController?.showPanel()
        case "window": statusController?.showPanelWindow()
        case "settings": statusController?.openSettings()
        case "all":
            statusController?.openSettings()
            statusController?.showPanelWindow()
        default: break
        }

        if ProcessInfo.processInfo.environment["ZEPHYR_SHOW_PANEL"] == nil, !HelperClient.isInstalled {
            // First run with no helper: open settings so the install button is visible.
            statusController?.openSettings()
        }

        // A crowded menu bar — especially on a notched Mac — can leave no room
        // for a new status item, and macOS then gives it no window at all. The
        // app would be running with no way to reach it, so show the panel and
        // say what happened. Checked on a delay because the item is not laid
        // out yet at the end of launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusController?.retryStatusItemPlacement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.statusController?.showPanelIfStatusItemUnavailable()
            }
        }
    }

    /// Clicking the app in Finder, Spotlight or the Dock while it is already
    /// running must do something visible — for a menu bar app that means
    /// bringing up the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusController?.showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// NSApplication holds its delegate weakly, so keep a strong reference here.
var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    application.delegate = delegate
    application.run()
}
