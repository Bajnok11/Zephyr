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
