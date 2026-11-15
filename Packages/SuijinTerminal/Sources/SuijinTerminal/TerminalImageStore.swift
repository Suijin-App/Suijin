import AppKit

/// Where images pasted or dropped on a terminal become files. A program in a terminal takes an image as a path on its
/// command line (see `TerminalFileDrop`), so image data that is not a file yet (a screenshot on the clipboard, the
/// screenshot tool's floating thumbnail) is written here first. The host chooses the folder; nothing is written
/// anywhere else.
public struct TerminalImageStore: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// How long a pasted image is kept: long enough for the conversation that refers to it.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Writes PNG data as `Pasted-<date>-<time>.png` (numbered when that name is taken) and returns the file.
    public func save(png: Data, at date: Date = Date()) throws -> URL {
        try prepareDirectory()
        let name = "Pasted-\(Self.stamp(date))"
        for attempt in 1...1_000 {
            let file = directory.appendingPathComponent(attempt == 1 ? "\(name).png" : "\(name)-\(attempt).png")
            do {
                try png.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return file
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// A new folder for the files of one drop of promised files, so a promised name never replaces an earlier file.
    public func makeDropFolder() throws -> URL {
        try prepareDirectory()
        let folder = directory.appendingPathComponent("Dropped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Removes what was saved more than `lifetime` before `date`. Returns how many items were removed.
    @discardableResult
    public func removeExpired(at date: Date = Date(), lifetime: TimeInterval = TerminalImageStore.lifetime) -> Int {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for item in items {
            guard let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date.timeIntervalSince(modified) > lifetime else { continue }
            if (try? manager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }

    /// The image on a pasteboard as PNG data: its PNG when it has one, otherwise its TIFF converted. Nil without an image.
    public static func png(on pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// The pasteboard types `png(on:)` reads.
    public static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// Creates the folder, private to the user; one that exists with wider permissions is made private too.
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
