import AppKit

/// Plain view whose layer gets a solid rounded background; colours resolve
/// against the current appearance in updateLayer().
final class FillView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 4 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor
        layer?.cornerRadius = cornerRadius
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Layer-hosting view: the CALayer is ours, AppKit never redraws its contents.
/// The GPU scales `contents` to the layer bounds using nearest-neighbour filtering.
final class PixelImageView: NSView {
    let imageLayer = CALayer()

    var smooth = false {
        didSet {
            let filter: CALayerContentsFilter = smooth ? .trilinear : .nearest
            imageLayer.magnificationFilter = filter
            imageLayer.minificationFilter = filter
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.masksToBounds = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                              "cornerRadius": NSNull(), "contentsRect": NSNull()]
        layer = imageLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class IconItemView: NSView {
    static let topPadding: CGFloat = 8
    static let iconLabelGap: CGFloat = 8
    static let labelAreaHeight: CGFloat = 34
    static let labelFont = NSFont.systemFont(ofSize: 12)

    enum Content {
        case none
        case pixels(Thumbnail)
        case icon(CGImage?)
    }

    private let selectionView = FillView()
    private let imageView = PixelImageView()
    private let pillView = FillView()
    private let label = NSTextField(wrappingLabelWithString: "")

    var iconSize: CGFloat = 64 { didSet { if oldValue != iconSize { needsLayout = true } } }
    var integerScaling = false { didSet { if oldValue != integerScaling { needsLayout = true } } }
    var whiteBackground = true { didSet { if oldValue != whiteBackground { updateImageBackground() } } }
    var cropTransparent = false { didSet { if oldValue != cropTransparent { needsLayout = true } } }
    var isSelected = false { didSet { if oldValue != isSelected { refreshColors() } } }
    var isEmphasized = true { didSet { if oldValue != isEmphasized { refreshColors() } } }

    var title: String = "" {
        didSet {
            guard oldValue != title else { return }
            label.stringValue = title
            needsLayout = true
        }
    }

    var content: Content = .none {
        didSet {
            switch content {
            case .none:
                imageView.imageLayer.contents = nil
                imageView.imageLayer.backgroundColor = nil
            case .pixels(let thumb):
                imageView.imageLayer.contents = thumb.image
                imageView.smooth = false
                updateImageBackground()
            case .icon(let img):
                imageView.imageLayer.contents = img
                imageView.smooth = true
                imageView.imageLayer.backgroundColor = nil
            }
            needsLayout = true
        }
    }

    private func updateImageBackground() {
        guard case .pixels = content else { return }
        imageView.imageLayer.backgroundColor = whiteBackground ? CGColor.white : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        selectionView.cornerRadius = 6
        pillView.cornerRadius = 4

        label.font = Self.labelFont
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.drawsBackground = false
        label.isSelectable = false

        addSubview(selectionView)
        addSubview(imageView)
        addSubview(pillView)
        addSubview(label)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Children never take clicks; the item view itself does so NSCollectionView
    // can resolve the item for selection, rubber-banding and dragging.
    static var keepVisible = false

    override var isHidden: Bool {
        get { super.isHidden }
        set { super.isHidden = Self.keepVisible ? false : newValue }
    }

    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set { super.alphaValue = Self.keepVisible ? 1 : newValue }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    private func refreshColors() {
        selectionView.isHidden = !isSelected
        pillView.isHidden = !isSelected
        selectionView.fillColor = NSColor.unemphasizedSelectedContentBackgroundColor
        pillView.fillColor = isEmphasized ? .selectedContentBackgroundColor
                                          : .unemphasizedSelectedContentBackgroundColor
        label.textColor = (isSelected && isEmphasized) ? .alternateSelectedControlTextColor : .labelColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let b = bounds
        let s = iconSize
        let box = NSRect(x: round((b.width - s) / 2), y: b.height - Self.topPadding - s, width: s, height: s)
        selectionView.frame = box.insetBy(dx: -5, dy: -5)

        switch content {
        case .pixels(let thumb):
            let size = thumb.size
            let src = cropTransparent ? thumb.opaqueRect : CGRect(origin: .zero, size: size)
            let rect = fitRect(pixelWidth: src.width, pixelHeight: src.height, in: box)
            imageView.frame = backingAlignedRect(rect, options: .alignAllEdgesNearest)
            imageView.imageLayer.cornerRadius = s >= 64 ? 3 : 1.5
            // contentsRect is in unit coordinates with a bottom-left origin.
            imageView.imageLayer.contentsRect = CGRect(x: src.minX / size.width,
                                                       y: (size.height - src.maxY) / size.height,
                                                       width: src.width / size.width,
                                                       height: src.height / size.height)
        case .icon, .none:
            imageView.frame = box
            imageView.imageLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            imageView.imageLayer.cornerRadius = 0
        }
        imageView.imageLayer.contentsGravity = {
            if case .icon = content { return .resizeAspect }
            return .resize
        }()

        let maxWidth = b.width - 10
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: Self.labelAreaHeight))
            ?? .zero
        let w = min(ceil(measured.width), maxWidth)
        let h = min(ceil(measured.height), Self.labelAreaHeight)
        let top = box.minY - Self.iconLabelGap
        label.frame = NSRect(x: round((b.width - w) / 2), y: top - h, width: w, height: h)
        pillView.frame = label.frame.insetBy(dx: -3, dy: 0)

        CATransaction.commit()
    }

    private func fitRect(pixelWidth w: CGFloat, pixelHeight h: CGFloat, in box: NSRect) -> NSRect {
        guard w > 0, h > 0 else { return box }
        var scale = min(box.width / w, box.height / h)
        if integerScaling {
            // Whole multiples of the device pixel grid so every source pixel is the same size.
            let backing = window?.backingScaleFactor ?? 2
            let devScale = scale * backing
            if devScale >= 1 { scale = floor(devScale) / backing }
        }
        let dw = w * scale, dh = h * scale
        return NSRect(x: box.midX - dw / 2, y: box.midY - dh / 2, width: dw, height: dh)
    }
}

final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private(set) var entry: Entry?
    private var operation: Operation?

