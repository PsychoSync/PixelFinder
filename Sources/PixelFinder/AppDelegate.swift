import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []
    private var launchedWithURLs = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        if !launchedWithURLs {
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            if let path = args.first {
                open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            } else {
                newWindow(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithURLs = true
        urls.forEach { open($0) }
    }

    private var defaultFolder: URL {
        if let path = UserDefaults.standard.string(forKey: "lastFolder"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
    }

    private var frontController: BrowserWindowController? {
        NSApp.keyWindow?.windowController as? BrowserWindowController
            ?? NSApp.mainWindow?.windowController as? BrowserWindowController
    }

    func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        let file = isDir.boolValue ? nil : url
        if let front = frontController {
            front.navigate(to: folder, select: file)
            front.window?.makeKeyAndOrderFront(nil)
        } else {
            makeWindow(folder: folder, select: file)
        }
    }

    @discardableResult
    private func makeWindow(folder: URL, select file: URL? = nil) -> BrowserWindowController {
        let wc = BrowserWindowController(folder: folder, select: file)
        wc.onClose = { [weak self] closed in
            DispatchQueue.main.async { self?.controllers.removeAll { $0 === closed } }
        }
        controllers.append(wc)
        if let front = frontController?.window, let new = wc.window {
            new.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 24, y: front.frame.maxY - 24))
        }
        wc.showWindow(nil)
        return wc
    }

    @objc func newWindow(_ sender: Any?) {
        makeWindow(folder: frontController?.currentFolder ?? defaultFolder)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.directoryURL = frontController?.currentFolder
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
        if let window = frontController?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: Menus

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appName = "PixelFinder"

        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }

        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            menu.addItem(item)
        }

        submenu(appName) { m in
            add(m, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            add(m, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        }
        submenu("File") { m in
            add(m, "New Window", #selector(newWindow(_:)), "n")
            add(m, "Open…", #selector(openDocument(_:)), "o")
            m.addItem(.separator())
            add(m, "Open Selection", #selector(GridViewController.openSelection(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!))
            add(m, "Show in Finder", #selector(GridViewController.showInFinder(_:)), "r")
            add(m, "Add to Sidebar", #selector(BrowserWindowController.addToSidebar(_:)), "t", [.command, .control])
            m.addItem(.separator())
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        }
        submenu("Edit") { m in
            add(m, "Copy", #selector(GridViewController.copy(_:)), "c")
            add(m, "Copy as Pathname", #selector(GridViewController.copyPathnames(_:)), "c", [.command, .option])
            add(m, "Select All", #selector(NSResponder.selectAll(_:)), "a")
            m.addItem(.separator())
            add(m, "Find", #selector(BrowserWindowController.focusSearch(_:)), "f")
        }
        submenu("View") { m in
            let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            let sortMenu = NSMenu(title: "Sort By")
            GridViewController.sortMenuItems().forEach(sortMenu.addItem)
            sortItem.submenu = sortMenu
            m.addItem(sortItem)
            m.addItem(.separator())
            add(m, "Zoom In", #selector(GridViewController.zoomIn(_:)), "+")
            add(m, "Zoom In", #selector(GridViewController.zoomIn(_:)), "=")
            m.items.last?.isAlternate = false
            m.items.last?.isHidden = true
            m.items.last?.allowsKeyEquivalentWhenHidden = true
            add(m, "Zoom Out", #selector(GridViewController.zoomOut(_:)), "-")
            add(m, "Integer Scaling", #selector(GridViewController.toggleIntegerScaling(_:)), "i", [.command, .option])
            add(m, "Transparent Background as White", #selector(GridViewController.toggleWhiteBackground(_:)), "b", [.command, .option])
            add(m, "Crop Transparent Borders", #selector(GridViewController.toggleCropTransparent(_:)), "k", [.command, .option])
            m.addItem(.separator())
            add(m, "Hide Path Bar", #selector(GridViewController.togglePathBar(_:)), "p", [.command, .option])
            add(m, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
            m.addItem(.separator())
            add(m, "Refresh", #selector(GridViewController.refresh(_:)), "r", [.command, .shift])
            add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
        submenu("Go") { m in
            add(m, "Back", #selector(BrowserWindowController.goBack(_:)), "[")
            add(m, "Forward", #selector(BrowserWindowController.goForward(_:)), "]")
            add(m, "Enclosing Folder", #selector(BrowserWindowController.goEnclosingFolder(_:)),
                String(UnicodeScalar(NSUpArrowFunctionKey)!))
            m.addItem(.separator())
            add(m, "Documents", #selector(BrowserWindowController.goDocuments(_:)), "o", [.command, .shift])
            add(m, "Desktop", #selector(BrowserWindowController.goDesktop(_:)), "d", [.command, .shift])
            add(m, "Downloads", #selector(BrowserWindowController.goDownloads(_:)), "l", [.command, .option])
            add(m, "Home", #selector(BrowserWindowController.goHome(_:)), "h", [.command, .shift])
            add(m, "Pictures", #selector(BrowserWindowController.goPictures(_:)), "p", [.command, .shift])
            add(m, "Applications", #selector(BrowserWindowController.goApplications(_:)), "a", [.command, .shift])
            m.addItem(.separator())
            add(m, "Go to Folder…", #selector(BrowserWindowController.goToFolder(_:)), "g", [.command, .shift])
        }
        submenu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            add(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
            NSApp.windowsMenu = m
        }
        return main
    }
}
