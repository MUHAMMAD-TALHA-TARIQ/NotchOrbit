import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only (no Dock icon). The bundled Info.plist also sets LSUIElement.
app.setActivationPolicy(.accessory)
app.run()
