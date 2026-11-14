import AppKit
import QuartzCore

/// What the HUD shows.
public enum HUDState: Equatable, Sendable {
    case scanning(String)
    case enroll(step: Int, of: Int, String)
    case success(String)
    case failure(String)

    public var text: String {
        switch self {
        case .scanning(let t), .success(let t), .failure(let t): return t
        case .enroll(_, _, let t): return t
        }
    }
}

/// Is there a GUI (Aqua) session we can draw into?
public enum GUISession {
    public static var isAvailable: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? false
    }
}

/// Geometry of the HUD for a screen: anchored to the notch when there is one,
/// otherwise a pill at the top centre (SPEC Q3, Q4).
public struct HUDGeometry: Equatable {
    public static let expandedSize = CGSize(width: 360, height: 120)
    public static let cornerRadius: CGFloat = 24

    public var collapsed: CGRect
    public var expanded: CGRect
    public var hasNotch: Bool
    /// Height of the top strip the notch covers (content goes below it).
    public var topInset: CGFloat

    public static func forScreen(_ screen: NSScreen) -> HUDGeometry {
        let f = screen.frame
        let size = expandedSize
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let notchW = f.width - l.width - r.width
            let notchH = screen.safeAreaInsets.top
            let collapsed = CGRect(x: f.midX - notchW / 2, y: f.maxY - notchH, width: notchW, height: notchH)
            let expanded = CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                                  width: size.width, height: size.height)
            return HUDGeometry(collapsed: collapsed, expanded: expanded, hasNotch: true, topInset: notchH)
        }
        // No notch: a pill just below the menu bar.
        let top = screen.visibleFrame.maxY - 8
        let expanded = CGRect(x: f.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let collapsed = CGRect(x: f.midX - 40, y: top - 24, width: 80, height: 24)
        return HUDGeometry(collapsed: collapsed, expanded: expanded, hasNotch: false, topInset: 0)
    }
}

/// The face-scan glyph: our own drawing (SPEC Q2a) — rounded corner
/// brackets, two round eyes, a short nose and a smile. Drawn in a 100×100 box.
enum Glyph {
    static func face(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let s = r.width / 100
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        // Corner brackets (y up). Each: two straight legs joined by a quarter arc.
        let leg: CGFloat = 22, rad: CGFloat = 14, m: CGFloat = 6
        for (cx, cy, dx, dy) in [(m, m, 1.0, 1.0), (100 - m, m, -1.0, 1.0), (m, 100 - m, 1.0, -1.0), (100 - m, 100 - m, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            p.move(to: pt(cx + dx * (rad + leg), cy))
            p.addLine(to: pt(cx + dx * rad, cy))
            p.addQuadCurve(to: pt(cx, cy + dy * rad), control: pt(cx, cy))
            p.addLine(to: pt(cx, cy + dy * (rad + leg)))
        }
        // Eyes: small circles.
        p.addEllipse(in: CGRect(origin: pt(33, 58), size: CGSize(width: 7 * s, height: 7 * s)))
        p.addEllipse(in: CGRect(origin: pt(60, 58), size: CGSize(width: 7 * s, height: 7 * s)))
        // Nose: a short straight line.
        p.move(to: pt(50, 58))
        p.addLine(to: pt(50, 45))
        // Smile: a shallow arc.
        p.move(to: pt(34, 34))
        p.addQuadCurve(to: pt(66, 34), control: pt(50, 22))
        return p
    }

    static func check(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let s = r.width / 100
        p.move(to: CGPoint(x: r.minX + 24 * s, y: r.minY + 50 * s))
        p.addLine(to: CGPoint(x: r.minX + 42 * s, y: r.minY + 32 * s))
        p.addLine(to: CGPoint(x: r.minX + 76 * s, y: r.minY + 68 * s))
        return p
    }

    static func cross(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let s = r.width / 100
        p.move(to: CGPoint(x: r.minX + 30 * s, y: r.minY + 30 * s))
        p.addLine(to: CGPoint(x: r.minX + 70 * s, y: r.minY + 70 * s))
        p.move(to: CGPoint(x: r.minX + 70 * s, y: r.minY + 30 * s))
        p.addLine(to: CGPoint(x: r.minX + 30 * s, y: r.minY + 70 * s))
        return p
    }
}

/// The layer tree for the HUD contents. Separate from the window so it can be
/// rendered offscreen for snapshots (R15).
public final class HUDContentLayer: CALayer {
    let background = CAShapeLayer()
    let glyph = CAShapeLayer()
    let mark = CAShapeLayer()
    let label = CATextLayer()
    let dots = CALayer()
    var topInset: CGFloat = 0
    var hasNotch = true
    public var reduceMotion = false

