import Foundation
import Testing
@testable import Prestel

@Suite
struct GitParsingTests {
    @Test func porcelainV2ParsesOrdinaryRenameUntrackedAndBranch() {
        var data = Data()
        data.append(contentsOf: Array("# branch.oid abcdef".utf8))
        data.append(0)
        data.append(contentsOf: Array("# branch.head main".utf8))
        data.append(0)
        data.append(contentsOf: Array("1 M. N... 100644 100644 100644 aaa bbb File.swift".utf8))
        data.append(0)
        data.append(contentsOf: Array("2 R. N... 100644 100644 100644 old new R100 New.swift".utf8))
        data.append(0)
        data.append(contentsOf: Array("Old.swift".utf8))
        data.append(0)
        data.append(contentsOf: Array("? untracked.txt".utf8))
        data.append(0)
        let parsed = GitStatusParser.parse(data)
        #expect(parsed.branch.head == "main")
        #expect(parsed.branch.oid == "abcdef")
        #expect(parsed.ordinary.count == 1)
        #expect(parsed.ordinary[0].path.display == "File.swift")
        #expect(parsed.renames.count == 1)
        #expect(parsed.renames[0].origPath.display == "Old.swift")
        #expect(parsed.renames[0].path.display == "New.swift")
        #expect(parsed.untracked.map(\.display) == ["untracked.txt"])
    }

    @Test func porcelainV2KeepsNewlinesInsideNulTerminatedPaths() {
        var data = Data()
        data.append(contentsOf: Array("? ".utf8))
        data.append(contentsOf: Array("weird\nname.txt".utf8))
        data.append(0)
        let parsed = GitStatusParser.parse(data)
        #expect(parsed.untracked.first?.display == "weird\nname.txt")
    }

    @Test func numstatParsesRenameAndBinaryRecords() {
        var data = Data()
        data.append(contentsOf: Array("12\t3\tFile.swift".utf8))
        data.append(0)
        data.append(contentsOf: Array("-\t-".utf8))
        data.append(0)
        data.append(contentsOf: Array("old.bin".utf8))
        data.append(0)
        data.append(contentsOf: Array("new.bin".utf8))
        data.append(0)
        let records = GitNumstatParser.parse(data)
        #expect(records.count == 2)
        #expect(records[0].additions == 12)
        #expect(records[0].deletions == 3)
        #expect(records[1].isBinary)
        #expect(records[1].origPath?.display == "old.bin")
        #expect(records[1].path.display == "new.bin")
    }

