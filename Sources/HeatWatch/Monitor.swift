import Foundation
import SwiftUI

struct Snapshot: Sendable {
    var temps = Temperatures()
    var thermalPressure = 0
    var memory = MemoryStats()
    var load = 0.0
    var culprits: [Culprit] = []

    static func take() -> Snapshot {
        Snapshot(
            temps: Sensors.read(),
            thermalPressure: Sensors.thermalPressure(),
            memory: SystemStats.memory(),
            load: SystemStats.loadAverage(),
            culprits: ProcessScanner.scan()
        )
    }
}

enum HeatLevel {
    case cool, warm, hot, critical

    init(chip: Double?, pressure: Int) {
        // Thresholds are for the core average; the hottest core runs ~15-20 °C above it.
        let t = chip ?? 0
        switch t {
        case ..<60: self = .cool
        case ..<75: self = .warm
        case ..<88: self = .hot
        default: self = .critical
        }
        // On a fanless Air macOS throttles on chassis temperature, so the die can
        // read cool while performance is already being cut.
        if pressure >= 1, self == .cool { self = .warm }
        if pressure >= 2, self == .cool || self == .warm { self = .hot }
    }

    var label: String {
        switch self {
        case .cool: "Fresco"
        case .warm: "Morno"
        case .hot: "Quente"
        case .critical: "Muito quente"
        }
    }

    var color: Color {
        switch self {
        case .cool: .green
        case .warm: .yellow
        case .hot: .orange
        case .critical: .red
        }
    }

    var symbol: String {
        switch self {
        case .cool: "thermometer.low"
        case .warm: "thermometer.medium"
        case .hot: "thermometer.high"
        case .critical: "flame.fill"
        }
    }
}

struct SwapActivity {
    var readPerSecond: Double = 0
    var writePerSecond: Double = 0

    /// Swap that just sits there costs nothing; swap being shuffled to and from the SSD costs heat.
    var isActive: Bool { readPerSecond + writePerSecond >= 1_048_576 }
}

enum QuitPhase: Sendable {
    case closing, forcing
    /// Still running after being killed: something keeps relaunching it.
    case failed
}

enum Settings {
    static let autoCloseDaemons = "autoCloseIdleDaemons"
    static let autoCloseAfter: TimeInterval = 15 * 60
}

@MainActor
final class Monitor: ObservableObject {
    static let interval: TimeInterval = 3
    /// 3 minutes of chip temperature at one sample every 3 s.
    static let historyLength = 60

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var chipHistory: [Double] = []
    @Published private(set) var quitPhases: [String: QuitPhase] = [:]
    @Published private(set) var swapActivity = SwapActivity()

    let cores = ProcessInfo.processInfo.activeProcessorCount
    private let alerts = Alerts()
    private var timer: Timer?
    private var sampling = false
    private var lastMemorySample: (date: Date, memory: MemoryStats)?

    init() {
        Notifier.requestAuthorization()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 1
        Task { await refresh() }
    }

    var level: HeatLevel { HeatLevel(chip: snapshot.temps.chip, pressure: snapshot.thermalPressure) }

    func refresh() async {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }

        let next = await Task.detached(priority: .utility) { Snapshot.take() }.value
        snapshot = next
        updateSwapActivity(next.memory)
        if let chip = next.temps.chip {
            chipHistory.append(chip)
            if chipHistory.count > Self.historyLength {
                chipHistory.removeFirst(chipHistory.count - Self.historyLength)
            }
        }
        let alive = Set(next.culprits.map(\.id))
        quitPhases = quitPhases.filter { $0.value != .failed || alive.contains($0.key) }
        alerts.evaluate(next, history: chipHistory)
    }

    func quit(_ culprit: Culprit) {
        let id = culprit.id
        guard quitPhases[id] == nil || quitPhases[id] == .failed else { return }
        quitPhases[id] = .closing
        Task {
            let closed = await Killer.close(culprit) { @MainActor [weak self] in
                self?.quitPhases[id] = .forcing
            }
            quitPhases[id] = closed ? nil : .failed
            await refresh()
        }
    }

    private func updateSwapActivity(_ memory: MemoryStats) {
        let now = Date()
        defer { lastMemorySample = (now, memory) }
        guard let last = lastMemorySample else { return }
        let elapsed = now.timeIntervalSince(last.date)
        guard elapsed > 0 else { return }
        let read = Double(memory.swapInBytes &- last.memory.swapInBytes) / elapsed
        let write = Double(memory.swapOutBytes &- last.memory.swapOutBytes) / elapsed
        // Smooth out the 3 s sampling so the tile doesn't flicker.
        swapActivity = SwapActivity(
            readPerSecond: swapActivity.readPerSecond * 0.5 + read * 0.5,
            writePerSecond: swapActivity.writePerSecond * 0.5 + write * 0.5
        )
    }

}

