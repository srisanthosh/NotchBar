import Foundation
import CoreServices

/// Reports changed files under a set of folders, using FSEvents, so nothing polls the disk.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    /// - Parameters:
    ///   - paths: Folders to watch. Each must exist when `start()` is called.
    ///   - latency: How long FSEvents may wait to batch changes together.
    ///   - handler: Called on the main queue with the changed file paths.
    init(paths: [String], latency: TimeInterval = 0.3, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            watcher.handler(Array(changed.prefix(count)))
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
    }

    func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
