import ServiceManagement
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: monitor.level.symbol)
            Text(monitor.snapshot.temps.chip.map { "\(Int($0.rounded()))°" } ?? "—")
                .monospacedDigit()
        }
    }
}

struct MenuView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderView(monitor: monitor)
            StatsView(snapshot: monitor.snapshot, swap: monitor.swapActivity, cores: monitor.cores)
            Divider()
            CulpritsView(monitor: monitor)
            Divider()
            FooterView()
        }
        .padding(16)
        .frame(width: 380)
    }
}

private struct HeaderView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let level = monitor.level
        let snapshot = monitor.snapshot
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.temps.chip.map(Format.temp) ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(level.color)
                    Text(level.label)
                        .font(.headline)
                        .foregroundStyle(level.color)
                }
                Text(subtitle(snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.thermalPressure >= 1 {
                    Text("macOS está reduzindo a velocidade para esfriar")
                        .font(.caption)
                        .foregroundStyle(level.color)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Sparkline(values: monitor.chipHistory, capacity: Monitor.historyLength, color: level.color)
                    .frame(width: 110, height: 34)
                Text("últimos 3 min")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func subtitle(_ snapshot: Snapshot) -> String {
        var parts = ["Média dos núcleos"]
        if let peak = snapshot.temps.chipPeak { parts.append("pico \(Format.temp(peak))") }
        parts.append("pressão térmica \(Format.thermalPressure(snapshot.thermalPressure))")
        return parts.joined(separator: " · ")
    }
}

private struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                // Fixed floor/ceiling so a 2 °C wiggle doesn't look like a spike.
                let low = min(values.min()!, 40)
                let high = max(values.max()!, 100)
                let step = geo.size.width / CGFloat(max(capacity - 1, 1))
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geo.size.width - CGFloat(values.count - 1 - index) * step
                        let y = geo.size.height * (1 - CGFloat((value - low) / (high - low)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityLabel("Temperatura do chip nos últimos 3 minutos")
    }
}

private struct StatsView: View {
    let snapshot: Snapshot
    let swap: SwapActivity
    let cores: Int

    private var swapDetail: String {
        if swap.isActive {
            return swap.readPerSecond >= swap.writePerSecond
                ? "lendo \(Format.bytes(UInt64(swap.readPerSecond)))/s"
                : "gravando \(Format.bytes(UInt64(swap.writePerSecond)))/s"
        }
        return snapshot.memory.swapUsed >= 1_073_741_824 ? "parado (antigo)" : "ok"
    }

    var body: some View {
        let memory = snapshot.memory
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatTile(
                    title: "Memória",
                    value: "\(Format.bytes(memory.used)) / \(Int((Double(memory.total) / 1_073_741_824).rounded())) GB",
                    detail: "pressão \(Format.memoryPressure(memory.pressure))",
                    alert: memory.pressure >= 2
                )
                StatTile(
                    title: "Swap",
                    value: Format.bytes(memory.swapUsed),
                    detail: swapDetail,
                    alert: swap.isActive
                )
                StatTile(
                    title: "Carga",
                    value: snapshot.load.formatted(.number.precision(.fractionLength(1))),
                    detail: "\(cores) núcleos",
                    alert: snapshot.load > Double(cores) * 1.5
                )
            }
            let extras = [
                snapshot.temps.gpu.map { "GPU \(Format.temp($0))" },
                snapshot.temps.ssd.map { "SSD \(Format.temp($0))" },
                snapshot.temps.battery.map { "Bateria \(Format.temp($0))" },
            ].compactMap { $0 }
            if !extras.isEmpty {
                Text(extras.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let alert: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(.caption2).foregroundStyle(alert ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

private struct CulpritsView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quem está esquentando")
                .font(.subheadline.weight(.semibold))
            if monitor.snapshot.culprits.isEmpty {
                Text("Nada pesado rodando agora.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.snapshot.culprits) { culprit in
                CulpritRow(culprit: culprit, monitor: monitor)
            }
        }
    }
}

private struct CulpritRow: View {
    let culprit: Culprit
    @ObservedObject var monitor: Monitor
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CulpritIcon(kind: culprit.kind)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(culprit.name)
                    .lineLimit(1)
                Text(stats)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let detail = culprit.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let about = culprit.about {
                    Text(about)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let advice = culprit.advice {
                    Label(advice.text, systemImage: advice.safe ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(advice.safe ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            action
                .controlSize(.small)
        }
    }

    private var stats: String {
        var parts = ["\(Format.cpu(culprit.cpu)) CPU", Format.bytes(culprit.memory)]
        if let age = Format.age(culprit.age) { parts.append("aberto há \(age)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var action: some View {
        if !culprit.killable {
            EmptyView()
        } else if monitor.needsForce(culprit) {
            Button("Forçar") { monitor.forceQuit(culprit) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Ainda aberto. Mata na hora (dados não salvos se perdem).")
        } else if monitor.isQuitting(culprit) {
            ProgressView().controlSize(.small)
        } else if confirming {
            Button("Confirmar") {
                confirming = false
                monitor.quit(culprit)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button("Encerrar") {
                confirming = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirming = false }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct CulpritIcon: View {
    let kind: CulpritKind
    private static var iconCache: [String: NSImage] = [:]

    var body: some View {
        switch kind {
        case .app(let path):
            Image(nsImage: Self.icon(for: path)).resizable()
        case .simulators:
            symbol("iphone")
        case .androidEmulator:
            symbol("candybarphone")
        case .nativeBuild:
            symbol("hammer.fill")
        case .gradleDaemon, .kotlinDaemon:
            symbol("gearshape.2.fill")
        case .process:
            symbol("terminal.fill")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }
}

private struct FooterView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Settings.autoCloseDaemons) private var autoCloseDaemons = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Fechar sozinho o build Android parado há \(Int(Settings.autoCloseAfter / 60)) min", isOn: $autoCloseDaemons)
                .help("Gradle e compilador Kotlin. Nada se perde; o próximo build só demora um pouco mais.")
            HStack(spacing: 14) {
                Toggle("Abrir ao iniciar", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                Spacer()
                Button("Monitor de Atividade") {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
                Button("Sair") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }
}
