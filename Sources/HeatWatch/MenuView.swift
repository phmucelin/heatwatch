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
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(monitor: monitor)
            HistoryChart(values: monitor.chipHistory, capacity: Monitor.historyLength, color: monitor.level.color)
            SensorTiles(temps: monitor.snapshot.temps)
            SystemMeters(snapshot: monitor.snapshot, swap: monitor.swapActivity, cores: monitor.cores)
            Divider()
            CulpritsView(monitor: monitor)
            Divider()
            FooterView()
        }
        .padding(18)
        .frame(width: 380)
        .background(Backdrop())
        .environment(\.colorScheme, .dark)
    }
}

/// Dark see-through panel that blurs the desktop behind the popover.
private struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = DarkEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class DarkEffectView: NSVisualEffectView {
    // The panel is designed dark, so native controls (checkboxes, buttons)
    // must be dark too, even when the system is in light mode.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.appearance = NSAppearance(named: .darkAqua)
    }
}

private enum Style {
    static let track = Color.white.opacity(0.15)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let columnHeader = Font.system(size: 10)
    static let cpuColumn: CGFloat = 84
    static let memoryColumn: CGFloat = 58
    static let actionColumn: CGFloat = 26
}

private struct Meter: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Style.track)
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

private struct HeaderView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let level = monitor.level
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                Text(snapshot.temps.chip.map(Format.temp) ?? "—")
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .tracking(-1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(level.color)
                Text(level.label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(level.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(level.color))
                    .fixedSize()
                    .padding(.bottom, 7)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    if let peak = snapshot.temps.chipPeak {
                        HStack(spacing: 4) {
                            Text("pico")
                            Text(Format.temp(peak)).fontWeight(.semibold).foregroundStyle(.primary)
                        }
                    }
                    Text("pressão térmica \(Format.thermalPressure(snapshot.thermalPressure))")
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.bottom, 6)
            }
            if snapshot.thermalPressure >= 1 {
                Text("macOS está reduzindo a velocidade para esfriar")
                    .font(.caption)
                    .foregroundStyle(level.color)
            }
        }
    }
}

private struct HistoryChart: View {
    let values: [Double]
    let capacity: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                // Fixed floor/ceiling so a 2 °C wiggle doesn't look like a spike.
                let low = min(values.min() ?? 40, 40)
                let high = max(values.max() ?? 100, 100)
                func y(_ temp: Double) -> CGFloat { size.height * (1 - CGFloat((temp - low) / (high - low))) }

                let hot = y(HeatLevel.hotFrom), critical = y(HeatLevel.criticalFrom)
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: critical)), with: .color(.red.opacity(0.1)))
                context.fill(Path(CGRect(x: 0, y: critical, width: size.width, height: hot - critical)), with: .color(.orange.opacity(0.1)))
                let thresholds = [(HeatLevel.criticalFrom, "muito quente"), (HeatLevel.hotFrom, "quente"), (HeatLevel.warmFrom, "morno")]
                for (temp, name) in thresholds {
                    var rule = Path()
                    rule.move(to: CGPoint(x: 0, y: y(temp)))
                    rule.addLine(to: CGPoint(x: size.width, y: y(temp)))
                    context.stroke(rule, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    let label = Text("\(Int(temp))° \(name)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                    context.draw(label, at: CGPoint(x: 4, y: y(temp) - 2), anchor: .bottomLeading)
                }

                guard values.count > 1 else { return }
                // Newest sample sits at the right edge, leaving room for its dot.
                let right = size.width - 5
                let step = right / CGFloat(max(capacity - 1, 1))
                let points = values.enumerated().map { index, value in
                    CGPoint(x: right - CGFloat(values.count - 1 - index) * step, y: y(value))
                }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                area.addLine(to: CGPoint(x: points[0].x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.12)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                let last = points[points.count - 1]
                context.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(color))
            }
            .frame(height: 120)
            .accessibilityLabel("Temperatura do chip nos últimos 3 minutos")
            HStack {
                Text("−3 min")
                Spacer()
                Text("−2 min")
                Spacer()
                Text("−1 min")
                Spacer()
                Text("agora")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}

private struct SensorTiles: View {
    let temps: Temperatures

    var body: some View {
        // SSD and battery have their own limits, so only the chip sensors get heat colors.
        let neutral = Color.white.opacity(0.55)
        let tiles: [(name: String, value: Double?, color: Color?)] = [
            ("CPU", temps.chip, nil), ("GPU", temps.gpu, nil), ("SSD", temps.ssd, neutral), ("Bateria", temps.battery, neutral),
        ]
        HStack(spacing: 8) {
            ForEach(tiles, id: \.name) { tile in
                if let value = tile.value {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tile.name.uppercased())
                            .font(Style.columnHeader)
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text("\(Int(value.rounded()))°")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        Meter(fraction: value / 100, color: tile.color ?? HeatLevel(chip: value, pressure: 0).color, height: 3)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                }
            }
        }
    }
}

