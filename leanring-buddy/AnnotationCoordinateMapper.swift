//
//  AnnotationCoordinateMapper.swift
//  leanring-buddy
//
//  Pure coordinate math for annotations (CONTRACTS section 8), kept free of
//  AppKit/SwiftUI so it can be unit-tested without the app.
//
//  Spaces involved:
//   - image pixels: top-left origin, the screenshot Claude saw
//   - AppKit global points: bottom-left origin, same space as NSEvent.mouseLocation
//   - screen-local view points: top-left origin inside one per-screen overlay view
//   - Accessibility global points: top-left origin of the PRIMARY screen
//

import Foundation
import CoreGraphics

/// Shape geometry in AppKit global points.
enum MappedAnnotationGeometry: Equatable {
    case circle(center: CGPoint, radius: CGFloat)
    case box(rect: CGRect)
    case highlight(rect: CGRect)
    case arrow(tip: CGPoint, tail: CGPoint)
    case label(anchor: CGPoint)
    case path(points: [CGPoint])

    /// The point used to ask the Accessibility API "what element is here?".
    var accessibilityLookupPoint: CGPoint? {
        switch self {
        case .circle(let center, _): return center
        case .box(let rect), .highlight(let rect): return CGPoint(x: rect.midX, y: rect.midY)
        case .arrow(let tip, _): return tip
        case .label, .path: return nil
        }
    }

    /// Bounding rect in global points (used for click hit-testing and the cursor flight target).
    var boundingRect: CGRect {
        switch self {
        case .circle(let center, let radius):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .box(let rect), .highlight(let rect):
            return rect
        case .arrow(let tip, let tail):
            return CGRect(x: min(tip.x, tail.x), y: min(tip.y, tail.y),
                          width: abs(tip.x - tail.x), height: abs(tip.y - tail.y))
        case .label(let anchor):
            return CGRect(origin: anchor, size: .zero)
        case .path(let points):
            guard let firstPoint = points.first else { return .zero }
            var minimumX = firstPoint.x, maximumX = firstPoint.x
            var minimumY = firstPoint.y, maximumY = firstPoint.y
            for point in points {
                minimumX = min(minimumX, point.x); maximumX = max(maximumX, point.x)
                minimumY = min(minimumY, point.y); maximumY = max(maximumY, point.y)
            }
            return CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
        }
    }

