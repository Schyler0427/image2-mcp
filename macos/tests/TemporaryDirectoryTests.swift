import Foundation
import Darwin

@main
private enum TemporaryDirectoryTests {
    static func main() throws {
        let fm = FileManager.default
        var base = fm.temporaryDirectory.appendingPathComponent("image2-safety-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        base = base.resolvingSymlinksInPath().standardizedFileURL
        let previousCwd = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(previousCwd); try? fm.removeItem(at: base) }
        let cwd = base.appendingPathComponent("working-directory", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: false)
        let sentinel = cwd.appendingPathComponent("keep.txt")
        try Data("keep working directory".utf8).write(to: sentinel)
        precondition(fm.changeCurrentDirectoryPath(cwd.path))

        for invalid in ["", ".", "..", "relative", "/", cwd.path, base.path,
                        base.path + "/../image2-launcher.abcdef", base.path + "/image2-launcher.",
                        base.path + "/image2-launcher.abcde", base.path + "/image2-launcher.abcdefg",
                        base.path + "/nested/image2-launcher.abcdef", base.path + "/image2-launcher.abc\0de"] {
            var refused = false
            do { _ = try LauncherPrivateDirectory.validatedURL(createdPath: invalid, parentURL: base) }
            catch { refused = true }
            precondition(refused, "unsafe cleanup path accepted")
        }

        for _ in 0..<200 {
            let directory = try LauncherPrivateDirectory(parentURL: base)
            let pressure = (0..<128).map { String(repeating: "allocation-pressure-\($0)", count: 8) }
            precondition(pressure.count == 128)
            precondition(directory.url.deletingLastPathComponent() == base)
            precondition(fm.fileExists(atPath: directory.url.path))
            try Data("temporary".utf8).write(to: directory.url.appendingPathComponent("test.txt"))
            directory.remove()
            precondition(!fm.fileExists(atPath: directory.url.path))
            let retainedSentinel = try Data(contentsOf: sentinel)
            precondition(retainedSentinel == Data("keep working directory".utf8))
        }

        let directory = try LauncherPrivateDirectory(parentURL: base)
        let moved = base.appendingPathComponent("original-directory", isDirectory: true)
        try fm.moveItem(at: directory.url, to: moved)
        try fm.createDirectory(at: directory.url, withIntermediateDirectories: false)
        let replacement = directory.url.appendingPathComponent("keep-replacement.txt")
        try Data("unrelated replacement".utf8).write(to: replacement)
        directory.remove()
        precondition(fm.fileExists(atPath: replacement.path), "cleanup removed another directory")
        try fm.removeItem(at: directory.url)
        try fm.createSymbolicLink(at: directory.url, withDestinationURL: cwd)
        directory.remove()
        let replacementDestination = try fm.destinationOfSymbolicLink(atPath: directory.url.path)
        precondition(replacementDestination == cwd.path)
        precondition(fm.fileExists(atPath: sentinel.path), "cleanup followed a replacement symlink")
        print("PASS: owned temporary directories, optimized buffer lifetime, unsafe-path refusal, cwd preservation and replacement refusal")
    }
}
