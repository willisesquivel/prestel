import CoreGraphics
import Foundation

enum ReviewBudgets {
    static let preferredWidth: Double = 420
    static let minimumWidth: Double = 256
    static let maximumWidth: Double = 720
    static let automaticPatchBytes = 1 * 1024 * 1024
    static let automaticChangedLines = 10_000
    static let explicitPatchBytes = 8 * 1024 * 1024
    static let explicitDisplayedLines = 50_000
    static let sourceSnapshotBytes = 8 * 1024 * 1024
    static let highlightBytes = 256 * 1024
    static let highlightLines = 5_000
    static let highlightCharactersPerLine = 5_000
    static let contentCacheBytes = 64 * 1024 * 1024
    static let presentationCacheCount = 8
    static let statusOutputBytes = 8 * 1024 * 1024
    static let statusChangedEntries = 20_000
    static let discoveryTimeout: Duration = .seconds(5)
    static let operationTimeout: Duration = .seconds(15)
    static let gitConcurrency = 2
    static let watcherDebounceNanoseconds: UInt64 = 500_000_000
    static let watcherMaxCoalesceNanoseconds: UInt64 = 2_000_000_000
    static let indexLockWaitNanoseconds: UInt64 = 5_000_000_000
    static let safetyRefreshNanoseconds: UInt64 = 30_000_000_000
    static let watcherFallbackNanoseconds: UInt64 = 5_000_000_000
    static let contextLines = 3
    static let commitTimeout: Duration = .seconds(60)
    static let pushTimeout: Duration = .seconds(120)
    static let commitDiffBytes = 8 * 1024 * 1024
    static let revealMoreLines = 20
    static let intralinePairLimit = 20
    static let intralineCharacterLimit = 2_000
}

struct ReviewPath: Hashable, Sendable, Equatable {
    var display: String
    var bytes: [UInt8]
    var isLossless: Bool

    init(display: String, bytes: [UInt8], isLossless: Bool) {
        self.display = display
        self.bytes = bytes
        self.isLossless = isLossless
    }

    static func from(_ data: Data) -> ReviewPath {
        if let string = String(data: data, encoding: .utf8) {
            return ReviewPath(display: string, bytes: Array(data), isLossless: true)
        }
        let escaped = data.map { String(format: "\\x%02x", $0) }.joined()
        return ReviewPath(display: escaped, bytes: Array(data), isLossless: false)
    }

    static func from(_ string: String) -> ReviewPath {
        ReviewPath(display: string, bytes: Array(string.utf8), isLossless: true)
    }

    var basename: String { (display as NSString).lastPathComponent }
    var parent: String { (display as NSString).deletingLastPathComponent }
}

struct ReviewContext: Hashable, Sendable {
    var windowID: UUID
    var sessionID: UUID
    var directory: String
    var generation: UInt64
}

struct RepositoryKey: Hashable, Sendable {
    var worktreeRoot: String
    var gitDirectory: String
    var commonGitDirectory: String

    var basename: String { (worktreeRoot as NSString).lastPathComponent }
}

struct RepositoryRevision: Hashable, Sendable {
    var key: RepositoryKey
    var headOID: String?
    var branchName: String?
    var isDetached: Bool
    var isUnborn: Bool
    var indexFingerprint: String
    var generation: UInt64
}

enum FileChangeKind: String, Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case conflicted
    case symlink
    case submodule
    case typeChange
    case untracked
    case modeChange
}

enum FileComparisonKind: String, Sendable, Equatable, CaseIterable {
    case staged
    case unstaged
    case untracked
    case conflict
}

enum ReviewFilter: String, Sendable, CaseIterable, Identifiable {
    case all
    case staged
    case unstaged
    case untracked
    case conflicts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        case .conflicts: "Conflicts"
        }
    }
}

struct ComparisonSummary: Hashable, Sendable {
    var kind: FileComparisonKind
    var additions: Int?
    var deletions: Int?
    var isBinary: Bool
    var oldPath: ReviewPath?
    var newPath: ReviewPath
    var oldMode: String?
    var newMode: String?
    var oldOID: String?
    var newOID: String?
}

struct ChangedFile: Hashable, Sendable, Identifiable {
    var id: String { identityPath.display }
    var identityPath: ReviewPath
    var kind: FileChangeKind
    var comparisons: [ComparisonSummary]
    var oldPath: ReviewPath?

