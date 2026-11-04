import Foundation
import Darwin
import Samplers

let args = Array(CommandLine.arguments.dropFirst())
var seconds = 5
var timing = false
var dump = false
var reset = false
var index = 0
while index < args.count {
    switch args[index] {
    case "--seconds":
        index += 1
        guard index < args.count, let count = Int(args[index]), (0...3600).contains(count) else {
            fatalError("--seconds requires an integer in 0...3600")
        }
        seconds = count
    case "--dump": dump = true
    case "--timing": timing = true
    case "--reset": reset = true
    default: fatalError("Usage: SpikeSMC [--seconds N] [--dump] [--timing] [--reset]")
    }
    index += 1
}
let sampler = SMCTemperatureSampler()
print("# Swift SMCKeyData size=\(SMCTemperatureSampler.messageSize) stride=\(SMCTemperatureSampler.messageStride)")
print("# SMC keys: \(sampler.totalKeyCount); Tp: \(sampler.cpuKeyCount); Tg: \(sampler.gpuKeyCount)")
if sampler.totalKeyCount == 0 { exit(1) }
if dump {
    for reading in sampler.allTemperatureReadings() {
        switch reading.value {
        case .success(let value): print(String(format: "SMC\t%@\t%.2f", reading.key, value))
        case .failure(let failure): print("SMC\t\(reading.key)\tunreadable (\(failure))")
        }
    }
}
if reset {
    sampler.reset()
    let reading = sampler.sampleTemperatures()
    print("# reset recovered: \(reading.cpu != nil && reading.gpu != nil); keys: \(sampler.totalKeyCount)")
}
if timing {
    func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { exit(3) }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    var times: [Double] = []
    let cpuStart = cpuSeconds()
    for _ in 0..<100 {
        let start = DispatchTime.now().uptimeNanoseconds
        let reading = sampler.sampleTemperatures()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        guard reading.cpu != nil, reading.gpu != nil else { exit(2) }
    }
    let cpuMilliseconds = (cpuSeconds() - cpuStart) * 1000 / 100
    print(String(format: "# 100 samples: mean=%.3f ms max=%.3f ms", times.reduce(0, +) / 100, times.max()!))
    print(String(format: "# CPU mean=%.3f ms/sample; one core at 2s=%.4f%% at 4s=%.4f%%",
                 cpuMilliseconds, cpuMilliseconds / 20, cpuMilliseconds / 40))
}
for second in 0..<seconds {
    let reading = sampler.sampleTemperatures()
    if let cpu = reading.cpu, let gpu = reading.gpu {
        print(String(format: "%d CPU peak=%.2f avg=%.2f (%d) GPU peak=%.2f avg=%.2f (%d)",
                     second, cpu.peak, cpu.average, cpu.sensorCount, gpu.peak, gpu.average, gpu.sensorCount))
    } else { print("\(second) CPU — GPU —") }
    fflush(stdout)
    if second + 1 < seconds { Thread.sleep(forTimeInterval: 1) }
}
