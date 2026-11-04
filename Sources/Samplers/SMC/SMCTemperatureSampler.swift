import Foundation
import IOKit
import MonitorCore

// Explicit padding preserves the probe.c ABI, including nested C struct tail padding.
struct SMCKeyData {
    var key: UInt32 = 0
    var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var versionPadding: UInt16 = 0
    var limitVersion: UInt16 = 0
    var limitLength: UInt16 = 0
    var cpuLimit: UInt32 = 0
    var gpuLimit: UInt32 = 0
    var memoryLimit: UInt32 = 0
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
    var infoPadding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var commandPadding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCCodec {
    static func fourCC(_ name: String) -> UInt32? {
        let bytes = Array(name.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 128 }) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func name(_ code: UInt32) -> String {
        String(bytes: [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
                       UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)], encoding: .ascii) ?? ""
    }

    static func isTemperature(key: UInt32, type: UInt32, size: UInt32) -> Bool {
        key >> 24 == 0x54 && type == fourCC("flt ") && size == 4
    }

    static func isCPUTemperature(_ key: UInt32) -> Bool { key >> 16 == 0x5470 }
    static func isGPUTemperature(_ key: UInt32) -> Bool { key >> 16 == 0x5467 }

    static func float(_ bytes: UnsafeRawBufferPointer) -> Double? {
        guard bytes.count >= 4 else { return nil }
        // AppleSMC flt payloads are IEEE-754 little endian, unlike big-endian fourCCs/#KEY.
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Double(Float(bitPattern: bits))
    }
}

public enum SMCReadFailure: Error, Sendable, Equatable { case unavailable, transport, rejected }

/// Inventory comes from metadata enumeration, independent of whether a value was readable.
public protocol SMCDiagnosticReading: AnyObject {
    var inventory: Set<String> { get }
    func readAll() -> [(key: String, value: Result<Double, SMCReadFailure>)]
}

/// Injectable transport; the policy layer owns parking, family fallback and tick backoff.
protocol SMCReading: AnyObject {
    var inventory: Set<String> { get }
    var totalKeyCount: Int { get }
    func reopen() throws
    func close()
    func readTemperature(key: String) -> Result<Double, SMCReadFailure>
}

public final class SMCTemperatureSampler: TemperatureSampling, SMCDiagnosticReading {
    private let reader: SMCReading
    private let chipName: String
    private var connected = false
    private var retry = RetrySchedule()
    private var connectionFault: MetricFault = .serviceUnavailable
    private struct KeyState { var misses = 0; var retry = RetrySchedule(); var fault: MetricFault? }
    private var keys: [String: KeyState] = [:]
    private var cpuKeys: [String] = [], gpuKeys: [String] = []
    private var genericCPU: [String] = [], genericGPU: [String] = []
    public var forceGenericCPU = false
    public var forceGenericGPU = false
    public private(set) var selection = SMCSensorSelection.select(inventory: [], chipName: "")
    public var inventory: Set<String> { reader.inventory }
    public var totalKeyCount: Int { reader.totalKeyCount }
    public var cpuKeyCount: Int { cpuKeys.count }
    public var gpuKeyCount: Int { gpuKeys.count }
    public static var messageSize: Int { MemoryLayout<SMCKeyData>.size }
    public static var messageStride: Int { MemoryLayout<SMCKeyData>.stride }

