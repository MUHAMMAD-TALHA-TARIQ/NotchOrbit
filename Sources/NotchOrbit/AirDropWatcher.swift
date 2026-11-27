import Foundation

/// Fires when a file received over AirDrop lands in ~/Downloads.
///
/// macOS has no public "incoming AirDrop" notification, but every received
/// file is quarantined by `sharingd`, the AirDrop daemon, and that name is
/// recorded in the file's `com.apple.quarantine` attribute. Browser downloads
/// carry the browser's name there instead, so they do not trigger.
final class AirDropWatcher {
    private let directory: URL
    private let onReceive: ([URL]) -> Void
    private let queue = DispatchQueue(label: "NotchOrbit.AirDropWatcher")
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []     // names already present or already announced
    private var pending: [URL] = []         // received, waiting for the rest of the drop

    init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
         onReceive: @escaping ([URL]) -> Void) {
        self.directory = directory
        self.onReceive = onReceive
    }

    func start() {
        queue.async { [self] in
            guard source == nil else { return }
            // The first open may show the "access Downloads folder" prompt.
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                if fd >= 0 { close(fd) }
                debugLog("airdrop watcher: cannot read \(directory.path)")
                return
            }
            known = Set(names)

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.scan()
                // The quarantine attribute can be written just after the file appears.
                self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scan() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
            debugLog("airdrop watcher: watching \(directory.path) (\(names.count) items)")
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    private func scan() {
        guard source != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let current = Set(names)
        // New names stay unannounced (and get rechecked) until they carry the attribute.
        for name in current.subtracting(known).sorted() {
            let url = directory.appendingPathComponent(name)
            guard isFromAirDrop(url) else { continue }
            known.insert(name)
            pending.append(url)
            // Several files in one drop arrive moments apart; announce them together.
            if pending.count == 1 {
                queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.announce() }
            }
        }
        known.formIntersection(current)
    }

    private func announce() {
        let urls = pending
        pending = []
        guard source != nil, !urls.isEmpty else { return }
        debugLog("airdrop watcher: received \(urls.count) file(s)")
        DispatchQueue.main.async { [onReceive] in onReceive(urls) }
    }

    private func isFromAirDrop(_ url: URL) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 512)
        let length = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return false }
        return String(decoding: buffer[..<length], as: UTF8.self).contains("sharingd")
    }
}
