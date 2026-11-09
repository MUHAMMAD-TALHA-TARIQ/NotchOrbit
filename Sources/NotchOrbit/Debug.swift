import Foundation

/// Diagnostics switched on with `NOTCHORBIT_DEBUG=1` in the environment. Read once:
/// `ProcessInfo.environment` copies the whole environment on every access, and some
/// of the call sites run on every mouse move.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["NOTCHORBIT_DEBUG"] != nil
    /// `NOTCHORBIT_DEBUG_TAB=stats|weather|mic|camera` opens the panel on that tab after launch.
    static let tab = ProcessInfo.processInfo.environment["NOTCHORBIT_DEBUG_TAB"]
}

/// Unbuffered logging to stderr. Silent unless `Debug.enabled`.
func debugLog(_ items: Any...) {
    guard Debug.enabled else { return }
    let line = items.map { "\($0)" }.joined(separator: " ") + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}
