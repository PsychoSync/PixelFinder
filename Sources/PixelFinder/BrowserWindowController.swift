import AppKit

extension NSToolbarItem.Identifier {
    static let navigation = Self("navigation")
    static let share = Self("share")
    static let sort = Self("sort")
    static let actions = Self("actions")
    static let search = Self("search")
}

final class BrowserWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate,
                                     NSSharingServicePickerToolbarItemDelegate, NSMenuItemValidation,
                                     NSWindowDelegate {
    let splitController = NSSplitViewController()
    let sidebar = SidebarViewController()
    let grid = GridViewController()

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private(set) var currentFolder: URL?
    private let navControl = NSSegmentedControl()
    private var searchItem: NSSearchToolbarItem?

    var onClose: ((BrowserWindowController) -> Void)?

    init(folder: URL, select fileURL: URL? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: grid)
        contentItem.minimumThickness = 300
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = "PixelFinderSplit"
        window.contentViewController = splitController

        let toolbar = NSToolbar(identifier: "PixelFinderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1000, height: 720))
        if !window.setFrameUsingName("PixelFinderWindow") { window.center() }
        window.setFrameAutosaveName("PixelFinderWindow")

        sidebar.onSelect = { [weak self] url in self?.navigate(to: url) }
        grid.onNavigate = { [weak self] url in self?.navigate(to: url) }

        navigate(to: folder, select: fileURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?(self) }

    // MARK: Navigation

    func navigate(to url: URL, select fileURL: URL? = nil, record: Bool = true) {
        let url = url.standardizedFileURL
        if record, let current = currentFolder, current != url {
            backStack.append(current)
            forwardStack.removeAll()
        }
        currentFolder = url
        window?.title = FileManager.default.displayName(atPath: url.path)
        if let searchItem, !searchItem.searchField.stringValue.isEmpty {
            searchItem.searchField.stringValue = ""
            grid.filter = ""
        }
        grid.show(folder: url, select: fileURL)
        sidebar.highlight(url)
        updateNavButtons()
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        window?.makeFirstResponder(grid.collectionView)
    }

    private func updateNavButtons() {
        navControl.setEnabled(!backStack.isEmpty, forSegment: 0)
        navControl.setEnabled(!forwardStack.isEmpty, forSegment: 1)
    }

    @objc private func navClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? goBack(nil) : goForward(nil)
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = backStack.popLast(), let current = currentFolder else { return }
        forwardStack.append(current)
        navigate(to: previous, select: current, record: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forwardStack.popLast(), let current = currentFolder else { return }
        backStack.append(current)
        navigate(to: next, record: false)
    }

    @objc func goEnclosingFolder(_ sender: Any?) {
        guard let current = currentFolder, current.path != "/" else { return }
        navigate(to: current.deletingLastPathComponent(), select: current)
    }

    private func goHomeRelative(_ component: String?) {
        var url = FileManager.default.homeDirectoryForCurrentUser
        if let component { url.appendPathComponent(component) }
        navigate(to: url)
    }

    @objc func goHome(_ sender: Any?) { goHomeRelative(nil) }
    @objc func goDesktop(_ sender: Any?) { goHomeRelative("Desktop") }
    @objc func goDocuments(_ sender: Any?) { goHomeRelative("Documents") }
    @objc func goDownloads(_ sender: Any?) { goHomeRelative("Downloads") }
    @objc func goPictures(_ sender: Any?) { goHomeRelative("Pictures") }
    @objc func goApplications(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Applications")) }

    @objc func goToFolder(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "~/Pictures"
        field.stringValue = currentFolder?.path ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let path = (field.stringValue as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { NSSound.beep(); return }
            let url = URL(fileURLWithPath: path)
            if isDir.boolValue {
                self?.navigate(to: url)
            } else {
                self?.navigate(to: url.deletingLastPathComponent(), select: url)
            }
        }
    }

    @objc func addToSidebar(_ sender: Any?) {
        let dirs = grid.selectedEntries.filter(\.isDirectory).map(\.url)
        if dirs.isEmpty, let currentFolder {
            sidebar.addFavorite(currentFolder)
        } else {
            dirs.forEach(sidebar.addFavorite)
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goEnclosingFolder(_:)): return currentFolder?.path != "/"
        default: return true
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .navigation, .flexibleSpace, .sort, .share, .actions, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .navigation:
            navControl.segmentCount = 2
            navControl.trackingMode = .momentary
            navControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back"), forSegment: 0)
            navControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward"), forSegment: 1)
            navControl.setWidth(32, forSegment: 0)
            navControl.setWidth(32, forSegment: 1)
            navControl.target = self
            navControl.action = #selector(navClicked(_:))
            updateNavButtons()
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = navControl
            item.label = "Back/Forward"
            item.isNavigational = true
            return item
        case .sort:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "square.grid.3x1.below.line.grid.1x2",
                                 accessibilityDescription: "Sort By")
            item.label = "Sort By"
            item.toolTip = "Change the item sort order"
            let menu = NSMenu()
            for mi in GridViewController.sortMenuItems() {
                mi.keyEquivalent = ""
                mi.target = grid
                menu.addItem(mi)
            }
            item.menu = menu
            return item
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = self
            item.toolTip = "Share"
            return item
        case .actions:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")
            item.label = "Action"
            item.toolTip = "Perform tasks with the selected items"
            item.showsIndicator = false
            let menu = NSMenu()
            menu.addItem(withTitle: "Open", action: #selector(GridViewController.openSelection(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Show in Finder", action: #selector(GridViewController.showInFinder(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy", action: #selector(GridViewController.copy(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy as Pathname", action: #selector(GridViewController.copyPathnames(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Add to Sidebar", action: #selector(addToSidebar(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Integer Scaling", action: #selector(GridViewController.toggleIntegerScaling(_:)), keyEquivalent: "")
            for mi in menu.items where mi.action != #selector(addToSidebar(_:)) { mi.target = grid }
            for mi in menu.items where mi.action == #selector(addToSidebar(_:)) { mi.target = self }
            item.menu = menu
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.delegate = self
            item.searchField.placeholderString = "Search"
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item
        default:
            return nil
        }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        grid.selectedEntries.map(\.url)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        grid.filter = field.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        grid.filter = ""
    }
}
