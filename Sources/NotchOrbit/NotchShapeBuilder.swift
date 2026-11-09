import AppKit

/// Builds the overlay path. Coordinates are *flipped* (y grows downward,
/// y = 0 is the top edge of the screen), with `notch` being the hardware notch.
enum NotchShapeBuilder {
    static func path(notch: CGRect, params: NotchShapeParams) -> CGPath {
        let x0 = notch.minX - params.extraWidth
        let x1 = notch.maxX + params.extraWidth
        let h  = notch.height + params.extraHeight
        let br = max(0, min(params.bottomRadius, h, (x1 - x0) / 2))
        let er = max(0, params.earRadius)

        let p = CGMutablePath()
        // Top-left "ear": concave curve blending the overlay into the screen edge.
        p.move(to: CGPoint(x: x0 - er, y: 0))
        p.addQuadCurve(to: CGPoint(x: x0, y: er), control: CGPoint(x: x0, y: 0))
        // Left side down + bottom-left corner.
        p.addArc(tangent1End: CGPoint(x: x0, y: h), tangent2End: CGPoint(x: x0 + br, y: h), radius: br)
        // Bottom edge + bottom-right corner.
        p.addArc(tangent1End: CGPoint(x: x1, y: h), tangent2End: CGPoint(x: x1, y: h - br), radius: br)
        // Right side up + top-right ear.
        p.addLine(to: CGPoint(x: x1, y: er))
        p.addQuadCurve(to: CGPoint(x: x1 + er, y: 0), control: CGPoint(x: x1, y: 0))
        p.closeSubpath()
        return p
    }

    /// Overlay path that also swallows the given circle frames (plus padding),
    /// so the circles look like part of the notch. Frames are in the same
    /// flipped coordinate space as `notch`.
    static func path(notch: CGRect, params: NotchShapeParams, embracing circles: [CGRect], padding: CGFloat) -> CGPath {
        guard !circles.isEmpty else { return path(notch: notch, params: params) }
        var island = CGRect(x: notch.minX - params.extraWidth, y: 0,
                            width: notch.width + 2 * params.extraWidth,
                            height: notch.height + params.extraHeight)
        for c in circles {
            island = island.union(c.insetBy(dx: -padding, dy: -padding))
        }
        island.origin.y = 0   // always hang from the top edge
        var p = params
        p.extraWidth = 0
        p.extraHeight = 0
        return path(notch: island, params: p)
    }

    /// Floating Dynamic-Island pill for displays without a notch. If the island
    /// touches the top edge it is drawn like a notch (with ears) instead.
    static func islandPath(rect: CGRect, cornerRadius: CGFloat, shape: NotchShapeParams,
                           embracing circles: [CGRect], padding: CGFloat) -> CGPath {
        var island = rect
        for c in circles {
            island = island.union(c.insetBy(dx: -padding, dy: -padding))
        }
        if rect.minY <= 0 {
            island.origin.y = 0
            var p = shape
            p.extraWidth = 0
            p.extraHeight = 0
            p.bottomRadius = cornerRadius
            return path(notch: island, params: p)
        }
        island.origin.y = min(island.minY, rect.minY)
        let r = max(0, min(cornerRadius, island.height / 2, island.width / 2))
        return CGPath(roundedRect: island, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Approximation of the hardware notch (used for the preview in Settings).
    static func hardwarePath(notch: CGRect) -> CGPath {
        path(notch: notch, params: NotchShapeParams(extraWidth: 0, extraHeight: 0, bottomRadius: 10, earRadius: 0))
    }
}
