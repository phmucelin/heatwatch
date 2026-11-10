import AppKit
import Darwin

enum CulpritKind: Equatable, Sendable {
    case app(bundlePath: String)
    case simulators
    case androidEmulator
    case nativeBuild
    case gradleDaemon
    case kotlinDaemon
    case process

    /// Dev leftovers that keep eating RAM after you stop using them.
    var isLeftover: Bool {
        switch self {
        case .simulators, .androidEmulator, .gradleDaemon, .kotlinDaemon: true
        default: false
        }
    }
}

struct Advice: Sendable {
    let text: String
    /// true: quitting loses nothing. false: quitting interrupts something.
    let safe: Bool
}

/// A group of processes that belong to the same thing the user recognizes
/// (Chrome and all its helpers, every booted simulator, the Gradle daemon...).
struct Culprit: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: CulpritKind
    var pids: [pid_t] = []
    var cpu: Double = 0
    var memory: UInt64 = 0
    var killable = true
    /// Seconds since the oldest process in the group started.
    var age: TimeInterval = 0
    /// Concrete specifics, e.g. which simulators are booted.
    var detail: String?

    /// CPU is what heats the chip; memory pushes the Mac into swap, which heats it too.
    var score: Double { cpu + Double(memory) / 1_073_741_824 * 15 }

    /// What this is, in plain words, for people who don't know the tooling.
    var about: String? {
        switch kind {
        case .gradleDaemon:
            return "Ferramenta que compila o app Android. Fica aberta escondida depois do build pra o próximo ser mais rápido."
        case .kotlinDaemon:
            return "Compilador do código Kotlin do Android. Também fica aberto escondido depois do build."
        case .nativeBuild:
            return "Compiladores que o Xcode abre enquanto faz o build do app iOS."
        case .simulators:
            return "iPhones virtuais do Xcode. Cada um ligado ocupa memória mesmo sem uso."
        case .androidEmulator:
            return "Celular Android virtual. Ocupa bastante memória enquanto está ligado."
        case .app:
            switch name {
            case "Google Chrome": return "O navegador com todas as abas e extensões."
            case "Xcode": return "Inclui a indexação do código (SourceKit)."
            default: return nil
            }
        case .process:
            switch name {
            case "WindowServer": return "Parte do macOS que desenha tudo na tela. Sobe com monitor externo, 165 Hz e animações."
            case "kernel_task": return "Parte do macOS. Quando sobe, é o sistema segurando a CPU pra esfriar o chip."
            case "mds", "mds_stores", "mdworker_shared": return "Spotlight indexando arquivos. Passa sozinho."
            case "claude", "codex": return "\(name) rodando nos seus terminais."
            case "node": return "Programas JavaScript: servidor de dev, Metro, ferramentas de linha de comando."
            case "java": return "Programa Java (Android Studio ou outra ferramenta)."
            default: return nil
            }
        }
    }

    var advice: Advice? {
        guard killable else { return nil }
        switch kind {
        case .gradleDaemon, .kotlinDaemon:
            return cpu >= 5
                ? Advice(text: "Compilando agora. Encerrar cancela o build.", safe: false)
                : Advice(text: "Parado. Pode encerrar: nada se perde, o próximo build só demora um pouco mais.", safe: true)
        case .nativeBuild:
            return Advice(text: "Encerrar cancela o build em andamento.", safe: false)
        case .simulators:
            return Advice(text: "Pode desligar: apps e dados do simulador continuam lá.", safe: true)
        case .androidEmulator:
            return Advice(text: "Pode fechar: liga de novo pelo Android Studio quando precisar.", safe: true)
        case .app:
            return name == "Google Chrome"
                ? Advice(text: "Pode fechar: as abas voltam ao reabrir. Shift+Esc no Chrome mostra qual aba pesa.", safe: true)
                : nil
        case .process:
            return name == "claude" || name == "codex"
                ? Advice(text: "Encerrar fecha todas as suas sessões de \(name), inclusive conversas em andamento.", safe: false)
                : nil
        }
    }
}

enum ProcessScanner {
    private static let compileTools: Set<String> = [
        "clang", "clang++", "swift-frontend", "swiftc", "swift-driver", "ld", "ld64", "ibtool", "actool",
    ]
    private static let protectedNames: Set<String> = [
        "WindowServer", "kernel_task", "launchd", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "coreaudiod", "mds", "mds_stores", "mdworker_shared",
    ]
    private static let maxShown = 8

