//
//  AgenticOSOutline.swift
//  Agentic OS (GTD fork of OpenClicky, 11 Nov 2026)
//
//  The outline around the window the screen agent is working in ("background hands",
//  AgenticOSHands.swift): a click-through panel over the target window's frame drawing a glowing
//  cyan border, a pill at its top-left corner ("Screen agent · Figma", or who is busy), and the
//  pulse marks the agent leaves where it pressed or clicked. The hands feed it frames in global
//  points (main display's top-left at 0,0), which are turned into AppKit's here, so a window on a
//  second display is outlined where it is.
//

import AppKit

@MainActor
final class AgenticOSOutline {
    static let shared = AgenticOSOutline()

    /// The screen agent's colour.
    static let color = NSColor(srgbRed: 0, green: 0.898, blue: 1, alpha: 1)   // #00E5FF
    static let margin: CGFloat = 8
    static let glow: CGFloat = 14
    static let pulseSeconds: TimeInterval = 0.9

    private var panel: OutlinePanel?
    private var view: OutlineView { panelOrMade().outlineView }
    /// The window's frame in global top-left points, as last shown.
    private(set) var windowFrame: CGRect?

    /// Outlines `frame` (global top-left points) with `label` in the pill.
    func show(frame: CGRect, label: String) {
        windowFrame = frame
        let panel = panelOrMade()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let pad = Self.margin + Self.glow
        let appKit = CGRect(x: frame.minX - pad, y: mainHeight - frame.maxY - pad, width: frame.width + 2 * pad, height: frame.height + 2 * pad)
        if panel.frame != appKit { panel.setFrame(appKit, display: true) }
        panel.outlineView.label = label
        panel.outlineView.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func setLabel(_ label: String) {
        guard let panel, panel.isVisible else { return }
        panel.outlineView.label = label
        panel.outlineView.needsDisplay = true
    }

    func hide() {
        windowFrame = nil
        panel?.outlineView.pulses.removeAll()
        panel?.orderOut(nil)
    }

    /// A ring that grows and fades at `point` (global top-left points) for ~0.9 s, with `label` beside it.
    func pulse(at point: CGPoint, label: String?) {
        guard let panel, panel.isVisible else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKit = CGPoint(x: point.x, y: mainHeight - point.y)
        let local = panel.outlineView.convert(appKit, from: nil)
        panel.outlineView.pulses.append(OutlineView.Pulse(center: local, label: label, startedAt: Date()))
        panel.outlineView.startAnimating()
    }

    private func panelOrMade() -> OutlinePanel {
        if let panel { return panel }
        let panel = OutlinePanel()
        self.panel = panel
        return panel
    }
}

/// Borderless, non-activating and click-through, above everything (like OverlayWindow).
private final class OutlinePanel: NSPanel {
    let outlineView = OutlineView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = outlineView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The border, the pill and the pulses, drawn by hand.
private final class OutlineView: NSView {
    struct Pulse {
        let center: CGPoint
        let label: String?
        let startedAt: Date
    }

    var label = ""
    var pulses: [Pulse] = []
    private var animationTimer: Timer?

    override var isFlipped: Bool { false }

    func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.pulses.removeAll { Date().timeIntervalSince($0.startedAt) > AgenticOSOutline.pulseSeconds }
                self.needsDisplay = true
                if self.pulses.isEmpty {
                    timer.invalidate()
                    self.animationTimer = nil
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad = AgenticOSOutline.margin + AgenticOSOutline.glow
        let box = bounds.insetBy(dx: pad - AgenticOSOutline.margin, dy: pad - AgenticOSOutline.margin)
        let border = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        border.lineWidth = 3

        // The soft glow: the same path, wider and fainter, twice.
        for (width, alpha) in [(CGFloat(11), 0.18), (CGFloat(6), 0.32)] {
            AgenticOSOutline.color.withAlphaComponent(alpha).setStroke()
            border.lineWidth = width
            border.stroke()
        }
        AgenticOSOutline.color.setStroke()
        border.lineWidth = 3
        border.stroke()

        // The pill at the top-left corner, just outside the border.
        if !label.isEmpty {
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let pill = NSRect(x: box.minX + 10, y: box.maxY - 9, width: size.width + 16, height: 18)
            AgenticOSOutline.color.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            text.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + (pill.height - size.height) / 2))
        }

        // The pulses: a ring growing from 6 to 22 pt and fading out.
        let now = Date()
        for pulse in pulses {
            let progress = min(1, now.timeIntervalSince(pulse.startedAt) / AgenticOSOutline.pulseSeconds)
            let radius = 6 + 16 * CGFloat(progress)
            let alpha = 1 - progress
            let ring = NSBezierPath(ovalIn: NSRect(x: pulse.center.x - radius, y: pulse.center.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 2.5
            AgenticOSOutline.color.withAlphaComponent(alpha).setStroke()
            ring.stroke()
            AgenticOSOutline.color.withAlphaComponent(alpha * 0.25).setFill()
            ring.fill()
            if let label = pulse.label, !label.isEmpty {
                let text = NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.black.withAlphaComponent(alpha),
                ])
                let size = text.size()
                let tag = NSRect(x: pulse.center.x + 14, y: pulse.center.y - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
                AgenticOSOutline.color.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: tag, xRadius: 6, yRadius: 6).fill()
                text.draw(at: NSPoint(x: tag.minX + 6, y: tag.minY + 2))
            }
        }
    }
}
