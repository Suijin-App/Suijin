import AppKit
import AVFoundation
import AVKit
import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Audio and video in the file viewer: which viewer a file gets, and the player's life with its tab. Sample media is
/// written at test time into a temporary folder (a second of video, a second of tone), nothing is checked in.
@MainActor
@Suite(.serialized)
struct MediaViewerTests {
    // MARK: Which viewer

    @Test func playableVideoOpensInThePlayerWithItsInfo() async throws {
        let folder = try MediaFolder()
        for (name, type, codec, expected) in [
            ("clip.mp4", AVFileType.mp4, AVVideoCodecType.h264, "H.264"),
            ("clip.mov", AVFileType.mov, AVVideoCodecType.hevc, "HEVC"),
        ] {
            let url = folder.url(name)
            try await MediaSamples.writeVideo(to: url, fileType: type, codec: codec, width: 320, height: 240, seconds: 1)
            guard case .media(let info) = await FileViewer.load(url) else {
                Issue.record("\(name) should play")
                continue
            }
            #expect(info.hasVideo)
            #expect(info.dimensions == CGSize(width: 320, height: 240))
            #expect(info.codecs == [expected])
            #expect(abs((info.duration ?? 0) - 1) < 0.1, "\(name) lasts a second: \(info.duration ?? -1)")
            #expect(info.summary.hasPrefix("0:01 · 320×240 · \(expected) · "), "\(info.summary)")
        }
    }

    @Test func audioPlaysWithTheAudioLayout() async throws {
        let folder = try MediaFolder()
        for (name, format, expected) in [("tone.m4a", kAudioFormatMPEG4AAC, "AAC"), ("tone.wav", kAudioFormatLinearPCM, "PCM")] {
            let url = folder.url(name)
            try MediaSamples.writeTone(to: url, format: format, seconds: 1)
            guard case .media(let info) = await FileViewer.load(url) else {
                Issue.record("\(name) should play")
                continue
            }
            #expect(!info.hasVideo)
            #expect(info.dimensions == nil)
            #expect(info.codecs == [expected])
        }
    }

