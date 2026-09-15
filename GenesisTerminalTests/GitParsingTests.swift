import Foundation
import Testing
@testable import GenesisTerminal

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
        #expect(!snapshot.isClean)
        #expect(snapshot.isComplete)
    }
}

enum GitFixture {
    static func make() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genesis-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitExecutable())
            process.currentDirectoryURL = root
            process.arguments = arguments
            process.environment = [
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_AUTHOR_NAME": "Genesis",
                "GIT_AUTHOR_EMAIL": "genesis@example.com",
                "GIT_COMMITTER_NAME": "Genesis",
                "GIT_COMMITTER_EMAIL": "genesis@example.com",
                "HOME": root.path
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitRunnerError.failed(status: process.terminationStatus, stderr: arguments.joined(separator: " "))
            }
        }
        try git(["init", "-b", "main"])
        try "base\n".write(toFile: root.appendingPathComponent("staged.txt").path, atomically: true, encoding: .utf8)
        try "base\n".write(toFile: root.appendingPathComponent("unstaged.txt").path, atomically: true, encoding: .utf8)
        try "base\n".write(toFile: root.appendingPathComponent("both.txt").path, atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-m", "base"])
        try "staged\n".write(toFile: root.appendingPathComponent("staged.txt").path, atomically: true, encoding: .utf8)
        try git(["add", "staged.txt"])
        try "unstaged\n".write(toFile: root.appendingPathComponent("unstaged.txt").path, atomically: true, encoding: .utf8)
        try "staged-both\n".write(toFile: root.appendingPathComponent("both.txt").path, atomically: true, encoding: .utf8)
        try git(["add", "both.txt"])
        try "unstaged-both\n".write(toFile: root.appendingPathComponent("both.txt").path, atomically: true, encoding: .utf8)
        try "new\n".write(toFile: root.appendingPathComponent("untracked.txt").path, atomically: true, encoding: .utf8)
        try "ignored\n".write(toFile: root.appendingPathComponent("skip.log").path, atomically: true, encoding: .utf8)
        try "*.log\n".write(toFile: root.appendingPathComponent(".gitignore").path, atomically: true, encoding: .utf8)
        return root.path
    }

    private static func gitExecutable() -> String {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/bin/git"
    }
}
