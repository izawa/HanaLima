import AppKit

/// The menu bar icon: the app icon's plumeria as a one-colour template image, so macOS tints it
/// for light/dark menu bars and the selected state. The petal curve matches scripts/make-icon.py.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Petal tips reach about 404 units from the centre; fit them (and the gaps) into 18 pt.
            let scale = rect.width / 2 / 420
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: scale, y: scale)

            for i in 0..<5 {
                let angle = CGFloat(i * 72 - 12) * .pi / 180
                let petal = petalPath().copy(using: [CGAffineTransform(rotationAngle: angle)])!
                // Cut a thin gap along the petal's edge first, so overlapping petals stay distinct.
                ctx.setBlendMode(.clear)
                ctx.addPath(petal)
                ctx.setLineWidth(46)
                ctx.setLineJoin(.round)
                ctx.strokePath()
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.addPath(petal)
                ctx.fillPath()
            }
            // The core: a ring cut out of the petals, with the hub inside.
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: -96, y: -96, width: 192, height: 192))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: CGRect(x: -58, y: -58, width: 116, height: 116))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "HanaLima"
        return image
    }()

    /// One petal pointing up, relative to the flower's centre (y grows downwards).
    private static func petalPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 22, y: -46))
        p.addCurve(to: CGPoint(x: -106, y: -286), control1: CGPoint(x: -50, y: -96), control2: CGPoint(x: -126, y: -200))
        p.addCurve(to: CGPoint(x: 46, y: -404), control1: CGPoint(x: -92, y: -344), control2: CGPoint(x: -14, y: -376))
        p.addCurve(to: CGPoint(x: 162, y: -226), control1: CGPoint(x: 104, y: -384), control2: CGPoint(x: 176, y: -306))
        p.addCurve(to: CGPoint(x: 22, y: -46), control1: CGPoint(x: 148, y: -150), control2: CGPoint(x: 104, y: -92))
        p.closeSubpath()
        return p
    }
}