    @Test func unplayableVideoGoesToQuickLookOrTheFallback() async throws {
        let folder = try MediaFolder()
        // A Matroska / WebM header with no streams AVFoundation knows.
        var ebml = Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01])
        ebml.append(Data(count: 64))
        for name in ["clip.mkv", "clip.webm"] {
            let url = folder.url(name)
            try ebml.write(to: url)
            #expect(FileViewer.read(url).isMediaFile, "\(name) is media by type, so it never goes to Finder")
            #expect(await MediaProbe.content(for: url, quickLook: { _ in true }).isQuickLook)
            #expect(await MediaProbe.content(for: url, quickLook: { _ in false }).isUnplayable)
            let real = await FileViewer.load(url)
            #expect(real.isQuickLook || real.isUnplayable, "\(name): \(real)")
        }
    }

    @Test func unplayableAudioSaysAudio() async throws {
        let folder = try MediaFolder()
        let url = folder.url("voice.opus")
        try Data([0x4F, 0x67, 0x67, 0x53, 0, 2, 0, 0, 0, 0]).write(to: url)
        guard case .unplayable(let isAudio) = await MediaProbe.content(for: url, quickLook: { _ in false }) else {
            Issue.record("a broken Opus file cannot play")
            return
        }
        #expect(isAudio)
        #expect(MediaProbe.isAudioFile(folder.url("song.mp3")))
        #expect(!MediaProbe.isAudioFile(folder.url("clip.mkv")), "an undeclared movie container is video")
        #expect(!MediaProbe.isAudioFile(folder.url("clip.webm")))
    }

    @Test func textSharingAMediaExtensionStaysText() async throws {
        let folder = try MediaFolder()
        // `.ts` is both TypeScript and an MPEG transport stream.
        let url = folder.url("index.ts")
        try "export const answer = 42\n".write(to: url, atomically: true, encoding: .utf8)
        guard case .code(_, let language) = await FileViewer.load(url) else {
            Issue.record("TypeScript should open as code")
            return
        }
        #expect(language == "typescript")
    }

    @Test func mediaFilesOpenInATabNotFinder() async throws {
        let folder = try MediaFolder()
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: folder.url("data"))
        let context = SessionContext.workspace(UUID())
        let url = folder.url("clip.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]).write(to: url)
        #expect(model.open(fileAt: url, in: context))
        #expect(model.openFiles[context] == [url.path])
    }

    @Test func codecNamesAreReadable() {
        #expect(MediaProbe.codecName(kCMVideoCodecType_AppleProRes422) == "ProRes")
        #expect(MediaProbe.codecName(kCMVideoCodecType_H264) == "H.264")
        #expect(MediaProbe.codecName(kAudioFormatMPEG4AAC) == "AAC")
        #expect(MediaProbe.codecName(0x7A7A_7A7A) == "zzzz")
        #expect(MediaInfo.format(duration: 3725) == "1:02:05")
    }

    // MARK: Player lifecycle

    @Test func playerStartsPausedAndIsReleasedWhenSuspended() async throws {
        let folder = try MediaFolder()
        let url = folder.url("clip.mp4")
        try await MediaSamples.writeVideo(to: url, fileType: .mp4, codec: .h264, width: 160, height: 120, seconds: 2)
        let controller = MediaPlaybackController()
        weak var released: AVPlayer?
        do {
            let player = controller.show(url, at: nil)
            released = player
            #expect(player.rate == 0, "a new tab never plays on its own")
            #expect(controller.show(url, at: nil) === player, "showing again keeps the same player")
            try await waitUntil { player.currentItem?.status == .readyToPlay }
            await player.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try await waitUntil { abs(player.currentTime().seconds - 1.2) < 0.05 }
            player.play()
        }
        let position = try #require(controller.suspend())
        #expect(abs(position - 1.2) < 0.3, "position handed back: \(position)")
        #expect(controller.player == nil)
        try await waitUntil { released == nil }
        #expect(released == nil, "the player is freed once its tab is hidden")

        let resumed = controller.show(url, at: position)
        try await waitUntil { abs(resumed.currentTime().seconds - position) < 0.05 }
        #expect(resumed.rate == 0)
        #expect(abs(resumed.currentTime().seconds - position) < 0.05, "it resumes where it was")
        controller.suspend()
    }

    @Test func reloadKeepsThePosition() async throws {
        let folder = try MediaFolder()
        let url = folder.url("clip.mov")
        try await MediaSamples.writeVideo(to: url, fileType: .mov, codec: .h264, width: 160, height: 120, seconds: 2)
        let controller = MediaPlaybackController()
        let player = controller.show(url, at: 1.5)
        try await waitUntil { player.currentItem?.status == .readyToPlay && abs(player.currentTime().seconds - 1.5) < 0.05 }
        let before = player.currentItem
        try await MediaSamples.writeVideo(to: url, fileType: .mov, codec: .h264, width: 200, height: 100, seconds: 3)
        controller.reload(url)
        #expect(player.currentItem !== before, "the new version is loaded")
        try await waitUntil { player.currentItem?.status == .readyToPlay && abs(player.currentTime().seconds - 1.5) < 0.05 }
        #expect(abs(player.currentTime().seconds - 1.5) < 0.05, "kept at 1.5 s: \(player.currentTime().seconds)")
        controller.suspend()
    }

    @Test func tabPausesWhenHiddenResumesWhenShownAndForgetsWhenClosed() async throws {
        let folder = try MediaFolder()
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: folder.url("data"))
        let context = SessionContext.workspace(UUID())
        let url = folder.url("clip.mp4")
        try await MediaSamples.writeVideo(to: url, fileType: .mp4, codec: .h264, width: 320, height: 240, seconds: 2)
        model.openFile(url.path, in: context)
        let key = MediaPositionKey(context: context, path: url.path)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: AnyView(FileViewer(path: url.path, context: context).environment(model)))
        window.contentView = host
        window.orderFrontRegardless()

        weak var released: AVPlayer?
        do {
            let player = try await shownPlayer(in: host)
            released = player
            #expect(player.rate == 0, "the tab opens paused")
            try await waitUntil { player.currentItem?.status == .readyToPlay }
            await player.seek(to: CMTime(seconds: 0.8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try await waitUntil { abs(player.currentTime().seconds - 0.8) < 0.05 }
            player.play()
            #expect(player.rate != 0)
        }

        // Another tab selected: the viewer goes away with its player. The app's run loop drains its autorelease pool
        // after every event; a test's main-actor task does not, so the teardown gets its own pool.
        autoreleasepool {
            host.rootView = AnyView(Color.clear)
            host.layoutSubtreeIfNeeded()
        }
        try await waitUntil { model.mediaPositions[key] != nil && released == nil }
        #expect(released == nil, "the hidden tab's player is freed")
        let saved = try #require(model.mediaPositions[key])
        #expect(saved >= 0.75 && saved < 1.5, "position kept: \(saved)")

        // Back to the tab: a new player at the same place, still paused.
        weak var closed: AVPlayer?
        do {
            host.rootView = AnyView(FileViewer(path: url.path, context: context).environment(model))
            let again = try await shownPlayer(in: host)
            closed = again
            try await waitUntil { abs(again.currentTime().seconds - saved) < 0.05 }
            #expect(again.rate == 0)
            #expect(abs(again.currentTime().seconds - saved) < 0.05, "resumed at \(saved): \(again.currentTime().seconds)")
        }

        // Closing the tab frees the player and forgets the position.
        model.closeFile(url.path, in: context)
        autoreleasepool {
            host.rootView = AnyView(Color.clear)
            host.layoutSubtreeIfNeeded()
        }
        try await waitUntil { closed == nil }
        #expect(closed == nil, "the closed tab's player is freed")
        #expect(model.mediaPositions[key] == nil)
    }

    // MARK: Helpers

    /// The player of the AVPlayerView in `host`, once the file was probed and the view is up.
    private func shownPlayer(in host: NSView) async throws -> AVPlayer {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let player = playerViews(in: host).first?.player { return player }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("no player shown")
        throw CancellationError()
    }

    private func playerViews(in view: NSView) -> [AVPlayerView] {
        ((view as? AVPlayerView).map { [$0] } ?? []) + view.subviews.flatMap { playerViews(in: $0) }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Small media files written with AVFoundation, so tests need no checked-in binaries or command-line tools.
enum MediaSamples {
    /// A video of moving gray frames at 10 frames per second.
    nonisolated static func writeVideo(to url: URL, fileType: AVFileType, codec: AVVideoCodecType, width: Int, height: Int,
                                       seconds: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 12 % 255), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in writer.finishWriting { done.resume() } }
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A 440 Hz tone in `format` (AAC in an `.m4a`, linear PCM in a `.wav`).
    nonisolated static func writeTone(to url: URL, format: AudioFormatID, seconds: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 44_100.0
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        if format == kAudioFormatLinearPCM { settings[AVLinearPCMBitDepthKey] = 16 }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(rate) * AVAudioFrameCount(seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { samples[index] = Float(sin(2 * .pi * 440 * Double(index) / rate) * 0.3) }
        try file.write(from: buffer)
    }
}

/// A temporary folder removed when the test ends.
private final class MediaFolder {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
}

private extension FileViewer.Content {
    var isMediaFile: Bool {
        if case .mediaFile = self { return true }
        return false
    }

    var isQuickLook: Bool {
        if case .quickLook = self { return true }
        return false
    }

    var isUnplayable: Bool {
        if case .unplayable = self { return true }
        return false
    }
}
