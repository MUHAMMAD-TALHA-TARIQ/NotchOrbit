import AppKit
import Combine
import CryptoKit

/// Downloads the BlackHole 2ch loopback driver package (free, open source, by Existential
/// Audio), checks its SHA-256 against the published one, and opens it in Installer.
/// macOS asks for an administrator password there; NotchOrbit never runs anything
/// privileged itself. Coreaudiod picks the new device up without a restart.
final class BlackHoleInstaller: ObservableObject {
    static let shared = BlackHoleInstaller()

    enum State: Equatable {
        case idle, downloading, opened, failed(String)
    }

    @Published private(set) var state: State = .idle

    static let version = "0.7.1"
    static let packageURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-\(version).pkg")!
    /// SHA-256 of the package above, as published by the Homebrew cask `blackhole-2ch`.
    static let packageSHA256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    static let homepage = URL(string: "https://existential.audio/blackhole/")!

    private var task: URLSessionDownloadTask?

    private init() {}

    func install() {
        guard state != .downloading else { return }
        state = .downloading
        let task = URLSession.shared.downloadTask(with: Self.packageURL) { [weak self] location, _, error in
            let outcome: State
            if let error {
                outcome = .failed("Download failed: \(error.localizedDescription)")
            } else if let location {
                outcome = Self.verifyAndOpen(location)
            } else {
                outcome = .failed("Download failed.")
            }
            DispatchQueue.main.async { self?.state = outcome }
        }
        self.task = task
        task.resume()
    }

    private static func verifyAndOpen(_ location: URL) -> State {
        do {
            let data = try Data(contentsOf: location)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == packageSHA256 else {
                return .failed("The downloaded package doesn't match the published checksum, so it wasn't opened. Download it from existential.audio instead.")
            }
            let downloads = StatsSettings.defaultPhotoDirectory
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let destination = downloads.appendingPathComponent(packageURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            var opened = false
            DispatchQueue.main.sync { opened = NSWorkspace.shared.open(destination) }
            return opened ? .opened : .failed("Saved to Downloads › \(destination.lastPathComponent) but couldn't open it. Double-click it to install.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
