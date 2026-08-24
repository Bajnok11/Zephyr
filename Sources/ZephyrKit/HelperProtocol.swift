import Foundation

/// Shared constants and the tiny line protocol spoken between the app and the
/// root helper. Keeping it text-based means you can debug it with `nc`.
public enum HelperProtocol {
    public static let version = 1
    public static let label = "com.bence.zephyr.helper"
    public static let socketPath = "/var/run/zephyr-helper.sock"
    public static let installDirectory = "/Library/Application Support/Zephyr"
    public static var binaryPath: String { installDirectory + "/zephyr-helper" }
    public static var daemonPlistPath: String { "/Library/LaunchDaemons/\(label).plist" }

    /// If the helper hears nothing for this long it hands the fans back to macOS.
    public static let watchdogInterval: TimeInterval = 12

    public enum Command {
        case hello
        case ping
        case set(fan: Int, rpm: Double)
        case auto(fan: Int)
        case autoAll

        public var wire: String {
            switch self {
            case .hello: return "HELLO"
            case .ping: return "PING"
            case .set(let fan, let rpm): return "SET \(fan) \(Int(rpm.rounded()))"
            case .auto(let fan): return "AUTO \(fan)"
            case .autoAll: return "AUTOALL"
            }
        }
    }
}

// MARK: - Client

public final class HelperClient {

    public enum ClientError: Error, LocalizedError {
        case notInstalled
        case connectionFailed(String)
        case rejected(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "The control service is not installed."
            case .connectionFailed(let reason): return "Could not connect to the service: \(reason)"
            case .rejected(let reason): return "The service refused the request: \(reason)"
            case .timeout: return "The service did not respond."
            }
        }
    }

    private var fd: Int32 = -1
    private let lock = NSLock()

    public init() {}

    deinit { disconnect() }

    /// Whether the privileged helper is installed on disk.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperProtocol.binaryPath)
            && FileManager.default.fileExists(atPath: HelperProtocol.daemonPlistPath)
    }

    /// The helper that ships inside this app bundle.
    public static var bundledHelperPath: String? {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/zephyr-helper").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// True when the installed root helper is a different build from the one in
    /// this app bundle. Updating the app does not update the helper — it lives
    /// outside the bundle and only a privileged install can replace it — so
    /// without this check an old daemon keeps running silently after an update.
    public static var installedHelperIsStale: Bool {
        guard isInstalled, let bundled = bundledHelperPath else { return false }
        // Half a megabyte each — an exact comparison is cheap and leaves no
        // room for a hash collision or an unstable hashing seed.
        guard let installed = FileManager.default.contents(atPath: HelperProtocol.binaryPath),
              let shipped = FileManager.default.contents(atPath: bundled) else { return false }
        return installed != shipped
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0
    }

    public func connect() throws {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return }
        guard FileManager.default.fileExists(atPath: HelperProtocol.socketPath) else {
            if Self.isInstalled { throw ClientError.connectionFailed("the service is not running") }
            throw ClientError.notInstalled
        }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ClientError.connectionFailed(String(cString: strerror(errno))) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(HelperProtocol.socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes.prefix(buffer.count - 1))
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(socketFD)
            throw ClientError.connectionFailed(reason)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        fd = socketFD
    }

    public func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        fd = -1
    }

    @discardableResult
    public func send(_ command: HelperProtocol.Command) throws -> String {
        try connect()
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { throw ClientError.connectionFailed("no connection") }

        let payload = command.wire + "\n"
        let written = payload.withCString { pointer in
            Darwin.send(fd, pointer, strlen(pointer), 0)
        }
        guard written > 0 else {
            closeUnsafe()
            throw ClientError.connectionFailed("write failed")
        }

        var response = ""
        var byte: UInt8 = 0
        while true {
            let read = recv(fd, &byte, 1, 0)
            if read <= 0 {
                closeUnsafe()
                throw ClientError.timeout
            }
            if byte == UInt8(ascii: "\n") { break }
            response.append(Character(UnicodeScalar(byte)))
            if response.count > 512 { break }
        }

        if response.hasPrefix("ERR") {
            throw ClientError.rejected(String(response.dropFirst(4)))
        }
        return response
    }

    private func closeUnsafe() {
        if fd >= 0 { close(fd) }
        fd = -1
    }
}
