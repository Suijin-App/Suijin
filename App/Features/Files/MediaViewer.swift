import AppKit
import AVFoundation
import AVKit
import QuickLookThumbnailing
import QuickLookUI
import SuijinUI
import SwiftUI
import UniformTypeIdentifiers

/// What the viewer knows about a playable audio or video file, read from its headers (the media itself streams from
/// disk while it plays).
struct MediaInfo: Equatable, Sendable {
    /// Whether the file has a picture; an audio file gets the audio layout.
    var hasVideo: Bool
    var duration: Double?
    /// Display size of the picture (rotation applied), in pixels.
    var dimensions: CGSize?
    /// Codec names of the tracks, video first ("HEVC", "AAC").
    var codecs: [String]
    var fileSize: Int64

    /// "1:23 · 1920×1080 · HEVC, AAC · 12.4 MB" for the viewer header.
    var summary: String {
        var parts: [String] = []
        if let duration { parts.append(Self.format(duration: duration)) }
        if let dimensions, dimensions.width > 0, dimensions.height > 0 {
            parts.append("\(Int(dimensions.width.rounded()))×\(Int(dimensions.height.rounded()))")
        }
        if !codecs.isEmpty { parts.append(codecs.joined(separator: ", ")) }
        parts.append(fileSize.formatted(.byteCount(style: .file)))
        return parts.joined(separator: " · ")
    }

    static func format(duration: Double) -> String {
        guard duration.isFinite, duration >= 0 else { return "--:--" }
        let pattern: Duration.TimeFormatStyle.Pattern = duration >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(duration.rounded()).formatted(.time(pattern: pattern))
    }
}

/// Decides how an audio or video file is shown. Playability is AVFoundation's answer for the file itself, so anything
/// the system can decode (H.264, HEVC, ProRes, AAC, FLAC…) plays in the native player whatever its extension says.
enum MediaProbe {
    /// Containers often left undeclared on macOS (no app claims `.mkv` unless one is installed); they still count as
    /// media so the viewer can say it cannot play them instead of sending the file to Finder.
    nonisolated static let mediaExtensions: Set<String> = [
        "mkv", "mka", "webm", "avi", "flv", "wmv", "wma", "asf", "ogv", "ogg", "oga", "opus", "rm", "rmvb", "vob", "3gp",
    ]

    /// Whether `url` names an audio or video file by type. Text that only shares a media extension (`.ts` is also
    /// TypeScript) is not media: a media header has NUL bytes in its first few kilobytes, text never does.
    nonisolated static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let typed = UTType(filenameExtension: ext).map { $0.conforms(to: .audiovisualContent) } ?? false
        guard typed || mediaExtensions.contains(ext) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return head.isEmpty || head.contains(0)
    }

    /// Whether Quick Look has a generator for the file: a real thumbnail (not just the type's icon) means an installed
    /// Quick Look extension understands the format, and those ship a preview beside the thumbnail.
    nonisolated static func quickLookCanPreview(_ url: URL) async -> Bool {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: 1,
                                                   representationTypes: .thumbnail)
        do {
            _ = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return true
        } catch {
            return false
        }
    }

    /// The viewer content for a media file: the player when AVFoundation can play it, else Quick Look when it can
    /// preview it, else the "Can't Play" state.
    nonisolated static func content(
        for url: URL,
        quickLook: @Sendable (URL) async -> Bool = { await quickLookCanPreview($0) }
    ) async -> FileViewer.Content {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let info = await playableInfo(url, fileSize: fileSize) { return .media(info) }
        return await quickLook(url) ? .quickLook : .unplayable(isAudio: isAudioFile(url))
    }

    /// Whether `url` is sound only by type, for the wording of the "Can't Play" state.
    nonisolated static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.isDeclared { return type.conforms(to: .audio) }
        return audioExtensions.contains(ext)
    }

    /// Undeclared containers from `mediaExtensions` that hold sound only.
    nonisolated static let audioExtensions: Set<String> = ["mka", "wma", "ogg", "oga", "opus"]

    /// Duration, picture size and codecs when AVFoundation can play the file; nil when it cannot.
    private nonisolated static func playableInfo(_ url: URL, fileSize: Int64) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let (playable, duration) = try? await asset.load(.isPlayable, .duration), playable else { return nil }
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !video.isEmpty || !audio.isEmpty else { return nil }
        var info = MediaInfo(hasVideo: !video.isEmpty, duration: duration.isNumeric ? duration.seconds : nil,
                             dimensions: nil, codecs: [], fileSize: fileSize)
        if let track = video.first,
           let (size, transform, formats) = try? await track.load(.naturalSize, .preferredTransform, .formatDescriptions) {
            let shown = size.applying(transform)
            info.dimensions = CGSize(width: abs(shown.width), height: abs(shown.height))
            info.codecs += formats.prefix(1).map { codecName(CMFormatDescriptionGetMediaSubType($0)) }
        }
        if let track = audio.first, let formats = try? await track.load(.formatDescriptions) {
            info.codecs += formats.prefix(1).map { codecName(CMFormatDescriptionGetMediaSubType($0)) }
        }
        return info
    }

    /// A readable name for a codec four-character code, or the code itself when it is not a common one.
    nonisolated static func codecName(_ code: FourCharCode) -> String {
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespaces) ?? "\(code)"
        switch fourCC {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "Dolby Vision"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x", "aprn", "aprh": return "ProRes"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4v": return "MPEG-4"
        case "jpeg": return "Motion JPEG"
        case "mp4a", "aac": return "AAC"
        case ".mp3": return "MP3"
        case "lpcm", "sowt", "twos": return "PCM"
        case "alac": return "Apple Lossless"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        default: return fourCC
        }
    }
}

