import CSensors
import Darwin
import Foundation

struct Temperatures: Sendable {
    /// Average of the CPU cores — the number Stats/iStat Menus show.
    var chip: Double?
    /// Hottest CPU core sensor — what macOS throttles on.
    var chipPeak: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
}

struct MemoryStats: Sendable {
    var used: UInt64 = 0
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    /// Cumulative bytes read back from / written to swap since boot.
    var swapInBytes: UInt64 = 0
    var swapOutBytes: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressure = 1
}

enum Sensors {
    static func read() -> Temperatures {
        var buffer = [hw_temp_t](repeating: hw_temp_t(), count: 128)
        let count = Int(hw_read_temperatures(&buffer, Int32(buffer.count)))

        var die: [Double] = [], other: [Double] = [], ssd: [Double] = [], battery: [Double] = []
        for entry in buffer.prefix(count) {
            let value = entry.value
            // Some sensors report placeholders like -22 °C when idle.
            guard value > 5, value < 130 else { continue }
            let name = withUnsafeBytes(of: entry.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if name.hasPrefix("NAND") {
                ssd.append(value)
            } else if name.localizedCaseInsensitiveContains("battery") {
                battery.append(value)
            } else if name.contains("tdie") {
                die.append(value)
            } else {
                other.append(value)
            }
        }
        var result = Temperatures(
            ssd: ssd.max(),
            battery: battery.isEmpty ? nil : battery.reduce(0, +) / Double(battery.count)
        )

        var cores = hw_chip_temps_t()
        if hw_read_chip_temps(&cores) == 0 {
            result.chip = cores.cpu_avg
            result.chipPeak = cores.cpu_max
            result.gpu = cores.gpu_avg > 0 ? cores.gpu_avg : nil
        } else {
            // No SMC access: the HID die sensors run cooler than the cores
            // (on M4 they are the PMU), but they're better than nothing.
            result.chip = die.max() ?? other.max()
        }
        return result
    }

    static func thermalPressure() -> Int {
        max(0, Int(hw_thermal_pressure()))
    }
}

enum SystemStats {
    static func memory() -> MemoryStats {
        var result = MemoryStats()

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            // Same formula as Activity Monitor's "Memory Used".
            let page = UInt64(getpagesize())
            let anonymous = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            let app = anonymous > purgeable ? anonymous - purgeable : 0
            result.used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            result.swapInBytes = stats.swapins * page
            result.swapOutBytes = stats.swapouts * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            result.swapUsed = swap.xsu_used
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            result.pressure = Int(level)
        }
        return result
    }

    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }
}