    private struct RawProcess {
        let pid: pid_t
        let uid: uid_t
        let cpu: Double
        let rssKB: UInt64
        let elapsed: TimeInterval
        let path: String
        var base: String { (path as NSString).lastPathComponent }
        var isEmulator: Bool { base.hasPrefix("qemu-system") || path.contains("/emulator/") }
    }

    private static func running() -> (processes: [RawProcess], arguments: [pid_t: String]) {
        let myPid = getpid()
        let processes = listProcesses().filter { $0.pid > 0 && $0.pid != myPid }
        return (processes, readArguments(processes.filter { $0.base == "java" || $0.isEmulator }.map(\.pid)))
    }

    /// Every process still alive in a culprit's group, even when the group is
    /// no longer heavy enough to be listed.
    static func survivors(of culprit: Culprit) -> [pid_t] {
        let (processes, arguments) = running()
        return processes.filter { process in
            guard classify(process, arguments: arguments[process.pid]).0 == culprit.id else { return false }
            // CoreSimulator's background services outlive the devices and come back on demand.
            return culprit.kind != .simulators || process.base == "launchd_sim" || process.path.contains("Simulator.app/")
        }.map(\.pid)
    }

    static func scan() -> [Culprit] {
        let me = getuid()
        let (processes, arguments) = running()

        var groups: [String: Culprit] = [:]
        var hasOwnProcess: Set<String> = []
        for process in processes {
            let (key, name, kind) = classify(process, arguments: arguments[process.pid])
            var group = groups[key] ?? Culprit(id: key, name: name, kind: kind)
            group.pids.append(process.pid)
            group.cpu += process.cpu
            group.memory += footprint(of: process, me: me)
            group.age = max(group.age, process.elapsed)
            if kind == .androidEmulator, group.detail == nil, let args = arguments[process.pid] {
                group.detail = avdName(in: args)
            }
            // Simulators are shut down through simctl, so their system helpers don't matter.
            if kind != .simulators {
                if process.uid != me || protectedNames.contains(name) || isSystemPath(process.path) {
                    group.killable = false
                }
                // ps can't read the path of some exiting/helper processes; don't let those decide.
                if process.uid == me, process.path.hasPrefix("/") { hasOwnProcess.insert(key) }
            }
            groups[key] = group
        }
        for key in groups.keys where groups[key]!.kind != .simulators && !hasOwnProcess.contains(key) {
            groups[key]!.killable = false
        }

        var shown = groups.values
            .filter { $0.cpu >= 2 || $0.memory >= 400 * 1_048_576 }
            .sorted { $0.score > $1.score }
            .prefix(maxShown)
            .map { $0 }
        if let index = shown.firstIndex(where: { $0.kind == .simulators }) {
            let names = bootedSimulators()
            if !names.isEmpty { shown[index].detail = "Ligados: " + names.joined(separator: ", ") }
        }
        return shown
    }

    private static func listProcesses() -> [RawProcess] {
        let output = Shell.run("/bin/ps", ["-Aww", "-o", "pid=,uid=,pcpu=,rss=,etime=,comm="])
        return output.split(separator: "\n").compactMap { line in
            let scanner = Scanner(string: String(line))
            scanner.charactersToBeSkipped = .whitespaces
            guard let pid = scanner.scanInt32(),
                  let uid = scanner.scanUInt64(),
                  let cpu = scanner.scanDouble(),
                  let rss = scanner.scanUInt64(),
                  let etime = scanner.scanUpToCharacters(from: .whitespaces)
            else { return nil }
            var path = String(scanner.string[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
            // ps shows "(name)" when it can't read the executable path (system or exiting processes).
            if path.hasPrefix("("), path.hasSuffix(")") { path = String(path.dropFirst().dropLast()) }
            return RawProcess(pid: pid, uid: uid_t(uid), cpu: cpu, rssKB: rss, elapsed: parseElapsed(etime), path: path)
        }
    }

    /// ps etime: [[dd-]hh:]mm:ss
    private static func parseElapsed(_ text: String) -> TimeInterval {
        var days = 0.0
        var clock = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[..<dash]) ?? 0
            clock = text[text.index(after: dash)...]
        }
        let seconds = clock.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }

