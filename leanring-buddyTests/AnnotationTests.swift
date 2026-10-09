//
//  AnnotationTests.swift
//  leanring-buddyTests
//
//  Pure-logic tests for WS4: shape decoding, coordinate mapping, snapping
//  conversion, label placement and click slack. The same cases are mirrored in
//  test-fixtures/annotations/run-logic-tests.sh for machines without Xcode.
//

import Testing
import CoreGraphics
import Foundation
@testable import leanring_buddy

struct AnnotationTests {

    private func expectClose(_ actualPoint: CGPoint, _ expectedX: Double, _ expectedY: Double, tolerance: Double = 0.05) {
        #expect(abs(Double(actualPoint.x) - expectedX) < tolerance)
        #expect(abs(Double(actualPoint.y) - expectedY) < tolerance)
    }

    // MARK: Mapper

    @Test func upstreamExampleMapsToExpectedGlobalPoint() {
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 1512, height: 982),
            imageWidthInPixels: 1280, imageHeightInPixels: 831)
        expectClose(mapper.appKitGlobalPoint(fromImagePixelX: 1100, imagePixelY: 42), 1299.4, 932.4)
    }

    @Test func retinaDisplayWithLargerImageStillMapsToPoints() {
        // Image is 2x the display in pixels; result is still in points.
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            imageWidthInPixels: 2880, imageHeightInPixels: 1800)
        expectClose(mapper.appKitGlobalPoint(fromImagePixelX: 2880, imagePixelY: 0), 1440, 900)
        expectClose(mapper.appKitGlobalPoint(fromImagePixelX: 0, imagePixelY: 1800), 0, 0)
    }

    @Test func outOfRangePixelsAreClamped() {
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 1000, height: 500),
            imageWidthInPixels: 1000, imageHeightInPixels: 500)
        expectClose(mapper.appKitGlobalPoint(fromImagePixelX: -50, imagePixelY: 9999), 0, 0)
    }

    @Test func screenLeftOfPrimaryHasNegativeOrigin() {
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            imageWidthInPixels: 1280, imageHeightInPixels: 720)
        expectClose(mapper.appKitGlobalPoint(fromImagePixelX: 640, imagePixelY: 360), -960, 540)
    }

    @Test func screenAbovePrimaryHasLargePositiveY() {
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 982, width: 1512, height: 982),
            imageWidthInPixels: 1280, imageHeightInPixels: 831)
        expectClose(mapper.appKitGlobalPoint(fromImagePixelX: 0, imagePixelY: 0), 0, 1964)
    }

    @Test func globalToScreenLocalFlipsYPerScreen() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        expectClose(AnnotationCoordinateMapper.screenLocalPoint(fromAppKitGlobalPoint: CGPoint(x: 1299.375, y: 932.4), screenFrame: primaryFrame), 1299.375, 49.6)
        let leftFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        expectClose(AnnotationCoordinateMapper.screenLocalPoint(fromAppKitGlobalPoint: CGPoint(x: -960, y: 540), screenFrame: leftFrame), 960, 540)
    }

    @Test func boxCornersAreNormalizedAfterYFlip() {
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 1000, height: 500),
            imageWidthInPixels: 1000, imageHeightInPixels: 500)
        let mapped = mapper.mappedGeometry(from: .box(corner: CGPoint(x: 100, y: 100), oppositeCorner: CGPoint(x: 300, y: 150)))
        #expect(mapped == .box(rect: CGRect(x: 100, y: 350, width: 200, height: 50)))
    }

    // MARK: Snapping conversion

    @Test func accessibilityRectConvertsToAppKitRect() {
        let appKitRect = AnnotationCoordinateMapper.appKitGlobalRect(
            fromAccessibilityRect: CGRect(x: 100, y: 50, width: 40, height: 20), primaryScreenHeightInPoints: 982)
        #expect(appKitRect == CGRect(x: 100, y: 912, width: 40, height: 20))
    }

    @Test func accessibilityRectOnScreenAbovePrimaryHasNegativeAXY() {
        // A screen above the primary has negative AX y; its AppKit y exceeds the primary height.
        let appKitRect = AnnotationCoordinateMapper.appKitGlobalRect(
            fromAccessibilityRect: CGRect(x: 10, y: -100, width: 50, height: 30), primaryScreenHeightInPoints: 982)
        #expect(appKitRect == CGRect(x: 10, y: 1052, width: 50, height: 30))
    }

    @Test func snapPlausibilityRejectsLargeFrames() {
        #expect(AnnotationCoordinateMapper.isPlausibleSnapTarget(sizeInPoints: CGSize(width: 599, height: 199)))
        #expect(!AnnotationCoordinateMapper.isPlausibleSnapTarget(sizeInPoints: CGSize(width: 600, height: 100)))
        #expect(!AnnotationCoordinateMapper.isPlausibleSnapTarget(sizeInPoints: CGSize(width: 100, height: 200)))
        #expect(!AnnotationCoordinateMapper.isPlausibleSnapTarget(sizeInPoints: .zero))
    }

    @Test func snappingBoxUsesElementFramePlusPadding() {
        let elementFrame = CGRect(x: 100, y: 100, width: 30, height: 20)
        let snapped = MappedAnnotationGeometry.box(rect: CGRect(x: 90, y: 90, width: 60, height: 60)).snapped(toElementFrame: elementFrame)
        #expect(snapped == .box(rect: CGRect(x: 97, y: 97, width: 36, height: 26)))
    }

    @Test func labelsAndPathsNeverSnap() {
        let elementFrame = CGRect(x: 0, y: 0, width: 10, height: 10)
        let label = MappedAnnotationGeometry.label(anchor: CGPoint(x: 5, y: 5))
        #expect(label.snapped(toElementFrame: elementFrame) == label)
    }

    // MARK: Decoding and response rules

    @Test func decodesContractShapesAndSkipsMalformedOnes() throws {
        let json = """
        [ {"kind":"circle","x":1100,"y":42,"r":28,"label":"color inspector","snap":true,"emphasis":"primary"},
          {"kind":"circle","x":1,"y":2},
          {"kind":"arrow","x":1100,"y":42,"from_x":950,"from_y":160},
          {"kind":"path","points":[[1,2]]} ]
        """
        let shapes = try JSONDecoder().decode([AnnotationShape].self, from: Data(json.utf8))
        #expect(shapes.count == 4)
        #expect(shapes[0].shouldSnapToAccessibilityElement)
        #expect(shapes[0].emphasis == .primary)
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 1512, height: 982),
            imageWidthInPixels: 1280, imageHeightInPixels: 831)
        #expect(mapper.mappedShapes(from: shapes).count == 2)
    }

    @Test func onlyFirstPrimaryShapeStaysPrimary() {
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageWidthInPixels: 100, imageHeightInPixels: 100)
        let mapped = mapper.mappedShapes(from: [
            AnnotationShape(kind: .circle, xInPixels: 10, yInPixels: 10, radiusInPixels: 5, emphasis: .primary),
            AnnotationShape(kind: .circle, xInPixels: 50, yInPixels: 50, radiusInPixels: 5, emphasis: .primary),
        ])
        #expect(mapped.map(\.isPrimary) == [true, false])
    }

    @Test func respondIsLimitedToSixShapes() {
        let mapper = AnnotationCoordinateMapper(
            displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageWidthInPixels: 100, imageHeightInPixels: 100)
        let tenShapes = (0..<10).map { AnnotationShape(kind: .circle, xInPixels: Double($0), yInPixels: 1, radiusInPixels: 2) }
        #expect(mapper.mappedShapes(from: tenShapes).count == 6)
    }

    @Test func walkthroughStepDecodesWireKeys() throws {
        let json = #"{"say":"Click File.","shapes":[{"kind":"box","x":1,"y":2,"x2":3,"y2":4}],"expect_click":true}"#
        let step = try JSONDecoder().decode(WalkthroughStep.self, from: Data(json.utf8))
        #expect(step.spokenText == "Click File.")
        #expect(step.annotationShapes.count == 1)
        #expect(step.expectsClickOnPrimaryShape)
    }

    // MARK: Labels and clicks

    @Test func labelFlipsAboveWhenItWouldOverflowBottomAndClampsRight() {
        let screenBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frame = AnnotationCoordinateMapper.labelFrame(
            besideShapeRect: CGRect(x: 950, y: 560, width: 40, height: 30),
            labelSize: CGSize(width: 120, height: 28), screenBounds: screenBounds)
        #expect(frame.maxY <= screenBounds.maxY)
        #expect(frame.maxX <= screenBounds.maxX)
        #expect(frame.maxY < 560)
    }

    @Test func clickSlackIsTwelvePoints() {
        let target = CGRect(x: 100, y: 100, width: 50, height: 20)
        #expect(AnnotationCoordinateMapper.isClick(atAppKitGlobalPoint: CGPoint(x: 88, y: 110), insideTargetRect: target))
        #expect(!AnnotationCoordinateMapper.isClick(atAppKitGlobalPoint: CGPoint(x: 87, y: 110), insideTargetRect: target))
    }

    @Test func jitterIsDeterministicPerSeed() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        #expect(AnnotationCoordinateMapper.jitteredPoints(points, seed: 3) == AnnotationCoordinateMapper.jitteredPoints(points, seed: 3))
        #expect(AnnotationCoordinateMapper.jitteredPoints(points, seed: 3) != AnnotationCoordinateMapper.jitteredPoints(points, seed: 4))
    }
}