    @Test func unifiedDiffParsesHunksLineNumbersAndEOFMarker() throws {
        let patch = """
        diff --git a/File.swift b/File.swift
        --- a/File.swift
        +++ b/File.swift
        @@ -1,3 +1,4 @@
         keep
        -old
        +new
         tail
        \\ No newline at end of file

        """
        let parsed = try UnifiedDiffParser.parse(Data(patch.utf8))
        #expect(parsed.hunks.count == 1)
        let hunk = parsed.hunks[0]
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldCount == 3)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 4)
        #expect(hunk.lines.map(\.kind) == [.context, .deletion, .addition, .context])
        #expect(hunk.lines[1].oldNumber == 2)
        #expect(hunk.lines[2].newNumber == 2)
        #expect(hunk.lines[3].missingNewline)
        #expect(hunk.lines[1].text == "old")
        #expect(hunk.lines[2].text == "new")
    }

    @Test func unifiedDiffRejectsCombinedMergeDiffs() {
        let patch = "diff --cc File.swift\n"
        #expect(throws: UnifiedDiffParser.ParseError.combinedDiff) {
            try UnifiedDiffParser.parse(Data(patch.utf8))
        }
    }

    @Test func unifiedDiffParsesOmittedHunkCounts() throws {
        let patch = """
        @@ -1 +1,2 @@
        -only
        +one
        +two

        """
        let parsed = try UnifiedDiffParser.parse(Data(patch.utf8))
        #expect(parsed.hunks[0].oldCount == 1)
        #expect(parsed.hunks[0].newCount == 2)
    }

    @Test func catalogSeparatesStagedAndUnstagedLanes() {
        var data = Data()
        data.append(contentsOf: Array("# branch.head main\n# branch.oid abc\n".utf8))
        data.append(contentsOf: Array("1 MM N... 100644 100644 100644 h i Mixed.swift".utf8))
        data.append(0)
        let status = GitStatusParser.parse(data)
        var stagedData = Data()
        stagedData.append(contentsOf: Array("1\t1\tMixed.swift".utf8))
        stagedData.append(0)
        var unstagedData = Data()
        unstagedData.append(contentsOf: Array("2\t0\tMixed.swift".utf8))
        unstagedData.append(0)
        let files = GitRepositoryService.catalog(
            status: status,
            staged: GitNumstatParser.parse(stagedData),
            unstaged: GitNumstatParser.parse(unstagedData)
        )
        #expect(files.count == 1)
        #expect(files[0].comparisons.map(\.kind) == [.staged, .unstaged])
        #expect(files[0].additions == 3)
        #expect(files[0].metadataLabel.contains("Staged + unstaged"))
    }

    @Test func fixtureRepositoryProducesStagedUnstagedAndUntrackedFiles() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)
        let names = Set(snapshot.files.map(\.identityPath.display))
        #expect(names.contains("staged.txt"))
        #expect(names.contains("unstaged.txt"))
        #expect(names.contains("both.txt"))
        #expect(names.contains("untracked.txt"))
        let both = try #require(snapshot.files.first { $0.identityPath.display == "both.txt" })
        #expect(both.comparisons.map(\.kind) == [.staged, .unstaged])
        let untracked = try #require(snapshot.files.first { $0.identityPath.display == "untracked.txt" })
        #expect(untracked.additions == 1)
        #expect(untracked.deletions == 0)
        #expect(untracked.metadataLabel == "Untracked")
        #expect(!snapshot.isClean)
        #expect(snapshot.isComplete)
    }

    @Test func untrackedFilesCountLinesAndSkipBinaryAndEmptyFiles() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "one\ntwo\nthree\n".write(toFile: (root as NSString).appendingPathComponent("trailing.txt"), atomically: true, encoding: .utf8)
        try "alpha\nbeta".write(toFile: (root as NSString).appendingPathComponent("no-newline.txt"), atomically: true, encoding: .utf8)
        try "".write(toFile: (root as NSString).appendingPathComponent("empty.txt"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: root).appendingPathComponent("image.bin"))

        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)

        let trailing = try #require(snapshot.files.first { $0.identityPath.display == "trailing.txt" })
        #expect(trailing.additions == 3)
        #expect(trailing.deletions == 0)
        #expect(!trailing.hasBinaryComparison)

        let noNewline = try #require(snapshot.files.first { $0.identityPath.display == "no-newline.txt" })
        #expect(noNewline.additions == 2)
        #expect(noNewline.deletions == 0)

        let empty = try #require(snapshot.files.first { $0.identityPath.display == "empty.txt" })
        #expect(empty.additions == 0)
        #expect(empty.deletions == 0)

        let binary = try #require(snapshot.files.first { $0.identityPath.display == "image.bin" })
        #expect(binary.hasBinaryComparison)

        // Expanded untracked file should have no bogus trailing "unchanged lines" row.
        let comparison = try #require(trailing.comparisons.first)
        let diff = try await service.loadComparison(for: key, file: trailing, comparison: comparison, generation: 1, loadLarge: false)
        let rows = ReviewDocumentBuilder.bodyRows(
            file: trailing,
            diffs: [reviewDiffKey(trailing.id, comparison.kind): diff],
            presentation: ReviewPresentationState()
        )
        let foldedRows = rows.filter {
            if case .folded = $0 { return true }
            return false
        }
        #expect(foldedRows.isEmpty)
        #expect(diff.additions == 3)
    }

    @Test func stageAndUnstagePerFilePreserveWorkingTreeIncludingUnbornAndRenames() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))

        // Stage an untracked file and verify it moves to staged.
        try await service.stage(in: key, paths: ["untracked.txt"])
        var snapshot = try await service.loadCatalog(for: key, generation: 2)
        var untracked = try #require(snapshot.files.first { $0.identityPath.display == "untracked.txt" })
        #expect(untracked.isStaged)
        #expect(!untracked.hasUnstagedChanges)

        // Unstage it and verify it becomes untracked again without losing content.
        try await service.unstage(in: key, paths: untracked.unstagePaths, isUnborn: snapshot.revision.isUnborn)
        snapshot = try await service.loadCatalog(for: key, generation: 3)
        untracked = try #require(snapshot.files.first { $0.identityPath.display == "untracked.txt" })
        #expect(!untracked.isStaged)
        #expect(untracked.kind == .untracked)
        let content = try String(contentsOfFile: (root as NSString).appendingPathComponent("untracked.txt"), encoding: .utf8)
        #expect(content == "new\n")

        // Unstage a staged rename: both paths unstage cleanly and the renamed file stays on disk.
        try "keep me\n".write(toFile: (root as NSString).appendingPathComponent("orig.txt"), atomically: true, encoding: .utf8)
        try GitFixture.run(["add", "orig.txt"], in: root)
        try GitFixture.run(["commit", "-m", "add orig"], in: root)
        try GitFixture.run(["mv", "orig.txt", "renamed.txt"], in: root)
        snapshot = try await service.loadCatalog(for: key, generation: 4)
        let renamed = try #require(snapshot.files.first { $0.identityPath.display == "renamed.txt" })
        #expect(renamed.oldPath?.display == "orig.txt")
        try await service.unstage(in: key, paths: renamed.unstagePaths, isUnborn: snapshot.revision.isUnborn)
        snapshot = try await service.loadCatalog(for: key, generation: 5)
        let restoredDelete = try #require(snapshot.files.first { $0.identityPath.display == "orig.txt" })
        #expect(!restoredDelete.isStaged)
        let renamedUntracked = try #require(snapshot.files.first { $0.identityPath.display == "renamed.txt" })
        #expect(!renamedUntracked.isStaged)
        #expect(FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("renamed.txt")))

        // Unborn branch: staging then unstaging keeps the working-tree file untouched.
        let unbornRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prestel-unborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unbornRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unbornRoot) }
        try GitFixture.run(["init", "-b", "main"], in: unbornRoot.path)
        try "hello\n".write(toFile: unbornRoot.appendingPathComponent("first.txt").path, atomically: true, encoding: .utf8)
        let unbornKey = try #require(try await service.resolveRepository(directory: unbornRoot.path))
        try await service.stage(in: unbornKey, paths: ["first.txt"])
        var unbornSnap = try await service.loadCatalog(for: unbornKey, generation: 1)
        #expect(unbornSnap.revision.isUnborn)
        #expect(unbornSnap.files.first?.isStaged == true)
        try await service.unstage(in: unbornKey, paths: ["first.txt"], isUnborn: unbornSnap.revision.isUnborn)
        unbornSnap = try await service.loadCatalog(for: unbornKey, generation: 2)
        #expect(unbornSnap.files.first?.isStaged == false)
        #expect(unbornSnap.files.first?.kind == .untracked)
        #expect(try String(contentsOf: unbornRoot.appendingPathComponent("first.txt"), encoding: .utf8) == "hello\n")
    }
}