    public convenience init(chipName: String = SystemInfo().chipName) {
        self.init(chipName: chipName, reader: SMCConnection())
    }
    init(chipName: String, reader: SMCReading) {
        self.chipName = chipName; self.reader = reader
        _ = ensureConnection()
    }
    /// Preserve the retry schedule: wake/stuck notifications must never cause a reopen storm.
    public func reset() { reader.close(); connected = false }
    private func ensureConnection() -> Bool {
        guard !connected else { return true }
        guard retry.shouldAttempt() else { return false }
        if ProcessInfo.processInfo.environment["MAC_MONITOR_PROFILE"] == "1" { fputs("smc.reopen\n", stderr) }
        do {
            try reader.reopen()
            connected = true; keys.removeAll(keepingCapacity: true)
            selection = SMCSensorSelection.select(inventory: inventory, chipName: chipName)
            cpuKeys = selection.cpuKeys.sorted(); gpuKeys = selection.gpuKeys.sorted()
            genericCPU = inventory.filter(SMCSensorSelection.isGenericCPU).sorted()
            genericGPU = inventory.filter { $0.hasPrefix("Tg") }.sorted()
            return true
        } catch {
            reader.close(); connected = false; retry.recordFailure()
            connectionFault = SystemInfo.hvVMMPresent ? .virtualMachine :
                ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ? .permission : .serviceUnavailable
            return false
        }
    }
    public func sampleTemperatures() -> (cpu: TempStat?, gpu: TempStat?) {
        let sample = sampleTemperaturesStatus(); return (sample.cpu.value, sample.gpu.value)
    }
    public func sampleTemperaturesStatus() -> TemperatureSample {
        guard ensureConnection() else {
            return TemperatureSample(cpu: .failure(connectionFault, source: .chipMap), gpu: .failure(connectionFault, source: .chipMap))
        }
        var cache: [String: Result<Double, SMCReadFailure>] = [:]
        func values(_ family: [String]) -> [Double] {
            family.compactMap { key in
                let result: Result<Double, SMCReadFailure>
                if let existing = cache[key] { result = existing }
                else {
                    var state = keys[key] ?? KeyState()
                    if state.misses >= 3 && !state.retry.shouldAttempt() { result = .failure(.rejected) }
                    else if !connected { result = .failure(.transport) }
                    else {
                        result = reader.readTemperature(key: key)
                        switch result {
                        case .success(let value) where value.isFinite && (value == 0 || TempStat.validRange.contains(value)):
                            state.misses = 0; state.fault = nil; state.retry.recordSuccess()
                        case .success(let value):
                            state.fault = value.isFinite ? .outOfRange : .nonFinite
                            state.misses += 1
                            if state.misses >= 3 { state.retry.recordFailure() }
                        case .failure(.rejected):
                            state.misses += 1
                            if state.misses >= 3 { state.retry.recordFailure() }
                        case .failure:
                            reset(); retry.recordFailure(); connectionFault = .apiError
                        }
                    }
                    // Keep only faulty keys: healthy steady-state reads allocate no policy entry.
                    if state.misses > 0 { keys[key] = state } else { keys.removeValue(forKey: key) }
                    cache[key] = result
                }
                guard let value = try? result.get(), value.isFinite,
                      value == 0 || TempStat.validRange.contains(value) else { return nil }
                return value
            }
        }
        func family(_ selected: [String], generic: [String], source: SMCSensorSelection.Source, force: Bool) -> Sample<TempStat> {
            let primary = force ? [] : values(selected)
            // Powered-down zero probes are readable. They do not demote a known map.
            if !force && source == .chipMap && primary.count >= 2 {
                let stat = TempStat(readings: primary)
                return Sample(value: stat, source: .chipMap, fault: stat == nil ? .outOfRange : nil)
            }
            let reads = values(generic)
            let stat = reads.count >= 2 ? TempStat(readings: reads) : nil
            let payloadFault = (selected + generic).compactMap { keys[$0]?.fault }.first
            let fault: MetricFault = !connected ? .apiError : payloadFault ?? (stat == nil ? .familyMissing :
                SMCSensorMap.forChip(chipName).verified && !force ? .familyMissing : .unknownChip)
            return Sample(value: stat, source: .genericFamily, fault: fault)
        }
        let cpu = family(cpuKeys, generic: genericCPU, source: selection.cpuSource, force: forceGenericCPU)
        let gpu = family(gpuKeys, generic: genericGPU, source: selection.gpuSource, force: forceGenericGPU)
        guard connected else {
            return TemperatureSample(cpu: .failure(.apiError, source: .chipMap), gpu: .failure(.apiError, source: .chipMap))
        }
        retry.recordSuccess()
        return TemperatureSample(cpu: cpu, gpu: gpu)
    }
    public func allTemperatureReadings() -> [(key: String, value: Result<Double, SMCReadFailure>)] { readAll() }
    public func readAll() -> [(key: String, value: Result<Double, SMCReadFailure>)] {
        guard ensureConnection() else { return inventory.sorted().map { ($0, .failure(.unavailable)) } }
        let result = inventory.sorted().map { key -> (key: String, value: Result<Double, SMCReadFailure>) in
            guard connected else { return (key, .failure(.transport)) }
            let value = reader.readTemperature(key: key)
            if case .failure(.transport) = value { reset(); retry.recordFailure(); connectionFault = .apiError }
            return (key, value)
        }
        if connected { retry.recordSuccess() }
        return result
    }
}

