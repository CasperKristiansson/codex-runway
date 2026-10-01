import Darwin
import Foundation

/// Opens the credential directory once and uses relative, no-follow operations.
/// The temporary replacement is private from creation, then renamed atomically.
struct CodexAuthFile {
    let home: URL

    static var defaultHome: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Serialize manual operations across multiple Runway instances. Codex does
    /// not take this lock, so process and compare-before-replace guards remain.
    func acquireOperationLock() throws -> FileHandle {
        let directory = try openDirectory()
        defer { close(directory) }
        let descriptor = openat(directory, ".runway-auth-switch.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw LoginSwitchError.unsafeFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw LoginSwitchError.unsafeFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LoginSwitchError.refreshRunning
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func read() throws -> Data? {
        let directory = try openDirectory()
        defer { close(directory) }
        return try read(directory: directory)
    }

    func replace(with data: Data?, expecting expected: Data?, assertClosed: () throws -> Void) throws {
        let directory = try openDirectory()
        defer { close(directory) }
        let temporary = ".runway-auth-\(UUID().uuidString).tmp"
        defer { unlinkat(directory, temporary, 0) }
        if let data {
            let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw LoginSwitchError.fileOperationFailed }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                guard fsync(descriptor) == 0 else { throw LoginSwitchError.fileOperationFailed }
                try handle.close()
            } catch {
                try? handle.close()
                throw LoginSwitchError.fileOperationFailed
            }
        }
        try assertClosed()
        guard try read(directory: directory) == expected else { throw LoginSwitchError.credentialsChanged }
        if data != nil {
            guard renameat(directory, temporary, directory, "auth.json") == 0 else { throw LoginSwitchError.fileOperationFailed }
        } else if unlinkat(directory, "auth.json", 0) != 0 && errno != ENOENT {
            throw LoginSwitchError.fileOperationFailed
        }
        // The rename is the commit point. A directory fsync failure must not be
        // reported as an uncommitted write or cause the wrong rollback decision.
        _ = fsync(directory)
    }

    private func openDirectory() throws -> Int32 {
        let directory = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LoginSwitchError.unsafeFile }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(directory)
            throw LoginSwitchError.unsafeFile
        }
        return directory
    }

    private func read(directory: Int32) throws -> Data? {
        let descriptor = openat(directory, "auth.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LoginSwitchError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 1_048_576 else { throw LoginSwitchError.unsafeFile }
        guard let data = try handle.read(upToCount: 1_048_577), data.count == info.st_size else {
            throw LoginSwitchError.unsafeFile
        }
        return data
    }
}
