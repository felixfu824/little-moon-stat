import Foundation

/// Core-sensor assignments, intersected with the enumerated `flt ` inventory.
/// Upstream sources, exact revisions, and the measured M3 firmware variant are
/// recorded in docs/wave3/fixes-3.md and docs/wave4/chip-compat.md. Never infer a new chip from a substring (M10 != M1).
struct SMCSensorMap {
    var verified = true
    let cpuKeys: Set<String>
    let gpuKeys: Set<String>
    var cpuPrefixes: [String] = []
    var gpuPrefixes: [String] = []

    func isCPU(_ key: String) -> Bool { cpuKeys.contains(key) || cpuPrefixes.contains { key.hasPrefix($0) } }
    func isGPU(_ key: String) -> Bool { gpuKeys.contains(key) || gpuPrefixes.contains { key.hasPrefix($0) } }

    static func forChip(_ chip: String) -> Self {
        let tokens = chip.split(separator: " ").map(String.init)
        let model = tokens.first == "Apple" ? Array(tokens.dropFirst()) : tokens
        guard let generation = model.first,
              model.count == 1 || (model.count == 2 && ["Pro", "Max", "Ultra"].contains(model[1])) else {
            return fallback
        }
        switch generation {
        case "M1":
            if model.last == "Ultra" {
                return Self(cpuKeys: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                                      "Tp29", "Tp2T", "Tp21", "Tp25", "Tp2D", "Tp2H", "Tp2L", "Tp2P", "Tp2X", "Tp2b"],
                            gpuKeys: [], gpuPrefixes: ["Tg"])
            }
            return Self(cpuKeys: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                        gpuKeys: [], gpuPrefixes: ["Tg"])
        case "M2":
            return Self(cpuKeys: ["Te05", "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
                        gpuKeys: [], gpuPrefixes: ["Tg"])
        case "M3":
            if model.count == 1 {
                // Base M3 Air on macOS 26 exposes Tp/Tg rather than Stats' Tf
                // performance/GPU names. These core keys respond to CPU load;
                // GPU-coupled Tp14/Tp18/Tp1I and other package keys are excluded.
                return Self(cpuKeys: ["Te05", "Te0L", "Te0P", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D"],
                            gpuKeys: ["Tg0C", "Tg0D", "Tg0O", "Tg0P", "Tg0W", "Tg0X", "Tg0a", "Tg0b", "Tg0i", "Tg0j", "Tg0u", "Tg0v"])
            }
            // iSMC labels the old Tf CPU probes as GPU fabric. M3 Pro and
            // Max inventories instead expose these Te efficiency / Tp core probes.
            // Keep only confirmed core keys; unlabelled additional Max probes need
            // a load report before adding them. All Tg probes are GPU die sensors.
            return Self(cpuKeys: ["Te05", "Te0H", "Te0L", "Te0P", "Te0S",
                                  "Tp05", "Tp0D", "Tp0L", "Tp0b", "Tp0h", "Tp0n", "Tp1F", "Tp1R", "Tp0z"],
                        gpuKeys: [], gpuPrefixes: ["Tg"])
        case "M4":
            guard model.count == 1 || model[1] != "Ultra" else { return fallback }
            if model.count == 1 {
                // Tp0d/e/f are labelled fabric on Pro/Max; exclude the ambiguous
                // shared addresses even on base M4. Keep its other core triplets.
                return Self(cpuKeys: ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b"],
                            gpuKeys: [], gpuPrefixes: ["Tg"])
            }
            // Pro/Max firmware exposes two alternate per-core grids. Read both;
            // TempStat rejects powered-down sentinels. Never include Tp0d-w fabric.
            return Self(cpuKeys: ["Te05", "Te0S", "Tpx9", "TpxC", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b",
                                  "Tp1j", "Tp1n", "Tp1t", "Tp1w", "Tp1z", "Tp22", "Tp25", "Tp28", "Tp2B", "Tp2E"],
                        gpuKeys: [], gpuPrefixes: ["Tg"])
        case "M5":
            // Keep the validated full GPU die family: Stats' eight named GPU
            // probes are only a subset of the 84 readable M5 Max die sensors.
            return Self(cpuKeys: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
                        gpuKeys: [], gpuPrefixes: ["Tg"])
        default: return fallback
        }
    }

    /// Preserve firmware enumeration for unknown chips until their assignments are verified.
    static let fallback = Self(verified: false, cpuKeys: [], gpuKeys: [], cpuPrefixes: ["Tp", "Te"], gpuPrefixes: ["Tg"])
}

/// Pure classification of an enumerated float-key inventory. Each family chooses
/// independently; a one-probe map is insufficient to represent a family peak.
public struct SMCSensorSelection: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case chipMap, fallback }
    public let cpuKeys: Set<String>
    public let gpuKeys: Set<String>
    public let cpuSource: Source
    public let gpuSource: Source

    public static func isGenericCPU(_ key: String) -> Bool { key.hasPrefix("Tp") || key.hasPrefix("Te") }

    public static func select(inventory: Set<String>, chipName: String) -> Self {
        let map = SMCSensorMap.forChip(chipName)
        let cpu = Set(inventory.filter(map.isCPU))
        let gpu = Set(inventory.filter(map.isGPU))
        let useCPU = map.verified && cpu.count >= 2
        let useGPU = map.verified && gpu.count >= 2
        return Self(cpuKeys: useCPU ? cpu : Set(inventory.filter { Self.isGenericCPU($0) }),
                    gpuKeys: useGPU ? gpu : Set(inventory.filter { $0.hasPrefix("Tg") }),
                    cpuSource: useCPU ? .chipMap : .fallback,
                    gpuSource: useGPU ? .chipMap : .fallback)
    }
}
