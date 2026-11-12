// SPDX-License-Identifier: GPL-2.0-or-later
// The real iPhone this runs on – reported to Windows (System Information, Task Manager)
// and used for sensible defaults (RAM, vCPUs).
import Foundation

struct DeviceProfile {
    let modelID: String        // e.g. "iPhone18,2"
    let name: String           // e.g. "iPhone 17 Pro Max"
    let chip: String           // e.g. "Apple A19 Pro"
    let maxMHz: UInt16
    let memoryType: String
    let memoryMTs: UInt16
    let physicalMemoryMB: UInt64
    let cpuCores: Int
    let performanceCores: Int

    static let current = DeviceProfile.detect()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    /// Marketing names and chips (iPhone 15 Pro and newer – the ones with enough RAM).
    private static let models: [String: (String, String, UInt16, UInt16)] = [
        "iPhone18,1": ("iPhone 17 Pro", "Apple A19 Pro", 4260, 9600),
        "iPhone18,2": ("iPhone 17 Pro Max", "Apple A19 Pro", 4260, 9600),
        "iPhone18,3": ("iPhone 17", "Apple A19", 4260, 8533),
        "iPhone18,4": ("iPhone Air", "Apple A19 Pro", 4260, 9600),
        "iPhone17,1": ("iPhone 16 Pro", "Apple A18 Pro", 4050, 7500),
        "iPhone17,2": ("iPhone 16 Pro Max", "Apple A18 Pro", 4050, 7500),
        "iPhone17,3": ("iPhone 16", "Apple A18", 4040, 7500),
        "iPhone17,4": ("iPhone 16 Plus", "Apple A18", 4040, 7500),
        "iPhone17,5": ("iPhone 16e", "Apple A18", 4040, 7500),
        "iPhone16,1": ("iPhone 15 Pro", "Apple A17 Pro", 3780, 6400),
        "iPhone16,2": ("iPhone 15 Pro Max", "Apple A17 Pro", 3780, 6400),
    ]

    static func detect() -> DeviceProfile {
        let id = sysctlString("hw.machine") ?? "iPhone"
        let memMB = WinIOSBridge.shared.deviceMemoryMB
        let cores = sysctlInt("hw.ncpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? 2
        if let m = models[id] {
            return DeviceProfile(modelID: id, name: m.0, chip: m.1, maxMHz: m.2, memoryType: "LPDDR5X",
                                 memoryMTs: m.3, physicalMemoryMB: memMB, cpuCores: cores, performanceCores: pCores)
        }
        let isPhone = id.hasPrefix("iPhone")
        return DeviceProfile(modelID: id, name: isPhone ? "iPhone" : "iPad", chip: "Apple Silicon", maxMHz: 4000,
                             memoryType: "LPDDR5X", memoryMTs: 8533, physicalMemoryMB: memMB,
                             cpuCores: cores, performanceCores: pCores)
    }

    var physicalMemoryGB: Int { Int((Double(physicalMemoryMB) / 1024).rounded()) }

    /// RAM choices that make sense on this device (MiB).
    var ramChoices: [Int] {
        var c = [3072, 4096, 4608]
        if physicalMemoryMB >= 11000 { c += [6144, 7168, 8192] }
        else if physicalMemoryMB >= 7500 { c += [5120] }
        return c
    }

    var automaticRamMB: Int { physicalMemoryMB >= 11000 ? 6144 : 4608 }

    /// Hands the identity to the engine (SMBIOS).
    func applyToEngine() {
        WinIOSBridge.shared.setDeviceProduct(name, modelID: modelID, cpuName: chip, cpuMaxMHz: maxMHz,
                                             memoryType: memoryType, memoryMTs: memoryMTs)
    }
}
