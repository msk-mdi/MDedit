import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?

    static func main() {
        // A headless render path, so export can be checked without a GUI.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render"), index + 1 < arguments.count {
            CommandLineRenderer.run(path: arguments[index + 1])
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        MainMenu.install(into: app)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @discardableResult
    private func showMainWindow() -> MainWindowController {
        if let mainWindow {
            mainWindow.showWindow(nil)
            return mainWindow
        }
        let controller = MainWindowController()
        mainWindow = controller
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let controller = showMainWindow()
        for url in urls { controller.open(url: url) }
    }

    // MARK: - Menu actions

    @objc func newDocument(_ sender: Any?) {
        showMainWindow().newDocument()
    }

    @objc func openDocument(_ sender: Any?) {
        let controller = showMainWindow()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"]
            .compactMap { .init(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { controller.open(url: url) }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let controller = mainWindow, let document = controller.activeDocument else { return }
        controller.save(document: document)
    }

    @objc func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/marktext/marktext")!)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let controller = mainWindow, let document = controller.activeDocument else { return }
        controller.saveAs(document: document)
    }
}
