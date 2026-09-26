import SwiftUI

/// Window-sized host. The review column must not own this dialog, and the
/// shell must not observe review load-state or the side panels snap.
struct CommitDialogHost: View {
    @ObservedObject var model: CodeReviewModel

    var body: some View {
        ZStack {
            if model.commitDraft != nil, let snapshot = model.snapshot {
                CommitDialog(model: model, snapshot: snapshot)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(model.commitDraft != nil)
        .animation(.easeOut(duration: 0.16), value: model.commitDraft != nil)
    }
}

private enum CommitMetrics {
    static let cardWidth: CGFloat = 440
    static let cardRadius: CGFloat = 30
    static let cardPadding: CGFloat = 14
    static let sectionRadius: CGFloat = 20
    static let fieldRadius: CGFloat = 12
    static let buttonHeight: CGFloat = 38
    /// The blue of the reference’s primary button; the system accent can be any colour.
    static let buttonBlue = Color(red: 0.20, green: 0.47, blue: 0.86)
}

private struct CommitDialog: View {
    @ObservedObject var model: CodeReviewModel
    var snapshot: ReviewSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.30 : 0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.closeCommitComposer() }
                .accessibilityHidden(true)
            card
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageSection
            CommitActionPicker(selection: actionBinding, isDisabled: model.commitDraft?.isCommitting == true)
            filesSection
            if let guidance {
                Label {
                    Text(guidance)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            }
            commitButton
        }
        .padding(CommitMetrics.cardPadding)
        .frame(width: CommitMetrics.cardWidth)
        .background {
            RoundedRectangle(cornerRadius: CommitMetrics.cardRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.32) : Color.white.opacity(0.55))
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: CommitMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CommitMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.16), radius: 30, y: 16)
        .background {
            // Escape closes, as the old close button did.
            Button("Close") { model.closeCommitComposer() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.commitDraft?.isCommitting == true)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commit")
    }

    // MARK: Sections

    private var messageSection: some View {
        CommitSection {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: branchSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 20)
                    Text(branch)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    draftButton
                }
                Text("Files are committed from the working tree.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: messageBinding)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 7)
                        .disabled(isBusy)
                    if model.commitDraft?.message.isEmpty ?? true {
                        Text(model.commitDraft?.isGenerating == true ? "Drafting a message…" : "Commit message")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 104)
                .background {
                    RoundedRectangle(cornerRadius: CommitMetrics.fieldRadius, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: CommitMetrics.fieldRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                }

            }
        }
    }

    private var draftButton: some View {
        Button {
            model.draftCommitName()
        } label: {
            HStack(spacing: 5) {
                if model.commitDraft?.isGenerating == true {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("Draft")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 24)
        }
        .buttonStyle(CommitPrimaryButtonStyle())
        .disabled(generateDisabled)
        .help("Draft with Apple Intelligence")
    }

    private var filesSection: some View {
        CommitSection {
            VStack(alignment: .leading, spacing: 8) {
                fileHeader
                if snapshot.files.isEmpty {
                    Text("The working tree is clean.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshot.files) { file in
                                fileRow(file)
                            }
                        }
                        .padding(.trailing, scrollerLane)
                    }
                    .padding(.trailing, -scrollerLane)
                    .frame(height: listHeight)
                    .clipped()
                }
            }
        }
    }

    private var fileHeader: some View {
        let additions = snapshot.files.reduce(0) { $0 + $1.additions }
        let deletions = snapshot.files.reduce(0) { $0 + $1.deletions }
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 20)
            Text("\(snapshot.files.count) Changed File\(snapshot.files.count == 1 ? "" : "s")")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            Group {
                Text("+\(additions)")
                    .foregroundStyle(AppColors.reviewAddition)
                Text("−\(deletions)")
                    .foregroundStyle(AppColors.reviewDeletion)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private func fileRow(_ file: ChangedFile) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(kindColor(file))
                .frame(width: 6, height: 6)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.identityPath.display)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(file))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if file.comparisons.contains(where: { $0.additions != nil || $0.deletions != nil }) {
                Group {
                    Text("+\(file.additions)")
                        .foregroundStyle(AppColors.reviewAddition)
                    Text("−\(file.deletions)")
                        .foregroundStyle(AppColors.reviewDeletion)
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var commitButton: some View {
        Button {
            model.commitFromComposer()
        } label: {
            ZStack {
                if model.commitDraft?.isCommitting == true {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Text(model.commitDraft?.action.buttonTitle ?? "Commit")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: CommitMetrics.buttonHeight)
        }
        .buttonStyle(CommitPrimaryButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canSubmitCommit)
        .help("Commit (⌘↩)")
    }

    // MARK: Helpers

    private func kindColor(_ file: ChangedFile) -> Color {
        switch file.kind {
        case .untracked, .added: AppColors.reviewAddition
        case .deleted: AppColors.reviewDeletion
        default: Color.primary.opacity(0.35)
        }
    }

    private func subtitle(_ file: ChangedFile) -> String {
        if let old = file.oldPath?.display, old != file.identityPath.display {
            return "\(file.kind.title) · \(old)"
        }
        return file.kind.title
    }

    private var branch: String {
        if snapshot.revision.isDetached {
            let short = snapshot.revision.headOID.map { String($0.prefix(7)) } ?? "HEAD"
            return "Detached · \(short)"
        }
        if snapshot.revision.isUnborn {
            return "\(snapshot.revision.branchName ?? "main") · No commits yet"
        }
        return snapshot.revision.branchName ?? "—"
    }

    private var branchSymbol: String {
        snapshot.revision.isDetached ? "point.topleft.down.to.point.bottomright.curvepath" : "arrow.triangle.branch"
    }

    private var isBusy: Bool {
        model.commitDraft?.isGenerating == true || model.commitDraft?.isCommitting == true
    }

    private var generateDisabled: Bool {
        isBusy
    }

    /// Room for the vertical scroller, taken from the section’s trailing padding
    /// so the line counts stay aligned with the header.
    private var scrollerLane: CGFloat { 12 }

    private var listHeight: CGFloat {
        min(CGFloat(snapshot.files.count) * 38, 152)
    }

    private var guidance: String? {
        if let notice = model.commitDraft?.notice, !notice.isEmpty { return notice }
        return CommitPlanner.refusal(
            files: snapshot.files,
            push: model.commitDraft?.push ?? false,
            detached: snapshot.revision.isDetached,
            indexLocked: snapshot.waitingOnIndexLock,
            catalogComplete: snapshot.isComplete
        )
    }

    private var messageBinding: Binding<String> {
        Binding(
            get: { model.commitDraft?.message ?? "" },
            set: { model.updateCommitMessage($0) }
        )
    }

    private var actionBinding: Binding<CommitAction> {
        Binding(
            get: { model.commitDraft?.action ?? .commit },
            set: { model.updateCommitAction($0) }
        )
    }
}

/// A recessed rounded well inside the glass card.
private struct CommitSection<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: CommitMetrics.sectionRadius, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
            }
    }
}

/// Capsule segmented control: a recessed track with a raised white thumb.
private struct CommitActionPicker: View {
    @Binding var selection: CommitAction
    var isDisabled: Bool
    @Namespace private var thumb
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CommitAction.allCases) { action in
                segment(action)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)))
        .disabled(isDisabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Action")
    }

    private func segment(_ action: CommitAction) -> some View {
        let selected = selection == action
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selection = action
            }
        } label: {
            Text(action.title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if selected {
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct CommitPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                Capsule()
                    .fill(CommitMetrics.buttonBlue)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
