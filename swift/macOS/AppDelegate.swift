import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    override func applicationWillFinishLaunching(_ notification: Notification) {
        initApp()
        super.applicationWillFinishLaunching(notification)
        // After launch, once the run loop turns.
        DispatchQueue.main.async { [weak self] in
            self?.warnIfOutsideApplications()
        }
    }

    /// macOS installs the VPN's system extension only for an app in the
    /// Applications folder; opened from the DMG or Downloads, connecting
    /// fails. A sandboxed app cannot move itself, so it says what to do.
    private func warnIfOutsideApplications() {
        guard Constants.useSystemExtension else { return }
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard !path.hasPrefix("/Applications/") else { return }
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let text: (title: String, body: String, ok: String)
        switch language {
        case "tr":
            text = ("Colitu'yu Uygulamalar klasörüne taşıyın",
                    "VPN bağlantısı için macOS, Colitu'nun ağ uzantısını yalnızca Uygulamalar klasöründeki uygulamaya kurar. Colitu'yu Uygulamalar klasörüne sürükleyin ve oradan açın.",
                    "Tamam")
        case "ru":
            text = ("Переместите Colitu в папку «Программы»",
                    "macOS устанавливает сетевое расширение Colitu для VPN, только если приложение находится в папке «Программы». Перетащите Colitu в «Программы» и откройте его оттуда.",
                    "OK")
        default:
            text = ("Move Colitu to the Applications folder",
                    "macOS installs Colitu's network extension for the VPN only when the app is in the Applications folder. Drag Colitu to Applications and open it from there.",
                    "OK")
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: text.ok)
        alert.runModal()
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApp.windows {
                if !window.isVisible {
                    window.setIsVisible(true)
                }
                window.orderFront(self)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return true
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
