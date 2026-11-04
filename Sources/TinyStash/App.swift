import AppKit

@main
@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var note: NoteController!
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pendingOpenURL: URL?
    private var editorVisible = false
    private var changingWindowLayout = false
    private let editorFrameName = "StashEditor"
    private lazy var settings = SettingsController { [weak self] in self?.applySettings() }

    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        note = NoteController()
        installMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Tiny Stash"
        window.minSize = NSSize(width: 480, height: 660)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = note
        note.onLockStateChange = { [weak self] unlocked in
            self?.updateWindowLayout(unlocked: unlocked)
        }
        applySettings()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let pendingOpenURL {
            note.openFile(pendingOpenURL)
            self.pendingOpenURL = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.note?.lock() }
            })
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.note?.lock() }
                })
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let note {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            note.openFile(url)
        } else {
            pendingOpenURL = url
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Tiny Stash", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let preferences = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tiny Stash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let file = NSMenuItem()
        file.title = "File"
        let fileMenu = NSMenu(title: "File")
        let new = NSMenuItem(title: "New Stash…", action: #selector(NoteController.newStash), keyEquivalent: "n")
        new.target = note
        fileMenu.addItem(new)
        let open = NSMenuItem(title: "Open Stash…", action: #selector(NoteController.openStash), keyEquivalent: "o")
        open.target = note
        fileMenu.addItem(open)
        file.submenu = fileMenu
        menu.addItem(file)
        let edit = NSMenuItem()
        edit.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                     ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    @objc private func showSettings() {
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
    }

    private func applySettings() {
        NSApp.appearance = settings.appearance
    }

    private func lockOnFocusLoss() {
        if settings.locksOnFocusLoss { note?.lock() }
    }

    private func updateWindowLayout(unlocked: Bool) {
        guard editorVisible != unlocked else { return }
        changingWindowLayout = true
        defer { changingWindowLayout = false }
        if editorVisible { window.saveFrame(usingName: editorFrameName) }
        editorVisible = unlocked
        window.minSize = unlocked
            ? NSSize(width: 380, height: 260)
            : NSSize(width: 480, height: 660)
        if unlocked {
            window.setFrameUsingName(editorFrameName)
        } else {
            var frame = window.frame
            let height = max(frame.height, window.minSize.height)
            frame.origin.y -= height - frame.height
            frame.size = NSSize(width: max(frame.width, window.minSize.width), height: height)
            window.setFrame(frame, display: true)
        }
    }

    func windowDidResize(_ notification: Notification) { saveEditorFrame() }
    func windowDidMove(_ notification: Notification) { saveEditorFrame() }

    private func saveEditorFrame() {
        guard editorVisible, !changingWindowLayout else { return }
        window.saveFrame(usingName: editorFrameName)
    }

    func applicationWillResignActive(_ notification: Notification) { lockOnFocusLoss() }
    func windowWillMiniaturize(_ notification: Notification) { note?.lock() }
    func windowDidResignKey(_ notification: Notification) { lockOnFocusLoss() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        note.lock()
        if note.hasUnsavedEdits { showUnsavedWarning(); return false }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        note?.lock()
        if note?.hasUnsavedEdits == true { showUnsavedWarning(); return .terminateCancel }
        return .terminateNow
    }
    private func showUnsavedWarning() {
        let alert = NSAlert()
        alert.messageText = "Keep Tiny Stash open to preserve unsaved edits"
        alert.informativeText = "The page is locked. Unlock to retry saving after fixing disk space or file permissions. Quitting or force quitting would lose the pending edits."
        alert.addButton(withTitle: "Keep open")
        alert.runModal()
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
}
