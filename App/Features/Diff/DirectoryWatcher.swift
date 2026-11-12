import CoreServices
import Foundation

/// Calls `onChange` on the main actor, debounced, whenever something under `directory` changes (FSEvents).
@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private let debounce: Duration
    private let onChange: @MainActor () -> Void

    init(directory: URL, debounce: Duration = .milliseconds(400), onChange: @escaping @MainActor () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.schedule() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Must be called before the watcher is released; the stream holds an unretained pointer to it.
    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
