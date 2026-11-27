import Carbon.HIToolbox

/// System-wide hotkeys through Carbon, which needs no Accessibility permission.
enum HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    @discardableResult
    static func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers),
            EventHotKeyID(signature: 0x4E4F_5242 /* 'NORB' */, id: id),
            GetApplicationEventTarget(), 0, &ref)
        debugLog("hotkey register keyCode=\(keyCode) status=\(status)")
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    static func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            debugLog("hotkey fired id=\(hotKeyID.id)")
            HotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
