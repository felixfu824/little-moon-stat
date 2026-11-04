import Foundation
import MonitorCore

public final class ThermalSampler: ThermalSampling {
    public init() {}
    public func sampleThermal() -> ThermalLevel? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }
    public func sampleThermalStatus() -> Sample<ThermalLevel> {
        let value = sampleThermal()
        return Sample(value: value, source: .processInfo, fault: value == nil ? .apiError : nil)
    }
}
