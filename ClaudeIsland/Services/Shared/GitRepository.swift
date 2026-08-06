//
//  GitRepository.swift
//  ClaudeIsland
//
//  Reads the checked-out branch for a session's working directory
//

import Foundation

/// Reads git state straight off disk.
///
/// Deliberately avoids shelling out to `git`: the notch re-reads this for every
/// session on each status tick, and spawning a process per session per tick
/// would cost far more than reading a one-line file.
enum GitRepository {

    /// Current branch for the repository containing `path`.
    ///
    /// Returns a short commit hash when HEAD is detached, and nil when `path`
    /// is not inside a repository.
    static func currentBranch(at path: String) -> String? {
        guard let gitDir = gitDirectory(for: path) else { return nil }

        let headPath = gitDir.appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headPath, encoding: .utf8) else { return nil }

        let head = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        // Attached: "ref: refs/heads/<branch>"
        if head.hasPrefix("ref: ") {
            let ref = String(head.dropFirst("ref: ".count))
            if ref.hasPrefix("refs/heads/") {
                return String(ref.dropFirst("refs/heads/".count))
            }
            return URL(fileURLWithPath: ref).lastPathComponent
        }

        // Detached: HEAD holds the raw commit hash.
        guard head.count >= 7, head.allSatisfy(\.isHexDigit) else { return nil }
        return String(head.prefix(7))
    }

    // MARK: - Repository Discovery

    /// Locate the `.git` directory governing `path`, walking up to the root.
    private static func gitDirectory(for path: String) -> URL? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL

        // Bounded so a pathological path can't spin here.
        for _ in 0..<40 {
            let candidate = directory.appendingPathComponent(".git")

            if let resolved = resolve(dotGit: candidate) {
                return resolved
            }

            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }

        return nil
    }

    /// A `.git` entry is normally a directory, but in a worktree or submodule it
    /// is a file pointing at the real git dir.
    private static func resolve(dotGit url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return url
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: .newlines) {
            guard line.hasPrefix("gitdir:") else { continue }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }

            // The pointer may be relative to the directory holding `.git`.
            if target.hasPrefix("/") {
                return URL(fileURLWithPath: target)
            }
            return url.deletingLastPathComponent()
                .appendingPathComponent(target)
                .standardizedFileURL
        }

        return nil
    }
}
