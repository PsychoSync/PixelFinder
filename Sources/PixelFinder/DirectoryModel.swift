import AppKit
import UniformTypeIdentifiers

struct Entry: Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let modificationDate: Date?

    var cacheKey: String {
        "\(url.path)|\(modificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }
}

struct DirectoryListing {
    var entries: [Entry] = []
    var freeSpace: Int64?
    var error: String?
}

enum DirectoryModel {
    static func load(_ folder: URL) -> DirectoryListing {
        var listing = DirectoryListing()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            var entries: [Entry] = []
            entries.reserveCapacity(urls.count)
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let isDir = (values.isDirectory ?? false) && !(values.isPackage ?? false)
                let isImage = values.contentType?.conforms(to: .image) ?? false
                guard isDir || isImage else { continue }
                entries.append(Entry(url: url, name: url.lastPathComponent, isDirectory: isDir,
                                     modificationDate: values.contentModificationDate))
            }
            entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            listing.entries = entries
        } catch {
            listing.error = error.localizedDescription
        }
        if let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            listing.freeSpace = v.volumeAvailableCapacityForImportantUsage
        }
        return listing
    }
}

final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, handler: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