    static let white = CGColor(gray: 1, alpha: 1)
    static let green = CGColor(srgbRed: 0.20, green: 0.84, blue: 0.29, alpha: 1)
    static let red = CGColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)

    public override init() {
        super.init()
        for l in [background, glyph, mark, label, dots] as [CALayer] { addSublayer(l) }
        background.fillColor = CGColor(gray: 0, alpha: 1)
        for s in [glyph, mark] {
            s.fillColor = nil
            s.strokeColor = Self.white
            s.lineWidth = 3.5
            s.lineCap = .round
            s.lineJoin = .round
        }
        label.foregroundColor = Self.white
        label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        label.fontSize = 15
        label.isWrapped = true
        label.alignmentMode = .left
        label.contentsScale = 2
    }

    public override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    public func layout(size: CGSize, topInset: CGFloat, hasNotch: Bool) {
        self.topInset = topInset
        self.hasNotch = hasNotch
        frame = CGRect(origin: .zero, size: size)
        background.frame = bounds
        let r = HUDGeometry.cornerRadius
        // Notch style: square top corners flush with the screen edge, round bottom corners.
        background.path = hasNotch
            ? Self.notchPath(bounds, radius: r)
            : CGPath(roundedRect: bounds, cornerWidth: size.height / 2.5, cornerHeight: size.height / 2.5, transform: nil)
        let content = CGRect(x: 0, y: 0, width: size.width, height: size.height - topInset)
        let g = min(56, content.height - 24)
        let glyphRect = CGRect(x: 26, y: content.midY - g / 2, width: g, height: g)
        glyph.frame = bounds
        mark.frame = bounds
        glyph.path = Glyph.face(in: glyphRect)
        label.frame = CGRect(x: glyphRect.maxX + 20, y: content.midY - 22, width: size.width - glyphRect.maxX - 40, height: 44)
        dots.frame = CGRect(x: glyphRect.maxX + 20, y: content.minY + 12, width: 120, height: 8)
    }

    static func notchPath(_ b: CGRect, radius r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.minX, y: b.maxY))
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
        p.addLine(to: CGPoint(x: b.maxX, y: b.minY + r))
        p.addQuadCurve(to: CGPoint(x: b.maxX - r, y: b.minY), control: CGPoint(x: b.maxX, y: b.minY))
        p.addLine(to: CGPoint(x: b.minX + r, y: b.minY))
        p.addQuadCurve(to: CGPoint(x: b.minX, y: b.minY + r), control: CGPoint(x: b.minX, y: b.minY))
        p.closeSubpath()
        return p
    }

    /// Applies a state. `animated` controls pulse and shake (off for snapshots
    /// and when Reduce Motion is on).
    public func apply(_ state: HUDState, animated: Bool) {
        let motion = animated && !reduceMotion
        label.string = state.text
        // Centre the text block vertically on the glyph.
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let textWidth = bounds.width - 26 - min(56, bounds.height - topInset - 24) - 40
        let textHeight = ceil((state.text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: 200), options: [.usesLineFragmentOrigin],
            attributes: [.font: font]).height)
        label.frame = CGRect(x: label.frame.minX, y: (bounds.height - topInset) / 2 - textHeight / 2,
                             width: textWidth, height: textHeight + 2)
        glyph.removeAllAnimations()
        removeAnimation(forKey: "shake")
        let glyphRect = CGRect(x: 26, y: (bounds.height - topInset) / 2 - min(56, bounds.height - topInset - 24) / 2,
                               width: min(56, bounds.height - topInset - 24), height: min(56, bounds.height - topInset - 24))
        dots.sublayers?.forEach { $0.removeFromSuperlayer() }
        switch state {
        case .scanning, .enroll:
            glyph.strokeColor = Self.white
            glyph.opacity = 1
            mark.path = nil
            if motion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.45
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                glyph.add(pulse, forKey: "pulse")
            }
            if case .enroll(let step, let total, _) = state {
                for i in 0..<total {
                    let d = CALayer()
                    d.frame = CGRect(x: CGFloat(i) * 16, y: 0, width: 8, height: 8)
                    d.cornerRadius = 4
                    d.backgroundColor = i < step ? Self.green : CGColor(gray: 1, alpha: 0.3)
                    dots.addSublayer(d)
                }
            }
        case .success:
            glyph.opacity = 0
            mark.strokeColor = Self.green
            mark.path = Glyph.check(in: glyphRect)
        case .failure:
            glyph.opacity = 0
            mark.strokeColor = Self.red
            mark.path = Glyph.cross(in: glyphRect)
            if motion {
                let shake = CAKeyframeAnimation(keyPath: "position.x")
                shake.values = [0, -10, 10, -8, 8, -4, 4, 0].map { position.x + $0 }
                shake.duration = 0.45
                add(shake, forKey: "shake")
            }
        }
    }

    /// Whether any motion animation is attached (used by the R18 check).
    public var hasMotionAnimations: Bool {
        glyph.animation(forKey: "pulse") != nil || animation(forKey: "shake") != nil
    }

    /// Renders the HUD to PNG data (offscreen; no window server needed).
    public func pngData(scale: CGFloat = 2) -> Data? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        render(in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

/// Hosts the content layer pinned to the top centre, so a smaller window
/// (collapsed into the notch) shows only the black top strip.
final class HUDHostView: NSView {
    var content: HUDContentLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let content else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame.origin = CGPoint(x: (newSize.width - content.bounds.width) / 2,
                                       y: newSize.height - content.bounds.height)
        CATransaction.commit()
    }
}

