//
//  AccessibilityElementSnapper.swift
//  leanring-buddy
//
//  Looks up the real UI element under a screen point via the Accessibility
//  API so a roughly placed shape can be tightened onto it. Requires the
//  Accessibility permission the app already asks for; without it every lookup
//  simply returns nil and the raw shape is drawn.
//

import AppKit
import ApplicationServices

/// An element's frame in AppKit global points (bottom-left origin), already converted from AX coordinates.
struct AXFrame: Equatable {
    let frameInAppKitGlobalPoints: CGRect
}

enum AccessibilityElementSnapper {

    /// Upper bound on how long one AX call may block, so a hung app can't stall snapping.
    private static let accessibilityMessagingTimeoutInSeconds: Float = 0.2

    /// Blocking AX lookup. Call it OFF the main thread (see `snappedFrame`).
    /// `primaryScreenHeightInPoints` is `NSScreen.screens[0].frame.height`, read on the main actor by the caller.
    static func lookUpFrameSynchronously(
        atAppKitGlobalPoint appKitGlobalPoint: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) -> AXFrame? {
        guard AXIsProcessTrusted() else { return nil }

        let accessibilityPoint = AnnotationCoordinateMapper.accessibilityPoint(
            fromAppKitGlobalPoint: appKitGlobalPoint,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )

        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, accessibilityMessagingTimeoutInSeconds)

        var elementUnderPoint: AXUIElement?
        let lookupResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(accessibilityPoint.x),
            Float(accessibilityPoint.y),
            &elementUnderPoint
        )
        guard lookupResult == .success, let elementUnderPoint else { return nil }

        // Never snap onto our own overlay windows.
        var owningProcessIdentifier: pid_t = 0
        AXUIElementGetPid(elementUnderPoint, &owningProcessIdentifier)
        if owningProcessIdentifier == ProcessInfo.processInfo.processIdentifier { return nil }

        guard let accessibilityRect = readFrame(of: elementUnderPoint) else { return nil }
        guard AnnotationCoordinateMapper.isPlausibleSnapTarget(sizeInPoints: accessibilityRect.size) else { return nil }

        let appKitRect = AnnotationCoordinateMapper.appKitGlobalRect(
            fromAccessibilityRect: accessibilityRect,
            primaryScreenHeightInPoints: primaryScreenHeightInPoints
        )
        return AXFrame(frameInAppKitGlobalPoints: appKitRect)
    }

    /// Async wrapper that runs the blocking lookup on a background queue so the main thread never waits on AX.
    static func snappedFrame(
        atAppKitGlobalPoint appKitGlobalPoint: CGPoint,
        primaryScreenHeightInPoints: CGFloat
    ) async -> AXFrame? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let frame = lookUpFrameSynchronously(
                    atAppKitGlobalPoint: appKitGlobalPoint,
                    primaryScreenHeightInPoints: primaryScreenHeightInPoints
                )
                continuation.resume(returning: frame)
            }
        }
    }

    /// Reads AXPosition + AXSize (top-left origin global coordinates).
    private static func readFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }
}
