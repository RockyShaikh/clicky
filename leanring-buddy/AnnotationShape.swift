//
//  AnnotationShape.swift
//  leanring-buddy
//
//  Codable models for the shapes Claude sends in a `respond` event
//  (docs/fork/CONTRACTS.md section 5). All coordinates here are screenshot
//  pixels with a top-left origin; AnnotationCoordinateMapper turns them into
//  AppKit global points.
//

import Foundation
import CoreGraphics

enum AnnotationShapeKind: String, Codable, Equatable {
    case circle
    case box
    case arrow
    case label
    case path
    case highlight
}

enum AnnotationEmphasis: String, Codable, Equatable {
    /// The blue cursor flies to this shape. At most one per response (first wins).
    case primary
    case secondary
}

/// One drawing primitive. The wire format is a flat JSON object whose required
/// fields depend on `kind`, so every coordinate is optional here and
/// `pixelGeometry` reports whether the required ones are present. Claude is an
/// imperfect JSON author, so a malformed shape is skipped rather than failing
/// the whole response.
struct AnnotationShape: Codable, Equatable {
    let kind: AnnotationShapeKind
    var xInPixels: Double?
    var yInPixels: Double?
    var radiusInPixels: Double?
    var oppositeCornerXInPixels: Double?
    var oppositeCornerYInPixels: Double?
    var arrowTailXInPixels: Double?
    var arrowTailYInPixels: Double?
    var pathPointsInPixels: [[Double]]?
    var captionText: String?
    var textForLabelShape: String?
    var shouldSnapToAccessibilityElement: Bool
    var emphasis: AnnotationEmphasis?

    enum CodingKeys: String, CodingKey {
        case kind
        case xInPixels = "x"
        case yInPixels = "y"
        case radiusInPixels = "r"
        case oppositeCornerXInPixels = "x2"
        case oppositeCornerYInPixels = "y2"
        case arrowTailXInPixels = "from_x"
        case arrowTailYInPixels = "from_y"
        case pathPointsInPixels = "points"
        case captionText = "label"
        case textForLabelShape = "text"
        case shouldSnapToAccessibilityElement = "snap"
        case emphasis
    }

