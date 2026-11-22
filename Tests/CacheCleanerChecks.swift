import Foundation

@main
struct CacheCleanerChecks {
    struct CheckFailure: Error {
        let message: String
    }

    private let identifier = "org.example.cache-cleaner-fixture"
    private let fm = FileManager.default

    static func main() {
        do {
            let checks = Self()
            try checks.checkOnlyUnchangedPreviewFilesAreRemoved()
            try checks.checkSymlinkSubstitutionDoesNotRedirectCleanup()
            print("Cache cleaner checks passed.")
        } catch let failure as CheckFailure {
            fail(failure.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Cache cleaner check failed: \(message)\n".utf8))
        exit(1)
    }

    private func checkOnlyUnchangedPreviewFilesAreRemoved() throws {
        try withFixture { home, caches, app in
            let eligible = app.appendingPathComponent("original.bin")
            let changed = app.appendingPathComponent("changed.bin")
            let later = app.appendingPathComponent("new-after-preview.bin")
            let outside = home.appendingPathComponent("outside.bin")
            let alias = app.appendingPathComponent("alias.bin")
            try Data([1]).write(to: eligible)
            try Data([2]).write(to: changed)
            try Data([3]).write(to: outside)
            try fm.createSymbolicLink(at: alias, withDestinationURL: outside)

            let unknown = caches.appendingPathComponent("Unknown", isDirectory: true)
            try fm.createDirectory(at: unknown, withIntermediateDirectories: false)
            let unknownFile = unknown.appendingPathComponent("data.bin")
            try Data([4]).write(to: unknownFile)

            let snapshot = try preview(at: caches)
            try require(snapshot.items.count == 1, "Expected one previewed application")
            try require(snapshot.skippedCount == 1, "Unknown cache root was not skipped")
            guard let item = snapshot.items.first else { throw CheckFailure(message: "Missing preview result") }
            try require(item.isPartial, "Symbolic link was not recorded as excluded")

            try Data([5, 6]).write(to: changed)
            try Data([7]).write(to: later)
            let result = CacheCleaner.clearFiles(from: item, at: caches)

            try require(result.removed == 1 && result.skipped == 1, "Incorrect removal or skip counts")
            try require(!fm.fileExists(atPath: eligible.path), "Original preview file was not removed")
            try require(Data(contentsOf: changed) == Data([5, 6]), "Modified file was changed")
            try require(Data(contentsOf: later) == Data([7]), "New file was changed")
            try require(Data(contentsOf: outside) == Data([3]), "Symbolic link target was changed")
            try require(Data(contentsOf: unknownFile) == Data([4]), "Unknown cache file was changed")
            _ = try fm.destinationOfSymbolicLink(atPath: alias.path)
        }
    }

    private func checkSymlinkSubstitutionDoesNotRedirectCleanup() throws {
        try withFixture { home, caches, app in
            let child = app.appendingPathComponent("nested", isDirectory: true)
            let outside = home.appendingPathComponent("unrelated", isDirectory: true)
            try fm.createDirectory(at: child, withIntermediateDirectories: false)
            try fm.createDirectory(at: outside, withIntermediateDirectories: false)
            let member = "cached.bin"
            try Data([1]).write(to: child.appendingPathComponent(member))
            try Data([2]).write(to: outside.appendingPathComponent(member))

            guard let item = try preview(at: caches).items.first else { throw CheckFailure(message: "Missing directory preview") }
            let moved = home.appendingPathComponent("previous-cache-dir", isDirectory: true)
            try fm.moveItem(at: child, to: moved)
            try fm.createSymbolicLink(at: child, withDestinationURL: outside)

            let result = CacheCleaner.clearFiles(from: item, at: caches)
            try require(result.removed == 0 && result.skipped == 1, "Substituted directory was not skipped")
            try require(Data(contentsOf: outside.appendingPathComponent(member)) == Data([2]), "Substitution target was changed")
            try require(Data(contentsOf: moved.appendingPathComponent(member)) == Data([1]), "Relocated cache was changed")
        }
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
    }

    private func preview(at caches: URL) throws -> CacheCleanupSnapshot {
        let owner = CacheCleaner.Owner(name: "Fixture App", bundleIdentifier: identifier, bundlePaths: [])
        return try CacheCleaner.preview(at: caches, owners: [identifier: owner], liveApps: [], processes: [])
    }

    private func withFixture(_ exercise: (URL, URL, URL) throws -> Void) throws {
        let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("cache-cleaner-tests-\(UUID().uuidString)", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let app = caches.appendingPathComponent(identifier, isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try exercise(home, caches, app)
    }
}