private struct SystemMeters: View {
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
        let calm = Color(red: 0.54, green: 0.71, blue: 1)
        let totalGB = Int((Double(memory.total) / 1_073_741_824).rounded())
        VStack(spacing: 8) {
            row("Memória", value: "\(Format.bytes(memory.used)) / \(totalGB) GB") {
                Meter(fraction: Double(memory.used) / Double(max(memory.total, 1)),
                      color: memory.pressure >= 2 ? .orange : calm, height: 6)
            }
            row("Carga", value: "\(snapshot.load.formatted(.number.precision(.fractionLength(1)))) / \(cores) núcleos") {
                Meter(fraction: snapshot.load / Double(cores),
                      color: snapshot.load > Double(cores) * 1.5 ? .orange : calm, height: 6)
            }
            row("Swap", value: Format.bytes(memory.swapUsed)) {
                Text(swapDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(swap.isActive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ title: String, value: String, @ViewBuilder middle: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            middle()
            Text(value)
                .font(Style.mono)
                .lineLimit(1)
                .frame(width: 112, alignment: .trailing)
        }
    }
}

private struct CulpritsView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let culprits = monitor.snapshot.culprits
        // One full core is the smallest scale, so a 3% process doesn't fill its bar.
        let cpuScale = max(culprits.map(\.cpu).max() ?? 0, 100)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text("PROCESSO").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: Style.cpuColumn, alignment: .leading)
                Text("MEMÓRIA").frame(width: Style.memoryColumn, alignment: .trailing)
                Color.clear.frame(width: Style.actionColumn, height: 1)
            }
            .font(Style.columnHeader)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            if culprits.isEmpty {
                Text("Nada pesado rodando agora.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(culprits.enumerated()), id: \.element.id) { index, culprit in
                CulpritRow(culprit: culprit, isTop: index == 0, cpuScale: cpuScale, monitor: monitor)
            }
        }
    }
}

private struct CulpritRow: View {
    let culprit: Culprit
    /// The heaviest item on the list is the one painted red.
    let isTop: Bool
    let cpuScale: Double
    @ObservedObject var monitor: Monitor
    @State private var confirming = false
    @State private var expanded = false

    private static let topText = Color(red: 1, green: 0.54, blue: 0.51)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: { title }
                    .buttonStyle(.plain)
                    .help(expanded ? "Esconder detalhes" : "Mostrar detalhes")
                if confirming {
                    Button("Confirmar") {
                        confirming = false
                        monitor.quit(culprit)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .help("Se não fechar em \(Int(Killer.grace)) s, é encerrado à força (o que não foi salvo se perde).")
                } else {
                    HStack(spacing: 6) {
                        Meter(fraction: culprit.cpu / cpuScale, color: isTop ? .red : culprit.cpu >= 50 ? .orange : .yellow)
                        Text(Format.cpu(culprit.cpu))
                            .font(Style.mono)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: Style.cpuColumn)
                    Text(Format.bytes(culprit.memory))
                        .font(Style.mono)
                        .lineLimit(1)
                        .frame(width: Style.memoryColumn, alignment: .trailing)
                    action
                        .frame(width: Style.actionColumn, height: Style.actionColumn)
                }
            }
            .frame(height: 32)
            if expanded { details }
        }
        .font(.system(size: 12))
        .foregroundStyle(isTop ? AnyShapeStyle(Self.topText) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .background {
            if isTop {
                RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.18))
                RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.5))
            }
        }
        .padding(.horizontal, -8)
    }

    private var title: some View {
        HStack(spacing: 5) {
            Text(culprit.name)
                .fontWeight(isTop ? .semibold : .regular)
                .lineLimit(1)
            if let tag {
                Text(tag.text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tag.color)
                    .fixedSize()
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// Only what's happening to the row right now; the advice lives in the details.
    private var tag: (text: String, color: Color)? {
        switch monitor.quitPhases[culprit.id] {
        case .closing: ("fechando…", .secondary)
        case .forcing: ("forçando…", .orange)
        case .failed: ("reabriu sozinho", .red)
        case nil: nil
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let age = Format.age(culprit.age) {
                Text("Aberto há \(age)")
                    .foregroundStyle(.secondary)
            }
            if let detail = culprit.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            if let about = culprit.about {
                Text(about)
                    .foregroundStyle(.secondary)
            }
            if let advice = culprit.advice {
                Label(advice.text, systemImage: advice.safe ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(advice.safe ? .green : .orange)
            }
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var action: some View {
        let phase = monitor.quitPhases[culprit.id]
        if !culprit.killable {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Protegido: o HeatWatch não fecha processos do sistema.")
        } else if phase == .closing || phase == .forcing {
            ProgressView().controlSize(.small)
        } else {
            Button {
                confirming = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirming = false }
            } label: {
                Image(systemName: phase == .failed ? "arrow.clockwise" : "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.2)))
            .help(phase == .failed
                ? "Foi encerrado à força, mas o sistema abriu de novo sozinho. Tentar de novo."
                : "Fechar \(culprit.name)")
            .accessibilityLabel("Fechar \(culprit.name)")
        }
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
