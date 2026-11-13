import AppKit
import ImageIO
import SuijinGit
import SuijinUI
import SwiftUI
import UniformTypeIdentifiers

/// One version of an image to show in a diff: which side it is and where that side keeps the file.
struct ImageDiffSource: Hashable, Sendable {
    var side: DiffSide
    /// The path on that side, relative to the toplevel (the old path of a renamed or copied file).
    var path: String

    /// Whether a binary diff of `path` is an image the system can draw.
    static func isImage(path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// The versions a binary image diff compares: the old one unless the file was added, the new one unless it was
    /// deleted. A renamed or copied file reads its old version under its old path.
    static func sources(for diff: FileDiff) -> [ImageDiffSource] {
        guard diff.isBinary, isImage(path: diff.displayPath) || diff.oldPath.map(isImage(path:)) == true else { return [] }
        var sources: [ImageDiffSource] = []
        if let old = diff.oldPath { sources.append(ImageDiffSource(side: .old, path: old)) }
        if let new = diff.newPath { sources.append(ImageDiffSource(side: .new, path: new)) }
        return sources
    }
}

/// A decoded image version. The bitmap is decoded off the main thread, downsampled when it is huge.
struct DecodedImage: @unchecked Sendable {
    // `CGImage` is immutable and thread-safe, but not marked `Sendable` by CoreGraphics.
    let image: CGImage
    /// The size of the original image in pixels (the bitmap may be smaller when it was downsampled).
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    /// Images wider or taller than this many pixels are downsampled for display, so a small file that declares a
    /// huge canvas cannot exhaust memory.
    static let maximumPixelSize = 8192

    /// Decodes the largest representation in `data` (icons hold several); nil when it is not a readable image.
    static func decode(_ data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var best: (index: Int, width: Int, height: Int)?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else { continue }
            // EXIF orientations 5 to 8 turn the image a quarter; report the dimensions as shown.
            if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            if width * height > (best.map { $0.width * $0.height } ?? 0) { best = (index, width, height) }
        }
        guard let best else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(best.width, best.height), maximumPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best.index, options as CFDictionary) else { return nil }
        return DecodedImage(image: image, pixelWidth: best.width, pixelHeight: best.height, byteCount: data.count)
    }
}

/// A binary image in the Changes view: the new image for an added file, the old one for a deleted file, and both,
/// labelled, for a modified, renamed or copied one. Side by side when the pane is wide enough, else stacked.
struct ImageDiffView: View {
    let directory: URL
    let scope: DiffScope
    let sources: [ImageDiffSource]
    /// Changes when the checkout changed on disk, so a rewritten image is read again.
    let revision: Int

    /// Larger versions are not read at all.
    static let maximumFileSize = 64 * 1024 * 1024
    /// Side by side needs room for two readable images.
    static let sideBySideMinimumWidth: CGFloat = 560

    enum Version {
        case loading
        case loaded(DecodedImage, NSImage)
        case failed(String)
    }

    private struct LoadKey: Hashable {
        var directory: URL
        var scope: DiffScope
        var sources: [ImageDiffSource]
        var revision: Int
    }

    @State private var versions: [ImageDiffSource: Version] = [:]
    /// The bytes behind each loaded version, so a refresh that finds the same bytes keeps the image (and its zoom).
    @State private var loadedData: [ImageDiffSource: Data] = [:]
    @State private var width: CGFloat = 0

    var body: some View {
        let isSideBySide = sources.count > 1 && width >= Self.sideBySideMinimumWidth
        let layout = isSideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                if index > 0 { Divider() }
                ImageVersionPanel(source: source, version: versions[source] ?? .loading, isPair: sources.count > 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: LoadKey(directory: directory, scope: scope, sources: sources, revision: revision)) { await load() }
    }

    /// Reads every side; a side whose bytes did not change keeps its image. Results are dropped once the task is
    /// cancelled because the view moved on to other sources (git calls themselves are not cancellable).
    private func load() async {
        let service = DiffService(worktree: directory)
        let requested = sources
        for key in versions.keys where !requested.contains(key) {
            versions[key] = nil
            loadedData[key] = nil
        }
        for source in requested {
            if versions[source] == nil { versions[source] = .loading }
            let result: Result<Data?, any Error>
            do {
                result = .success(try await service.contents(of: source.path, side: source.side, scope: scope,
                                                              maximumSize: Self.maximumFileSize))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            switch result {
            case .failure(let error):
                versions[source] = .failed(error.localizedDescription)
                loadedData[source] = nil
            case .success(nil):
                versions[source] = .failed(String(localized: "The file is not there in this version."))
                loadedData[source] = nil
            case .success(let data?):
                if loadedData[source] == data, case .loaded = versions[source] { continue }
                let decoded = await Task.detached(priority: .userInitiated) { DecodedImage.decode(data) }.value
                guard !Task.isCancelled else { return }
                if let decoded {
                    let size = NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight)
                    versions[source] = .loaded(decoded, NSImage(cgImage: decoded.image, size: size))
                    loadedData[source] = data
                } else {
                    versions[source] = .failed(String(localized: "The file is not an image this Mac can read, or it is damaged."))
                    loadedData[source] = nil
                }
            }
        }
    }
}

/// One labelled version ("Before" or "After", or "Added" or "Deleted" when alone) with its pixel size and file size, and the image fitted to the panel.
private struct ImageVersionPanel: View {
    let source: ImageDiffSource
    let version: ImageDiffView.Version
    let isPair: Bool
    @State private var zoom = ImageZoomController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SuijinSpacing.s) {
                // A lone version is the whole added or deleted file; a pair is the change.
                switch (source.side, isPair) {
                case (.old, true): Label("Before", systemImage: "minus.circle").foregroundStyle(.red)
                case (.new, true): Label("After", systemImage: "plus.circle").foregroundStyle(.green)
                case (.old, false): Label("Deleted", systemImage: "minus.circle").foregroundStyle(.red)
                case (.new, false): Label("Added", systemImage: "plus.circle").foregroundStyle(.green)
                }
                Spacer(minLength: SuijinSpacing.s)
                if case .loaded(let decoded, _) = version {
                    Text(details(of: decoded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.callout)
            .padding(.horizontal, SuijinSpacing.m)
            .padding(.vertical, SuijinSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: 24)
            Group {
                switch version {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(_, let image):
                    ZoomableImageView(image: image, controller: zoom)
                        .accessibilityLabel(source.side == .old ? Text("Image before the change") : Text("Image after the change"))
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Cannot Show the Image", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text(verbatim: message)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func details(of decoded: DecodedImage) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(decoded.byteCount), countStyle: .file)
        return String(localized: "\(decoded.pixelWidth) × \(decoded.pixelHeight) px, \(size)",
                      comment: "Pixel dimensions and file size of an image in the Changes view")
    }
}