    /// The point the blue cursor should fly to when this shape is primary.
    var cursorTargetPoint: CGPoint {
        switch self {
        case .arrow(let tip, _): return tip
        case .label(let anchor): return anchor
        default:
            let rect = boundingRect
            return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// Returns this geometry tightened onto a real UI element's frame (global points).
    /// Labels and paths are never snapped.
    func snapped(toElementFrame elementFrame: CGRect) -> MappedAnnotationGeometry {
        switch self {
        case .box:
            return .box(rect: elementFrame.insetBy(dx: -3, dy: -3))
        case .highlight:
            return .highlight(rect: elementFrame)
        case .circle:
            let snappedRadius = max(elementFrame.width, elementFrame.height) / 2 + 4
            return .circle(center: CGPoint(x: elementFrame.midX, y: elementFrame.midY), radius: snappedRadius)
        case .arrow(_, let tail):
            // Point at the closest spot on the element's edge to where the arrow starts.
            let closestPointOnElement = CGPoint(
                x: min(max(tail.x, elementFrame.minX), elementFrame.maxX),
                y: min(max(tail.y, elementFrame.minY), elementFrame.maxY)
            )
            let tailIsInsideElement = elementFrame.contains(tail)
            let newTip = tailIsInsideElement ? CGPoint(x: elementFrame.midX, y: elementFrame.midY) : closestPointOnElement
            return .arrow(tip: newTip, tail: tail)
        case .label, .path:
            return self
        }
    }
}

struct MappedAnnotationShape: Equatable, Identifiable {
    /// Index of the shape in the response; also seeds the hand-drawn jitter.
    let id: Int
    var geometry: MappedAnnotationGeometry
    let displayedText: String?
    let isPrimary: Bool
    let shouldSnapToAccessibilityElement: Bool
}

struct AnnotationCoordinateMapper {
    /// `NSScreen.frame` of the screen the screenshot was taken from (AppKit global points).
    let displayFrameInAppKitGlobalPoints: CGRect
    let imageWidthInPixels: Double
    let imageHeightInPixels: Double

    // MARK: Point mapping

    /// image px (top-left) -> clamp -> scale to display points -> flip Y -> add display origin.
    func appKitGlobalPoint(fromImagePixelX imagePixelX: Double, imagePixelY: Double) -> CGPoint {
        let clampedPixelX = min(max(imagePixelX, 0), imageWidthInPixels)
        let clampedPixelY = min(max(imagePixelY, 0), imageHeightInPixels)
        let displayWidth = displayFrameInAppKitGlobalPoints.width
        let displayHeight = displayFrameInAppKitGlobalPoints.height
        let pointXInDisplay = clampedPixelX * (displayWidth / imageWidthInPixels)
        let pointYFromTop = clampedPixelY * (displayHeight / imageHeightInPixels)
        return CGPoint(
            x: pointXInDisplay + displayFrameInAppKitGlobalPoints.origin.x,
            y: (displayHeight - pointYFromTop) + displayFrameInAppKitGlobalPoints.origin.y
        )
    }

    func appKitGlobalPoint(fromImagePixelPoint imagePixelPoint: CGPoint) -> CGPoint {
        appKitGlobalPoint(fromImagePixelX: Double(imagePixelPoint.x), imagePixelY: Double(imagePixelPoint.y))
    }

    /// Pixels-to-points scale for lengths (circle radius), averaged so it stays sane if aspect ratios differ slightly.
    private var averagePointsPerPixel: Double {
        let horizontalScale = displayFrameInAppKitGlobalPoints.width / imageWidthInPixels
        let verticalScale = displayFrameInAppKitGlobalPoints.height / imageHeightInPixels
        return (horizontalScale + verticalScale) / 2
    }

    private func normalizedGlobalRect(fromCornerPixel firstCorner: CGPoint, oppositeCornerPixel secondCorner: CGPoint) -> CGRect {
        let firstGlobalPoint = appKitGlobalPoint(fromImagePixelPoint: firstCorner)
        let secondGlobalPoint = appKitGlobalPoint(fromImagePixelPoint: secondCorner)
        return CGRect(
            x: min(firstGlobalPoint.x, secondGlobalPoint.x),
            y: min(firstGlobalPoint.y, secondGlobalPoint.y),
            width: abs(firstGlobalPoint.x - secondGlobalPoint.x),
            height: abs(firstGlobalPoint.y - secondGlobalPoint.y)
        )
    }

    // MARK: Shape mapping

    func mappedGeometry(from pixelGeometry: AnnotationPixelGeometry) -> MappedAnnotationGeometry {
        switch pixelGeometry {
        case .circle(let center, let radius):
            return .circle(center: appKitGlobalPoint(fromImagePixelPoint: center),
                           radius: CGFloat(radius * averagePointsPerPixel))
        case .box(let corner, let oppositeCorner):
            return .box(rect: normalizedGlobalRect(fromCornerPixel: corner, oppositeCornerPixel: oppositeCorner))
        case .highlight(let corner, let oppositeCorner):
            return .highlight(rect: normalizedGlobalRect(fromCornerPixel: corner, oppositeCornerPixel: oppositeCorner))
        case .arrow(let tip, let tail):
            return .arrow(tip: appKitGlobalPoint(fromImagePixelPoint: tip), tail: appKitGlobalPoint(fromImagePixelPoint: tail))
        case .label(let anchor):
            return .label(anchor: appKitGlobalPoint(fromImagePixelPoint: anchor))
        case .path(let points):
            return .path(points: points.map { appKitGlobalPoint(fromImagePixelPoint: $0) })
        }
    }

    /// Maps a whole response. Malformed shapes are dropped; only the first
    /// `primary` shape stays primary; at most `maximumShapeCount` are kept.
    func mappedShapes(from annotationShapes: [AnnotationShape], maximumShapeCount: Int = 6) -> [MappedAnnotationShape] {
        var mappedShapes: [MappedAnnotationShape] = []
        var primaryShapeAlreadyAssigned = false
        for (shapeIndex, annotationShape) in annotationShapes.prefix(maximumShapeCount).enumerated() {
            guard let pixelGeometry = annotationShape.pixelGeometry else { continue }
            let isPrimary = annotationShape.emphasis == .primary && !primaryShapeAlreadyAssigned
            if isPrimary { primaryShapeAlreadyAssigned = true }
            mappedShapes.append(MappedAnnotationShape(
                id: shapeIndex,
                geometry: mappedGeometry(from: pixelGeometry),
                displayedText: annotationShape.displayedText,
                isPrimary: isPrimary,
                shouldSnapToAccessibilityElement: annotationShape.shouldSnapToAccessibilityElement
            ))
        }
        return mappedShapes
    }

    // MARK: Space conversions

    /// AppKit global -> top-left-origin point inside a per-screen overlay view.
    static func screenLocalPoint(fromAppKitGlobalPoint globalPoint: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: globalPoint.x - screenFrame.origin.x,
                y: screenFrame.height - (globalPoint.y - screenFrame.origin.y))
    }

    static func screenLocalRect(fromAppKitGlobalRect globalRect: CGRect, screenFrame: CGRect) -> CGRect {
        let topLeft = screenLocalPoint(fromAppKitGlobalPoint: CGPoint(x: globalRect.minX, y: globalRect.maxY), screenFrame: screenFrame)
        return CGRect(x: topLeft.x, y: topLeft.y, width: globalRect.width, height: globalRect.height)
    }

    /// AppKit global point -> Accessibility global point (top-left origin of the primary screen).
    static func accessibilityPoint(fromAppKitGlobalPoint globalPoint: CGPoint, primaryScreenHeightInPoints: CGFloat) -> CGPoint {
        CGPoint(x: globalPoint.x, y: primaryScreenHeightInPoints - globalPoint.y)
    }

    /// Accessibility rect (top-left origin on the primary screen) -> AppKit global rect.
    static func appKitGlobalRect(fromAccessibilityRect accessibilityRect: CGRect, primaryScreenHeightInPoints: CGFloat) -> CGRect {
        CGRect(x: accessibilityRect.origin.x,
               y: primaryScreenHeightInPoints - accessibilityRect.origin.y - accessibilityRect.height,
               width: accessibilityRect.width,
               height: accessibilityRect.height)
    }

    // MARK: Snapping and click rules

    /// Only small controls are plausible snap targets; a window-sized element means the lookup hit a container.
    static func isPlausibleSnapTarget(sizeInPoints: CGSize) -> Bool {
        sizeInPoints.width > 0 && sizeInPoints.height > 0 && sizeInPoints.width < 600 && sizeInPoints.height < 200
    }

    static let clickSlackInPoints: CGFloat = 12

    static func isClick(atAppKitGlobalPoint clickPoint: CGPoint, insideTargetRect targetRect: CGRect, slackInPoints: CGFloat = clickSlackInPoints) -> Bool {
        targetRect.insetBy(dx: -slackInPoints, dy: -slackInPoints).contains(clickPoint)
    }

    // MARK: Label placement

    /// Places a label pill next to a shape (all rects in the same top-left space),
    /// below it by default, flipping above when it would run off the bottom,
    /// then clamping so it never overflows the screen edge.
    static func labelFrame(besideShapeRect shapeRect: CGRect, labelSize: CGSize, screenBounds: CGRect, gap: CGFloat = 8, edgeMargin: CGFloat = 8) -> CGRect {
        var labelOriginY = shapeRect.maxY + gap
        if labelOriginY + labelSize.height > screenBounds.maxY - edgeMargin {
            labelOriginY = shapeRect.minY - gap - labelSize.height
        }
        let labelOrigin = CGPoint(x: shapeRect.midX - labelSize.width / 2, y: labelOriginY)
        return clamped(CGRect(origin: labelOrigin, size: labelSize), within: screenBounds, margin: edgeMargin)
    }

    static func clamped(_ rect: CGRect, within bounds: CGRect, margin: CGFloat) -> CGRect {
        let maximumX = bounds.maxX - margin - rect.width
        let maximumY = bounds.maxY - margin - rect.height
        let clampedX = max(bounds.minX + margin, min(rect.origin.x, maximumX))
        let clampedY = max(bounds.minY + margin, min(rect.origin.y, maximumY))
        return CGRect(x: clampedX, y: clampedY, width: rect.width, height: rect.height)
    }

    // MARK: Hand-drawn jitter

    /// Deterministic wobble for a polyline so a shape looks the same every frame (no shimmer).
    static func jitteredPoints(_ points: [CGPoint], seed: Int, amplitude: CGFloat = 1.5) -> [CGPoint] {
        var generatorState = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15 &+ 0x12345678
        func nextValueBetweenMinusOneAndOne() -> CGFloat {
            // SplitMix64
            generatorState = generatorState &+ 0x9E3779B97F4A7C15
            var mixed = generatorState
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
            mixed = mixed ^ (mixed >> 31)
            return CGFloat(Double(mixed % 2001) / 1000.0 - 1.0)
        }
        return points.map {
            CGPoint(x: $0.x + nextValueBetweenMinusOneAndOne() * amplitude,
                    y: $0.y + nextValueBetweenMinusOneAndOne() * amplitude)
        }
    }
}
