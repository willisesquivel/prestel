import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// In-app tab drag only. Not a public UTI; other apps receive no useful session data.
    static let genesisTab = NSPasteboard.PasteboardType("com.example.GenesisTerminal.tab-drag")
}

/// Transient identifiers for a live tab. Resolves through the window registry; never serializes a PTY.
struct TabDragPayload: Codable, Equatable {
    let dragID: UUID
    let tabID: UUID
    let sourceWindowID: UUID
}

struct TabDragPin: Equatable {
    let windowID: UUID
    let insertionIndex: Int
}

/// Pure geometry for vertical tab insertion. Screen space uses AppKit's bottom-left origin.
enum TabInsertionGeometry {
    static let pinHeight: CGFloat = 8
    static let acquireDistance: CGFloat = 28
    static let releaseDistance: CGFloat = 48
    static let autoScrollEdge: CGFloat = 28
    static let autoScrollMinSpeed: CGFloat = 80
    static let autoScrollMaxSpeed: CGFloat = 340

    /// `rows` are screen-space frames, first visual tab first (top of the list).
    static func insertionIndex(at screenY: CGFloat, rows: [CGRect]) -> Int {
        guard !rows.isEmpty else { return 0 }
        for (index, row) in rows.enumerated() where screenY >= row.midY {
            return index
        }
        return rows.count
    }

    static func pinOffsetY(insertionIndex: Int) -> CGFloat {
        CGFloat(insertionIndex) * (ShellMetrics.sidebarRowHeight + ShellMetrics.sidebarRowSpacing) - pinHeight / 2
    }

    /// Map a gap in the currently visible (possibly filtered) list onto the canonical tab array.
    /// Hidden tabs keep their relative order: inserting between two visible neighbors places the
    /// moving tab immediately before the next visible tab in the underlying collection.
    /// Same-list insertion that would put the moving tab back where it already is.
    static func isNoOpInsertion(movingID: UUID, visibleInsertion: Int, visibleIDs: [UUID]) -> Bool {
        guard let from = visibleIDs.firstIndex(of: movingID) else { return false }
        return visibleInsertion == from || visibleInsertion == from + 1
    }

