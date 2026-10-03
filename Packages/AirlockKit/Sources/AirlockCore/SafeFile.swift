import Darwin
import Foundation

/// File access inside folders the agent can write to (its config, its event log, its
/// checkout). The agent controls everything below `root`, so a path there may be a symlink
/// to anywhere on the Mac, a FIFO that never answers, or a file of any size. These calls never
/// follow a symlink below `root`, only read regular files, never block on open, and cap reads.
/// `root` itself is AIrlock's own folder and is trusted.
public enum SafeFile {
    /// An open regular file and its size when opened.
    public struct Opened {
        public let handle: FileHandle
        public let size: UInt64
    }

    /// True for a relative path whose every component is a plain name: no `..`, `.`, empty
    /// parts or leading `/`. Without symlinks, such a path can't leave the folder it's in.
    public static func isConfined(_ relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else { return false }
        return relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// `path` relative to `root`, when it's lexically inside it and confined.
    public static func relativePath(_ path: String, under root: String) -> String? {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return nil }
        let relative = String(path.dropFirst(base.count))
        return isConfined(relative) ? relative : nil
    }

    /// Opens a regular file below `root` without following any symlink on the way.
    public static func open(_ relative: String, in root: URL) -> Opened? {
        guard isConfined(relative) else { return nil }
        let dir = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        // O_NOFOLLOW_ANY refuses a symlink in any component; O_NONBLOCK keeps a FIFO from hanging the open.
        let fd = openat(dir, relative, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        // Reads from a regular file don't block; clear the flag so they behave normally.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        return Opened(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), size: UInt64(info.st_size))
    }

    /// Up to `limit` bytes from `offset`.
    public static func read(_ relative: String, in root: URL, from offset: UInt64 = 0, limit: Int) -> Data? {
        guard let file = open(relative, in: root) else { return nil }
        guard offset < file.size else { return Data() }
        try? file.handle.seek(toOffset: offset)
        return (try? file.handle.read(upToCount: limit)) ?? Data()
    }

    /// The last `limit` bytes (all of a smaller file).
    public static func readTail(_ relative: String, in root: URL, limit: Int) -> Data? {
        guard let file = open(relative, in: root) else { return nil }
        let start = file.size > UInt64(limit) ? file.size - UInt64(limit) : 0
        try? file.handle.seek(toOffset: start)
        return (try? file.handle.read(upToCount: limit)) ?? Data()
    }

    /// Replaces `name` in `dir` with `data`: written to a new file, then renamed over it.
    /// Whatever was there (a symlink included) is replaced, never written through.
    public static func write(_ data: Data, to name: String, in dir: URL, mode: mode_t = 0o644) throws {
        guard isConfined(name), !name.contains("/") else { throw SafeFileError("Bad file name \(name)") }
        let dirFD = Darwin.open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else { throw SafeFileError("Can't open \(dir.path)") }
        defer { close(dirFD) }
        let temp = ".airlock-\(UUID().uuidString.prefix(8)).tmp"
        let fd = openat(dirFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw SafeFileError("Can't create a file in \(dir.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlinkat(dirFD, temp, 0)
            throw error
        }
        guard renameat(dirFD, temp, dirFD, name) == 0 else {
            unlinkat(dirFD, temp, 0)
            throw SafeFileError("Can't replace \(name) in \(dir.path)")
        }
    }

    /// True when `name` in `dir` is a regular file (not a symlink to one).
    public static func isRegularFile(_ name: String, in dir: URL) -> Bool {
        var info = stat()
        return lstat(dir.appending(path: name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

public struct SafeFileError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