    var additions: Int { comparisons.compactMap(\.additions).reduce(0, +) }
    var deletions: Int { comparisons.compactMap(\.deletions).reduce(0, +) }
    var hasBinaryComparison: Bool { comparisons.contains(where: \.isBinary) }

    func matches(_ filter: ReviewFilter) -> Bool {
        switch filter {
        case .all: true
        case .staged: comparisons.contains { $0.kind == .staged }
        case .unstaged: comparisons.contains { $0.kind == .unstaged }
        case .untracked: comparisons.contains { $0.kind == .untracked }
        case .conflicts: kind == .conflicted || comparisons.contains { $0.kind == .conflict }
        }
    }

    var metadataLabel: String {
        let status = kind.title
        let lanes = comparisons.map(\.kind.shortTitle)
        if lanes.isEmpty { return status }
        if lanes.count == 1 { return "\(status) · \(lanes[0])" }
        if Set(lanes) == ["Staged", "Unstaged"] { return "\(status) · Staged + unstaged" }
        return "\(status) · \(lanes.joined(separator: " + "))"
    }
}

extension FileChangeKind {
    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .conflicted: "Conflicted"
        case .symlink: "Symlink"
        case .submodule: "Submodule"
        case .typeChange: "Type change"
        case .untracked: "Untracked"
        case .modeChange: "Mode change"
        }
    }
}

extension FileComparisonKind {
    var shortTitle: String {
        switch self {
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        case .conflict: "Conflict"
        }
    }

    var subtitle: String {
        switch self {
        case .staged: "HEAD → Index diff"
        case .unstaged: "Index → Working tree diff"
        case .untracked: "New file"
        case .conflict: "Working-file preview"
        }
    }
}

enum DiffLineKind: Sendable, Equatable {
    case context
    case addition
    case deletion
}

struct DiffLine: Hashable, Sendable {
    var kind: DiffLineKind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
    var missingNewline: Bool
}

struct DiffHunk: Hashable, Sendable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var header: String
    var lines: [DiffLine]
}

enum FileDiffLimitation: Sendable, Equatable, Hashable {
    case none
    case large(reason: String)
    case binary
    case unsupportedEncoding
    case truncated
    case symlink(target: String)
    case submodule(summary: String)
    case conflictPreview
    case modeOnly
}

struct SourceSnapshot: Hashable, Sendable {
    var identity: String
    var text: String?
    var data: Data
    var isBinary: Bool
    var hasTrailingNewline: Bool
    var exceedsBudget: Bool
}

struct FileDiff: Hashable, Sendable {
    var fileID: String
    var comparison: FileComparisonKind
    var revision: String
    var hunks: [DiffHunk]
    var oldSource: SourceSnapshot?
    var newSource: SourceSnapshot?
    var limitation: FileDiffLimitation
    var patchText: String
    var additions: Int
    var deletions: Int
}

struct ReviewSnapshot: Hashable, Sendable {
    var revision: RepositoryRevision
    var files: [ChangedFile]
    var additions: Int
    var deletions: Int
    var isComplete: Bool
    var isClean: Bool
    var isBare: Bool
    var waitingOnIndexLock: Bool
    var diagnostic: String?

    var uniqueFileCount: Int { files.count }
}

enum ReviewLoadState: Sendable, Equatable {
    case hidden
    case resolving
    case loading
    case ready
    case noRepository
    case noWorkingTree
    case unavailable(String)
    case error(String)
    case waitingForGit
    case noTerminal
}

struct ReviewPresentationState: Sendable {
    var filter: ReviewFilter = .all
    var expandedFileIDs: Set<String> = []
    var collapsedFileIDs: Set<String> = []
    var revealedContext: [String: Set<Int>] = [:]
    var selectedFileID: String?
    var scrollAnchor: ReviewScrollAnchor?
    var horizontalOffset: CGFloat = 0
}

struct ReviewScrollAnchor: Hashable, Sendable {
    var fileID: String
    var comparison: FileComparisonKind?
    var lineKind: DiffLineKind?
    var oldNumber: Int?
    var newNumber: Int?
    var offsetInsideRow: CGFloat
}

struct SyntaxSpan: Hashable, Sendable {
    var utf16Start: Int
    var utf16Length: Int
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat
}

