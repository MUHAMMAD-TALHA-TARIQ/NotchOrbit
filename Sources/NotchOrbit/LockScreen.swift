import AppKit

/// Lock state, and the way onto the lock screen.
///
/// No public window level sits above the lock screen. WindowServer does
/// however stack whole spaces by an "absolute level", and a window moved into
/// a space above the lock screen's is drawn over it. That needs private
/// SkyLight calls, looked up at runtime so a macOS that drops them only
/// loses the lock-screen ripple.
enum LockScreen {
    private(set) static var isLocked = false
    private static var observing = false

    static func observe(onLock: @escaping () -> Void, onUnlock: @escaping () -> Void) {
        guard !observing else { return }
        observing = true
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            isLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            isLocked = true
            onLock()
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            isLocked = false
            onUnlock()
        }
    }

    /// Moves `window` into the space above the lock screen. It keeps showing
    /// over the unlocked desktop as before.
    static func raise(_ window: NSWindow) {
        guard let space, let connection, let move, window.windowNumber > 0 else { return }
        _ = move(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }

    // MARK: SkyLight

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int, Int) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias MoveWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    /// The lock screen's own space is at 300; 400 is where the system puts
    /// what it shows on top of it.
    private static let levelAboveLockScreen: Int32 = 400

    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else {
            debugLog("lock screen: \(name) is unavailable")
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }

    private static let connection: Int32? = symbol("SLSMainConnectionID", as: MainConnection.self)?()
    private static let move = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: MoveWindows.self)

    private static let space: UInt64? = {
        guard let connection,
              let create = symbol("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetLevel.self),
              let show = symbol("SLSShowSpaces", as: ShowSpaces.self) else { return nil }
        let space = create(connection, 1, 0)
        guard space != 0 else {
            debugLog("lock screen: could not create a space")
            return nil
        }
        _ = setLevel(connection, space, levelAboveLockScreen)
        _ = show(connection, [NSNumber(value: space)] as CFArray)
        debugLog("lock screen: space \(space) at level \(levelAboveLockScreen)")
        return space
    }()
}
