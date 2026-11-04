import Darwin
import Foundation

struct EncryptedStore: Sendable {
    static let maximumFileSize = 16 * 1024 * 1024
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func readSealed() throws -> Data {
        // O_NONBLOCK prevents a selected FIFO from hanging before fstat.
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw StorageError.notRegularFile }
        guard info.st_size <= Self.maximumFileSize else { throw StorageError.fileTooLarge }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return result }
            // Also bound a file that grows after fstat.
            guard count <= Self.maximumFileSize - result.count else { throw StorageError.fileTooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func saveSealed(_ data: Data, createOnly: Bool = false) throws {
        guard data.count <= Self.maximumFileSize else { throw StorageError.fileTooLarge }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let directoryFD = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard directoryFD >= 0 else { throw posixError() }
        defer { Darwin.close(directoryFD) }

        // The temporary file starts private, and only ever contains ciphertext.
        // Directory-relative operations keep this write attached to the opened
        // directory even if a path component changes concurrently.
        let temporaryName = ".tinystash-\(UUID().uuidString).tmp"
        let fileFD = Darwin.openat(
            directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600
        )
        guard fileFD >= 0 else { throw posixError() }
        var needsClose = true
        defer {
            if needsClose { Darwin.close(fileFD) }
            _ = Darwin.unlinkat(directoryFD, temporaryName, 0)
        }
        guard Darwin.fchmod(fileFD, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    fileFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard written > 0 else { throw StorageError.incompleteWrite }
                offset += written
            }
        }
        guard Darwin.fsync(fileFD) == 0 else { throw posixError() }
        let closeResult = Darwin.close(fileFD)
        needsClose = false
        guard closeResult == 0 else { throw posixError() }
        if createOnly {
            // A hard-link publication is atomic and refuses every existing
            // destination, including symlinks. The defer removes our temp name.
            guard Darwin.linkat(directoryFD, temporaryName, directoryFD, url.lastPathComponent, 0) == 0 else {
                throw posixError()
            }
        } else {
            guard Darwin.renameat(directoryFD, temporaryName, directoryFD, url.lastPathComponent) == 0 else {
                throw posixError()
            }
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
}

private enum StorageError: LocalizedError {
    case incompleteWrite
    case notRegularFile
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .incompleteWrite: "The encrypted file could not be written completely."
        case .notRegularFile: "Choose a regular encrypted file, not a folder or device."
        case .fileTooLarge: "Tiny Stash supports encrypted files up to 16 MiB. Reduce the note size or copy the text somewhere safe."
        }
    }
}
