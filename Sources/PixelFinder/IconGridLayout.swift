import AppKit

/// Finder icon-view style grid: equal-width columns spread evenly across the
/// available width, rows of fixed height. Attributes are computed arithmetically
/// so the layout cost is O(visible items) even for very large folders.
final class IconGridLayout: NSCollectionViewLayout {
    var iconSize: CGFloat = 64

    private let insets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
    private let lineSpacing: CGFloat = 12
    private var columns = 1
    private var columnPitch: CGFloat = 100
    private var count = 0
    private var lastWidth: CGFloat = 0

    var columnCount: Int { columns }

    var itemSize: NSSize {
        let width = max(iconSize, 64) + 36
        let height = IconItemView.topPadding + iconSize + IconItemView.iconLabelGap + IconItemView.labelAreaHeight
        return NSSize(width: ceil(width), height: ceil(height))
    }

    private var rowPitch: CGFloat { itemSize.height + lineSpacing }

    private var availableWidth: CGFloat {
        guard let cv = collectionView else { return 0 }
        return cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
    }

    override func prepare() {
        super.prepare()
        count = collectionView?.numberOfSections ?? 0 > 0 ? collectionView!.numberOfItems(inSection: 0) : 0
        lastWidth = availableWidth
        let usable = max(0, lastWidth - insets.left - insets.right)
        columns = max(1, Int(floor(usable / itemSize.width)))
        columnPitch = max(itemSize.width, usable / CGFloat(columns))
    }

    override var collectionViewContentSize: NSSize {
        let rows = (count + columns - 1) / columns
        let height = insets.top + CGFloat(rows) * rowPitch - (rows > 0 ? lineSpacing : 0) + insets.bottom
        return NSSize(width: lastWidth, height: height)
    }

    func frameForItem(_ index: Int) -> NSRect {
        let size = itemSize
        let col = index % columns
        let row = index / columns
        let x = insets.left + CGFloat(col) * columnPitch + (columnPitch - size.width) / 2
        let y = insets.top + CGFloat(row) * rowPitch
        return NSRect(x: floor(x), y: y, width: size.width, height: size.height)
    }

    func index(nearest point: NSPoint) -> Int? {
        guard count > 0 else { return nil }
        let row = max(0, Int((point.y - insets.top) / rowPitch))
        let col = min(columns - 1, max(0, Int((point.x - insets.left) / columnPitch)))
        return min(count - 1, row * columns + col)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0 else { return [] }
        let firstRow = max(0, Int(floor((rect.minY - insets.top) / rowPitch)))
        let lastRow = max(0, Int(floor((rect.maxY - insets.top) / rowPitch)))
        let first = firstRow * columns
        let last = min(count - 1, (lastRow + 1) * columns - 1)
        guard first <= last else { return [] }
        var result: [NSCollectionViewLayoutAttributes] = []
        result.reserveCapacity(last - first + 1)
        for i in first...last {
            let frame = frameForItem(i)
            if frame.intersects(rect) {
                result.append(attributes(i, frame))
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < count else { return nil }
        return attributes(indexPath.item, frameForItem(indexPath.item))
    }

    private func attributes(_ i: Int, _ frame: NSRect) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
        a.frame = frame
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(availableWidth - lastWidth) > 0.5 || abs(newBounds.width - lastWidth) > 0.5
    }
}
