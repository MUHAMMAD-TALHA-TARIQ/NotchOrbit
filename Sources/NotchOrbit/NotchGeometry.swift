import AppKit

enum OverlayKind: Equatable {
    /// The display has a hardware notch; `rect` is the notch itself.
    case notch
    /// A display without a notch; `rect` is a virtual Dynamic Island.
    case island
}

/// One overlay target per display, in global screen coordinates (origin bottom-left).
struct OverlayTarget {
    let screen: NSScreen
    let rect: CGRect
    let kind: OverlayKind

    /// Every display that should get an overlay given the current settings.
    static func detect(settings: AppSettings) -> [OverlayTarget] {
        var targets: [OverlayTarget] = []
        for screen in NSScreen.screens {
            let top = screen.safeAreaInsets.top
            if top > 0,
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                let rect = CGRect(x: left.maxX, y: screen.frame.maxY - top,
                                  width: right.minX - left.maxX, height: top)
                targets.append(OverlayTarget(screen: screen, rect: rect, kind: .notch))
            } else if settings.island.enabled {
                let i = settings.island
                let rect = CGRect(x: screen.frame.midX - i.width / 2,
                                  y: screen.frame.maxY - i.topOffset - i.height,
                                  width: i.width, height: i.height)
                targets.append(OverlayTarget(screen: screen, rect: rect, kind: .island))
            }
        }
        return targets
    }

    var description: String {
        let size = "\(Int(rect.width))×\(Int(rect.height)) pt"
        switch kind {
        case .notch:  return "\(screen.localizedName): notch \(size)"
        case .island: return "\(screen.localizedName): Dynamic Island \(size)"
        }
    }
}