@MainActor
final class Alerts {
    private let cooldown: TimeInterval = 15 * 60
    private var lastFired: [String: Date] = [:]
    private var hotSince: Date?
    private var idleSince: [String: Date] = [:]

    func evaluate(_ s: Snapshot, history: [Double]) {
        let now = Date()
        let culpritLine = s.culprits.first.map {
            "Maior culpado: \($0.name) (\(Format.cpu($0.cpu)) CPU, \(Format.bytes($0.memory)))."
        } ?? ""

        if let chip = s.temps.chip {
            if chip >= 88 || s.thermalPressure >= 2 {
                hotSince = hotSince ?? now
            } else {
                hotSince = nil
            }
            if let since = hotSince, now.timeIntervalSince(since) >= 30 {
                fire("hot", title: "Seu Mac está quente: \(Format.temp(chip))", body: culpritLine)
            }

            // ~1 minute ago is 20 samples back.
            if history.count >= 20 {
                let before = history[history.count - 20]
                if chip >= 75, chip - before >= 8 {
                    fire("rising",
                         title: "Esquentando rápido: \(Format.temp(before)) → \(Format.temp(chip)) em 1 min",
                         body: culpritLine)
                }
            }
        }

        if s.memory.pressure >= 2 {
            let hog = s.culprits.max { $0.memory < $1.memory }
            let hogLine = hog.map { " Quem mais ocupa: \($0.name) (\(Format.bytes($0.memory)))." } ?? ""
            fire("memory", title: "Memória no limite",
                 body: "Swap em \(Format.bytes(s.memory.swapUsed)), o SSD está fazendo papel de RAM.\(hogLine)")
        }

        var seen = Set<String>()
        for culprit in s.culprits where culprit.kind.isLeftover {
            seen.insert(culprit.id)
            let idleCPU = culprit.kind == .gradleDaemon || culprit.kind == .kotlinDaemon ? 1.0 : 3.0
            guard culprit.cpu < idleCPU else {
                idleSince[culprit.id] = nil
                continue
            }
            let since = idleSince[culprit.id] ?? now
            idleSince[culprit.id] = since
            let idleFor = now.timeIntervalSince(since)

            // Build daemons are always safe to close; simulators/emulators may be open on purpose.
            let isDaemon = culprit.kind == .gradleDaemon || culprit.kind == .kotlinDaemon
            if isDaemon, UserDefaults.standard.bool(forKey: Settings.autoCloseDaemons) {
                if idleFor >= Settings.autoCloseAfter, culprit.killable {
                    idleSince[culprit.id] = nil
                    Task {
                        guard await Killer.close(culprit) else { return }
                        Notifier.send(
                            title: "Fechei: \(culprit.name)",
                            body: "Estava parado há \(Int(Settings.autoCloseAfter / 60)) min. Liberou \(Format.bytes(culprit.memory)) de memória."
                        )
                    }
                }
                continue
            }
            if idleFor >= 10 * 60 {
                fire("idle:" + culprit.id,
                     title: "\(culprit.name) parado há 10 min",
                     body: "Ocupando \(Format.bytes(culprit.memory)) sem uso. \(culprit.advice?.text ?? "Abra o HeatWatch para encerrar.")")
            }
        }
        idleSince = idleSince.filter { seen.contains($0.key) }
    }

    private func fire(_ key: String, title: String, body: String) {
        let now = Date()
        if let last = lastFired[key], now.timeIntervalSince(last) < cooldown { return }
        lastFired[key] = now
        Notifier.send(title: title, body: body)
    }
}

enum Format {
    static func temp(_ value: Double) -> String { "\(Int(value.rounded()))°C" }

    static func cpu(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1 { return gb.formatted(.number.precision(.fractionLength(1))) + " GB" }
        return "\(Int(Double(value) / 1_048_576)) MB"
    }

    /// "12 min", "2 h", "3 dias"; nil under a minute.
    static func age(_ seconds: TimeInterval) -> String? {
        switch seconds {
        case ..<60: nil
        case ..<3600: "\(Int(seconds / 60)) min"
        case ..<86_400: "\(Int(seconds / 3600)) h"
        default: "\(Int(seconds / 86_400)) \(seconds < 172_800 ? "dia" : "dias")"
        }
    }

    static func thermalPressure(_ level: Int) -> String {
        switch level {
        case 0: "normal"
        case 1: "moderada"
        case 2: "alta"
        default: "crítica"
        }
    }

    static func memoryPressure(_ level: Int) -> String {
        switch level {
        case ..<2: "normal"
        case 2: "alta"
        default: "crítica"
        }
    }
}
