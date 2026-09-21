import Darwin
import XCTest
@testable import MenubarCalendar

/// Tests for the process-singleton hand-off: the wire format Chrome expects,
/// resolving the socket the `SingletonSocket` symlink points at, and the
/// accept/refuse paths. A tiny local socket server stands in for Chrome, so
/// none of this needs a browser installed.
final class ChromeSingletonTests: XCTestCase {

    // MARK: - Wire format

    func testPayloadIsStartTokenThenDirectoryThenArguments() {
        let payload = ChromeSingleton.payload(
            currentDirectory: "/tmp",
            arguments: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                        "--profile-directory=Profile 1",
                        "https://meet.google.com/abc-defg-hij"]
        )
        let fields = payload.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(fields, [
            "START",
            "/tmp",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--profile-directory=Profile 1",
            "https://meet.google.com/abc-defg-hij",
        ])
    }

    // MARK: - Locating the socket

    func testSocketPathFollowsTheSingletonSymlink() throws {
        let directory = try makeTemporaryDirectory()
        let socket = directory.appendingPathComponent("elsewhere.sock")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("SingletonSocket"), withDestinationURL: socket
        )
        XCTAssertEqual(ChromeSingleton.socketPath(inUserDataDirectory: directory), socket.path)
    }

    func testSocketPathIsNilWhenChromeNeverRan() throws {
        let directory = try makeTemporaryDirectory()
        XCTAssertNil(ChromeSingleton.socketPath(inUserDataDirectory: directory))
    }

    // MARK: - Hand-off

    func testSendDeliversTheCommandLineAndAcceptsACK() throws {
        let server = try FakeSingletonServer(reply: "ACK")
        defer { server.stop() }

        let sent = ChromeSingleton.send(
            arguments: ["chrome", "--profile-directory=Default", "https://example.com"],
            currentDirectory: "/tmp",
            socketPath: server.path
        )

        XCTAssertTrue(sent)
        server.waitForRequest()
        XCTAssertEqual(
            server.received,
            ChromeSingleton.payload(
                currentDirectory: "/tmp",
                arguments: ["chrome", "--profile-directory=Default", "https://example.com"]
            )
        )
    }

    /// Chrome answers `SHUTDOWN` while it is quitting: it did not take the URL,
    /// so the caller has to launch a fresh instance instead.
    func testSendFailsWhenTheInstanceIsShuttingDown() throws {
        let server = try FakeSingletonServer(reply: "SHUTDOWN")
        defer { server.stop() }
        XCTAssertFalse(
            ChromeSingleton.send(arguments: ["chrome"], currentDirectory: "/tmp", socketPath: server.path)
        )
    }

    /// A leftover socket file from a crashed Chrome: connecting fails fast.
    func testSendFailsWhenNothingIsListening() {
        let stale = "/tmp/mbc-missing-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertFalse(
            ChromeSingleton.send(arguments: ["chrome"], currentDirectory: "/tmp", socketPath: stale)
        )
    }

    func testSendFailsWhenTheSocketPathIsTooLongForSunPath() {
        let tooLong = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertFalse(
            ChromeSingleton.send(arguments: ["chrome"], currentDirectory: "/tmp", socketPath: tooLong)
        )
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mbc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// A one-shot `AF_UNIX` server that mimics Chrome's singleton: it reads until
/// the client half-closes, then answers with `reply`.
private final class FakeSingletonServer {
    let path: String

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "fake-singleton-server")
    private let handled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _received = Data()

    var received: Data {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    init(reply: String) throws {
        path = "/tmp/mbc-\(UUID().uuidString.prefix(8)).sock"
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EBADF) }

        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) {
                _ = strlcpy($0, path, capacity)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else { throw POSIXError(.EADDRINUSE) }

        queue.async { [listenFD, handled, lock] in
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { handled.signal(); return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                lock.lock(); self._received.append(contentsOf: buffer[0..<count]); lock.unlock()
            }
            _ = reply.withCString { write(client, $0, strlen($0)) }
            close(client)
            handled.signal()
        }
    }

    func waitForRequest(timeout: TimeInterval = 2) {
        _ = handled.wait(timeout: .now() + timeout)
    }

    func stop() {
        close(listenFD)
        unlink(path)
    }
}