    /// Full command lines, needed to tell Gradle from Kotlin daemons and to name the emulator.
    private static func readArguments(_ pids: [pid_t]) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = Shell.run("/bin/ps", ["-ww", "-o", "pid=,args=", "-p", list])
        var result: [pid_t: String] = [:]
        for line in output.split(separator: "\n") {
            let scanner = Scanner(string: String(line))
            guard let pid = scanner.scanInt32() else { continue }
            result[pid] = String(line)
        }
        return result
    }

    private static func avdName(in arguments: String) -> String? {
        guard let match = arguments.firstMatch(of: #/-avd\s+(\S+)/#) else { return nil }
        return "Aparelho: " + match.1.replacingOccurrences(of: "_", with: " ")
    }

    // simctl is slow-ish; booted devices rarely change, so refresh at most every 30 s.
    private static var simulatorCache: (date: Date, names: [String])?

    private static func bootedSimulators() -> [String] {
        if let cache = simulatorCache, Date().timeIntervalSince(cache.date) < 30 { return cache.names }
        let output = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"])
        let names = output.split(separator: "\n").compactMap { line in
            line.firstMatch(of: #/^\s*(.+?) \([0-9A-F-]{36}\) \(Booted\)/#).map { String($0.1) }
        }
        simulatorCache = (Date(), names)
        return names
    }

    private static func classify(_ process: RawProcess, arguments: String?) -> (String, String, CulpritKind) {
        let path = process.path
        let base = process.base

        if base == "java", let arguments {
            if arguments.contains("GradleDaemon") { return ("gradle", "Gradle (build Android)", .gradleDaemon) }
            if arguments.contains("KotlinCompileDaemon") {
                return ("kotlin", "Compilador Kotlin (build Android)", .kotlinDaemon)
            }
        }
        if path.contains("/CoreSimulator/") || path.contains("Simulator.app/")
            || path.contains("iPhoneSimulator.platform") || base == "launchd_sim" {
            return ("simulators", "Simuladores iOS", .simulators)
        }
        if process.isEmulator {
            return ("android-emulator", "Emulador Android", .androidEmulator)
        }
        if compileTools.contains(base) {
            return ("native-build", "Build do Xcode (iOS)", .nativeBuild)
        }
        if let range = path.range(of: ".app/") {
            let bundle = canonical(String(path[..<range.lowerBound]) + ".app")
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return ("app:" + bundle, name, .app(bundlePath: bundle))
        }
        return ("proc:" + base, base, .process)
    }

    /// A helper started through a symlink (/tmp, /var, Homebrew) reports a
    /// different path than its app; resolving it keeps them in one group.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    }

    /// Activity Monitor's "Memory" column (phys_footprint) when we can read it, RSS otherwise.
    private static func footprint(of process: RawProcess, me: uid_t) -> UInt64 {
        if process.uid == me {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
                }
            }
            if status == 0 { return info.ri_phys_footprint }
        }
        return process.rssKB * 1024
    }
}

enum Killer {
    /// How long a polite quit gets before whatever is left is killed.
    static let grace: TimeInterval = 5

    /// Quits politely, kills what is still alive after `grace`, and only
    /// reports success once nothing of the group is left running.
    static func close(_ culprit: Culprit, onForce: @Sendable () async -> Void = {}) async -> Bool {
        quit(culprit)
        if await isGone(culprit, within: grace) { return true }
        await onForce()
        // A dying parent can still spawn a helper, so sweep more than once.
        for _ in 0..<3 {
            ProcessScanner.survivors(of: culprit).forEach { kill($0, SIGKILL) }
            if await isGone(culprit, within: 2) { return true }
        }
        return false
    }

    private static func isGone(_ culprit: Culprit, within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            try? await Task.sleep(for: .milliseconds(500))
            if ProcessScanner.survivors(of: culprit).isEmpty { return true }
        } while Date() < deadline
        return false
    }

    /// Polite quit: apps get a normal Quit (they can save), everything else gets SIGTERM.
    private static func quit(_ culprit: Culprit) {
        switch culprit.kind {
        case .simulators:
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
                .forEach { $0.terminate() }
            // Waits for the devices to shut down, so the grace period starts after that.
            _ = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
        case .app(let bundlePath):
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL.map { ProcessScanner.canonical($0.path) } == bundlePath
            }
            if apps.isEmpty {
                culprit.pids.forEach { kill($0, SIGTERM) }
            } else {
                apps.forEach { $0.terminate() }
            }
        default:
            culprit.pids.forEach { kill($0, SIGTERM) }
        }
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // ps prints "12,3" under pt_BR; force the C locale so numbers parse.
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