    static func canonicalInsertionIndex(visibleInsertion: Int, visibleIDs: [UUID], canonicalIDs: [UUID]) -> Int {
        guard !visibleIDs.isEmpty else { return canonicalIDs.count }
        if visibleInsertion <= 0 {
            return canonicalIDs.firstIndex(of: visibleIDs[0]) ?? 0
        }
        if visibleInsertion >= visibleIDs.count {
            guard let last = canonicalIDs.firstIndex(of: visibleIDs[visibleIDs.count - 1]) else {
                return canonicalIDs.count
            }
            return last + 1
        }
        return canonicalIDs.firstIndex(of: visibleIDs[visibleInsertion]) ?? canonicalIDs.count
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        if rect.contains(point) { return 0 }
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// Place a newly detached window so the drop point sits over its sidebar tab list, then clamp to `visible`.
    static func clampedOrigin(size: CGSize, drop: CGPoint, visible: CGRect) -> CGPoint {
        var origin = CGPoint(
            x: drop.x - ShellMetrics.sidebarDefaultWidth / 2,
            y: drop.y - (size.height - 110)
        )
        if size.width >= visible.width {
            origin.x = visible.minX
        } else {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        if size.height >= visible.height {
            origin.y = visible.minY
        } else {
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return origin
    }

    static func originForDetachedWindow(size: CGSize, drop: CGPoint, screens: [NSScreen] = NSScreen.screens) -> CGPoint {
        let screen = screens.first { $0.frame.contains(drop) }
            ?? screens.min {
                hypot($0.frame.midX - drop.x, $0.frame.midY - drop.y)
                    < hypot($1.frame.midX - drop.x, $1.frame.midY - drop.y)
            }
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return clampedOrigin(size: size, drop: drop, visible: visible)
    }
}

// MARK: - Coordinator

/// App-level coordination for one in-flight tab drag. Terminal ownership stays on `TerminalModel`.
@MainActor
final class TabDragCoordinator: ObservableObject {
    static let shared = TabDragCoordinator()

    @Published private(set) var pin: TabDragPin?

    private var payload: TabDragPayload?
    private var destination: TabDragPin?
    private var cancelled = false
    private var finishing = false
    private var lastScreenPoint = CGPoint.zero
    private var autoScrollTimer: Timer?
    private weak var autoScrollView: NSScrollView?
    private var autoScrollDeltaPerSecond: CGFloat = 0
    private var escapeMonitor: Any?
    private var draggingSession: NSDraggingSession?
    private var zones: [UUID: WeakDropZone] = [:]
    private var rows: [ObjectIdentifier: WeakRow] = [:]

    private init() {}

    func registerZone(_ view: TabListDropZoneNSView) {
        zones[view.windowID] = WeakDropZone(view)
    }

    func unregisterZone(_ view: TabListDropZoneNSView) {
        if zones[view.windowID]?.view === view {
            zones.removeValue(forKey: view.windowID)
        }
    }

    func registerRow(_ view: TabRowHitNSView) {
        rows[ObjectIdentifier(view)] = WeakRow(view)
    }

    func unregisterRow(_ view: TabRowHitNSView) {
        rows.removeValue(forKey: ObjectIdentifier(view))
    }

    func begin(payload: TabDragPayload, at screenPoint: CGPoint, session: NSDraggingSession?) {
        self.payload = payload
        draggingSession = session
        destination = nil
        cancelled = false
        finishing = false
        lastScreenPoint = screenPoint
        installEscapeMonitor()
        updatePointer(screenPoint)
        refreshReturnAnimation()
    }

    /// Finder-style slide-back when the drag is cancelled or dropped on the original slot.
    var shouldAnimateReturn: Bool {
        if cancelled { return true }
        guard let payload, let destination, destination.windowID == payload.sourceWindowID else { return false }
        let visibleIDs = visibleRowFrames(in: destination.windowID).map(\.id)
        return TabInsertionGeometry.isNoOpInsertion(
            movingID: payload.tabID,
            visibleInsertion: destination.insertionIndex,
            visibleIDs: visibleIDs
        )
    }

    func markCancelled() {
        cancelled = true
        destination = nil
        pin = nil
        stopAutoScroll()
        refreshReturnAnimation()
    }

    func updatePointer(_ screenPoint: CGPoint) {
        lastScreenPoint = screenPoint
        guard payload != nil, !cancelled else { return }
        let next = resolveDestination(at: screenPoint)
        destination = next
        setVisualPin(next)
        updateAutoScroll(destinationWindowID: next?.windowID, screenPoint: screenPoint)
        refreshReturnAnimation()
    }

    func finish(at screenPoint: CGPoint) {
        guard !finishing else { return }
        finishing = true
        lastScreenPoint = screenPoint
        if !cancelled {
            updatePointer(screenPoint)
        }
        let returning = shouldAnimateReturn
        let destination = cancelled ? nil : self.destination
        let moving = payload
        cleanupDragState()
        if returning { return }
        guard let moving else { return }
        commit(moving, destination: destination, screenPoint: screenPoint)
    }

    func resetForTests() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        removeEscapeMonitor()
        payload = nil
        destination = nil
        pin = nil
        cancelled = false
        finishing = false
        draggingSession = nil
        zones.removeAll()
        rows.removeAll()
    }

    // MARK: Destination

    private func resolveDestination(at screenPoint: CGPoint) -> TabDragPin? {
        let topNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        let topWindow = NSApp.windows.first { $0.windowNumber == topNumber }

        if let topWindow,
           let controller = topWindow.windowController as? TerminalWindowController,
           controller.model.sidebarVisible {
            let clip = clipFrame(for: controller.model.id)
            if clip.contains(screenPoint) {
                return pin(in: controller.model.id, at: screenPoint)
            }
        }

        if let current = destination {
            let clip = clipFrame(for: current.windowID)
            if TabInsertionGeometry.distance(from: screenPoint, to: clip) <= TabInsertionGeometry.releaseDistance,
               !listContainsPointerUnderAnotherWindow(screenPoint, excluding: current.windowID) {
                return pin(in: current.windowID, at: screenPoint)
            }
        }

        if let topWindow,
           let controller = topWindow.windowController as? TerminalWindowController,
           controller.model.sidebarVisible {
            let clip = clipFrame(for: controller.model.id)
            let distance = TabInsertionGeometry.distance(from: screenPoint, to: clip)
            if distance <= TabInsertionGeometry.acquireDistance {
                return pin(in: controller.model.id, at: screenPoint)
            }
            return nil
        }

        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? TerminalWindowController,
                  controller.model.sidebarVisible else { continue }
            let clip = clipFrame(for: controller.model.id)
            let distance = TabInsertionGeometry.distance(from: screenPoint, to: clip)
            if distance <= TabInsertionGeometry.acquireDistance {
                return pin(in: controller.model.id, at: screenPoint)
            }
        }
        return nil
    }

    private func listContainsPointerUnderAnotherWindow(_ screenPoint: CGPoint, excluding windowID: UUID) -> Bool {
        let topNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard let topWindow = NSApp.windows.first(where: { $0.windowNumber == topNumber }),
              let controller = topWindow.windowController as? TerminalWindowController,
              controller.model.id != windowID else { return false }
        return clipFrame(for: controller.model.id).contains(screenPoint)
    }

    private func pin(in windowID: UUID, at screenPoint: CGPoint) -> TabDragPin {
        let rows = visibleRowFrames(in: windowID)
        let index = TabInsertionGeometry.insertionIndex(at: screenPoint.y, rows: rows.map(\.frame))
        return TabDragPin(windowID: windowID, insertionIndex: index)
    }

    private func clipFrame(for windowID: UUID) -> CGRect {
        if let zone = zones[windowID]?.view {
            let frame = zone.listScreenFrame
            if !frame.isNull, frame.width > 1, frame.height > 1 { return frame }
        }
        if let row = rows.values.compactMap(\.view).first(where: { $0.windowID == windowID }),
           let scrollView = row.enclosingScrollView,
           let window = scrollView.window {
            let clip = scrollView.contentView.bounds
            return window.convertToScreen(scrollView.contentView.convert(clip, to: nil))
        }
        let frames = visibleRowFrames(in: windowID).map(\.frame)
        guard let first = frames.first else { return .null }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private func scrollView(for windowID: UUID) -> NSScrollView? {
        zones[windowID]?.view?.enclosingScrollView
            ?? rows.values.compactMap(\.view).first { $0.windowID == windowID }?.enclosingScrollView
    }

    private func visibleRowFrames(in windowID: UUID) -> [(id: UUID, frame: CGRect)] {
        rows.values.compactMap(\.view).compactMap { view -> (UUID, CGRect)? in
            guard view.windowID == windowID, let window = view.window, let tabID = view.tabID else { return nil }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            return (tabID, rect)
        }
        .sorted { $0.1.midY > $1.1.midY }
        .map { (id: $0.0, frame: $0.1) }
    }

    private func setVisualPin(_ next: TabDragPin?) {
        let visual: TabDragPin?
        if let next, let payload, next.windowID == payload.sourceWindowID {
            let visibleIDs = visibleRowFrames(in: next.windowID).map(\.id)
            visual = TabInsertionGeometry.isNoOpInsertion(
                movingID: payload.tabID,
                visibleInsertion: next.insertionIndex,
                visibleIDs: visibleIDs
            ) ? nil : next
        } else {
            visual = next
        }
        guard pin != visual else { return }
        pin = visual
        if visual != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    // MARK: Autoscroll

    private func updateAutoScroll(destinationWindowID: UUID?, screenPoint: CGPoint) {
        guard let destinationWindowID,
              let scrollView = scrollView(for: destinationWindowID) else {
            stopAutoScroll()
            return
        }
        let clip = clipFrame(for: destinationWindowID)
        guard !clip.isNull else {
            stopAutoScroll()
            return
        }
        let fromTop = clip.maxY - screenPoint.y
        let fromBottom = screenPoint.y - clip.minY
        let edge = TabInsertionGeometry.autoScrollEdge
        let horizontallyNear = screenPoint.x >= clip.minX - TabInsertionGeometry.releaseDistance
            && screenPoint.x <= clip.maxX + TabInsertionGeometry.releaseDistance
        guard horizontallyNear, clip.height > edge * 2 else {
            stopAutoScroll()
            return
        }
        let deltaPerSecond: CGFloat
        if fromTop >= 0, fromTop < edge {
            let t = (edge - fromTop) / edge
            deltaPerSecond = -(TabInsertionGeometry.autoScrollMinSpeed + t * (TabInsertionGeometry.autoScrollMaxSpeed - TabInsertionGeometry.autoScrollMinSpeed))
        } else if fromBottom >= 0, fromBottom < edge {
            let t = (edge - fromBottom) / edge
            deltaPerSecond = TabInsertionGeometry.autoScrollMinSpeed + t * (TabInsertionGeometry.autoScrollMaxSpeed - TabInsertionGeometry.autoScrollMinSpeed)
        } else {
            stopAutoScroll()
            return
        }
        startAutoScroll(scrollView: scrollView, deltaPerSecond: deltaPerSecond)
    }

    private func startAutoScroll(scrollView: NSScrollView, deltaPerSecond: CGFloat) {
        autoScrollView = scrollView
        autoScrollDeltaPerSecond = deltaPerSecond
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                TabDragCoordinator.shared.tickAutoScroll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func tickAutoScroll() {
        guard payload != nil, !cancelled,
              let scrollView = autoScrollView,
              let document = scrollView.documentView else {
            stopAutoScroll()
            return
        }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let delta = autoScrollDeltaPerSecond / 60
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        if clip.isFlipped {
            origin.y = min(max(origin.y + delta, 0), maxY)
        } else {
            origin.y = min(max(origin.y - delta, 0), maxY)
        }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        updatePointer(lastScreenPoint)
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollView = nil
        autoScrollDeltaPerSecond = 0
    }

    // MARK: Commit

    private func commit(_ payload: TabDragPayload, destination: TabDragPin?, screenPoint: CGPoint) {
        guard let app = AppDelegate.current,
              let source = app.controllers[payload.sourceWindowID],
              source.model.tabs.contains(where: { $0.id == payload.tabID }) else { return }

        if let destination, destination.windowID == payload.sourceWindowID {
            let canonical = canonicalIndex(for: destination, in: source.model)
            source.model.moveTab(payload.tabID, to: canonical)
            return
        }

        if let destination, let dest = app.controllers[destination.windowID] {
            let canonical = canonicalIndex(for: destination, in: dest.model)
            guard let tab = source.model.detachTab(payload.tabID) else { return }
            dest.model.adopt(tab, at: canonical, selecting: true)
            dest.refresh()
            closeIfEmpty(source)
            dest.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { dest.focusTerminal() }
            return
        }

        guard let tab = source.model.detachTab(payload.tabID) else { return }
        let created = app.createWindow(adopting: tab, near: screenPoint)
        closeIfEmpty(source)
        DispatchQueue.main.async { created.focusTerminal() }
    }

    private func canonicalIndex(for destination: TabDragPin, in model: TerminalModel) -> Int {
        TabInsertionGeometry.canonicalInsertionIndex(
            visibleInsertion: destination.insertionIndex,
            visibleIDs: model.filteredTabs.map(\.id),
            canonicalIDs: model.tabs.map(\.id)
        )
    }

    private func closeIfEmpty(_ controller: TerminalWindowController) {
        guard controller.model.tabs.isEmpty else {
            controller.refresh()
            return
        }
        controller.window?.performClose(nil)
    }

    private func cleanupDragState() {
        stopAutoScroll()
        removeEscapeMonitor()
        payload = nil
        destination = nil
        pin = nil
        cancelled = false
        draggingSession = nil
    }

    private func refreshReturnAnimation() {
        draggingSession?.animatesToStartingPositionsOnCancelOrFail = shouldAnimateReturn
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                TabDragCoordinator.shared.markCancelled()
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }
}

private struct WeakDropZone {
    weak var view: TabListDropZoneNSView?
    init(_ view: TabListDropZoneNSView) { self.view = view }
}

private struct WeakRow {
    weak var view: TabRowHitNSView?
    init(_ view: TabRowHitNSView) { self.view = view }
}

// MARK: - Drag preview (tab icon + title on an accent plate)

enum TabDragPreview {
    static let iconSide: CGFloat = 20
    static let iconGap: CGFloat = 8
    static let iconLeading: CGFloat = 8
    static let plateHorizontalPadding: CGFloat = 6
    static let plateCornerRadius: CGFloat = 6
    static let height: CGFloat = 28
    static let maxTitleWidth: CGFloat = 180

    static func size(for title: String) -> CGSize {
        CGSize(width: iconSide + iconGap + titleWidth(for: title) + plateHorizontalPadding, height: height)
    }

    static func titleWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(width), 12), maxTitleWidth)
    }

    static func image(title: String, symbol: String, appearance: NSAppearance) -> NSImage {
        let size = size(for: title)
        return NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                draw(title: title, symbol: symbol, in: rect)
            }
            return true
        }
    }

    private static func draw(title: String, symbol: String, in rect: CGRect) {
        let iconRect = CGRect(x: 0, y: (rect.height - iconSide) / 2, width: iconSide, height: iconSide)
        let nameX = iconSide + iconGap
        let nameWidth = titleWidth(for: title)
        let plate = CGRect(
            x: nameX - plateHorizontalPadding,
            y: (rect.height - iconSide) / 2,
            width: plateHorizontalPadding + nameWidth + plateHorizontalPadding,
            height: iconSide
        )

        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: plate, xRadius: plateCornerRadius, yRadius: plateCornerRadius).fill()

        let tile = NSBezierPath(roundedRect: iconRect, xRadius: 6, yRadius: 6)
        NSGradient(colors: [NSColor(white: 0.62, alpha: 1), NSColor(white: 0.48, alpha: 1)])?
            .draw(in: tile, angle: 270)

        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let symbolSize = symbolImage.size
            let symbolRect = CGRect(
                x: iconRect.midX - symbolSize.width / 2,
                y: iconRect.midY - symbolSize.height / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )
            NSGraphicsContext.current?.saveGraphicsState()
            tile.addClip()
            symbolImage.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let nameSize = (title as NSString).size(withAttributes: [.font: font])
        let textRect = CGRect(
            x: nameX,
            y: plate.midY - nameSize.height / 2,
            width: nameWidth,
            height: nameSize.height
        )
        (title as NSString).draw(in: textRect, withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
    }
}

