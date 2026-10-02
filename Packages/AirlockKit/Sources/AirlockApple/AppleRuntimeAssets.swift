import AirlockCore
import CryptoKit
import Foundation

/// The Linux kernel and init filesystem Apple Containerization boots each VM with.
///
/// Uses the same Kata Containers kernel and `vminit` image that apple/container
/// ships with for containerization 0.47.0.
public struct AppleRuntimeAssets: Sendable {
    public static let kernelURL = URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")!
    public static let kernelDigest = "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
    public static let kernelMember = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"
    public static let kernelDownloadSize = "about 570 MB"
    public static let initImage = "ghcr.io/apple/containerization/vminit:0.47.0"

    public let root: URL

    public init(root: URL) { self.root = root }

    public var kernel: URL { root.appending(path: "kernel/vmlinux") }
    public var store: URL { root.appending(path: "store", directoryHint: .isDirectory) }
    public var specs: URL { root.appending(path: "specs", directoryHint: .isDirectory) }
    public var volumes: URL { root.appending(path: "volumes", directoryHint: .isDirectory) }

    public var hasKernel: Bool { FileManager.default.fileExists(atPath: kernel.path) }

    public static var hostSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Downloads the Kata release, verifies its digest and extracts the kernel.
    public func installKernel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (download, response) = try await URLSession.shared.download(from: Self.kernelURL, delegate: ProgressDelegate(progress))
        defer { try? fm.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EngineAssetError("Kernel download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }

        let digest = try Self.sha256(of: download)
        guard digest == Self.kernelDigest else {
            throw EngineAssetError("Kernel download didn't match the expected checksum.")
        }

        let staging = fm.temporaryDirectory.appending(path: "airlock-kernel-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await ProcessRunner.run("/usr/bin/tar", ["-x", "-f", download.path, "-C", staging.path, Self.kernelMember])

        // The member is a symlink in some releases; copy what it resolves to.
        let extracted = staging.appending(path: Self.kernelMember).resolvingSymlinksInPath()
        try? fm.removeItem(at: kernel)
        try fm.copyItem(at: extracted, to: kernel)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct EngineAssetError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Double) -> Void
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { progress(Double(written) / Double(total)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