/// Read-only AppleSMC transport. A rejected key is local to that key.
private final class SMCConnection: SMCReading {
    private struct Sensor { let key: UInt32; let size: UInt32 }
    private var connection: io_connect_t = 0
    private var temperatures: [Sensor] = []
    private(set) var totalKeyCount = 0
    var inventory: Set<String> { Set(temperatures.map { SMCCodec.name($0.key) }) }
    deinit { close() }
    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
        // Keep metadata after transport loss, so diagnostics still enumerate failed keys.
    }
    func readTemperature(key: String) -> Result<Double, SMCReadFailure> {
        guard connection != 0 else { return .failure(.unavailable) }
        guard let code = SMCCodec.fourCC(key) else { return .failure(.rejected) }
        do { return .success(try readTemperature(Sensor(key: code, size: 4))) }
        catch let failure as SMCReadFailure { return .failure(failure) }
        catch { return .failure(.transport) }
    }
    func reopen() throws {
        close()
        temperatures.removeAll(keepingCapacity: true)
        totalKeyCount = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCReadFailure.unavailable }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            connection = 0
            throw SMCReadFailure.unavailable
        }
        do {
            let countKey: UInt32 = 0x234b4559 // #KEY
            let countInfo = try info(countKey)
            guard countInfo.dataSize == 4 else { throw SMCReadFailure.rejected }
            var countData = try read(Sensor(key: countKey, size: 4))
            let count = withUnsafeBytes(of: &countData.bytes) { bytes in
                bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            // Bound corrupted firmware responses rather than looping indefinitely.
            guard count <= 65_536 else { throw SMCReadFailure.rejected }
            for index in 0..<count {
                var request = SMCKeyData()
                request.command = 8
                request.data32 = index
                let key = try call(request).key
                guard key >> 24 == 0x54 else { continue }
                let metadata: SMCKeyData
                do { metadata = try info(key) }
                catch SMCReadFailure.rejected { continue }
                guard SMCCodec.isTemperature(key: key, type: metadata.dataType, size: metadata.dataSize) else { continue }
                let sensor = Sensor(key: key, size: metadata.dataSize)
                temperatures.append(sensor)
            }
            totalKeyCount = Int(count)
        } catch {
            close()
            throw error
        }
    }

    private func info(_ key: UInt32) throws -> SMCKeyData {
        var request = SMCKeyData()
        request.key = key
        request.command = 9
        return try call(request)
    }

    private func read(_ sensor: Sensor) throws -> SMCKeyData {
        var request = SMCKeyData()
        request.key = sensor.key
        request.dataSize = sensor.size
        request.command = 5
        return try call(request)
    }

    private func readTemperature(_ sensor: Sensor) throws -> Double {
        var response = try read(sensor)
        guard let value = withUnsafeBytes(of: &response.bytes, { SMCCodec.float($0) }) else {
            throw SMCReadFailure.rejected
        }
        return value
    }

    private func call(_ request: SMCKeyData) throws -> SMCKeyData {
        var input = request
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
        guard status == KERN_SUCCESS, size == MemoryLayout<SMCKeyData>.stride else { throw SMCReadFailure.transport }
        guard output.result == 0 else { throw SMCReadFailure.rejected }
        return output
    }
}