// MARK: - Insertion pin

struct TabInsertionPin: View {
    var width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)

            Circle()
                .stroke(Color.accentColor, lineWidth: 2)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .frame(width: 8, height: 8)
                .offset(x: -4)
        }
        .frame(width: max(20, width - 20), height: TabInsertionGeometry.pinHeight)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(width: width, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Row hit target / drag source / middle-click

struct TabRowHitRepresentable: NSViewRepresentable {
    let windowID: UUID
    let tabID: UUID
    let title: String
    let symbol: String
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TabRowHitNSView {
        TabRowHitNSView()
    }

    func updateNSView(_ nsView: TabRowHitNSView, context: Context) {
        nsView.windowID = windowID
        nsView.tabID = tabID
        nsView.titleText = title
        nsView.symbol = symbol
        nsView.onSelect = onSelect
        nsView.onClose = onClose
        nsView.onHover = onHover
    }
}

final class TabRowHitNSView: NSView, NSDraggingSource {
    var windowID = UUID()
    var tabID: UUID?
    var titleText = ""
    var symbol = "terminal"
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false
    private var hovering = false
    private var registered = false

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        postsFrameChangedNotifications = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TabDragCoordinator.shared.registerRow(self)
            if !registered {
                registerForDraggedTypes([.genesisTab])
                registered = true
            }
            installScrollObservers()
        } else {
            TabDragCoordinator.shared.unregisterRow(self)
            removeScrollObservers()
            setHover(false)
        }
    }

    override func mouseEntered(with event: NSEvent) { syncHoverFromMouseLocation() }
    override func mouseExited(with event: NSEvent) { syncHoverFromMouseLocation() }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let mouseDownEvent else { return }
        let start = mouseDownEvent.locationInWindow
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) >= 5 else { return }
        beginTabDrag(current: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !didStartDrag {
            onSelect?()
        }
        mouseDownEvent = nil
        didStartDrag = false
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Close Tab", action: #selector(closeFromMenu(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func closeFromMenu(_ sender: Any?) {
        onClose?()
    }

    private func beginTabDrag(current: NSEvent) {
        guard let tabID else { return }
        didStartDrag = true
        let payload = TabDragPayload(dragID: UUID(), tabID: tabID, sourceWindowID: windowID)
        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(payload) {
            pasteboardItem.setData(data, forType: .genesisTab)
        }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let preview = TabDragPreview.image(title: titleText, symbol: symbol, appearance: effectiveAppearance)
        let size = preview.size
        let rest = CGRect(
            x: TabDragPreview.iconLeading,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        item.setDraggingFrame(rest, contents: preview)
        let session = beginDraggingSession(with: [item], event: current, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .default
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        didStartDrag = true
        guard let tabID else { return }
        let payload = TabDragPayload(dragID: UUID(), tabID: tabID, sourceWindowID: windowID)
        TabDragCoordinator.shared.begin(payload: payload, at: screenPoint, session: session)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        TabDragCoordinator.shared.updatePointer(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if didStartDrag {
            TabDragCoordinator.shared.finish(at: screenPoint)
        }
        didStartDrag = false
        mouseDownEvent = nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.genesisTab]) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.availableType(from: [.genesisTab]) != nil else { return false }
        return !TabDragCoordinator.shared.shouldAnimateReturn
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    private func setHover(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        onHover?(value)
    }

    private func syncHoverFromMouseLocation() {
        guard let window, window.isVisible, bounds.width > 1, bounds.height > 1 else {
            setHover(false)
            return
        }
        let mouse = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        let frameInWindow = convert(bounds, to: nil)
        setHover(frameInWindow.contains(mouse))
    }

    private func installScrollObservers() {
        removeScrollObservers()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleScrollChange(_:)),
                           name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(handleScrollChange(_:)),
                           name: NSView.frameDidChangeNotification, object: self)
    }

    @objc private func handleScrollChange(_ note: Notification) {
        syncHoverFromMouseLocation()
    }

    private func removeScrollObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
    }
}

// MARK: - Tab-list drop zone (geometry + autoscroll; not an insertion target itself)

struct TabListDropZone: NSViewRepresentable {
    let windowID: UUID

    func makeNSView(context: Context) -> TabListDropZoneNSView {
        TabListDropZoneNSView(windowID: windowID)
    }

    func updateNSView(_ nsView: TabListDropZoneNSView, context: Context) {
        nsView.windowID = windowID
        TabDragCoordinator.shared.registerZone(nsView)
    }
}

final class TabListDropZoneNSView: NSView {
    var windowID: UUID

    init(windowID: UUID) {
        self.windowID = windowID
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TabDragCoordinator.shared.registerZone(self)
        } else {
            TabDragCoordinator.shared.unregisterZone(self)
        }
    }

    /// Visible clip of the scrolling tab list, in screen coordinates. Excludes the pinned search field.
    var listScreenFrame: CGRect {
        guard let scrollView = enclosingScrollView, let window = scrollView.window,
              window.isVisible, !window.isMiniaturized else { return .null }
        let clip = scrollView.contentView.bounds
        let inWindow = scrollView.contentView.convert(clip, to: nil)
        return window.convertToScreen(inWindow)
    }
}
