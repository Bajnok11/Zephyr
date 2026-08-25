import Foundation
import ZephyrKit

// Zephyr privileged helper.
//
// Runs as root from a LaunchDaemon and is the only component allowed to write
// to the SMC. It exposes a unix socket that is chowned to the installing user
// and refuses every key outside the fan-control set.
//
// Two independent safety nets hand the fans back to the firmware:
//   1. the controlling connection closing (app quit or crash) — immediate;
//   2. no command within the watchdog interval (app hung) — after 12 s.

// MARK: - Arguments

var allowedUID: uid_t = 0
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "--uid":
        if let raw = arguments.first, let value = UInt32(raw) {
            allowedUID = uid_t(value)
            arguments.removeFirst()
        }
    default:
        break
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(("[zephyr-helper] " + message + "\n").data(using: .utf8)!)
}

guard getuid() == 0 else {
    log("root privileges required")
    exit(1)
}

// MARK: - SMC

let smc: SMC
do {
    smc = try SMC()
} catch {
    log("could not open the SMC: \(error)")
    exit(1)
}

struct FanLimits {
    let index: Int
    let min: Double
    let max: Double
}

let fanCount = Int(smc.number("FNum") ?? 0)
let fans: [FanLimits] = (0..<fanCount).compactMap { index in
    guard let minimum = smc.number("F\(index)Mn"),
          let maximum = smc.number("F\(index)Mx"),
          maximum > minimum else { return nil }
    return FanLimits(index: index, min: minimum, max: maximum)
}
log("\(fans.count) fan(s) detected, permitted uid: \(allowedUID)")

let stateLock = NSLock()
var controlEngaged = false

func engage(fan: FanLimits, rpm: Double) throws {
    let clamped = Swift.min(Swift.max(rpm, fan.min), fan.max)

    // Order matters. While the fan is still in automatic mode the firmware owns
    // the target and silently discards writes to it, so setting the target
    // first and then switching to manual leaves manual mode engaged with a
    // target of 0 — a fan forced off while the app believes it asked for full
    // speed. Engage manual first, then set the target, then confirm it took:
    // the first write after a mode change does not always land.
    try smc.write("F\(fan.index)Md", value: 1)
    try smc.write("F\(fan.index)Tg", value: clamped)

    if let readback = smc.number("F\(fan.index)Tg"), abs(readback - clamped) > 1 {
        try smc.write("F\(fan.index)Tg", value: clamped)
    }

    stateLock.lock()
    controlEngaged = true
    stateLock.unlock()
}

func release(fan: FanLimits) {
    try? smc.write("F\(fan.index)Md", value: 0)
}

func releaseAll(reason: String) {
    stateLock.lock()
    let wasEngaged = controlEngaged
    controlEngaged = false
    stateLock.unlock()
    guard wasEngaged else { return }
    for fan in fans { release(fan: fan) }
    log("fans handed back to the firmware (\(reason))")
}

// MARK: - Signals

// A client that vanishes mid-write must never take the daemon down with it.
signal(SIGPIPE, SIG_IGN)

for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        releaseAll(reason: "shutdown")
        unlink(HelperProtocol.socketPath)
        exit(0)
    }
    source.resume()
}

// MARK: - Socket

unlink(HelperProtocol.socketPath)

let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else {
    log("socket() failed: \(String(cString: strerror(errno)))")
    exit(1)
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let socketPathBytes = Array(HelperProtocol.socketPath.utf8)
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: socketPathBytes.prefix(buffer.count - 1))
}

let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else {
    log("bind() failed: \(String(cString: strerror(errno)))")
    exit(1)
}

// Only the installing user may talk to us.
chmod(HelperProtocol.socketPath, 0o600)
chown(HelperProtocol.socketPath, allowedUID, 0)

guard listen(listener, 4) == 0 else {
    log("listen() failed: \(String(cString: strerror(errno)))")
    exit(1)
}
log("listening on \(HelperProtocol.socketPath)")

