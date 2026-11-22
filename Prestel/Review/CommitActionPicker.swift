import AppKit
import QuartzCore
import SwiftUI

struct CommitActionPicker: NSViewRepresentable {
    @Binding var selection: CommitAction
    var isDisabled: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CommitActionPickerView {
        CommitActionPickerView(selection: selection)
    }

    func updateNSView(_ view: CommitActionPickerView, context: Context) {
        let binding = $selection
        view.onSelect = { binding.wrappedValue = $0 }
        view.update(selection: selection, enabled: isEnabled && !isDisabled, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommitActionPickerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: CommitActionPickerView.height)
    }
}

final class CommitActionPickerView: NSView {
    static let height: CGFloat = 36
    private static let inset: CGFloat = 3
    private let actions = CommitAction.allCases
    private let track = CALayer()
    private let pill = CALayer()
    private var buttons: [NSButton] = []
    private var selection: CommitAction
    private var enabled = true
    private var reduceMotion = false
    private var isTracking = false
    // In tab units: index + 0.5 is a segment's center.
    private var position: CGFloat
    private var target: CGFloat
    private var velocity: CGFloat = 0
    private var timer: Timer?
    private var lastStep: CFTimeInterval = 0
    var onSelect: ((CommitAction) -> Void)?

    init(selection: CommitAction) {
        self.selection = selection
        let center = Self.center(of: selection)
        position = center
        target = center
        super.init(frame: .zero)
        wantsLayer = true
        track.addSublayer(pill)
        layer?.insertSublayer(track, at: 0)
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowRadius = 2
        pill.shadowOffset = CGSize(width: 0, height: -1)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Action")
        buttons = actions.enumerated().map { index, action in
            let button = NSButton(title: action.title, target: self, action: #selector(chooseButton(_:)))
            button.isBordered = false
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.tag = index
            button.attributedTitle = NSAttributedString(string: action.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
            button.setAccessibilityLabel(action.title)
            button.setAccessibilityRole(.radioButton)
            addSubview(button)
            return button
        }
        updateButtons()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetMotion() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func update(selection: CommitAction, enabled: Bool, reduceMotion: Bool) {
        let changed = self.selection != selection
        let reset = (!enabled && self.enabled) || (reduceMotion && !self.reduceMotion)
        let refreshButtons = changed || self.enabled != enabled
        self.selection = selection
        self.enabled = enabled
        self.reduceMotion = reduceMotion
        if refreshButtons { updateButtons() }
        if reset || (changed && (reduceMotion || !enabled || window == nil)) {
            resetMotion()
        } else if changed && !isTracking {
            target = Self.center(of: selection)
            startMotion()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        CATransaction.commit()
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
        }
        placePill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, enabled, frame.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let index = index(for: event)
        if reduceMotion {
            choose(index)
        } else {
            isTracking = true
            target = CGFloat(index) + 0.5
            startMotion()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard enabled, isTracking else { return }
        let next = CGFloat(index(for: event)) + 0.5
        guard target != next else { return }
        target = next
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        startMotion()
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled, isTracking else { return }
        isTracking = false
        choose(Int(target))
    }

    private var segmentWidth: CGFloat { bounds.width / CGFloat(actions.count) }

    private static func center(of action: CommitAction) -> CGFloat {
        CGFloat(CommitAction.allCases.firstIndex(of: action) ?? 0) + 0.5
    }

    private func index(for event: NSEvent) -> Int {
        guard segmentWidth > 0 else { return 0 }
        let x = convert(event.locationInWindow, from: nil).x
        return min(max(Int((x / segmentWidth).rounded(.down)), 0), actions.count - 1)
    }

    @objc private func chooseButton(_ sender: NSButton) { choose(sender.tag) }

    private func choose(_ index: Int) {
        guard enabled, actions.indices.contains(index) else { return }
        onSelect?(actions[index])
    }

    private func updateButtons() {
        for (index, button) in buttons.enumerated() {
            let selected = actions[index] == selection
            button.isEnabled = enabled
            button.setAccessibilityValue(selected)
        }
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(dark ? 0.08 : 0.06).cgColor
        }
        pill.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.16 : 1).cgColor
        pill.shadowOpacity = dark ? 0.3 : 0.1
        CATransaction.commit()
    }

    private func placePill() {
        let height = max(0, bounds.height - 2 * Self.inset)
        let stretch = min(0.45, abs(velocity) * 0.035)
        let width = max(0, segmentWidth - 2 * Self.inset) * (1 + stretch)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: position * segmentWidth - width / 2, y: Self.inset, width: width, height: height)
        pill.cornerRadius = height / 2
        CATransaction.commit()
    }

    private func resetMotion() {
        stopMotion()
        isTracking = false
        position = Self.center(of: selection)
        target = position
        velocity = 0
        placePill()
    }

    private func startMotion() {
        guard timer == nil, position != target || velocity != 0 else { return }
        lastStep = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.step()
            }
        }
        // Keep stepping while AppKit is tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopMotion() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        // Lume's damped spring retains velocity when the pointer retargets it.
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastStep, 1.0 / 30.0))
        lastStep = now
        let stiffness: CGFloat = 420
        let damping = 2 * 0.72 * stiffness.squareRoot()
        velocity += (stiffness * (target - position) - damping * velocity) * dt
        position += velocity * dt
        if abs(target - position) < 0.002, abs(velocity) < 0.016 {
            position = target
            velocity = 0
            stopMotion()
        }
        placePill()
    }
}
