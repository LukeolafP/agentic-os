//
//  ScreenDrawing.swift
//  Agentic OS (GTD fork of OpenClicky, 10 Nov 2026)
//
//  Drawing on the screen while talking to the Voice Agent. During a ⌃⌥ turn the island shows three
//  buttons (NotchTalkTools): the pencil puts a clear panel over the screen with the pointer, where
//  Luke draws in red with the mouse; clear snapshots the drawing and wipes it so he can draw again;
//  the region button lets him drag out a rectangle to screenshot. Each picture waits in
//  `CompanionManager.pendingUserImages` and goes with the question, after the pointer close-up.
//
//  A snapshot is a fresh capture of that display (the app's own windows left out, as for every
//  question) with the strokes drawn onto it here. One is also taken by itself three seconds after
//  the last stroke (once per drawing), and when the turn is sent; then the panel goes away.
//

import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class ScreenDrawing: ObservableObject {
    static let shared = ScreenDrawing()

    /// One stroke, in the panel's points (top-left origin).
    struct Stroke {
        var points: [CGPoint]
    }

    @Published private(set) var strokes: [Stroke] = []
    @Published private(set) var isPanelShown = false
    @Published private(set) var isSelectingRegion = false

    weak var companion: CompanionManager?
    private var panel: NSPanel?
    /// The display the panel covers (AppKit coordinates).
    private var displayFrame: CGRect = .zero
    /// Bumped on every finished stroke; a snapshot remembers the one it took.
    private var drawingRevision = 0
    private var capturedRevision = 0
    private var autoCaptureTask: Task<Void, Never>?
    /// Snapshots still being taken: the question waits for them (`waitForSnapshots`).
    private var snapshotTasks: [Task<Void, Never>] = []

    static let strokeColor = NSColor.systemRed
    static let strokeWidth: CGFloat = 4
    static let autoCaptureSeconds: TimeInterval = 3

    // MARK: the island's buttons

    func togglePencil() {
        if isPanelShown {
            snapshotIfNew(reason: "pencil off")
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// Clear: the drawing goes to the attachments (unless it already went), then the strokes go.
    func clearDrawing() {
        snapshotIfNew(reason: "clear")
        autoCaptureTask?.cancel()
        strokes.removeAll()
    }

    /// Lets Luke drag a rectangle (screencapture's own crosshair); the picture, with any strokes in
    /// it (the panel is on screen), goes to the attachments.
    func captureRegion() {
        guard !isSelectingRegion else { return }
        isSelectingRegion = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentic-os-region-\(UUID().uuidString).jpg")
        Task {
            let status: Int32 = await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-s", "-x", "-t", "jpg", file.path]
                do { try process.run() } catch { return -1 }
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            isSelectingRegion = false
            defer { try? FileManager.default.removeItem(at: file) }
            // Esc in the crosshair writes no file.
            guard status == 0, let data = try? Data(contentsOf: file), !data.isEmpty else {
                AppLog.append("draw: region screenshot cancelled (status \(status))")
                return
            }
            companion?.addPendingUserImage(data: Self.jpegFittingLimit(data) ?? data, label: "Luke's screenshot of a region")
            AppLog.append("draw: region screenshot attached (\(data.count / 1024) KB)")
        }
    }

    // MARK: the talk turn

    /// The ⌃⌥ turn ended: when it was sent, a drawing not yet attached goes with it; either way the
    /// panel goes and the strokes are wiped.
    func talkTurnEnded(sent: Bool) {
        if sent { snapshotIfNew(reason: "turn sent") }
        hidePanel()
    }

    /// The question waits for snapshots still being taken, so a drawing made just before letting
    /// go is in it.
    func waitForSnapshots() async {
        let pending = snapshotTasks
        for task in pending { await task.value }
    }

    // MARK: the panel

    private func showPanel() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        displayFrame = screen.frame
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        isPanelShown = true
        AppLog.append("draw: pencil on")
    }

    private func hidePanel() {
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        panel?.orderOut(nil)
        if isPanelShown { AppLog.append("draw: pencil off") }
        isPanelShown = false
        strokes.removeAll()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        backgroundColorForDrawing(panel)
        panel.hasShadow = false
        // Over ordinary windows, under the island (pop-up menu level) and the pointer's overlay.
        panel.level = .statusBar
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScreenDrawingView(drawing: self))
        return panel
    }

    /// Almost clear, not clear: a window with a fully transparent background lets clicks through.
    private func backgroundColorForDrawing(_ panel: NSPanel) {
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
    }

    // MARK: strokes (from the view)

    fileprivate func begin(at point: CGPoint) {
        autoCaptureTask?.cancel()
        strokes.append(Stroke(points: [point]))
    }

    fileprivate func extend(to point: CGPoint) {
        guard !strokes.isEmpty else { return begin(at: point) }
        strokes[strokes.count - 1].points.append(point)
    }

    fileprivate func end() {
        drawingRevision += 1
        // Three seconds without a new stroke: the drawing is attached by itself, once.
        autoCaptureTask?.cancel()
        let revision = drawingRevision
        autoCaptureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoCaptureSeconds))
            guard !Task.isCancelled, let self, self.drawingRevision == revision else { return }
            self.snapshotIfNew(reason: "3 s after the last stroke")
        }
    }

    // MARK: snapshots

    private func snapshotIfNew(reason: String) {
        guard !strokes.isEmpty, capturedRevision != drawingRevision else { return }
        capturedRevision = drawingRevision
        let strokesNow = strokes
        let frame = displayFrame
        let screenNumber = (NSScreen.screens.firstIndex { $0.frame == frame } ?? 0) + 1
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Self.snapshot(displayFrame: frame, strokes: strokesNow)
                self.companion?.addPendingUserImage(data: data, label: "Luke's drawing on screen \(screenNumber)")
                AppLog.append("draw: drawing attached (\(reason), \(strokesNow.count) strokes)")
            } catch {
                AppLog.append("draw: snapshot failed (\(reason)): \(error.localizedDescription)")
            }
        }
        snapshotTasks.append(task)
        Task { [weak self] in
            await task.value
            self?.snapshotTasks.removeAll { $0 == task }
        }
    }

    /// The display without this app's windows, at most 1600 px wide, with the strokes drawn on.
    private static func snapshot(displayFrame: CGRect, strokes: [Stroke]) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = NSScreen.screens.first { $0.frame == displayFrame }?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "ScreenDrawing", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display to capture"])
        }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let configuration = SCStreamConfiguration()
        let backingScale = NSScreen.screens.first { $0.frame == displayFrame }?.backingScaleFactor ?? 1
        configuration.width = Int(min(displayFrame.width * backingScale, 1600))
        configuration.height = Int(displayFrame.height * CGFloat(configuration.width) / max(displayFrame.width, 1))
        let screenImage = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: ownWindows), configuration: configuration)

        let width = screenImage.width, height = screenImage.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "ScreenDrawing", code: 2, userInfo: [NSLocalizedDescriptionKey: "no drawing context"])
        }
        context.draw(screenImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Panel points (top-left origin) to image pixels (bottom-left origin).
        let pixelsPerPoint = CGFloat(width) / max(displayFrame.width, 1)
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(strokeWidth * pixelsPerPoint)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            func pixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * pixelsPerPoint, y: CGFloat(height) - point.y * pixelsPerPoint) }
            context.beginPath()
            context.move(to: pixel(first))
            if stroke.points.count == 1 { context.addLine(to: pixel(first)) }
            for point in stroke.points.dropFirst() { context.addLine(to: pixel(point)) }
            context.strokePath()
        }
        guard let composited = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: composited).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "ScreenDrawing", code: 3, userInfo: [NSLocalizedDescriptionKey: "couldn't encode the snapshot"])
        }
        return jpeg
    }

    /// A region screenshot at most 1600 px wide, as JPEG.
    private static func jpegFittingLimit(_ data: Data) -> Data? {
        guard let image = NSBitmapImageRep(data: data), let cgImage = image.cgImage else { return nil }
        guard cgImage.width > 1600 else { return data }
        let width = 1600, height = Int(CGFloat(cgImage.height) * 1600 / CGFloat(cgImage.width))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// The panel's content: the strokes, and a drag that draws.
private struct ScreenDrawingView: View {
    @ObservedObject var drawing: ScreenDrawing
    @State private var isStroking = false

    var body: some View {
        Canvas { context, _ in
            for stroke in drawing.strokes {
                guard let first = stroke.points.first else { continue }
                var path = Path()
                path.move(to: first)
                if stroke.points.count == 1 { path.addLine(to: first) }
                for point in stroke.points.dropFirst() { path.addLine(to: point) }
                context.stroke(path, with: .color(Color(nsColor: ScreenDrawing.strokeColor)),
                               style: StrokeStyle(lineWidth: ScreenDrawing.strokeWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if isStroking {
                        drawing.extend(to: value.location)
                    } else {
                        isStroking = true
                        drawing.begin(at: value.location)
                    }
                }
                .onEnded { _ in
                    isStroking = false
                    drawing.end()
                }
        )
        .onHover { inside in if inside { NSCursor.crosshair.set() } }
    }
}
