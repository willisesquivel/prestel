import CoreServices
import Foundation

final class RepositoryWatcher: RepositoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [RepositoryKey: StreamBox] = [:]

    func events(for key: RepositoryKey) -> AsyncStream<RepositoryInvalidation> {
        stop(key)
        let box = StreamBox()
        let (stream, continuation) = AsyncStream<RepositoryInvalidation>.makeStream()
        box.continuation = continuation
        let paths = [key.worktreeRoot, key.gitDirectory, key.commonGitDirectory]
            .filter { !$0.isEmpty }
            .map { $0 as CFString }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flagsPointer, _ in
            guard let info else { return }
            let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
            let flags = UnsafeBufferPointer(start: flagsPointer, count: count)
            let paths = UnsafeBufferPointer(start: pathsPointer.assumingMemoryBound(to: UnsafePointer<CChar>.self), count: count)
            var filePaths: [String] = []
            var metadata = false
            var rescan = false
            var lockChanged: Bool?
            for index in 0..<count {
                let path = String(cString: paths[index])
                let flag = flags[index]
                if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    rescan = true
                }
                let last = (path as NSString).lastPathComponent
                if last == "HEAD" || last == "index" || last.hasPrefix("refs") || path.contains("/refs/") || last == "packed-refs" || last == ".gitignore" || last == ".gitattributes" || last == "info" || path.contains("/info/exclude") || path.contains("/worktrees/") {
                    metadata = true
                }
                if last == "index.lock" {
                    lockChanged = !path.hasSuffix("~")
                    let exists = FileManager.default.fileExists(atPath: path)
                    lockChanged = exists
                }
                filePaths.append(path)
            }
            box.enqueue(
                rescan: rescan,
                metadata: metadata,
                lockChanged: lockChanged,
                files: filePaths
            )
        }
        guard let raw = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            continuation.yield(.rescan)
            return stream
        }
        box.stream = raw
        FSEventStreamSetDispatchQueue(raw, box.queue)
        FSEventStreamStart(raw)
        continuation.onTermination = { [weak self, weak box] _ in
            box?.stop()
            self?.remove(key)
        }
        lock.lock()
        streams[key] = box
        lock.unlock()
        return stream
    }

    func stop(_ key: RepositoryKey) {
        lock.lock()
        let box = streams.removeValue(forKey: key)
        lock.unlock()
        box?.stop()
    }

    func stopAll() {
        lock.lock()
        let values = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        values.forEach { $0.stop() }
    }

    private func remove(_ key: RepositoryKey) {
        lock.lock()
        streams.removeValue(forKey: key)
        lock.unlock()
    }
}

private final class StreamBox: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<UInt8>()
    let queue: DispatchQueue
    var stream: FSEventStreamRef?
    var continuation: AsyncStream<RepositoryInvalidation>.Continuation?
    private var pendingFiles: [String] = []
    private var pendingMetadata = false
    private var pendingRescan = false
    private var pendingLock: Bool?
    private var debounceWork: DispatchWorkItem?
    private var firstEvent: DispatchTime?
    private var stopped = false

    init() {
        queue = DispatchQueue(label: "genesis.review.fsevents")
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    func enqueue(rescan: Bool, metadata: Bool, lockChanged: Bool?, files: [String]) {
        queue.async {
            guard !self.stopped else { return }
            if rescan { self.pendingRescan = true }
            if metadata { self.pendingMetadata = true }
            if let lockChanged { self.pendingLock = lockChanged }
            self.pendingFiles.append(contentsOf: files)
            if self.firstEvent == nil { self.firstEvent = .now() }
            self.debounceWork?.cancel()
            let maxWaitExpired = self.firstEvent.map { DispatchTime.now() > $0 + .nanoseconds(Int(ReviewBudgets.watcherMaxCoalesceNanoseconds)) } ?? false
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.debounceWork = work
            let delay: DispatchTimeInterval = maxWaitExpired ? .nanoseconds(0) : .milliseconds(500)
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func flush() {
        guard !stopped else { return }
        if let lock = pendingLock {
            continuation?.yield(.indexLockChanged(locked: lock))
        }
        if pendingRescan {
            continuation?.yield(.rescan)
        } else if pendingMetadata {
            continuation?.yield(.metadata)
        } else if !pendingFiles.isEmpty {
            continuation?.yield(.files(pendingFiles))
        }
        pendingFiles = []
        pendingMetadata = false
        pendingRescan = false
        pendingLock = nil
        firstEvent = nil
        debounceWork = nil
    }

    func stop() {
        if queue.getSpecific(key: Self.queueKey) != nil {
            performStop()
        } else {
            queue.sync(execute: performStop)
        }
    }

    private func performStop() {
        guard !stopped else { return }
        stopped = true
        debounceWork?.cancel()
        debounceWork = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.finish()
    }
}