    var iconView: IconItemView { view as! IconItemView }

    override func loadView() {
        view = IconItemView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    override var isSelected: Bool {
        didSet { updateSelectionLook() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelectionLook() }
    }

    private func updateSelectionLook() {
        switch highlightState {
        case .forSelection: iconView.isSelected = true
        case .forDeselection: iconView.isSelected = false
        default: iconView.isSelected = isSelected
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        operation?.cancel()
        operation = nil
        entry = nil
        iconView.content = .none
    }

    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func configure(entry: Entry, iconSize: CGFloat, integerScaling: Bool, whiteBackground: Bool,
                   cropTransparent: Bool, emphasized: Bool) {
        self.entry = entry
        let v = iconView
        v.whiteBackground = whiteBackground
        v.cropTransparent = cropTransparent
        v.title = entry.name
        v.iconSize = iconSize
        v.integerScaling = integerScaling
        v.isEmphasized = emphasized
        operation?.cancel()
        operation = nil

        if entry.isDirectory {
            v.content = .icon(SystemIcons.folder(size: iconSize, scale: backingScale))
            return
        }
        if let thumb = ThumbnailLoader.shared.cached(entry) {
            v.content = .pixels(thumb)
            return
        }
        v.content = .none
        let key = entry.cacheKey
        operation = ThumbnailLoader.shared.load(entry) { [weak self] image in
            guard let self, self.entry?.cacheKey == key else { return }
            self.operation = nil
            if let image {
                self.iconView.content = .pixels(image)
            } else {
                self.iconView.content = .icon(SystemIcons.file(for: entry.url, size: self.iconView.iconSize,
                                                                scale: self.backingScale))
            }
        }
    }

    func updateIconSize(_ size: CGFloat, integerScaling: Bool) {
        iconView.iconSize = size
        iconView.integerScaling = integerScaling
        if let entry, entry.isDirectory {
            iconView.content = .icon(SystemIcons.folder(size: size, scale: backingScale))
        }
    }
}
