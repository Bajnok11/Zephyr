import Foundation
import IOKit

/// Low-level Apple SMC access.
///
/// The kernel side (`AppleSMC` / `AppleSMCClient`) takes an 80 byte parameter
/// struct through selector 2. We build that struct by raw byte offsets instead
/// of mirroring the C layout in Swift, because Swift makes no guarantees about
/// struct padding and a single misplaced byte here means garbage sensor values.
public final class SMC {

    // MARK: - Wire format

    private static let paramSize = 80
    private enum Offset {
        static let key = 0
        static let infoSize = 28
        static let infoType = 32
        static let result = 40
        static let data8 = 42
        static let data32 = 44
        static let bytes = 48
    }
    private enum Selector: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyFromIndex = 8
        case keyInfo = 9
    }

    public enum SMCError: Error, LocalizedError {
        case serviceNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case smcResult(UInt8)
        case unknownKey(String)
        case notPermitted

        public var errorDescription: String? {
            switch self {
            case .serviceNotFound: return "No AppleSMC service found."
            case .openFailed(let r): return "Could not open the SMC (0x\(String(r, radix: 16)))."
            case .callFailed(let r): return "SMC call failed (0x\(String(r, radix: 16)))."
            case .smcResult(let r): return "SMC error code: \(r)."
            case .unknownKey(let k): return "Unknown SMC key: \(k)."
            case .notPermitted: return "Writing to the SMC requires the privileged helper."
            }
        }
    }

    // MARK: - Value model

    public struct KeyInfo {
        public let size: UInt32
        public let type: String
    }

    public enum Value {
        case float(Double)
        case integer(Int64)
        case flag(Bool)
        case raw([UInt8])

        public var double: Double? {
            switch self {
            case .float(let v): return v
            case .integer(let v): return Double(v)
            case .flag(let v): return v ? 1 : 0
            case .raw: return nil
            }
        }
    }

    // MARK: - Lifecycle

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [String: KeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
        connection = conn
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Primitives

    private func call(_ input: UnsafeMutableRawPointer, _ output: UnsafeMutableRawPointer) throws {
        var outSize = Self.paramSize
        let kr = IOConnectCallStructMethod(connection, 2, input, Self.paramSize, output, &outSize)
        guard kr == kIOReturnSuccess else {
            // kIOReturnNotPrivileged is what an unprivileged process gets for writes.
            if kr == kIOReturnNotPrivileged { throw SMCError.notPermitted }
            throw SMCError.callFailed(kr)
        }
        let result = output.load(fromByteOffset: Offset.result, as: UInt8.self)
        guard result == 0 else { throw SMCError.smcResult(result) }
    }

    private func withBuffers<T>(_ body: (UnsafeMutableRawPointer, UnsafeMutableRawPointer) throws -> T) rethrows -> T {
        let input = UnsafeMutableRawPointer.allocate(byteCount: Self.paramSize, alignment: 8)
        let output = UnsafeMutableRawPointer.allocate(byteCount: Self.paramSize, alignment: 8)
        defer { input.deallocate(); output.deallocate() }
        memset(input, 0, Self.paramSize)
        memset(output, 0, Self.paramSize)
        return try body(input, output)
    }

    public static func fourCC(_ string: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in string.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    public static func string(fromFourCC value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                     UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Key discovery

    public func info(for key: String) throws -> KeyInfo {
        lock.lock(); defer { lock.unlock() }
        return try uncheckedInfo(for: key)
    }

    private func uncheckedInfo(for key: String) throws -> KeyInfo {
        if let cached = infoCache[key] { return cached }
        let info: KeyInfo = try withBuffers { input, output in
            input.storeBytes(of: Self.fourCC(key), toByteOffset: Offset.key, as: UInt32.self)
            input.storeBytes(of: Selector.keyInfo.rawValue, toByteOffset: Offset.data8, as: UInt8.self)
            try call(input, output)
            return KeyInfo(size: output.load(fromByteOffset: Offset.infoSize, as: UInt32.self),
                           type: Self.string(fromFourCC: output.load(fromByteOffset: Offset.infoType, as: UInt32.self)))
        }
        infoCache[key] = info
        return info
    }

    /// Total number of keys the SMC exposes.
    public func keyCount() throws -> Int {
        guard case .integer(let count) = try read("#KEY") else { return 0 }
        return Int(count)
    }

    public func key(at index: Int) throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try withBuffers { input, output in
            input.storeBytes(of: Selector.keyFromIndex.rawValue, toByteOffset: Offset.data8, as: UInt8.self)
            input.storeBytes(of: UInt32(index), toByteOffset: Offset.data32, as: UInt32.self)
            try call(input, output)
            return Self.string(fromFourCC: output.load(fromByteOffset: Offset.key, as: UInt32.self))
        }
    }

    /// Every key the SMC knows about. Takes a couple of seconds — call once, cache the result.
    public func allKeys() throws -> [String] {
        let count = try keyCount()
        var keys: [String] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            if let key = try? key(at: index) { keys.append(key) }
        }
        return keys
    }

    // MARK: - Reading

    public func readBytes(_ key: String) throws -> (KeyInfo, [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let info = try uncheckedInfo(for: key)
        let bytes: [UInt8] = try withBuffers { input, output in
            input.storeBytes(of: Self.fourCC(key), toByteOffset: Offset.key, as: UInt32.self)
            input.storeBytes(of: info.size, toByteOffset: Offset.infoSize, as: UInt32.self)
            input.storeBytes(of: Selector.readKey.rawValue, toByteOffset: Offset.data8, as: UInt8.self)
            try call(input, output)
            var out = [UInt8](repeating: 0, count: Int(info.size))
            for i in 0..<Int(info.size) {
                out[i] = output.load(fromByteOffset: Offset.bytes + i, as: UInt8.self)
            }
            return out
        }
        return (info, bytes)
    }

    public func read(_ key: String) throws -> Value {
        let (info, bytes) = try readBytes(key)
        return Self.decode(type: info.type, bytes: bytes)
    }

    /// Convenience: read a key as a Double, or nil if it does not exist / is not numeric.
    public func number(_ key: String) -> Double? {
        (try? read(key))?.double
    }

    public static func decode(type: String, bytes: [UInt8]) -> Value {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return .raw(bytes) }
            let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
            return .float(Double(value))
        case "ui8 ", "ui16", "ui32", "ui64":
            var value: UInt64 = 0
            for byte in bytes { value = (value << 8) | UInt64(byte) }
            return .integer(Int64(bitPattern: value))
        case "si8 ":
            guard let first = bytes.first else { return .raw(bytes) }
            return .integer(Int64(Int8(bitPattern: first)))
        case "si16":
            guard bytes.count >= 2 else { return .raw(bytes) }
            return .integer(Int64(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))))
        case "sp78":
            guard bytes.count >= 2 else { return .raw(bytes) }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return .float(Double(raw) / 256.0)
        case "sp87":
            guard bytes.count >= 2 else { return .raw(bytes) }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return .float(Double(raw) / 128.0)
        case "fpe2":
            guard bytes.count >= 2 else { return .raw(bytes) }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return .float(Double(raw) / 4.0)
        case "fp88":
            guard bytes.count >= 2 else { return .raw(bytes) }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return .float(Double(raw) / 256.0)
        case "flag":
            return .flag((bytes.first ?? 0) != 0)
        default:
            return .raw(bytes)
        }
    }

    public static func encode(type: String, size: UInt32, value: Double) -> [UInt8]? {
        switch type {
        case "flt ":
            var float = Float32(value)
            return withUnsafeBytes(of: &float) { Array($0) }
        case "ui8 ":
            return [UInt8(clamping: Int(value.rounded()))]
        case "ui16":
            let raw = UInt16(clamping: Int(value.rounded()))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui32":
            let raw = UInt32(clamping: Int(value.rounded()))
            return [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff), UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        case "fpe2":
            let raw = UInt16(clamping: Int((value * 4).rounded()))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "sp78":
            let raw = Int16(clamping: Int((value * 256).rounded()))
            let bits = UInt16(bitPattern: raw)
            return [UInt8(bits >> 8), UInt8(bits & 0xff)]
        case "flag":
            return [value != 0 ? 1 : 0]
        default:
            _ = size
            return nil
        }
    }

    // MARK: - Writing (root only)

    public func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let info = try uncheckedInfo(for: key)
        try withBuffers { input, output in
            input.storeBytes(of: Self.fourCC(key), toByteOffset: Offset.key, as: UInt32.self)
            input.storeBytes(of: info.size, toByteOffset: Offset.infoSize, as: UInt32.self)
            input.storeBytes(of: Selector.writeKey.rawValue, toByteOffset: Offset.data8, as: UInt8.self)
            for (i, byte) in bytes.prefix(Int(info.size)).enumerated() {
                input.storeBytes(of: byte, toByteOffset: Offset.bytes + i, as: UInt8.self)
            }
            try call(input, output)
        }
    }

    public func write(_ key: String, value: Double) throws {
        let info = try info(for: key)
        guard let bytes = Self.encode(type: info.type, size: info.size, value: value) else {
            throw SMCError.unknownKey(key)
        }
        try writeBytes(key, bytes)
    }
}