    init(
        kind: AnnotationShapeKind,
        xInPixels: Double? = nil,
        yInPixels: Double? = nil,
        radiusInPixels: Double? = nil,
        oppositeCornerXInPixels: Double? = nil,
        oppositeCornerYInPixels: Double? = nil,
        arrowTailXInPixels: Double? = nil,
        arrowTailYInPixels: Double? = nil,
        pathPointsInPixels: [[Double]]? = nil,
        captionText: String? = nil,
        textForLabelShape: String? = nil,
        shouldSnapToAccessibilityElement: Bool = false,
        emphasis: AnnotationEmphasis? = nil
    ) {
        self.kind = kind
        self.xInPixels = xInPixels
        self.yInPixels = yInPixels
        self.radiusInPixels = radiusInPixels
        self.oppositeCornerXInPixels = oppositeCornerXInPixels
        self.oppositeCornerYInPixels = oppositeCornerYInPixels
        self.arrowTailXInPixels = arrowTailXInPixels
        self.arrowTailYInPixels = arrowTailYInPixels
        self.pathPointsInPixels = pathPointsInPixels
        self.captionText = captionText
        self.textForLabelShape = textForLabelShape
        self.shouldSnapToAccessibilityElement = shouldSnapToAccessibilityElement
        self.emphasis = emphasis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AnnotationShapeKind.self, forKey: .kind)
        xInPixels = try container.decodeIfPresent(Double.self, forKey: .xInPixels)
        yInPixels = try container.decodeIfPresent(Double.self, forKey: .yInPixels)
        radiusInPixels = try container.decodeIfPresent(Double.self, forKey: .radiusInPixels)
        oppositeCornerXInPixels = try container.decodeIfPresent(Double.self, forKey: .oppositeCornerXInPixels)
        oppositeCornerYInPixels = try container.decodeIfPresent(Double.self, forKey: .oppositeCornerYInPixels)
        arrowTailXInPixels = try container.decodeIfPresent(Double.self, forKey: .arrowTailXInPixels)
        arrowTailYInPixels = try container.decodeIfPresent(Double.self, forKey: .arrowTailYInPixels)
        pathPointsInPixels = try container.decodeIfPresent([[Double]].self, forKey: .pathPointsInPixels)
        captionText = try container.decodeIfPresent(String.self, forKey: .captionText)
        textForLabelShape = try container.decodeIfPresent(String.self, forKey: .textForLabelShape)
        shouldSnapToAccessibilityElement = try container.decodeIfPresent(Bool.self, forKey: .shouldSnapToAccessibilityElement) ?? false
        emphasis = try container.decodeIfPresent(AnnotationEmphasis.self, forKey: .emphasis)
    }

    /// The text to draw next to the shape: `text` for label shapes, `label` otherwise.
    var displayedText: String? {
        let candidateText = (kind == .label) ? (textForLabelShape ?? captionText) : captionText
        guard let candidateText, !candidateText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return candidateText
    }

    /// Geometry in screenshot pixels, or nil when a field required by `kind` is missing.
    var pixelGeometry: AnnotationPixelGeometry? {
        switch kind {
        case .circle:
            guard let xInPixels, let yInPixels, let radiusInPixels, radiusInPixels > 0 else { return nil }
            return .circle(center: CGPoint(x: xInPixels, y: yInPixels), radius: radiusInPixels)
        case .box:
            guard let xInPixels, let yInPixels, let oppositeCornerXInPixels, let oppositeCornerYInPixels else { return nil }
            return .box(corner: CGPoint(x: xInPixels, y: yInPixels),
                        oppositeCorner: CGPoint(x: oppositeCornerXInPixels, y: oppositeCornerYInPixels))
        case .highlight:
            guard let xInPixels, let yInPixels, let oppositeCornerXInPixels, let oppositeCornerYInPixels else { return nil }
            return .highlight(corner: CGPoint(x: xInPixels, y: yInPixels),
                              oppositeCorner: CGPoint(x: oppositeCornerXInPixels, y: oppositeCornerYInPixels))
        case .arrow:
            guard let xInPixels, let yInPixels, let arrowTailXInPixels, let arrowTailYInPixels else { return nil }
            return .arrow(tip: CGPoint(x: xInPixels, y: yInPixels),
                          tail: CGPoint(x: arrowTailXInPixels, y: arrowTailYInPixels))
        case .label:
            guard let xInPixels, let yInPixels, displayedText != nil else { return nil }
            return .label(anchor: CGPoint(x: xInPixels, y: yInPixels))
        case .path:
            guard let pathPointsInPixels else { return nil }
            let points = pathPointsInPixels.compactMap { pair -> CGPoint? in
                pair.count >= 2 ? CGPoint(x: pair[0], y: pair[1]) : nil
            }
            guard points.count >= 2 else { return nil }
            return .path(points: points)
        }
    }
}

/// Shape geometry in screenshot pixels (top-left origin).
enum AnnotationPixelGeometry: Equatable {
    case circle(center: CGPoint, radius: Double)
    case box(corner: CGPoint, oppositeCorner: CGPoint)
    case highlight(corner: CGPoint, oppositeCorner: CGPoint)
    case arrow(tip: CGPoint, tail: CGPoint)
    case label(anchor: CGPoint)
    case path(points: [CGPoint])
}

/// One step of a walkthrough: the app shows one step at a time and posts
/// `step_done` when the user clicks inside the step's primary shape.
struct WalkthroughStep: Codable, Equatable {
    let spokenText: String
    let annotationShapes: [AnnotationShape]
    let expectsClickOnPrimaryShape: Bool

    enum CodingKeys: String, CodingKey {
        case spokenText = "say"
        case annotationShapes = "shapes"
        case expectsClickOnPrimaryShape = "expect_click"
    }

    init(spokenText: String, annotationShapes: [AnnotationShape], expectsClickOnPrimaryShape: Bool) {
        self.spokenText = spokenText
        self.annotationShapes = annotationShapes
        self.expectsClickOnPrimaryShape = expectsClickOnPrimaryShape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spokenText = try container.decodeIfPresent(String.self, forKey: .spokenText) ?? ""
        annotationShapes = try container.decodeIfPresent([AnnotationShape].self, forKey: .annotationShapes) ?? []
        expectsClickOnPrimaryShape = try container.decodeIfPresent(Bool.self, forKey: .expectsClickOnPrimaryShape) ?? false
    }
}
