import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// In-app tab drag only. Not a public UTI; other apps receive no useful session data.
    static let prestelTab = NSPasteboard.PasteboardType("com.example.Prestel.tab-drag")
}

/// Transient identifiers for a live tab. Resolves through the window registry; never serializes a PTY.
struct TabDragPayload: Codable, Equatable {
    let dragID: UUID
    let tabID: UUID
    let tabIDs: [UUID]
    let sourceWindowID: UUID

    init(dragID: UUID, tabID: UUID, sourceWindowID: UUID, tabIDs: [UUID]? = nil) {
        self.dragID = dragID
        self.tabID = tabID
        self.tabIDs = tabIDs.flatMap { $0.isEmpty ? nil : $0 } ?? [tabID]
        self.sourceWindowID = sourceWindowID
    }
}

struct TabDragPin: Equatable {
    let windowID: UUID
    let insertionIndex: Int
    /// Canonical index in the destination window's tab array, measured before removal.
    let canonicalIndex: Int
    /// Non-nil when this drop joins a folder.
    let folderID: UUID?
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
    @Published private(set) var splitPreview: TabSplitPreview?
    /// The one row under the pointer. Rows read this instead of keeping their own hover flag.
    @Published private(set) var hoveredRowKey: UUID?

    private var payload: TabDragPayload?
    /// Tab showing in the source window when the drag started.
    private var visibleTabID: UUID?
    private var destination: TabDragDestination?
    private var cancelled = false
    private var finishing = false
    private var lastScreenPoint = CGPoint.zero
    private var lastPointerY: CGFloat?
    private var dragDirection: FolderDragDirection?
    private var collapsedJoinID: UUID?
    private var dwellGeneration = 0
    private var autoScrollTimer: Timer?
    private weak var autoScrollView: NSScrollView?
    private var autoScrollDeltaPerSecond: CGFloat = 0
    private var escapeMonitor: Any?
    private var hoverMonitor: Any?
    private var draggingSession: NSDraggingSession?
    private var zones: [UUID: WeakDropZone] = [:]
    private var details: [UUID: WeakDetailZone] = [:]
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

    func registerDetail(_ view: TabDetailDropZoneNSView) {
        details[view.windowID] = WeakDetailZone(view)
    }

    func unregisterDetail(_ view: TabDetailDropZoneNSView) {
        if details[view.windowID]?.view === view {
            details.removeValue(forKey: view.windowID)
        }
    }

    func registerRow(_ view: TabRowHitNSView) {
        rows[ObjectIdentifier(view)] = WeakRow(view)
        installHoverMonitor()
    }

    func unregisterRow(_ view: TabRowHitNSView) {
        rows.removeValue(forKey: ObjectIdentifier(view))
    }

    func setHoveredRow(_ key: UUID?) {
        guard hoveredRowKey != key else { return }
        hoveredRowKey = key
    }

    /// One row owns the hover. Overlapping or stale tracking rects cannot light up a second row.
    func syncHoveredRow(at windowPoint: NSPoint, in window: NSWindow) {
        var best: (key: UUID, distance: CGFloat)?
        for row in rows.values {
            guard let view = row.view, view.window === window,
                  view.bounds.width > 1, view.bounds.height > 1 else { continue }
            let local = view.convert(windowPoint, from: nil)
            guard view.bounds.contains(local) else { continue }
            guard let key = view.tabID ?? view.listRowID else { continue }
            let distance = abs(local.y - view.bounds.midY)
            if best == nil || distance < best!.distance {
                best = (key, distance)
            }
        }
        setHoveredRow(best?.key)
    }

