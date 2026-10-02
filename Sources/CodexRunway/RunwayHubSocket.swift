import Darwin
import Foundation

/// Newline-framed JSON over a user-private Unix socket. No TCP listener and no
/// credentials on this channel. Blocking I/O runs off the main actor, with a
/// maximum of four clients, deadlines, peer UID checks and fixed frame limits.
final class RunwayHubSocket: @unchecked Sendable {
    private let listener: Int32
    private let lockFD: Int32
    private let path: String
    private let handler: @Sendable (Data) async -> Data
    private let lock = NSLock()
    private var stopped = false
    private var clients = 0
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Runway/Bridge", isDirectory: true)
    }
    static var socketPath: String { directory.appendingPathComponent("hub-v1.sock").path }

    init(path: String = RunwayHubSocket.socketPath, handler: @escaping @Sendable (Data) async -> Data) throws {
        self.path = path; self.handler = handler
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) { try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else { throw HubError.invalid }
        guard chmod(directory, 0o700) == 0 else { throw HubError.invalid }
        let lease = Darwin.open(directory + "/listener.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw HubError.invalid }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lease); throw HubError.busy }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Darwin.close(lease); throw HubError.invalid }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); Darwin.close(lease); throw HubError.invalid }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // Only the exclusive lease owner may remove a stale socket.
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { Darwin.close(fd); Darwin.close(lease); throw HubError.invalid }
            unlink(path)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { Darwin.close(fd); Darwin.close(lease); unlink(path); throw HubError.invalid }
        listener = fd; lockFD = lease
    }
    func start() {
        DispatchQueue(label: "runway.hub.accept", qos: .utility).async { [self] in
            while true {
                lock.lock(); let done = stopped; lock.unlock()
                if done { break }
                let client = accept(listener, nil, nil)
                if client < 0 { continue }
                lock.lock()
                let admitted = !stopped && clients < 4
                if admitted { clients += 1 }
                lock.unlock()
                guard admitted else { Darwin.close(client); continue }
                DispatchQueue.global(qos: .utility).async { [self] in serve(client) }
            }
        }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
        Darwin.close(lockFD)
    }
    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd); lock.lock(); clients -= 1; lock.unlock() }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while data.count <= 16_384 {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                guard newline == data.count - 1, newline <= 16_384 else { return }
                let input = Data(data.prefix(newline))
                let semaphore = DispatchSemaphore(value: 0)
                let box = ReplyBox()
                Task { box.set(await handler(input)); semaphore.signal() }
                guard semaphore.wait(timeout: .now() + 5) == .success, let reply = box.get(), reply.count <= 4_194_304 else { return }
                let output = reply + Data([10])
                output.withUnsafeBytes { bytes in
                    var sent = 0
                    while sent < bytes.count {
                        let count = send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, MSG_NOSIGNAL)
                        if count <= 0 { break }
                        sent += count
                    }
                }
                return
            }
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
}