/// A panel whose animated resizes take 0.3 s, may sit over the menu bar,
/// and never becomes key (so it cannot take keyboard focus).
final class HUDPanel: NSPanel {
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.3 }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The on-screen notch HUD. All methods must be called on the main thread.
@MainActor
public final class NotchHUD {
    private let panel: NSPanel
    private let content = HUDContentLayer()
    private let geometry: HUDGeometry
    public private(set) var isShown = false
    /// When the panel first went on screen (for the R14 timing check).
    public private(set) var onScreenAt: Date?

    /// Returns nil when there is no GUI session (SSH, headless) — the caller
    /// then uses text output only (R16).
    public static func make() -> NotchHUD? {
        guard GUISession.isAvailable, let screen = NSScreen.screens.first else { return nil }
        return NotchHUD(screen: screen)
    }

    init(screen: NSScreen) {
        geometry = HUDGeometry.forScreen(screen)
        panel = HUDPanel(contentRect: geometry.collapsed,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver // above full-screen apps and the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let view = HUDHostView(frame: CGRect(origin: .zero, size: geometry.expanded.size))
        view.content = content
        content.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content.contentsScale = screen.backingScaleFactor
        content.layout(size: geometry.expanded.size, topInset: geometry.topInset, hasNotch: geometry.hasNotch)
        view.layer?.addSublayer(content)
        panel.contentView = view
    }

    /// Shows the HUD, growing out of the notch.
    public func show(_ state: HUDState) {
        content.apply(state, animated: true)
        guard !isShown else { return }
        isShown = true
        panel.setFrame(geometry.collapsed, display: false)
        panel.orderFrontRegardless() // shown without activating the app or taking focus
        onScreenAt = Date()
        // Window resize animation (0.3 s, see HUDPanel). With Reduce Motion the
        // panel appears at full size without growing.
        panel.setFrame(geometry.expanded, display: true, animate: !content.reduceMotion)
    }

    public func update(_ state: HUDState) {
        content.apply(state, animated: true)
    }

    /// Shows the result for `hold` seconds, collapses in 0.3 s, then calls `done` (R17).
    public func finish(_ state: HUDState, hold: Double = 0.6, done: @escaping @MainActor () -> Void) {
        guard isShown else { done(); return }
        content.apply(state, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            MainActor.assumeIsolated {
                // Collapse back into the notch (0.3 s), then hide.
                self.panel.setFrame(self.geometry.collapsed, display: true, animate: !self.content.reduceMotion)
                self.panel.orderOut(nil)
                self.isShown = false
                done()
            }
        }
    }

    public var frame: CGRect { panel.frame }
    public var geometryInfo: HUDGeometry { geometry }
}