/// The player behind a media tab. It exists only while the tab is shown: hiding the tab (another tab selected, the
/// tab closed, the file deleted) pauses and releases it, and the position is handed back so the tab resumes there.
/// A new player always starts paused, so opening a tab never plays sound.
@MainActor
final class MediaPlaybackController {
    private(set) var player: AVPlayer?

    /// The player for `url`, created paused at `position` (seconds) when there is none yet.
    @discardableResult
    func show(_ url: URL, at position: Double?) -> AVPlayer {
        if let player { return player }
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.actionAtItemEnd = .pause
        if let position, position > 0 { player.seek(to: Self.time(position), toleranceBefore: .zero, toleranceAfter: .zero) }
        self.player = player
        return player
    }

    /// Loads the file again after it changed on disk: same position (clamped to the new length by AVFoundation),
    /// still playing if it was.
    func reload(_ url: URL) {
        guard let player else { return }
        let time = player.currentTime()
        let wasPlaying = player.rate != 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if time.isNumeric, time.seconds > 0 { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        if wasPlaying { player.play() }
    }

    /// Pauses and releases the player; returns where it was, in seconds.
    @discardableResult
    func suspend() -> Double? {
        guard let player else { return nil }
        player.pause()
        let time = player.currentTime()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        return time.isNumeric ? time.seconds : nil
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
}

/// Which open tab a saved playback position belongs to.
/// One file tab: a path opened in a context.
typealias FileTabKey = MediaPositionKey

struct MediaPositionKey: Hashable {
    let context: SessionContext
    let path: String
}

/// A playable file in the system player: a video fills the tab, an audio file shows its icon and name above the
/// player's controls.
struct MediaPlayerTab: View {
    @Environment(AppModel.self) private var model
    let path: String
    let context: SessionContext
    let info: MediaInfo
    /// Bumped by the file model each time the file is read again (it changed on disk).
    let revision: Int
    let controller: MediaPlaybackController
    @State private var player: AVPlayer?
    @State private var shownRevision: Int?

    private var url: URL { URL(fileURLWithPath: path) }
    private var key: MediaPositionKey { MediaPositionKey(context: context, path: path) }

    var body: some View {
        Group {
            if let player {
                if info.hasVideo {
                    SystemPlayerView(player: player, isVideo: true)
                        .accessibilityLabel(Text("Video player"))
                } else {
                    audioLayout(player)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            player = controller.show(url, at: model.mediaPositions[key])
            shownRevision = revision
        }
        .onDisappear {
            let position = controller.suspend()
            player = nil
            // A closed tab forgets its position; a tab that is only hidden resumes there.
            if model.openFiles[context]?.contains(path) == true { model.mediaPositions[key] = position }
        }
        .onChange(of: revision) { _, new in
            guard shownRevision != new else { return }
            shownRevision = new
            controller.reload(url)
        }
    }

    private func audioLayout(_ player: AVPlayer) -> some View {
        VStack(spacing: SuijinSpacing.l) {
            Spacer(minLength: 0)
            Image(nsImage: FileIcons.largeIcon(forPath: path))
                .accessibilityHidden(true)
            VStack(spacing: SuijinSpacing.xs) {
                Text(verbatim: url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(verbatim: info.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            // Inline controls are a 36 pt capsule 6 pt inside the player view, which paints an opaque backdrop around
            // them; clipping to that capsule leaves just the system control bar.
            SystemPlayerView(player: player, isVideo: false)
                .frame(maxWidth: 560)
                .frame(height: 48)
                .clipShape(Capsule().inset(by: 6))
                .accessibilityLabel(Text("Audio player"))
            Spacer(minLength: 0)
        }
        .padding(SuijinSpacing.xl)
    }
}

/// AVKit's own player view: inline controls with scrubbing and volume, plus full screen and Picture in Picture for
/// video. The view lets go of the player when it is removed, so the player is freed with its tab.
private struct SystemPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let isVideo: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = isVideo
        view.allowsPictureInPicturePlayback = isVideo
        view.showsSharingServiceButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    /// Whatever room the tab offers: the player's own fitting size follows the video's size and would widen the pane.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 48))
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// A file AVFoundation cannot play but Quick Look can preview, in the system preview view.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> QLPreviewView {
        // `.normal` draws the preview's own controls (a movie's play bar); it never returns nil for that style.
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.revision != revision || (view.previewItem as? NSURL) as URL? != url else { return }
        context.coordinator.revision = revision
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var revision = 0
    }
}
