import SwiftUI
import UserNotifications

@main
struct HeatWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = Monitor()

    init() {
        if CommandLine.arguments.contains("--dump") {
            Self.dump()
            exit(0)
        }
    }

    /// `HeatWatch --dump` prints what the popover would show, for debugging and bug reports.
    private static func dump() {
        _ = ProcessScanner.scan() // ps %CPU needs a warm-up read on some systems
        let s = Snapshot.take()
        print("Chip (média): \(s.temps.chip.map(Format.temp) ?? "n/a")  Pico: \(s.temps.chipPeak.map(Format.temp) ?? "n/a")  GPU: \(s.temps.gpu.map(Format.temp) ?? "n/a")  SSD: \(s.temps.ssd.map(Format.temp) ?? "n/a")  Bateria: \(s.temps.battery.map(Format.temp) ?? "n/a")")
        print("Pressão térmica: \(Format.thermalPressure(s.thermalPressure))  Carga: \(s.load)")
        print("Memória: \(Format.bytes(s.memory.used)) / \(Format.bytes(s.memory.total))  Swap: \(Format.bytes(s.memory.swapUsed))  Pressão: \(Format.memoryPressure(s.memory.pressure))")
        for c in s.culprits {
            let cpu = Format.cpu(c.cpu).padding(toLength: 6, withPad: " ", startingAt: 0)
            let mem = Format.bytes(c.memory).padding(toLength: 9, withPad: " ", startingAt: 0)
            let age = Format.age(c.age).map { ", aberto há \($0)" } ?? ""
            print("\(cpu)\(mem)\(c.name)\(c.killable ? "" : " (protegido)")  [\(c.pids.count) processos\(age)]")
            for line in [c.detail, c.about, c.advice.map { ($0.safe ? "✓ " : "⚠ ") + $0.text }].compactMap({ $0 }) {
                print("               \(line)")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Notifier.canUseNotificationCenter {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    // Show banners even while the popover is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