    func syncHoveredRowToCursor() {
        let screen = NSEvent.mouseLocation
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(screen) }) else {
            setHoveredRow(nil)
            return
        }
        let point = window.convertFromScreen(NSRect(origin: screen, size: .zero)).origin
        syncHoveredRow(at: point, in: window)
    }

    private func installHoverMonitor() {
        guard hoverMonitor == nil else { return }
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            guard let window = event.window else { return event }
            TabDragCoordinator.shared.syncHoveredRow(at: event.locationInWindow, in: window)
            return event
        }
    }

    /// The pane showing before a press can select the grabbed row. `begin` runs
    /// after that press, so a background drop would otherwise split with itself.
    func noteVisibleTabBeforePress(windowID: UUID) {
        guard visibleTabID == nil, payload == nil else { return }
        visibleTabID = AppDelegate.current?.controllers[windowID]?.model.selectedID
    }

    func clearVisibleTabIfPressDidNotDrag() {
        guard payload == nil else { return }
        visibleTabID = nil
    }

    func begin(payload: TabDragPayload, at screenPoint: CGPoint, session: NSDraggingSession?) {
        self.payload = payload
        draggingSession = session
        destination = nil
        cancelled = false
        finishing = false
        lastScreenPoint = screenPoint
        lastPointerY = nil
        dragDirection = nil
        if visibleTabID == nil {
            visibleTabID = AppDelegate.current?.controllers[payload.sourceWindowID]?.model.selectedID
        }
        cancelCollapsedDwell()
        installEscapeMonitor()
        updatePointer(screenPoint)
        refreshReturnAnimation()
    }

    /// Finder-style slide-back when the drag is cancelled, dropped on the original
    /// slot, dropped onto a pane the tab already occupies, or dropped on window
    /// chrome that is not a list or detail target. Empty-space detach does not return.
    var shouldAnimateReturn: Bool {
        if cancelled { return true }
        guard let payload, let destination else { return false }
        switch destination {
        case .list(let pin):
            guard pin.windowID == payload.sourceWindowID else { return false }
            return insertionIsStationary(pin, payload: payload)
        case .split(let preview):
            guard payload.tabIDs.count == 1 else { return true }
            guard let model = AppDelegate.current?.controllers[preview.windowID]?.model else { return false }
            return TabSplitGeometry.isNoOp(
                movingID: payload.tabID,
                side: preview.side,
                selectedID: visibleTabID ?? model.selectedID,
                split: model.visibleSplit
            )
        case .windowNoOp(_):
            return true
        }
    }

    func markCancelled() {
        cancelled = true
        destination = nil
        pin = nil
        splitPreview = nil
        cancelCollapsedDwell()
        stopAutoScroll()
        refreshReturnAnimation()
    }

    func updatePointer(_ screenPoint: CGPoint) {
        let moved: Bool
        if let lastPointerY {
            moved = lastPointerY != screenPoint.y
        } else {
            moved = true
        }
        dragDirection = FolderDrop.direction(after: dragDirection, pointerY: screenPoint.y)
        lastPointerY = screenPoint.y
        lastScreenPoint = screenPoint
        guard payload != nil, !cancelled else { return }
        if moved {
            scheduleCollapsedDwell(at: screenPoint)
        }
        let next = resolveDestination(at: screenPoint)
        destination = next
        applyVisuals(next)
        let listWindowID: UUID?
        if case .list(let pin) = next {
            listWindowID = pin.windowID
        } else {
            listWindowID = nil
        }
        updateAutoScroll(destinationWindowID: listWindowID, screenPoint: screenPoint)
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
        let panelTabID = visibleTabID
        cleanupDragState()
        if returning { return }
        guard let moving else { return }
        commit(moving, destination: destination, screenPoint: screenPoint, beside: panelTabID)
    }

    func resetForTests() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        removeEscapeMonitor()
        cancelCollapsedDwell()
        payload = nil
        destination = nil
        pin = nil
        splitPreview = nil
        cancelled = false
        finishing = false
        draggingSession = nil
        lastPointerY = nil
        dragDirection = nil
        visibleTabID = nil
        zones.removeAll()
        details.removeAll()
        rows.removeAll()
    }

    // MARK: Destination

    private func resolveDestination(at screenPoint: CGPoint) -> TabDragDestination? {
        let topNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        let topWindow = NSApp.windows.first { $0.windowNumber == topNumber }
        let topController = topWindow.flatMap { $0.windowController as? TerminalWindowController }

        if let topController, topController.model.sidebarVisible {
            let clip = clipFrame(for: topController.model.id)
            if clip.contains(screenPoint) {
                return .list(pin(in: topController.model.id, at: screenPoint))
            }
        }

        if let current = destination, case .list(let pin) = current {
            let clip = clipFrame(for: pin.windowID)
            let overDetail = detailFrame(for: pin.windowID).contains(screenPoint)
            if !overDetail,
               TabInsertionGeometry.distance(from: screenPoint, to: clip) <= TabInsertionGeometry.releaseDistance,
               !listContainsPointerUnderAnotherWindow(screenPoint, excluding: pin.windowID) {
                return .list(self.pin(in: pin.windowID, at: screenPoint))
            }
        }

        if payload?.tabIDs.count == 1,
           let topController,
           let split = splitDestination(in: topController, at: screenPoint) {
            return .split(split)
        }

        if let topController, topController.model.sidebarVisible {
            let clip = clipFrame(for: topController.model.id)
            let distance = TabInsertionGeometry.distance(from: screenPoint, to: clip)
            if distance <= TabInsertionGeometry.acquireDistance,
               !detailFrame(for: topController.model.id).contains(screenPoint) {
                return .list(pin(in: topController.model.id, at: screenPoint))
            }
        }

        if topController != nil {
            return topController.map { .windowNoOp($0.model.id) }
        }

        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? TerminalWindowController,
                  controller.model.sidebarVisible else { continue }
            let clip = clipFrame(for: controller.model.id)
            let distance = TabInsertionGeometry.distance(from: screenPoint, to: clip)
            if distance <= TabInsertionGeometry.acquireDistance,
               !detailFrame(for: controller.model.id).contains(screenPoint) {
                return .list(pin(in: controller.model.id, at: screenPoint))
            }
        }
        return nil
    }

    private func splitDestination(in controller: TerminalWindowController, at screenPoint: CGPoint) -> TabSplitPreview? {
        let detail = detailFrame(for: controller.model.id)
        guard let side = TabSplitGeometry.side(at: screenPoint, in: detail, split: controller.model.visibleSplit) else { return nil }
        return TabSplitPreview(windowID: controller.model.id, side: side)
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
        let visibleIDs = rows.map(\.id)
        let probe = FolderDropProbe(
            pointerY: screenPoint.y,
            rows: rows.map { FolderDropRow(id: $0.id, frame: $0.frame) },
            draggingDown: dragDirection?.draggingDown ?? true,
            collapsedJoinID: collapsedJoinID
        )
        let target = AppDelegate.current?.controllers[windowID]?.model.dropTarget(
            visibleInsertion: index,
            visibleIDs: visibleIDs,
            probe: probe
        ) ?? SidebarDropTarget(index: index, folderID: nil)
        return TabDragPin(
            windowID: windowID,
            insertionIndex: index,
            canonicalIndex: target.index,
            folderID: target.folderID
        )
    }

    /// Firefox restarts the collapsed-group timer on every pointer move and commits
    /// the join only after the pointer has been still for `createGroup.delayMS`.
    private func scheduleCollapsedDwell(at screenPoint: CGPoint) {
        collapsedJoinID = nil
        dwellGeneration += 1
        let generation = dwellGeneration
        guard let windowID = sidebarWindowID(at: screenPoint),
              let model = AppDelegate.current?.controllers[windowID]?.model else { return }
        let rows = visibleRowFrames(in: windowID).map { FolderDropRow(id: $0.id, frame: $0.frame) }
        guard let folderID = SidebarOutline.collapsedDwellFolder(
            pointerY: screenPoint.y,
            rows: rows,
            folders: model.folders
        ) else { return }
        Task { @MainActor in
            do {
                try await Task.sleep(for: FolderDrop.collapsedDwell)
            } catch {
                return
            }
            guard dwellGeneration == generation, payload != nil, !cancelled else { return }
            collapsedJoinID = folderID
            updatePointer(lastScreenPoint)
        }
    }

    private func cancelCollapsedDwell() {
        dwellGeneration += 1
        collapsedJoinID = nil
    }

    private func sidebarWindowID(at screenPoint: CGPoint) -> UUID? {
        let topNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        if let topWindow = NSApp.windows.first(where: { $0.windowNumber == topNumber }),
           let controller = topWindow.windowController as? TerminalWindowController,
           controller.model.sidebarVisible,
           clipFrame(for: controller.model.id).contains(screenPoint) {
            return controller.model.id
        }
        if let current = destination, case .list(let pin) = current,
           clipFrame(for: pin.windowID).contains(screenPoint) {
            return pin.windowID
        }
        return nil
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

    private func detailFrame(for windowID: UUID) -> CGRect {
        if let zone = details[windowID]?.view {
            let frame = zone.detailScreenFrame
            if !frame.isNull, frame.width > 1, frame.height > 1 { return frame }
        }
        return .null
    }

    private func scrollView(for windowID: UUID) -> NSScrollView? {
        zones[windowID]?.view?.enclosingScrollView
            ?? rows.values.compactMap(\.view).first { $0.windowID == windowID }?.enclosingScrollView
    }

    private func visibleRowFrames(in windowID: UUID) -> [(id: UUID, frame: CGRect)] {
        var rowFrames: [UUID: CGRect] = [:]
        for view in rows.values.compactMap(\.view) where view.windowID == windowID {
            guard let rowID = view.listRowID ?? view.tabID else { continue }
            guard let window = view.window else { continue }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            rowFrames[rowID] = rowFrames[rowID]?.union(rect) ?? rect
        }
        return rowFrames.map { (id: $0.key, frame: $0.value) }
            .sorted { lhs, rhs in
                if abs(lhs.frame.midY - rhs.frame.midY) > 4 { return lhs.frame.midY > rhs.frame.midY }
                return lhs.frame.minX < rhs.frame.minX
            }
    }

    private func insertionIsStationary(_ pin: TabDragPin, payload: TabDragPayload) -> Bool {
        if let model = AppDelegate.current?.controllers[pin.windowID]?.model,
           pin.windowID == payload.sourceWindowID {
            return !model.tabMoveWouldChange(
                payload.tabIDs,
                to: pin.canonicalIndex,
                folderID: pin.folderID
            )
        }
        let visibleIDs = visibleRowFrames(in: pin.windowID).map(\.id)
        let movingVisualID = occupyingVisualID(tabID: payload.tabID, windowID: pin.windowID, visualIDs: visibleIDs)
        guard let model = AppDelegate.current?.controllers[pin.windowID]?.model else {
            return TabInsertionGeometry.isNoOpInsertion(
                movingID: movingVisualID,
                visibleInsertion: pin.insertionIndex,
                visibleIDs: visibleIDs
            )
        }
        if model.folderContaining(payload.tabID)?.id != pin.folderID { return false }
        return TabInsertionGeometry.isNoOpInsertion(
            movingID: movingVisualID,
            visibleInsertion: pin.insertionIndex,
            visibleIDs: visibleIDs
        )
    }

    private func occupyingVisualID(tabID: UUID, windowID: UUID, visualIDs: [UUID]) -> UUID {
        if visualIDs.contains(tabID) { return tabID }
        if let view = rows.values.compactMap(\.view).first(where: { $0.tabID == tabID && $0.windowID == windowID }),
           let listRowID = view.listRowID,
           visualIDs.contains(listRowID) {
            return listRowID
        }
        guard let model = AppDelegate.current?.controllers[windowID]?.model,
              let split = model.split(containing: tabID),
              let partner = split.partner(of: tabID),
              visualIDs.contains(partner) else { return tabID }
        return partner
    }

    private func applyVisuals(_ next: TabDragDestination?) {
        switch next {
        case .list(let pin):
            setVisualPin(pin)
            setSplitPreview(nil)
        case .split(let preview):
            setVisualPin(nil)
            setSplitPreview(preview)
        case .windowNoOp(_), nil:
            setVisualPin(nil)
            setSplitPreview(nil)
        }
    }

    private func setVisualPin(_ next: TabDragPin?) {
        let visual: TabDragPin?
        if let next, let payload, next.windowID == payload.sourceWindowID {
            visual = insertionIsStationary(next, payload: payload) ? nil : next
        } else {
            visual = next
        }
        guard pin != visual else { return }
        pin = visual
        if visual != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func setSplitPreview(_ next: TabSplitPreview?) {
        guard splitPreview != next else { return }
        splitPreview = next
        if next != nil {
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

    private func commit(_ payload: TabDragPayload, destination: TabDragDestination?, screenPoint: CGPoint, beside: UUID?) {
        guard let app = AppDelegate.current,
              let source = app.controllers[payload.sourceWindowID],
              source.model.tabs.contains(where: { $0.id == payload.tabID }) else { return }

        switch destination {
        case .list(let pin) where pin.windowID == payload.sourceWindowID:
            source.model.moveTabs(
                payload.tabIDs,
                to: pin.canonicalIndex,
                folderID: pin.folderID,
                assignsFolder: true
            )
            return
        case .list(let pin):
            guard let dest = app.controllers[pin.windowID] else { return }
            let tabs = source.model.detachTabs(payload.tabIDs)
            guard !tabs.isEmpty else { return }
            dest.model.adopt(tabs, at: pin.canonicalIndex, selecting: payload.tabID)
            dest.model.setFolderMembership(tabs.map(\.id), folderID: pin.folderID)
            dest.refresh()
            closeIfEmpty(source)
            dest.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { dest.focusTerminal() }
            return
        case .split(let preview):
            commitSplit(payload, preview: preview, source: source, app: app, beside: beside)
            return
        case .windowNoOp(_):
            return
        case nil:
            break
        }

        let tabs = source.model.detachTabs(payload.tabIDs)
        guard !tabs.isEmpty else { return }
        let created = app.createWindow(adopting: tabs, selectedID: payload.tabID, near: screenPoint)
        closeIfEmpty(source)
        DispatchQueue.main.async { created.focusTerminal() }
    }

    private func commitSplit(
        _ payload: TabDragPayload,
        preview: TabSplitPreview,
        source: TerminalWindowController,
        app: AppDelegate,
        beside: UUID?
    ) {
        guard payload.tabIDs.count == 1 else { return }
        if preview.windowID == payload.sourceWindowID {
            source.model.split(with: payload.tabID, on: preview.side, beside: beside)
            source.refresh()
            DispatchQueue.main.async { source.focusTerminal() }
            return
        }
        guard let dest = app.controllers[preview.windowID] else { return }
        guard let tab = source.model.detachTab(payload.tabID) else { return }
        dest.model.adopt(tab, at: dest.model.tabs.count, selecting: false)
        dest.model.split(with: tab.id, on: preview.side)
        dest.refresh()
        closeIfEmpty(source)
        dest.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { dest.focusTerminal() }
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
        cancelCollapsedDwell()
        payload = nil
        destination = nil
        pin = nil
        splitPreview = nil
        cancelled = false
        draggingSession = nil
        lastPointerY = nil
        dragDirection = nil
        visibleTabID = nil
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

private struct WeakDetailZone {
    weak var view: TabDetailDropZoneNSView?
    init(_ view: TabDetailDropZoneNSView) { self.view = view }
}

private struct WeakRow {
    weak var view: TabRowHitNSView?
    init(_ view: TabRowHitNSView) { self.view = view }
}

// MARK: - Drag preview (tab icon + title on an accent plate)

enum TabDragPreview {
    struct Item {
        let title: String
        let symbol: String
    }

    static let iconSide: CGFloat = 20
    static let iconGap: CGFloat = 8
    static let iconLeading: CGFloat = 8
    static let plateHorizontalPadding: CGFloat = 6
    static let plateCornerRadius: CGFloat = 6
    static let height: CGFloat = 28
    static let maxTitleWidth: CGFloat = 180
    static let canvasPadding: CGFloat = 10
    private static let stackOffset: CGFloat = 5

    static func size(for title: String) -> CGSize {
        CGSize(width: iconSide + iconGap + titleWidth(for: title) + plateHorizontalPadding, height: height)
    }

    static func titleWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(width), 12), maxTitleWidth)
    }

    static func image(title: String, symbol: String, appearance: NSAppearance) -> NSImage {
        image(items: [Item(title: title, symbol: symbol)], totalCount: 1, appearance: appearance)
    }

    /// Lume-style stacked reorder art. The grabbed tab stays in front, up to
    /// two selected companions peek from behind, and a badge shows block size.
    static func image(items: [Item], totalCount: Int, appearance: NSAppearance) -> NSImage {
        let visible = Array(items.prefix(3))
        let fallback = visible.isEmpty ? [Item(title: "Tab", symbol: "terminal")] : visible
        let largest = fallback.map { size(for: $0.title) }.reduce(CGSize.zero) { current, next in
            CGSize(width: max(current.width, next.width), height: max(current.height, next.height))
        }
        let stack = CGFloat(max(0, fallback.count - 1)) * stackOffset
        let canvasSize = CGSize(
            width: largest.width + canvasPadding * 2 + stack,
            height: largest.height + canvasPadding * 2 + stack
        )
        return NSImage(size: canvasSize, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                for (index, item) in fallback.enumerated().reversed() {
                    let offset = CGFloat(index) * stackOffset
                    drawStackItem(
                        item,
                        at: CGPoint(x: canvasPadding + offset, y: canvasPadding + offset),
                        index: index
                    )
                }
                if totalCount > 1 {
                    drawCountBadge(totalCount, canvasSize: canvasSize)
                }
            }
            return true
        }
    }

    private static func drawStackItem(_ item: Item, at origin: CGPoint, index: Int) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let itemSize = size(for: item.title)
        context.saveGState()
        context.translateBy(x: origin.x + itemSize.width / 2, y: origin.y + itemSize.height / 2)
        let angle: CGFloat = index == 0 ? 0 : (index.isMultiple(of: 2) ? -1.8 : 1.8) * .pi / 180
        context.rotate(by: angle)
        let scale = 1 - CGFloat(index) * 0.025
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -itemSize.width / 2, y: -itemSize.height / 2)
        context.setAlpha(1 - CGFloat(index) * 0.12)
        draw(title: item.title, symbol: item.symbol, in: CGRect(origin: .zero, size: itemSize))
        context.restoreGState()
    }

    private static func drawCountBadge(_ count: Int, canvasSize: CGSize) {
        let width: CGFloat = count > 99 ? 30 : 22
        let badge = CGRect(x: 1, y: canvasSize.height - 23, width: width, height: 22)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSColor.white.withAlphaComponent(0.72).setStroke()
        NSBezierPath(ovalIn: badge).stroke()
        let text = String(count) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
            withAttributes: attributes
        )
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
    /// Shifts the needle in from the leading edge. The trailing edge stays put,
    /// so a drop inside a folder draws a shorter pin, same as Lume's track reorder indicator.
    var leadingIndent: CGFloat = 0

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
        .frame(width: max(20, width - 20 - leadingIndent), height: TabInsertionGeometry.pinHeight)
        .padding(.leading, 10 + leadingIndent)
        .padding(.trailing, 10)
        .frame(width: width, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Row hit target / drag source / middle-click

struct TabRowHitRepresentable: NSViewRepresentable {
    let windowID: UUID
    let tabID: UUID?
    var listRowID: UUID?
    let title: String
    let symbol: String
    let onSelect: () -> Void
    var onModifiedSelect: ((Bool, Bool) -> Void)?
    var onPrepareDrag: (() -> Void)?
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    var splitWithActiveEnabled = false
    var onSplitWithActive: (() -> Void)?
    var onUnsplit: (() -> Void)?
    var onArchive: (() -> Void)?
    var onRename: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onRemoveFromFolder: (() -> Void)?
    var onDeleteFolder: (() -> Void)?
    var folderDestinations: [(title: String, handler: () -> Void)] = []
    var allowsDrag = true
    var isFolder = false

    func makeNSView(context: Context) -> TabRowHitNSView {
        TabRowHitNSView()
    }

    func updateNSView(_ nsView: TabRowHitNSView, context: Context) {
        nsView.windowID = windowID
        nsView.tabID = tabID
        nsView.listRowID = listRowID
        nsView.titleText = title
        nsView.symbol = symbol
        nsView.onSelect = onSelect
        nsView.onModifiedSelect = onModifiedSelect
        nsView.onPrepareDrag = onPrepareDrag
        nsView.onClose = onClose
        nsView.onHover = onHover
        nsView.splitWithActiveEnabled = splitWithActiveEnabled
        nsView.onSplitWithActive = onSplitWithActive
        nsView.onUnsplit = onUnsplit
        nsView.onArchive = onArchive
        nsView.onRename = onRename
        nsView.onNewFolder = onNewFolder
        nsView.onRemoveFromFolder = onRemoveFromFolder
        nsView.onDeleteFolder = onDeleteFolder
        nsView.folderDestinations = folderDestinations
        nsView.allowsDrag = allowsDrag
        nsView.isFolder = isFolder
        nsView.publishAccessibility()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabRowHitNSView, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.bounds.width,
            height: min(proposal.height ?? ShellMetrics.sidebarRowHeight, ShellMetrics.sidebarRowHeight)
        )
    }
}

