//
//  DoModeStatusBubbleView.swift
//  leanring-buddy
//
//  Do mode status line and confirmation question near the cursor (CONTRACTS section 7: the lead
//  mounts one instance per screen in the overlay ZStack, above the annotations). The view only
//  draws on the screen the session was summoned from.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DoModeStatusState: ObservableObject {
    @Published private(set) var statusText: String?
    @Published private(set) var confirmationQuestion: String?
    /// Screen (NSScreen.frame, AppKit global points) the bubble belongs to.
    @Published private(set) var screenFrameInAppKitGlobalPoints: CGRect?
    /// Cursor position at summon time (AppKit global points); the bubble sits just below it.
    @Published private(set) var cursorLocationInAppKitGlobalPoints: CGPoint = .zero

    var isShowingAnything: Bool { statusText != nil || confirmationQuestion != nil }

    func showStatus(_ text: String, onScreenWithFrame screenFrame: CGRect?, cursorLocation: CGPoint) {
        screenFrameInAppKitGlobalPoints = screenFrame
        cursorLocationInAppKitGlobalPoints = cursorLocation
        statusText = text
    }

    func showConfirmationQuestion(_ question: String, onScreenWithFrame screenFrame: CGRect?, cursorLocation: CGPoint) {
        screenFrameInAppKitGlobalPoints = screenFrame
        cursorLocationInAppKitGlobalPoints = cursorLocation
        confirmationQuestion = question
    }

    func clearConfirmationQuestion() {
        confirmationQuestion = nil
    }

    func clear() {
        statusText = nil
        confirmationQuestion = nil
    }
}

struct DoModeStatusBubbleView: View {
    @ObservedObject var state: DoModeStatusState
    let screenFrame: CGRect

    private let bubbleMaximumWidth: CGFloat = 320

    var body: some View {
        if state.isShowingAnything, state.screenFrameInAppKitGlobalPoints == screenFrame {
            GeometryReader { geometryProxy in
                bubbleContent
                    .frame(maxWidth: bubbleMaximumWidth, alignment: .leading)
                    .position(bubbleCenter(in: geometryProxy.size))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let confirmationQuestion = state.confirmationQuestion {
                Text(confirmationQuestion)
                    .font(.system(size: 13, weight: .semibold))
                Text("Say yes or no")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            } else if let statusText = state.statusText {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Below-right of the summon-time cursor, kept fully inside this screen. Local y is flipped
    /// from AppKit global coordinates (CONTRACTS section 8).
    private func bubbleCenter(in viewSize: CGSize) -> CGPoint {
        let cursorLocalX = state.cursorLocationInAppKitGlobalPoints.x - screenFrame.origin.x
        let cursorLocalY = screenFrame.height - (state.cursorLocationInAppKitGlobalPoints.y - screenFrame.origin.y)
        let halfBubbleWidth = bubbleMaximumWidth / 2
        let centerX = min(max(cursorLocalX + 24 + halfBubbleWidth, halfBubbleWidth + 12), viewSize.width - halfBubbleWidth - 12)
        let centerY = min(max(cursorLocalY + 56, 48), viewSize.height - 48)
        return CGPoint(x: centerX, y: centerY)
    }
}
