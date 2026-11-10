import AppKit

final class SidebarItem: NSObject {
    let title: String
    let url: URL
    let symbol: String
    let isCustom: Bool

    init(title: String, url: URL, symbol: String, isCustom: Bool = false) {
        self.title = title
        self.url = url
        self.symbol = symbol
        self.isCustom = isCustom
    }
}

final class SidebarSection: NSObject {
    let title: String
    var items: [SidebarItem]
    init(title: String, items: [SidebarItem]) {
        self.title = title
        self.items = items
    }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let favoritesKey = "sidebarFavorites"

    var onSelect: ((URL) -> Void)?

    private let outlineView = NSOutlineView()
    private var sections: [SidebarSection] = []
    private var suppressSelection = false
    private var currentURL: URL?

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 0
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])

        scroll.documentView = outlineView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll

        rebuild()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    @objc private func volumesChanged() { rebuild() }

    private func rebuild() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var favorites: [SidebarItem] = [
            SidebarItem(title: "Applications", url: URL(fileURLWithPath: "/Applications"), symbol: "square.grid.2x2"),
            SidebarItem(title: "Desktop", url: home.appendingPathComponent("Desktop"), symbol: "menubar.dock.rectangle"),
            SidebarItem(title: "Documents", url: home.appendingPathComponent("Documents"), symbol: "doc"),
            SidebarItem(title: "Downloads", url: home.appendingPathComponent("Downloads"), symbol: "arrow.down.circle"),
            SidebarItem(title: "Pictures", url: home.appendingPathComponent("Pictures"), symbol: "photo"),
            SidebarItem(title: home.lastPathComponent, url: home, symbol: "house"),
        ]
        for path in UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [] {
            let url = URL(fileURLWithPath: path)
            favorites.append(SidebarItem(title: url.lastPathComponent, url: url, symbol: "folder", isCustom: true))
        }

        var locations: [SidebarItem] = []
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeLocalizedName ?? url.lastPathComponent
            let isInternal = values?.volumeIsInternal ?? true
            locations.append(SidebarItem(title: name, url: url, symbol: isInternal ? "internaldrive" : "externaldrive"))
        }
        locations.append(SidebarItem(title: "Network", url: URL(fileURLWithPath: "/Volumes"), symbol: "network"))

        sections = [SidebarSection(title: "Favorites", items: favorites),
                    SidebarSection(title: "Locations", items: locations)]
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let currentURL { highlight(currentURL) }
    }

    func highlight(_ url: URL) {
        currentURL = url
        let target = url.standardizedFileURL.path
        suppressSelection = true
        defer { suppressSelection = false }
        for section in sections {
            if let item = section.items.first(where: { $0.url.standardizedFileURL.path == target }) {
                let row = outlineView.row(forItem: item)
                if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    func addFavorite(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        guard !list.contains(url.path) else { return }
        list.append(url.path)
        UserDefaults.standard.set(list, forKey: Self.favoritesKey)
        rebuild()
    }

    private func removeFavorite(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        list.removeAll { $0 == url.path }
        UserDefaults.standard.set(list, forKey: Self.favoritesKey)
        rebuild()
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? SidebarItem { removeFavorite(item.url) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? SidebarSection)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        return (item as! SidebarSection).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is SidebarSection }

    // Dropping a folder on the sidebar adds it to Favorites (nothing is moved or copied).
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard folderURLs(from: info).isEmpty == false else { return [] }
        outlineView.setDropItem(sections.first, dropChildIndex: sections.first?.items.count ?? 0)
        return .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = folderURLs(from: info)
        urls.forEach(addFavorite)
        return !urls.isEmpty
    }

    private func folderURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarSection }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SidebarItem }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let id = NSUserInterfaceItemIdentifier("Header")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let entry = item as? SidebarItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("Item")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            iv.translatesAutoresizingMaskIntoConstraints = false
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.addSubview(tf)
            c.imageView = iv
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = entry.title
        cell.imageView?.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.title)
        cell.imageView?.contentTintColor = .controlAccentColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem else { return }
        currentURL = item.url
        onSelect?(item.url)
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        let open = NSMenuItem(title: "Show in Finder", action: #selector(showClicked(_:)), keyEquivalent: "")
        open.representedObject = item
        open.target = self
        menu.addItem(open)
        if item.isCustom {
            let remove = NSMenuItem(title: "Remove from Sidebar", action: #selector(removeClicked(_:)), keyEquivalent: "")
            remove.representedObject = item
            remove.target = self
            menu.addItem(remove)
        }
    }

    @objc private func showClicked(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? SidebarItem {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }
}