final class TabRowHitNSView: NSView, NSDraggingSource {
    var windowID = UUID()
    var tabID: UUID?
    var listRowID: UUID?
    var titleText = ""
    var symbol = "terminal"
    var onSelect: (() -> Void)?
    var onModifiedSelect: ((Bool, Bool) -> Void)?
    var onPrepareDrag: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var splitWithActiveEnabled = false
    var onSplitWithActive: (() -> Void)?
    var onUnsplit: (() -> Void)?
    var onArchive: (() -> Void)?
    var onRename: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onRemoveFromFolder: (() -> Void)?
    var onDeleteFolder: (() -> Void)?
    var folderDestinations: [(title: String, handler: () -> Void)] = []
    var allowsDrag = true
    var isFolder = false

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false
    private var hovering = false
    private var registered = false
    private var hoverSync: DispatchWorkItem?
    private var activePayload: TabDragPayload?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
        postsFrameChangedNotifications = true
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHidden(false)
    }

    func publishAccessibility() {
        let name = titleText.isEmpty ? "Tab" : titleText
        setAccessibilityLabel(name)
        setAccessibilityIdentifier(name)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TabDragCoordinator.shared.registerRow(self)
            if !registered {
                registerForDraggedTypes([.prestelTab])
                registered = true
            }
            installScrollObservers()
        } else {
            hoverSync?.cancel()
            hoverSync = nil
            let key = tabID ?? listRowID
            if TabDragCoordinator.shared.hoveredRowKey == key {
                TabDragCoordinator.shared.setHoveredRow(nil)
            }
            TabDragCoordinator.shared.unregisterRow(self)
            removeScrollObservers()
            setHover(false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window = event.window else { return }
        TabDragCoordinator.shared.syncHoveredRow(at: event.locationInWindow, in: window)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window = event.window else { return }
        TabDragCoordinator.shared.syncHoveredRow(at: event.locationInWindow, in: window)
    }

    override func mouseExited(with event: NSEvent) {
        guard let window = event.window else {
            TabDragCoordinator.shared.setHoveredRow(nil)
            return
        }
        TabDragCoordinator.shared.syncHoveredRow(at: event.locationInWindow, in: window)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didStartDrag = false
        if let controller = window?.windowController as? TerminalWindowController {
            TabDragCoordinator.shared.noteVisibleTabBeforePress(windowID: controller.model.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsDrag, !didStartDrag, let mouseDownEvent else { return }
        let start = mouseDownEvent.locationInWindow
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) >= 5 else { return }
        beginTabDrag(current: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            didStartDrag = false
            activePayload = nil
        }
        if didStartDrag { return }
        TabDragCoordinator.shared.clearVisibleTabIfPressDidNotDrag()
        if event.clickCount >= 2, clickIsOnTitle(event) {
            onRename?()
            return
        }
        if event.clickCount >= 2 { return }
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        if let onModifiedSelect {
            onModifiedSelect(shift, command)
        } else {
            onSelect?()
        }
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
        menu.autoenablesItems = false
        if isFolder {
            addRenameItem(to: menu)
            if onDeleteFolder != nil {
                let deleteItem = NSMenuItem(title: "Delete Folder", action: #selector(deleteFolderFromMenu(_:)), keyEquivalent: "")
                deleteItem.target = self
                menu.addItem(deleteItem)
            }
            return menu
        }

        let splitItem = NSMenuItem(
            title: "Split with Active",
            action: #selector(splitWithActiveFromMenu(_:)),
            keyEquivalent: ""
        )
        splitItem.target = self
        splitItem.isEnabled = splitWithActiveEnabled
        menu.addItem(splitItem)

        if onUnsplit != nil {
            let unsplitItem = NSMenuItem(
                title: "Unsplit Tabs",
                action: #selector(unsplitFromMenu(_:)),
                keyEquivalent: ""
            )
            unsplitItem.target = self
            unsplitItem.isEnabled = true
            menu.addItem(unsplitItem)
        }

        menu.addItem(.separator())
        addRenameItem(to: menu)
        let newFolder = NSMenuItem(title: "New Folder", action: #selector(newFolderFromMenu(_:)), keyEquivalent: "")
        newFolder.target = self
        menu.addItem(newFolder)
        if !folderDestinations.isEmpty {
            let submenu = NSMenu()
            for (index, destination) in folderDestinations.enumerated() {
                let item = NSMenuItem(title: destination.title, action: #selector(addToFolderFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                submenu.addItem(item)
            }
            let addItem = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
            addItem.submenu = submenu
            menu.addItem(addItem)
        }
        if onRemoveFromFolder != nil {
            let removeItem = NSMenuItem(title: "Remove from Folder", action: #selector(removeFromFolderFromMenu(_:)), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
        }
        menu.addItem(.separator())
        if onArchive != nil {
            let archiveItem = NSMenuItem(title: "Archive", action: #selector(archiveFromMenu(_:)), keyEquivalent: "")
            archiveItem.target = self
            archiveItem.isEnabled = true
            menu.addItem(archiveItem)
        }
        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeFromMenu(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.isEnabled = true
        menu.addItem(closeItem)
        return menu
    }

    private func addRenameItem(to menu: NSMenu) {
        let renameItem = NSMenuItem(title: "Rename Tab", action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)
    }

    private func clickIsOnTitle(_ event: NSEvent) -> Bool {
        convert(event.locationInWindow, from: nil).x >= 36
    }

    @objc private func closeFromMenu(_ sender: Any?) {
        onClose?()
    }

    @objc private func archiveFromMenu(_ sender: Any?) {
        onArchive?()
    }

    @objc private func renameFromMenu(_ sender: Any?) {
        onRename?()
    }

    @objc private func newFolderFromMenu(_ sender: Any?) {
        onNewFolder?()
    }

    @objc private func removeFromFolderFromMenu(_ sender: Any?) {
        onRemoveFromFolder?()
    }

    @objc private func deleteFolderFromMenu(_ sender: Any?) {
        onDeleteFolder?()
    }

    @objc private func addToFolderFromMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        guard folderDestinations.indices.contains(index) else { return }
        folderDestinations[index].handler()
    }

    @objc private func splitWithActiveFromMenu(_ sender: Any?) {
        onSplitWithActive?()
    }

    @objc private func unsplitFromMenu(_ sender: Any?) {
        onUnsplit?()
    }

    private func beginTabDrag(current: NSEvent) {
        guard let tabID else { return }
        onPrepareDrag?()
        didStartDrag = true
        let ids = AppDelegate.current?.controllers[windowID]?.model.orderedDraggedTabIDs(grabbed: tabID)
        let payload = TabDragPayload(
            dragID: UUID(),
            tabID: tabID,
            sourceWindowID: windowID,
            tabIDs: ids?.isEmpty == false ? ids : [tabID]
        )
        activePayload = payload
        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(payload) {
            pasteboardItem.setData(data, forType: .prestelTab)
        }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let previewItems = dragPreviewItems(for: payload)
        let preview = TabDragPreview.image(
            items: previewItems,
            totalCount: payload.tabIDs.count,
            appearance: effectiveAppearance
        )
        let size = preview.size
        let rest = CGRect(
            x: TabDragPreview.iconLeading - TabDragPreview.canvasPadding,
            y: (bounds.height - TabDragPreview.height) / 2 - TabDragPreview.canvasPadding,
            width: size.width,
            height: size.height
        )
        item.setDraggingFrame(rest, contents: preview)
        let session = beginDraggingSession(with: [item], event: current, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .default
    }

    private func dragPreviewItems(for payload: TabDragPayload) -> [TabDragPreview.Item] {
        guard let model = AppDelegate.current?.controllers[windowID]?.model else {
            return [.init(title: titleText, symbol: symbol)]
        }
        let ordered = [payload.tabID] + payload.tabIDs.filter { $0 != payload.tabID }
        return ordered.compactMap { id in
            guard let tab = model.tab(id: id) else { return nil }
            return TabDragPreview.Item(
                title: tab.displayTitle,
                symbol: tab.kind == .settings ? "gearshape.fill" : "terminal"
            )
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        didStartDrag = true
        guard let tabID else { return }
        let payload = activePayload ?? TabDragPayload(
            dragID: UUID(),
            tabID: tabID,
            sourceWindowID: windowID,
            tabIDs: AppDelegate.current?.controllers[windowID]?.model.orderedDraggedTabIDs(grabbed: tabID)
        )
        TabDragCoordinator.shared.begin(payload: payload, at: screenPoint, session: session)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        TabDragCoordinator.shared.updatePointer(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let sourceID = windowID
        if didStartDrag {
            TabDragCoordinator.shared.finish(at: screenPoint)
        }
        didStartDrag = false
        mouseDownEvent = nil
        activePayload = nil
        // A drop back onto the row is a no-op, but the drag still took first
        // responder. Put the shell back before the next keystroke.
        DispatchQueue.main.async {
            AppDelegate.current?.controllers[sourceID]?.focusTerminal()
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.prestelTab]) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.availableType(from: [.prestelTab]) != nil else { return false }
        return !TabDragCoordinator.shared.shouldAnimateReturn
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    private func setHover(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        onHover?(value)
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
        hoverSync?.cancel()
        let work = DispatchWorkItem {
            TabDragCoordinator.shared.syncHoveredRowToCursor()
        }
        hoverSync = work
        DispatchQueue.main.async(execute: work)
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
