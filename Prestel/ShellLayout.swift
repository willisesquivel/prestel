import AppKit
import CoreGraphics
import SwiftUI

/// Pure width/origin resolution for the left sidebar, terminal body, and review panel.
struct ShellLayout: Equatable, Sendable {
    var effectiveSidebarWidth: CGFloat
    var detailOriginX: CGFloat
    var detailWidth: CGFloat
    var effectiveReviewWidth: CGFloat
    var reviewOriginX: CGFloat
    /// Full sidebar width as if it were open. Show/hide slides this width instead of clipping through 0.
    var restingSidebarWidth: CGFloat
    /// Full review width as if it were open. Show/hide slides this width instead of clipping through 0.
    var restingReviewWidth: CGFloat
    var restingReviewOriginX: CGFloat
    var terminalWidth: CGFloat
    var headerLeadingPadding: CGFloat
    var showsSidebar: Bool
    var showsReview: Bool

    struct Input: Equatable, Sendable {
        var windowWidth: CGFloat
        var sidebarVisible: Bool
        var reviewVisible: Bool
        var preferredSidebarWidth: CGFloat
        var preferredReviewWidth: CGFloat
    }

    static func resolve(_ input: Input) -> ShellLayout {
        let windowWidth = max(0, input.windowWidth)
        let preferredSidebar = clamp(
            input.preferredSidebarWidth,
            ShellMetrics.sidebarMinimumWidth,
            ShellMetrics.sidebarMaximumWidth
        )
        let preferredReview = clamp(
            input.preferredReviewWidth,
            ShellMetrics.reviewMinimumWidth,
            ShellMetrics.reviewMaximumWidth
        )

        let showsSidebar = input.sidebarVisible
        let showsReview = input.reviewVisible
        let restingSidebar = openSidebarWidth(
            windowWidth: windowWidth,
            preferred: preferredSidebar,
            reviewVisible: showsReview
        )
        let effectiveSidebar: CGFloat = showsSidebar ? restingSidebar : 0
        let detailOrigin = showsSidebar ? effectiveSidebar : ShellMetrics.detailInset
        let restingReview = openReviewWidth(
            windowWidth: windowWidth,
            preferred: preferredReview,
            detailOrigin: detailOrigin
        )
        let effectiveReview: CGFloat = showsReview ? restingReview : 0

        let trailing = showsReview ? effectiveReview : ShellMetrics.detailInset
        let detailWidth = max(0, windowWidth - detailOrigin - trailing)
        let reviewOriginX = windowWidth - effectiveReview
        let restingReviewOriginX = windowWidth - restingReview

        return ShellLayout(
            effectiveSidebarWidth: effectiveSidebar,
            detailOriginX: detailOrigin,
            detailWidth: detailWidth,
            effectiveReviewWidth: effectiveReview,
            reviewOriginX: reviewOriginX,
            restingSidebarWidth: restingSidebar,
            restingReviewWidth: restingReview,
            restingReviewOriginX: restingReviewOriginX,
            terminalWidth: detailWidth,
            headerLeadingPadding: showsSidebar ? 12 : 80,
            showsSidebar: showsSidebar,
            showsReview: showsReview
        )
    }

    private static func openSidebarWidth(
        windowWidth: CGFloat,
        preferred: CGFloat,
        reviewVisible: Bool
    ) -> CGFloat {
        let trailingMinimum: CGFloat = reviewVisible ? ShellMetrics.reviewMinimumWidth : ShellMetrics.detailInset
        let maximumSidebar = windowWidth - ShellMetrics.minimumDetailWidth - trailingMinimum
        let upper = max(ShellMetrics.sidebarMinimumWidth, maximumSidebar)
        return clamp(preferred, ShellMetrics.sidebarMinimumWidth, min(ShellMetrics.sidebarMaximumWidth, upper))
    }

    private static func openReviewWidth(
        windowWidth: CGFloat,
        preferred: CGFloat,
        detailOrigin: CGFloat
    ) -> CGFloat {
        let maximumReview = max(
            ShellMetrics.reviewMinimumWidth,
            windowWidth - detailOrigin - ShellMetrics.minimumDetailWidth
        )
        return clamp(
            preferred,
            ShellMetrics.reviewMinimumWidth,
            min(ShellMetrics.reviewMaximumWidth, maximumReview)
        )
    }

    static func clampSidebarPreference(_ proposed: CGFloat, windowWidth: CGFloat, reviewVisible: Bool) -> CGFloat {
        let trailing: CGFloat = reviewVisible ? ShellMetrics.reviewMinimumWidth : ShellMetrics.detailInset
        let maximum = min(
            ShellMetrics.sidebarMaximumWidth,
            max(
                ShellMetrics.sidebarMinimumWidth,
                windowWidth - ShellMetrics.minimumDetailWidth - trailing
            )
        )
        return clamp(proposed, ShellMetrics.sidebarMinimumWidth, maximum)
    }

    static func clampReviewPreference(
        _ proposed: CGFloat,
        windowWidth: CGFloat,
        sidebarVisible: Bool,
        preferredSidebarWidth: CGFloat
    ) -> CGFloat {
        let layout = resolve(
            Input(
                windowWidth: windowWidth,
                sidebarVisible: sidebarVisible,
                reviewVisible: true,
                preferredSidebarWidth: preferredSidebarWidth,
                preferredReviewWidth: proposed
            )
        )
        return clamp(layout.effectiveReviewWidth, ShellMetrics.reviewMinimumWidth, ShellMetrics.reviewMaximumWidth)
    }
}

enum ShellPanelAnimation {
    static func run(_ body: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, body)
        } else {
            withAnimation(.smooth(duration: ShellMetrics.sidebarAnimationDuration), body)
        }
    }
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), max(lower, upper))
}