struct HighlightedSource: Hashable, Sendable {
    var identity: String
    var appearanceGeneration: UInt64
    var spans: [SyntaxSpan]
    /// UTF-16 offsets of each 1-based line start in the highlighted snapshot text.
    /// Used to convert file-absolute `SyntaxSpan` ranges onto a `DiffLine`.
    var lineStarts: [Int] = []
}

struct GitCommandRequest: Sendable {
    var identifier: UUID = UUID()
    var directory: String
    var arguments: [String]
    var timeout: Duration
    var outputLimit: Int
    var treatDiffExitAsSuccess: Bool
}

struct GitCommandResult: Sendable {
    var exitStatus: Int32
    var stdout: Data
    var stderr: Data
}

enum GitRunnerError: Error, Equatable, Sendable {
    case gitUnavailable(String)
    case timeout
    case cancelled
    case outputLimitExceeded
    case launchFailed(String)
    case failed(status: Int32, stderr: String)
}

protocol GitCommandExecuting: Sendable {
    func run(_ request: GitCommandRequest) async throws -> GitCommandResult
}

struct CommitMaterial: Sendable, Equatable {
    var diff: String
    var recentSubjects: [String]
}

enum CommitOutcome: Sendable, Equatable {
    case committed
    case committedPushFailed(String)
}

enum CommitAction: String, CaseIterable, Identifiable, Sendable {
    case commit
    case push
    case pullRequest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commit: "Commit"
        case .push: "Commit & Push"
        case .pullRequest: "Commit & PR"
        }
    }

    var buttonTitle: String {
        switch self {
        case .commit: "Commit"
        case .push: "Commit and Push"
        case .pullRequest: "Commit and Create Pull Request"
        }
    }

    var pushes: Bool { self != .commit }
}

struct CommitDraft: Equatable {
    var id = UUID()
    var message = ""
    var action: CommitAction = .commit
    var isGenerating = false
    var isCommitting = false
    var notice: String?
    var push: Bool { action.pushes }
}

protocol GitReviewServicing: Sendable {
    func resolveRepository(directory: String) async throws -> RepositoryKey?
    func loadCatalog(for key: RepositoryKey, generation: UInt64) async throws -> ReviewSnapshot
    func loadComparison(
        for key: RepositoryKey,
        file: ChangedFile,
        comparison: ComparisonSummary,
        generation: UInt64,
        loadLarge: Bool
    ) async throws -> FileDiff
    func commitMaterial(for key: RepositoryKey, paths: [String], untrackedPaths: [String]) async throws -> CommitMaterial
    func commit(in key: RepositoryKey, paths: [String], message: String, push: Bool) async throws -> CommitOutcome
    /// The remote’s page for opening a pull request from the current branch.
    func pullRequestURL(for key: RepositoryKey) async -> URL?
}

extension GitReviewServicing {
    func commitMaterial(for key: RepositoryKey, paths: [String], untrackedPaths: [String]) async throws -> CommitMaterial {
        CommitMaterial(diff: "", recentSubjects: [])
    }

    func commit(in key: RepositoryKey, paths: [String], message: String, push: Bool) async throws -> CommitOutcome {
        throw GitReviewServiceError.commitRejected("Commit is not available.")
    }

    func pullRequestURL(for key: RepositoryKey) async -> URL? { nil }
}

protocol RepositoryWatching: Sendable {
    func events(for key: RepositoryKey) -> AsyncStream<RepositoryInvalidation>
    func stop(_ key: RepositoryKey)
    func stopAll()
}

enum RepositoryInvalidation: Sendable, Equatable {
    case files([String])
    case metadata
    case rescan
    case indexLockChanged(locked: Bool)
}

struct ReviewLineSelection: Hashable, Sendable {
    var fileID: String
    var comparison: FileComparisonKind
    var revision: String
    var startRow: Int
    var endRow: Int
    var startUTF16: Int
    var endUTF16: Int

    var orderedBounds: (fromRow: Int, fromUTF16: Int, toRow: Int, toUTF16: Int) {
        if startRow < endRow {
            return (startRow, startUTF16, endRow, endUTF16)
        }
        if startRow > endRow {
            return (endRow, endUTF16, startRow, startUTF16)
        }
        return (startRow, min(startUTF16, endUTF16), endRow, max(startUTF16, endUTF16))
    }
}

func reviewDiffKey(_ fileID: String, _ comparison: FileComparisonKind) -> String {
    "\(fileID)|\(comparison.rawValue)"
}
