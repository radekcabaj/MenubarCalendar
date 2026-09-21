import Darwin
import Foundation

/// Hands a command line to the Chrome that is *already* running, over the
/// "process singleton" socket in its user-data directory.
///
/// This is how `--profile-directory=<dir>` reaches a live browser. Launching
/// the Chrome binary does the same thing — the second process forwards its
/// command line and exits immediately — but macOS still counts that as an app
/// launch, so the Dock keeps a second "Google Chrome" tile (in `recent-apps`)
/// next to the pinned one. Talking to the socket ourselves keeps everything in
/// the one running process, and the Dock never notices.
///
/// Protocol, from Chromium's `process_singleton_posix.cc`: `SingletonSocket` in
/// the user-data directory is a symlink to the real socket; a client sends
/// `"START" \0 <current dir> \0 <argv0> \0 <argv1> …`, half-closes, and waits
/// for `ACK`. Anything else — `SHUTDOWN` from a browser that is quitting, a
/// refused connection from a socket a crashed Chrome left behind, no symlink at
/// all — means the command line was *not* taken and the caller must fall back
/// to launching Chrome.
enum ChromeSingleton {
    private static let startToken = "START"
    private static let ackToken = "ACK"
    private static let separator: UInt8 = 0
    /// `sockaddr_un.sun_path` is a fixed 104-byte field on Darwin.
    private static let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// The bytes for one command line, in the order Chrome parses them.
    static func payload(currentDirectory: String, arguments: [String]) -> Data {
        var payload = Data(startToken.utf8)
        for field in [currentDirectory] + arguments {
            payload.append(separator)
            payload.append(contentsOf: field.utf8)
        }
        return payload
    }

    /// The socket `<userDataDirectory>/SingletonSocket` points at, or nil when
    /// Chrome has never run with this directory.
    static func socketPath(inUserDataDirectory directory: URL) -> String? {
        let link = directory.appendingPathComponent("SingletonSocket").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            return nil
        }
        if target.hasPrefix("/") { return target }
        return directory.appendingPathComponent(target).path
    }

    /// Send `arguments` (argv, so element 0 is the Chrome binary) to the
    /// instance listening on `socketPath`. Returns true only on `ACK`, i.e.
    /// when the running browser has taken over the command line.
    ///
    /// Everything here is bounded by `timeout` because it runs on the main
    /// thread when the user hits "join": the socket is local and Chrome answers
    /// in milliseconds, but a wedged browser must not freeze the menu bar.
    @discardableResult
    static func send(
        arguments: [String],
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        socketPath: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        // +1 for the terminating NUL `strlcpy` writes.
        guard socketPath.utf8.count + 1 <= sunPathCapacity else { return false }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // Without SO_NOSIGPIPE, writing to a socket Chrome just closed would
        // kill the app rather than return an error.
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) {
                _ = strlcpy($0, socketPath, sunPathCapacity)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        guard writeAll(descriptor, payload(currentDirectory: currentDirectory, arguments: arguments)) else {
            return false
        }
        shutdown(descriptor, SHUT_WR) // Chrome reads the command line until EOF.

        let expected = Data(ackToken.utf8)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64)
        while response.count < expected.count {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(contentsOf: buffer[0..<count])
        }
        return response.starts(with: expected)
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, base.advanced(by: written), bytes.count - written)
                if count <= 0 { return false }
                written += count
            }
            return true
        }
    }
}
