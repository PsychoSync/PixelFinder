import AppKit

final class GridCollectionView: NSCollectionView {
    weak var controller: GridViewController?

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        // Shift-click selects every item between the anchor and the clicked item, in grid order.
        if flags.contains(.shift), !flags.contains(.command), let ip,
           controller?.extendSelection(to: ip.item) == true {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
        if let ip, !flags.contains(.shift) { controller?.setSelectionAnchor(ip.item) }
        controller?.selectionDidChange()
        if event.clickCount == 2,
           indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            controller?.openSelection(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        controller?.selectionDidChange()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(ip) {
                selectionIndexPaths = [ip]
                controller?.selectionDidChange()
            }
            return controller?.itemMenu()
        }
        return nil
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.controller?.refreshEmphasis() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.controller?.refreshEmphasis() }
        return ok
    }

    // Files dragged out of this app may only ever be copied, never moved.
    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

final class GridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
                                NSPathControlDelegate, NSMenuItemValidation {
    static let minIconSize: CGFloat = 16
    static let maxIconSize: CGFloat = 512

    let collectionView = GridCollectionView()
    private let layout = IconGridLayout()
    private let scrollView = NSScrollView()
    private let pathControl = NSPathControl()
    private let pathBar = NSView()
    private let pathSeparator = NSBox()
    private let statusLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()

    var onNavigate: ((URL) -> Void)?
    var onSelectionChange: (() -> Void)?

    private(set) var folder: URL?
    private var allEntries: [Entry] = []
    private var sortedEntries: [Entry] = []
    private var sortToken: CancelToken?
    private var sortProgress: (done: Int, total: Int)?
    private(set) var entries: [Entry] = []
    private var freeSpace: Int64?
    private var loadError: String?
    private var loadGeneration = 0
    private var watcher: DirectoryWatcher?
    private var reloadWork: DispatchWorkItem?
    private var pendingSelection: URL?
    private var cursorIndex: Int?
    private var anchorURL: URL?
    private var lastShiftRange: Set<URL> = []
    private var typeSelectBuffer = ""
    private var typeSelectTime = Date.distantPast

    var sortMode: SortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: "sortMode") ?? "") ?? .name {
        didSet {
            guard oldValue != sortMode else { return }
            UserDefaults.standard.set(sortMode.rawValue, forKey: "sortMode")
            resort()
        }
    }

    var filter = "" {
        didSet { if oldValue != filter { applyFilter(preserveSelection: true) } }
    }

    var iconSize: CGFloat { layout.iconSize }

    var integerScaling: Bool = UserDefaults.standard.bool(forKey: "integerScaling") {
        didSet {
            UserDefaults.standard.set(integerScaling, forKey: "integerScaling")
            for case let item as IconItem in collectionView.visibleItems() {
                item.updateIconSize(layout.iconSize, integerScaling: integerScaling)
            }
        }
    }

    var whiteBackground: Bool = UserDefaults.standard.object(forKey: "whiteBackground") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(whiteBackground, forKey: "whiteBackground")
            for case let item as IconItem in collectionView.visibleItems() {
                item.iconView.whiteBackground = whiteBackground
            }
        }
    }

    var cropTransparent: Bool = UserDefaults.standard.bool(forKey: "cropTransparent") {
        didSet {
            UserDefaults.standard.set(cropTransparent, forKey: "cropTransparent")
            for case let item as IconItem in collectionView.visibleItems() {
                item.iconView.cropTransparent = cropTransparent
            }
        }
    }

    var isPathBarVisible: Bool {
        get { !pathBar.isHidden }
        set {
            pathBar.isHidden = !newValue
            pathSeparator.isHidden = !newValue
            UserDefaults.standard.set(!newValue, forKey: "hidePathBar")
        }
    }

    // MARK: View setup

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        let saved = UserDefaults.standard.double(forKey: "iconSize")
        layout.iconSize = saved > 0 ? CGFloat(saved) : 128

        collectionView.controller = self
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.textBackgroundColor]
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)

        scrollView.documentView = collectionView
        scrollView.verticalScroller = BigScroller()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.scrollView.scrollerStyle = .legacy
        }
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        // Path bar
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.focusRingType = .none
        pathControl.delegate = self
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathBar.addSubview(pathControl)
        NSLayoutConstraint.activate([
            pathBar.heightAnchor.constraint(equalToConstant: 24),
            pathControl.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: pathBar.trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
        ])

        // Status bar
        let statusBar = NSView()
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        slider.minValue = Double(Self.minIconSize)
        slider.maxValue = Double(Self.maxIconSize)
        slider.doubleValue = Double(layout.iconSize)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.toolTip = "Icon size"
        slider.translatesAutoresizingMaskIntoConstraints = false

        statusBar.addSubview(statusLabel)
        statusBar.addSubview(slider)
        NSLayoutConstraint.activate([
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            statusLabel.centerXAnchor.constraint(equalTo: statusBar.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusBar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -8),
            slider.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -14),
            slider.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 96),
        ])

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        pathSeparator.boxType = .separator

        let bottom = NSStackView(views: [topSeparator, pathBar, pathSeparator, statusBar])
        bottom.orientation = .vertical
        bottom.spacing = 0
        bottom.alignment = .leading
        bottom.detachesHiddenViews = true
        bottom.translatesAutoresizingMaskIntoConstraints = false
        for v in [topSeparator, pathBar, pathSeparator, statusBar] {
            v.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        }
        root.addSubview(bottom)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        isPathBarVisible = !UserDefaults.standard.bool(forKey: "hidePathBar")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: name, object: view.window)
        }
    }

    @objc private func windowKeyChanged(_ note: Notification) { refreshEmphasis() }

    // MARK: Loading

    func show(folder url: URL, select fileURL: URL? = nil) {
        let changed = url.standardizedFileURL != folder?.standardizedFileURL
        folder = url
        pendingSelection = fileURL
        pathControl.url = url
        if changed {
            ThumbnailLoader.shared.cancelAll()
            sortToken?.cancel()
            sortToken = nil
            sortProgress = nil
            allEntries = []
            sortedEntries = []
            entries = []
            cursorIndex = nil
            collectionView.reloadData()
            watcher = DirectoryWatcher(url: url) { [weak self] in self?.scheduleReload() }
        }
        reload(scrollToTop: changed)
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload(scrollToTop: false) }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func reload(scrollToTop: Bool = false) {
        guard let folder else { return }
        loadGeneration += 1
        let generation = loadGeneration
        updateStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = DirectoryModel.load(folder)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.freeSpace = listing.freeSpace
                self.loadError = listing.error
                if listing.entries != self.allEntries || self.pendingSelection != nil {
                    let changed = listing.entries != self.allEntries
                    self.allEntries = listing.entries
                    if changed { self.provisionalSort() }
                    self.applyFilter(preserveSelection: !scrollToTop)
                    if changed { self.resort() }
                }
                if scrollToTop { self.scrollToTop() }
                if let target = self.pendingSelection {
                    self.pendingSelection = nil
                    if let i = self.entries.firstIndex(where: { $0.url.standardizedFileURL == target.standardizedFileURL }) {
                        self.select(index: i, extend: false)
                    }
                }
                self.updateStatus()
            }
        }
    }

    /// Keeps the current similarity order for files that are still present and
    /// appends new ones, so the grid doesn't jump while a re-sort runs.
    private func provisionalSort() {
        guard sortMode != .name, !sortedEntries.isEmpty else {
            sortedEntries = allEntries
            return
        }
        let current = Dictionary(allEntries.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<URL>()
        var result: [Entry] = []
        for e in sortedEntries {
            if let fresh = current[e.url] { result.append(fresh); seen.insert(e.url) }
        }
        result += allEntries.filter { !seen.contains($0.url) }
        sortedEntries = result
    }

    private func resort() {
        sortToken?.cancel()
        sortToken = nil
        sortProgress = nil
        guard let folder, sortMode != .name else {
            if sortedEntries != allEntries {
                sortedEntries = allEntries
                applyFilter(preserveSelection: true, keepSelectionVisible: true)
            }
            updateStatus()
            return
        }
        let token = CancelToken()
        sortToken = token
        let snapshot = allEntries
        let mode = sortMode
        updateStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            let order = SimilarityEngine.order(entries: snapshot, folder: folder, mode: mode, token: token) { [weak self] done, total in
                guard let self, self.sortToken === token else { return }
                self.sortProgress = (done, total)
                self.updateStatus()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sortToken === token, !token.isCancelled else { return }
                self.sortToken = nil
                self.sortProgress = nil
                if let order, snapshot == self.allEntries {
                    self.sortedEntries = order.map { snapshot[$0] }
                    self.applyFilter(preserveSelection: true, keepSelectionVisible: true)
                }
                self.updateStatus()
            }
        }
    }

    private func applyFilter(preserveSelection: Bool, keepSelectionVisible: Bool = false) {
        let selected = preserveSelection ? Set(selectedEntries.map { $0.url }) : []
        let query = filter.trimmingCharacters(in: .whitespaces)
        let source = sortedEntries.count == allEntries.count ? sortedEntries : allEntries
        entries = query.isEmpty ? source : source.filter { $0.name.localizedCaseInsensitiveContains(query) }
        collectionView.reloadData()
        if !selected.isEmpty {
            var paths = Set<IndexPath>()
            for (i, e) in entries.enumerated() where selected.contains(e.url) {
                paths.insert(IndexPath(item: i, section: 0))
            }
            collectionView.selectionIndexPaths = paths
            if keepSelectionVisible, let first = paths.min() {
                cursorIndex = first.item
                collectionView.layoutSubtreeIfNeeded()
                collectionView.scrollToItems(at: [first], scrollPosition: .centeredVertically)
            }
        }
        selectionDidChange()
    }

    private func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Status

    func selectionDidChange() {
        if let last = collectionView.selectionIndexPaths.map(\.item).max(),
           cursorIndex == nil || !collectionView.selectionIndexPaths.contains(IndexPath(item: cursorIndex!, section: 0)) {
            cursorIndex = last
        }
        updateStatus()
        onSelectionChange?()
    }

    private func updateStatus() {
        if let loadError {
            statusLabel.stringValue = loadError
            return
        }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let total = nf.string(from: NSNumber(value: entries.count)) ?? "\(entries.count)"
        let selected = collectionView.selectionIndexPaths.count
        var text = selected > 0
            ? "\(nf.string(from: NSNumber(value: selected)) ?? "\(selected)") of \(total) selected"
            : "\(total) item\(entries.count == 1 ? "" : "s")"
        if let freeSpace {
            text += ", " + ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file) + " available"
        }
        if sortToken != nil {
            if let p = sortProgress, p.done < p.total {
                let done = nf.string(from: NSNumber(value: p.done)) ?? "\(p.done)"
                let all = nf.string(from: NSNumber(value: p.total)) ?? "\(p.total)"
                text += " — Analyzing similarity \(done) of \(all)…"
            } else {
                text += " — Sorting by similarity…"
            }
        }
        statusLabel.stringValue = text
    }

    var isEmphasized: Bool {
        guard let window = view.window else { return false }
        return window.isKeyWindow && window.firstResponder === collectionView
    }

    func refreshEmphasis() {
        let emphasized = isEmphasized
        for case let item as IconItem in collectionView.visibleItems() {
            item.iconView.isEmphasized = emphasized
        }
    }

    // MARK: Zoom

    @objc private func sliderChanged(_ sender: NSSlider) {
        setIconSize(CGFloat(sender.doubleValue.rounded()))
    }

    func setIconSize(_ newSize: CGFloat) {
        let size = min(Self.maxIconSize, max(Self.minIconSize, newSize.rounded()))
        guard size != layout.iconSize else { return }

        // Keep the selected (or centre) item at the same place on screen while zooming.
        let clip = scrollView.contentView
        let visible = clip.bounds
        let visibleItems = Set(collectionView.indexPathsForVisibleItems().map(\.item))
        let anchor = collectionView.selectionIndexPaths.map(\.item).sorted().first(where: visibleItems.contains)
            ?? layout.index(nearest: NSPoint(x: visible.midX, y: visible.midY))
        var fraction: CGFloat = 0.5
        if let anchor {
            fraction = (layout.frameForItem(anchor).midY - visible.minY) / max(1, visible.height)
        }

        layout.iconSize = size
        UserDefaults.standard.set(Double(size), forKey: "iconSize")
        if slider.doubleValue.rounded() != Double(size) { slider.doubleValue = Double(size) }
        for case let item as IconItem in collectionView.visibleItems() {
            item.updateIconSize(size, integerScaling: integerScaling)
        }
        layout.invalidateLayout()
        scrollView.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()

        if let anchor, anchor < entries.count {
            let frame = layout.frameForItem(anchor)
            let minY = -scrollView.contentInsets.top
            let maxY = max(minY, collectionView.frame.height - visible.height + scrollView.contentInsets.bottom)
            let y = min(maxY, max(minY, frame.midY - fraction * visible.height))
            clip.scroll(to: NSPoint(x: visible.minX, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    @objc func zoomIn(_ sender: Any?) { setIconSize(layout.iconSize < 64 ? layout.iconSize + 8 : layout.iconSize * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setIconSize(layout.iconSize <= 64 ? layout.iconSize - 8 : layout.iconSize / 1.25) }
    @objc func toggleIntegerScaling(_ sender: Any?) { integerScaling.toggle() }
    @objc func togglePathBar(_ sender: Any?) { isPathBarVisible.toggle() }
    @objc func toggleWhiteBackground(_ sender: Any?) { whiteBackground.toggle() }

    @objc func toggleCropTransparent(_ sender: Any?) { cropTransparent.toggle() }

    @objc func setSortMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = SortMode(rawValue: raw) { sortMode = mode }
    }

    static func sortMenuItems() -> [NSMenuItem] {
        let keys = ["1", "2", "3"]
        return SortMode.allCases.enumerated().map { i, mode in
            let item = NSMenuItem(title: mode.title, action: #selector(setSortMode(_:)), keyEquivalent: keys[i])
            item.keyEquivalentModifierMask = [.command, .option, .control]
            item.representedObject = mode.rawValue
            return item
        }
    }

    // MARK: Selection & keyboard

    var selectedEntries: [Entry] {
        collectionView.selectionIndexPaths.map(\.item).sorted().compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    func setSelectionAnchor(_ index: Int) {
        guard index < entries.count else { return }
        anchorURL = entries[index].url
        lastShiftRange = []
    }

    /// Selects the anchor-to-index range, replacing the previous shift range but keeping other selected items.
    func extendSelection(to index: Int) -> Bool {
        guard index < entries.count else { return false }
        let anchor = anchorURL.flatMap { url in entries.firstIndex { $0.url == url } }
            ?? collectionView.selectionIndexPaths.map(\.item).min()
        guard let anchor else { return false }
        if anchorURL == nil { setSelectionAnchor(anchor) }
        let range = min(anchor, index)...max(anchor, index)
        var paths = Set(range.map { IndexPath(item: $0, section: 0) })
        for ip in collectionView.selectionIndexPaths
        where ip.item < entries.count && !lastShiftRange.contains(entries[ip.item].url) {
            paths.insert(ip)
        }
        lastShiftRange = Set(entries[range].map(\.url))
        collectionView.selectionIndexPaths = paths
        cursorIndex = index
        selectionDidChange()
        return true
    }

    func select(index: Int, extend: Bool) {
        guard index >= 0, index < entries.count else { return }
        let ip = IndexPath(item: index, section: 0)
        if extend {
            collectionView.selectionIndexPaths.insert(ip)
        } else {
            collectionView.selectionIndexPaths = [ip]
            setSelectionAnchor(index)
        }
        cursorIndex = index
        collectionView.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        selectionDidChange()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let count = entries.count
        guard count > 0 else { return false }
        let current = cursorIndex ?? -1

        switch event.keyCode {
        case 123: // left
            select(index: current < 0 ? 0 : max(0, current - 1), extend: shift); return true
        case 124: // right
            select(index: current < 0 ? 0 : min(count - 1, current + 1), extend: shift); return true
        case 126: // up
            if command { return false }
            select(index: current < 0 ? 0 : max(current % layout.columnCount, current - layout.columnCount), extend: shift)
            return true
        case 125: // down
            if command { openSelection(nil); return true }
            if current < 0 { select(index: 0, extend: shift); return true }
            let next = current + layout.columnCount
            select(index: next < count ? next : current, extend: shift)
            return true
        case 115: select(index: 0, extend: shift); return true                 // home
        case 119: select(index: count - 1, extend: shift); return true         // end
        default: break
        }

        // Type-select: jump to the first item whose name starts with the typed text.
        if flags.isDisjoint(with: [.command, .control, .option]),
           let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) }) {
            if Date().timeIntervalSince(typeSelectTime) > 1 { typeSelectBuffer = "" }
            typeSelectTime = Date()
            typeSelectBuffer += chars
            let prefix = typeSelectBuffer
            if let i = entries.firstIndex(where: { $0.name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil }) {
                select(index: i, extend: false)
            }
            return true
        }
        return false
    }

    // MARK: Actions

    @objc func openSelection(_ sender: Any?) {
        let selection = selectedEntries
        if selection.count == 1, selection[0].isDirectory {
            onNavigate?(selection[0].url)
            return
        }
        let files = selection.filter { !$0.isDirectory }.map(\.url)
        if !files.isEmpty {
            NSWorkspace.shared.open(files, withApplicationAt: defaultApp(for: files[0]),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        if let dir = selection.first(where: { $0.isDirectory }), files.isEmpty {
            onNavigate?(dir.url)
        }
    }

    private func defaultApp(for url: URL) -> URL {
        NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? URL(fileURLWithPath: "/System/Applications/Preview.app")
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedEntries.map(\.url)
        if urls.isEmpty, let folder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedEntries.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    @objc func copyPathnames(_ sender: Any?) {
        let paths = selectedEntries.map(\.url.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func refresh(_ sender: Any?) { reload(scrollToTop: false) }

    func itemMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy as Pathname", action: #selector(copyPathnames(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSelection(_:)), #selector(copy(_:)), #selector(copyPathnames(_:)):
            return !collectionView.selectionIndexPaths.isEmpty
        case #selector(toggleIntegerScaling(_:)):
            menuItem.state = integerScaling ? .on : .off
            return true
        case #selector(setSortMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == sortMode.rawValue ? .on : .off
            return true
        case #selector(toggleCropTransparent(_:)):
            menuItem.state = cropTransparent ? .on : .off
            return true
        case #selector(toggleWhiteBackground(_:)):
            menuItem.state = whiteBackground ? .on : .off
            return true
        case #selector(togglePathBar(_:)):
            menuItem.title = isPathBarVisible ? "Hide Path Bar" : "Show Path Bar"
            return true
        case #selector(zoomIn(_:)): return layout.iconSize < Self.maxIconSize
        case #selector(zoomOut(_:)): return layout.iconSize > Self.minIconSize
        default: return true
        }
    }

    // MARK: Path control

    @objc private func pathClicked(_ sender: NSPathControl) {
        if let url = sender.clickedPathItem?.url { onNavigate?(url) }
    }

    func pathControl(_ pathControl: NSPathControl, shouldDrag pathItem: NSPathControlItem,
                     with pasteboard: NSPasteboard) -> Bool { false }

    func pathControl(_ pathControl: NSPathControl, validateDrop info: NSDraggingInfo) -> NSDragOperation { [] }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath) as! IconItem
        item.configure(entry: entries[indexPath.item], iconSize: layout.iconSize,
                       integerScaling: integerScaling, whiteBackground: whiteBackground,
                       cropTransparent: cropTransparent,
                       emphasized: isEmphasized)
        return item
    }

    // MARK: Delegate (selection + drag out)

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let ip = indexPaths.max() { cursorIndex = ip.item }
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { true }

    // NSCollectionView hides dragged items, which looks like a move. Keep them visible: this app only copies.
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        IconItemView.keepVisible = true
        revealItems()
        DispatchQueue.main.async { [weak self] in self?.revealItems() }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        IconItemView.keepVisible = false
        revealItems()
    }

    private func revealItems() {
        for item in collectionView.visibleItems() {
            item.view.isHidden = false
            item.view.alphaValue = 1
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < entries.count else { return nil }
        return entries[indexPath.item].url as NSURL
    }
}
