//
//  AnnotationLayerView.swift
//  leanring-buddy
//
//  Draws Claude's annotation shapes for ONE screen. The lead mounts one
//  AnnotationLayerView per overlay window (under the blue cursor, above the dim):
//      AnnotationLayerView(state: annotationLayerState)
//  and connects the blue-cursor flight to `state.primaryShapeCursorTargetInAppKitGlobalPoints`.
//

import SwiftUI
import AppKit

@MainActor
final class AnnotationLayerState: ObservableObject {
    /// `NSScreen.frame` of the screen this layer covers (AppKit global points).
    let screenFrameInAppKitGlobalPoints: CGRect

    @Published private(set) var mappedShapes: [MappedAnnotationShape] = []
    @Published private(set) var layerOpacity: Double = 1
    /// When the current shapes started drawing on; the view derives animation progress from it.
    @Published private(set) var presentationStartDate: Date = .distantPast
    /// False once the draw-on animation is over so the view's timeline can pause.
    @Published private(set) var isDrawOnAnimationRunning = false

    static let drawOnDurationInSeconds: Double = 0.25
    static let fadeOutDurationInSeconds: Double = 0.4
    static let fadeOutDelayAfterSpeechEndsInSeconds: Double = 2.0

    private var presentationGeneration = 0
    private var pendingFadeOutTask: Task<Void, Never>?
    private var drawOnFinishTask: Task<Void, Never>?

    init(screenFrameInAppKitGlobalPoints: CGRect) {
        self.screenFrameInAppKitGlobalPoints = screenFrameInAppKitGlobalPoints
    }

    var hasShapes: Bool { !mappedShapes.isEmpty }

    var primaryShape: MappedAnnotationShape? { mappedShapes.first(where: { $0.isPrimary }) }

    /// Where the blue cursor should fly (AppKit global points), or nil when no shape is primary.
    var primaryShapeCursorTargetInAppKitGlobalPoints: CGPoint? { primaryShape?.geometry.cursorTargetPoint }

    /// Primary shape bounds (AppKit global points) for `ClickTargetWatcher`.
    var primaryShapeRectInAppKitGlobalPoints: CGRect? { primaryShape?.geometry.boundingRect }

    /// Maps and shows shapes for this screen. Shapes flagged `snap` are tightened
    /// onto the Accessibility element under them first; the lookups run off the
    /// main thread and the shapes are published once, after they resolve.
    func present(shapes annotationShapes: [AnnotationShape], imageWidthInPixels: Int, imageHeightInPixels: Int) {
        guard imageWidthInPixels > 0, imageHeightInPixels > 0 else { return }
        clear()
        presentationGeneration += 1
        let generationAtStart = presentationGeneration

        let coordinateMapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: screenFrameInAppKitGlobalPoints,
            imageWidthInPixels: Double(imageWidthInPixels),
            imageHeightInPixels: Double(imageHeightInPixels)
        )
        let rawMappedShapes = coordinateMapper.mappedShapes(from: annotationShapes)
        guard !rawMappedShapes.isEmpty else { return }

        let needsSnapping = rawMappedShapes.contains { $0.shouldSnapToAccessibilityElement && $0.geometry.accessibilityLookupPoint != nil }
        guard needsSnapping else {
            publish(rawMappedShapes)
            return
        }