enum GitFixture {
    static func make() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prestel-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = root.path
        try run(["init", "-b", "main"], in: rootPath)
        try run(["config", "user.name", "Prestel"], in: rootPath)
        try run(["config", "user.email", "prestel@example.com"], in: rootPath)
        try run(["config", "commit.gpgsign", "false"], in: rootPath)
        try "base\n".write(toFile: root.appendingPathComponent("staged.txt").path, atomically: true, encoding: .utf8)
        try "base\n".write(toFile: root.appendingPathComponent("unstaged.txt").path, atomically: true, encoding: .utf8)
        try "base\n".write(toFile: root.appendingPathComponent("both.txt").path, atomically: true, encoding: .utf8)
        try run(["add", "."], in: rootPath)
        try run(["commit", "-m", "base"], in: rootPath)
        try "staged\n".write(toFile: root.appendingPathComponent("staged.txt").path, atomically: true, encoding: .utf8)
        try run(["add", "staged.txt"], in: rootPath)
        try "unstaged\n".write(toFile: root.appendingPathComponent("unstaged.txt").path, atomically: true, encoding: .utf8)
        try "staged-both\n".write(toFile: root.appendingPathComponent("both.txt").path, atomically: true, encoding: .utf8)
        try run(["add", "both.txt"], in: rootPath)
        try "unstaged-both\n".write(toFile: root.appendingPathComponent("both.txt").path, atomically: true, encoding: .utf8)
        try "new\n".write(toFile: root.appendingPathComponent("untracked.txt").path, atomically: true, encoding: .utf8)
        try "ignored\n".write(toFile: root.appendingPathComponent("skip.log").path, atomically: true, encoding: .utf8)
        try "*.log\n".write(toFile: root.appendingPathComponent(".gitignore").path, atomically: true, encoding: .utf8)
        return rootPath
    }

    static func run(_ arguments: [String], in root: String) throws {
        _ = try output(arguments, in: root)
    }

    static func output(_ arguments: [String], in root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutable())
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        process.arguments = arguments
        process.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "Prestel",
            "GIT_AUTHOR_EMAIL": "prestel@example.com",
            "GIT_COMMITTER_NAME": "Prestel",
            "GIT_COMMITTER_EMAIL": "prestel@example.com",
            "HOME": root
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitRunnerError.failed(status: process.terminationStatus, stderr: error.isEmpty ? arguments.joined(separator: " ") : error)
        }
        return text
    }

    private static func gitExecutable() -> String {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/bin/git"
    }
}