// MARK: - Peer verification

func peerUID(of fd: Int32) -> uid_t? {
    var credentials = xucred()
    var size = socklen_t(MemoryLayout<xucred>.size)
    let result = withUnsafeMutablePointer(to: &credentials) { pointer -> Int32 in
        getsockopt(fd, 0 /* SOL_LOCAL */, 1 /* LOCAL_PEERCRED */, pointer, &size)
    }
    guard result == 0, credentials.cr_version == XUCRED_VERSION else { return nil }
    return credentials.cr_uid
}

// MARK: - Command handling

func handle(line: String) -> String {
    let parts = line.split(separator: " ").map(String.init)
    guard let verb = parts.first?.uppercased() else { return "ERR empty command" }

    switch verb {
    case "HELLO":
        return "OK zephyr-helper \(HelperProtocol.version) fans=\(fans.count)"

    case "PING":
        return "OK"

    case "SET":
        guard parts.count == 3, let index = Int(parts[1]), let rpm = Double(parts[2]) else {
            return "ERR usage: SET <index> <rpm>"
        }
        guard let fan = fans.first(where: { $0.index == index }) else { return "ERR unknown fan" }
        do {
            try engage(fan: fan, rpm: rpm)
            return "OK \(Int(Swift.min(Swift.max(rpm, fan.min), fan.max).rounded()))"
        } catch {
            return "ERR SMC write failed: \(error)"
        }

    case "AUTO":
        guard parts.count == 2, let index = Int(parts[1]) else { return "ERR usage: AUTO <index>" }
        guard let fan = fans.first(where: { $0.index == index }) else { return "ERR unknown fan" }
        release(fan: fan)
        return "OK"

    case "AUTOALL":
        releaseAll(reason: "requested")
        return "OK"

    default:
        return "ERR unknown command"
    }
}

/// Only one client controls the fans at a time; a new connection takes over and
/// the previous one is shut down. Serving each connection on its own thread
/// means a hung client can never block a fresh one from taking control.
var currentConnection: Int32 = -1

func serve(connection fd: Int32) {
    defer {
        stateLock.lock()
        let isCurrent = currentConnection == fd
        if isCurrent { currentConnection = -1 }
        stateLock.unlock()

        close(fd)
        // The controlling app went away — never leave the fans pinned.
        if isCurrent { releaseAll(reason: "connection closed") }
    }

    guard let uid = peerUID(of: fd), uid == allowedUID else {
        log("connection refused (uid mismatch)")
        _ = "ERR unauthorised\n".withCString { send(fd, $0, strlen($0), 0) }
        return
    }

    var timeout = timeval(tv_sec: Int(HelperProtocol.watchdogInterval), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var buffer = [UInt8](repeating: 0, count: 1024)
    var pending = ""

    while true {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count <= 0 {
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                log("watchdog: no heartbeat for \(Int(HelperProtocol.watchdogInterval))s")
            }
            return
        }
        pending += String(decoding: buffer[0..<count], as: UTF8.self)

        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: newline)...])
            guard !line.isEmpty else { continue }
            let response = handle(line: line) + "\n"
            let sent = response.withCString { send(fd, $0, strlen($0), 0) }
            if sent <= 0 { return }
        }

        if pending.count > 4096 { return }
    }
}

// MARK: - Accept loop

DispatchQueue.global(qos: .userInitiated).async {
    while true {
        let connection = accept(listener, nil, nil)
        if connection < 0 {
            if errno == EINTR { continue }
            log("accept() failed: \(String(cString: strerror(errno)))")
            usleep(200_000)
            continue
        }

        stateLock.lock()
        let previous = currentConnection
        currentConnection = connection
        stateLock.unlock()
        // Wake the previous client's blocking recv so its thread can retire.
        if previous >= 0 { shutdown(previous, SHUT_RDWR) }

        DispatchQueue.global(qos: .userInitiated).async {
            serve(connection: connection)
        }
    }
}

dispatchMain()