        let primaryScreenHeightInPoints = NSScreen.screens.first?.frame.height ?? screenFrameInAppKitGlobalPoints.height
        Task { [weak self] in
            let snappedShapes = await Self.snapShapesOffMainThread(rawMappedShapes, primaryScreenHeightInPoints: primaryScreenHeightInPoints)
            guard let self, self.presentationGeneration == generationAtStart else { return }
            self.publish(snappedShapes)
        }
    }

    /// Removes everything immediately (Esc, or a new summon).
    func clear() {
        presentationGeneration += 1
        pendingFadeOutTask?.cancel()
        drawOnFinishTask?.cancel()
        pendingFadeOutTask = nil
        drawOnFinishTask = nil
        isDrawOnAnimationRunning = false
        layerOpacity = 1
        mappedShapes = []
    }

    /// Call when spoken audio finishes: shapes linger 2 s, then fade over 400 ms and are removed.
    func speechDidEnd() {
        guard hasShapes else { return }
        pendingFadeOutTask?.cancel()
        let generationAtStart = presentationGeneration
        pendingFadeOutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeOutDelayAfterSpeechEndsInSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.presentationGeneration == generationAtStart else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.clear()
                return
            }
            withAnimation(.easeOut(duration: Self.fadeOutDurationInSeconds)) { self.layerOpacity = 0 }
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeOutDurationInSeconds * 1_000_000_000))
            guard !Task.isCancelled, self.presentationGeneration == generationAtStart else { return }
            self.clear()
        }
    }

    private func publish(_ shapesToShow: [MappedAnnotationShape]) {
        layerOpacity = 1
        presentationStartDate = Date()
        mappedShapes = shapesToShow
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isDrawOnAnimationRunning = false
            return
        }
        isDrawOnAnimationRunning = true
        drawOnFinishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.drawOnDurationInSeconds + 0.05) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isDrawOnAnimationRunning = false
        }
    }

    nonisolated private static func snapShapesOffMainThread(
        _ shapesToSnap: [MappedAnnotationShape],
        primaryScreenHeightInPoints: CGFloat
    ) async -> [MappedAnnotationShape] {
        await withTaskGroup(of: (Int, CGRect?).self) { taskGroup in
            for (arrayIndex, shape) in shapesToSnap.enumerated() {
                guard shape.shouldSnapToAccessibilityElement, let lookupPoint = shape.geometry.accessibilityLookupPoint else { continue }
                taskGroup.addTask {
                    let snappedFrame = await AccessibilityElementSnapper.snappedFrame(
                        atAppKitGlobalPoint: lookupPoint,
                        primaryScreenHeightInPoints: primaryScreenHeightInPoints
                    )
                    return (arrayIndex, snappedFrame?.frameInAppKitGlobalPoints)
                }
            }
            var resultingShapes = shapesToSnap
            for await (arrayIndex, snappedFrame) in taskGroup {
                if let snappedFrame {
                    resultingShapes[arrayIndex].geometry = resultingShapes[arrayIndex].geometry.snapped(toElementFrame: snappedFrame)
                }
            }
            return resultingShapes
        }
    }
}

struct AnnotationLayerView: View {
    @ObservedObject var state: AnnotationLayerState

    var body: some View {
        TimelineView(.animation(paused: !state.isDrawOnAnimationRunning)) { timelineContext in
            let elapsedSeconds = timelineContext.date.timeIntervalSince(state.presentationStartDate)
            let drawOnProgress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 1.0
                : min(1.0, max(0.0, elapsedSeconds / AnnotationLayerState.drawOnDurationInSeconds))

            Canvas { graphicsContext, canvasSize in
                let canvasBounds = CGRect(origin: .zero, size: canvasSize)
                for shape in state.mappedShapes {
                    Self.draw(
                        shape,
                        in: &graphicsContext,
                        screenFrame: state.screenFrameInAppKitGlobalPoints,
                        canvasBounds: canvasBounds,
                        drawOnProgress: drawOnProgress
                    )
                }
            }
        }
        .opacity(state.layerOpacity)
        .allowsHitTesting(false)
    }

    // MARK: Drawing

    private static let primaryStrokeColor = DS.Colors.overlayCursorBlue
    private static let secondaryStrokeColor = DS.Colors.info
    private static let highlightFillColor = DS.Colors.warning.opacity(0.30)

