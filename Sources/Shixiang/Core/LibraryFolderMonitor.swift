@preconcurrency import CoreServices
import Foundation

/// One recursive FSEvents stream covers every imported root. Events are deliberately coarse:
/// the incremental scanner remains the source of truth after a quiet debounce period.
final class LibraryFolderMonitor: @unchecked Sendable {
    typealias ChangeHandler = @Sendable (_ packID: UUID, _ changedPath: String) -> Void

    private let queue = DispatchQueue(label: "com.jacksun.shixiang.folder-monitor", qos: .utility)
    private var stream: FSEventStreamRef?
    private var rootPathByPackID: [UUID: String] = [:]
    private var handler: ChangeHandler?

    func start(roots: [UUID: URL], onChange: @escaping ChangeHandler) {
        stop()
        guard !roots.isEmpty else { return }
        rootPathByPackID = roots.mapValues { $0.standardizedFileURL.path }
        handler = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = Array(Set(rootPathByPackID.values)).sorted() as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            libraryFolderEventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.25,
            flags
        ) else {
            rootPathByPackID = [:]
            handler = nil
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        rootPathByPackID = [:]
        handler = nil
    }

    func receive(paths: [String]) {
        guard let handler else { return }
        var delivered = Set<UUID>()
        for changedPath in paths {
            let standardized = URL(fileURLWithPath: changedPath).standardizedFileURL.path
            let matches = rootPathByPackID.filter { _, rootPath in
                standardized == rootPath || standardized.hasPrefix(rootPath + "/")
            }
            if let match = matches.max(by: { $0.value.count < $1.value.count }),
               delivered.insert(match.key).inserted {
                handler(match.key, standardized)
            }
        }
    }

    deinit { stop() }
}

private let libraryFolderEventCallback: FSEventStreamCallback = {
    _, clientInfo, numberOfEvents, eventPaths, _, _ in
    guard let clientInfo else { return }
    let monitor = Unmanaged<LibraryFolderMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    paths.reserveCapacity(numberOfEvents)
    for index in 0..<numberOfEvents {
        guard let rawValue = CFArrayGetValueAtIndex(array, index) else { continue }
        let value = Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue()
        paths.append(value as String)
    }
    monitor.receive(paths: paths)
}
