import Darwin
import Foundation
import IOKit

enum ThermalPressure: String, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

struct HealthSnapshot: Sendable {
    let capturedAt: Date
    let cpuUsage: Double?
    let memoryUsedBytes: UInt64?
    let memoryTotalBytes: UInt64
    let diskAvailableBytes: UInt64?
    let diskTotalBytes: UInt64?
    let uptime: TimeInterval
    let thermalPressure: ThermalPressure
    let temperatureCelsius: Double?
    let deviceName: String
    let modelIdentifier: String?
}

actor HealthMonitor {
    private var previousCPUTicks: CPUTicks?
    private let modelIdentifier = hardwareModel()

    func sample() -> HealthSnapshot {
        let process = ProcessInfo.processInfo
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        let disk = Self.diskCapacity()
        return HealthSnapshot(
            capturedAt: Date(),
            cpuUsage: cpuUsage(host),
            memoryUsedBytes: Self.memoryUsedBytes(host).map { min($0, process.physicalMemory) },
            memoryTotalBytes: process.physicalMemory,
            diskAvailableBytes: disk?.available,
            diskTotalBytes: disk?.total,
            uptime: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
            thermalPressure: ThermalPressure(process.thermalState),
            temperatureCelsius: modelIdentifier == "Mac16,10" ? M4Temperature.hottestCPUReading() : nil,
            deviceName: Host.current().localizedName ?? process.hostName,
            modelIdentifier: modelIdentifier
        )
    }

    private func cpuUsage(_ host: host_t) -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        // Mach reports this tuple in user, system, idle, nice order.
        let current = CPUTicks(info.cpu_ticks)
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return nil }

        return current.usage(since: previous)
    }

    private static func memoryUsedBytes(_ host: host_t) -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        // Count non-purgeable anonymous pages, wired memory, and the physical compressor.
        let appPages = max(0, Int64(info.internal_page_count) - Int64(info.purgeable_count))
        let usedPages = UInt64(appPages) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return usedPages * UInt64(getpagesize())
    }

    private static func diskCapacity() -> (available: UInt64, total: UInt64)? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        guard let available = attributes?[.systemFreeSize] as? NSNumber,
              let total = attributes?[.systemSize] as? NSNumber else {
            return nil
        }
        return (available.uint64Value, total.uint64Value)
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes {
            sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
    }

    private struct CPUTicks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32

        init(_ values: (UInt32, UInt32, UInt32, UInt32)) {
            (user, system, idle, nice) = values
        }

        func usage(since previous: Self) -> Double? {
            let busy = UInt64(user &- previous.user)
                + UInt64(system &- previous.system)
                + UInt64(nice &- previous.nice)
            let total = busy + UInt64(idle &- previous.idle)
            return total > 0 ? Double(busy) / Double(total) : nil
        }
    }
}

private enum M4Temperature {
    // The AppleSMC driver uses an undocumented wire format. The CPU keys below
    // match the Stats M4 sensor table and were verified on the Mac mini model Mac16,10.
    // https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
    // https://github.com/beltex/SMCKit/blob/master/SMCKit/SMC.swift
    private static let cpuKeys = [
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
        "Te05", "Te09", "Te0H", "Te0S"
    ].map(fourCharacterCode)
    private static let floatType = fourCharacterCode("flt ")

    private enum Message {
        static let byteCount = 80
        static let selector: UInt32 = 2
        static let keyOffset = 0
        static let sizeOffset = 28
        static let typeOffset = 32
        static let resultOffset = 40
        static let commandOffset = 42
        static let payloadOffset = 48
    }

    private enum ReadCommand: UInt8 {
        case value = 5
        case metadata = 9
    }

    static func hottestCPUReading() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }

        return cpuKeys.compactMap { readTemperature(key: $0, from: connection) }.max()
    }

    private static func readTemperature(key: UInt32, from connection: io_connect_t) -> Double? {
        guard let metadata = query(.metadata, key: key, in: connection),
              uint32(in: metadata, at: Message.typeOffset) == floatType else {
            return nil
        }
        let size = uint32(in: metadata, at: Message.sizeOffset)
        guard size == MemoryLayout<Float>.size,
              let value = query(.value, key: key, size: size, in: connection) else {
            return nil
        }
        let celsius = Double(Float(bitPattern: uint32(in: value, at: Message.payloadOffset)))
        return celsius.isFinite && (10...125).contains(celsius) ? celsius : nil
    }

    private static func query(
        _ command: ReadCommand, key: UInt32, size: UInt32 = 0, in connection: io_connect_t
    ) -> [UInt8]? {
        var request = [UInt8](repeating: 0, count: Message.byteCount)
        setUInt32(key, in: &request, at: Message.keyOffset)
        setUInt32(size, in: &request, at: Message.sizeOffset)
        request[Message.commandOffset] = command.rawValue

        var response = [UInt8](repeating: 0, count: Message.byteCount)
        var responseSize = response.count
        let status = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, Message.selector, input.baseAddress, input.count,
                                          output.baseAddress, &responseSize)
            }
        }
        guard status == KERN_SUCCESS, responseSize == Message.byteCount, response[Message.resultOffset] == 0 else {
            return nil
        }
        return response
    }

    private static func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint32(in bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func setUInt32(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) {
            bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }
}