    private static func draw(
        _ shape: MappedAnnotationShape,
        in graphicsContext: inout GraphicsContext,
        screenFrame: CGRect,
        canvasBounds: CGRect,
        drawOnProgress: Double
    ) {
        let strokeColor = shape.isPrimary ? primaryStrokeColor : secondaryStrokeColor
        let strokeStyle = StrokeStyle(lineWidth: shape.isPrimary ? 4 : 3, lineCap: .round, lineJoin: .round)
        let progress = CGFloat(drawOnProgress)

        func localPoint(_ globalPoint: CGPoint) -> CGPoint {
            AnnotationCoordinateMapper.screenLocalPoint(fromAppKitGlobalPoint: globalPoint, screenFrame: screenFrame)
        }
        func strokeTrimmed(_ outline: Path) {
            graphicsContext.stroke(outline.trimmedPath(from: 0, to: progress), with: .color(strokeColor), style: strokeStyle)
        }

        var rectForLabelPlacement: CGRect

        switch shape.geometry {
        case .circle(let center, let radius):
            let localCenter = localPoint(center)
            // A slightly wobbly closed loop instead of a perfect ellipse reads as hand-drawn.
            let loopSegmentCount = 36
            let loopPoints = (0...loopSegmentCount).map { segmentIndex -> CGPoint in
                let angle = Double(segmentIndex) / Double(loopSegmentCount) * 2 * .pi
                return CGPoint(x: localCenter.x + radius * CGFloat(cos(angle)), y: localCenter.y + radius * CGFloat(sin(angle)))
            }
            strokeTrimmed(smoothPath(through: AnnotationCoordinateMapper.jitteredPoints(loopPoints, seed: shape.id), closed: false))
            rectForLabelPlacement = CGRect(x: localCenter.x - radius, y: localCenter.y - radius, width: radius * 2, height: radius * 2)

        case .box(let rect):
            let localRect = AnnotationCoordinateMapper.screenLocalRect(fromAppKitGlobalRect: rect, screenFrame: screenFrame)
            let corners = [
                CGPoint(x: localRect.minX, y: localRect.minY), CGPoint(x: localRect.maxX, y: localRect.minY),
                CGPoint(x: localRect.maxX, y: localRect.maxY), CGPoint(x: localRect.minX, y: localRect.maxY),
                CGPoint(x: localRect.minX, y: localRect.minY)
            ]
            var outline = Path()
            outline.addLines(AnnotationCoordinateMapper.jitteredPoints(corners, seed: shape.id, amplitude: 1.2))
            strokeTrimmed(outline)
            rectForLabelPlacement = localRect

        case .highlight(let rect):
            let localRect = AnnotationCoordinateMapper.screenLocalRect(fromAppKitGlobalRect: rect, screenFrame: screenFrame)
            graphicsContext.opacity = drawOnProgress
            graphicsContext.fill(Path(roundedRect: localRect, cornerRadius: 3), with: .color(highlightFillColor))
            graphicsContext.opacity = 1
            rectForLabelPlacement = localRect

        case .arrow(let tip, let tail):
            let localTip = localPoint(tip)
            let localTail = localPoint(tail)
            var shaft = Path()
            shaft.move(to: localTail)
            shaft.addLine(to: localTip)
            strokeTrimmed(shaft)
            if drawOnProgress >= 0.85 {
                // Arrow head: two short strokes angled back from the tip.
                let shaftAngle = atan2(localTip.y - localTail.y, localTip.x - localTail.x)
                let headLength: CGFloat = 16
                var head = Path()
                for sideAngle in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
                    head.move(to: localTip)
                    head.addLine(to: CGPoint(x: localTip.x + headLength * cos(shaftAngle + sideAngle),
                                             y: localTip.y + headLength * sin(shaftAngle + sideAngle)))
                }
                graphicsContext.stroke(head, with: .color(strokeColor), style: strokeStyle)
            }
            // The caption sits at the tail so it never covers what the arrow points at.
            rectForLabelPlacement = CGRect(origin: localTail, size: .zero)

        case .path(let points):
            var outline = Path()
            outline.addLines(AnnotationCoordinateMapper.jitteredPoints(points.map(localPoint), seed: shape.id, amplitude: 1.0))
            strokeTrimmed(outline)
            rectForLabelPlacement = outline.boundingRect

        case .label(let anchor):
            let localAnchor = localPoint(anchor)
            rectForLabelPlacement = CGRect(origin: localAnchor, size: .zero)
        }

        if let displayedText = shape.displayedText, drawOnProgress > 0.4 {
            let isFreeStandingLabel: Bool
            if case .label = shape.geometry { isFreeStandingLabel = true } else { isFreeStandingLabel = false }
            drawLabelPill(
                text: displayedText,
                nearRect: rectForLabelPlacement,
                centeredOnRect: isFreeStandingLabel,
                accentColor: strokeColor,
                in: &graphicsContext,
                canvasBounds: canvasBounds
            )
        }
    }

    /// Catmull-Rom-ish smoothing is overkill here; jittered points are dense enough that straight segments look hand-drawn.
    private static func smoothPath(through points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        path.addLines(points)
        if closed { path.closeSubpath() }
        return path
    }

    private static func drawLabelPill(
        text: String,
        nearRect: CGRect,
        centeredOnRect: Bool,
        accentColor: Color,
        in graphicsContext: inout GraphicsContext,
        canvasBounds: CGRect
    ) {
        let resolvedText = graphicsContext.resolve(
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
        )
        let textSize = resolvedText.measure(in: CGSize(width: 260, height: 80))
        let pillSize = CGSize(width: textSize.width + 20, height: textSize.height + 10)

        let pillFrame: CGRect
        if centeredOnRect {
            let centeredFrame = CGRect(x: nearRect.midX - pillSize.width / 2, y: nearRect.midY - pillSize.height / 2,
                                       width: pillSize.width, height: pillSize.height)
            pillFrame = AnnotationCoordinateMapper.clamped(centeredFrame, within: canvasBounds, margin: 8)
        } else {
            pillFrame = AnnotationCoordinateMapper.labelFrame(besideShapeRect: nearRect, labelSize: pillSize, screenBounds: canvasBounds)
        }

        let pillPath = Path(roundedRect: pillFrame, cornerRadius: pillFrame.height / 2)
        graphicsContext.fill(pillPath, with: .color(DS.Colors.background.opacity(0.88)))
        graphicsContext.stroke(pillPath, with: .color(accentColor), lineWidth: 1.5)
        graphicsContext.draw(resolvedText, at: CGPoint(x: pillFrame.midX, y: pillFrame.midY), anchor: .center)
    }
}
