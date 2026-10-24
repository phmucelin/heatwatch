<p align="center"><img src="Resources/AppIcon.png" width="160" alt="HeatWatch icon"></p>

# HeatWatch

A tiny macOS menu bar app that tells you **why your Mac is hot** — and lets you shut the culprit down in one click.

Built for fanless MacBook Airs (M1–M4) doing developer work: Xcode and Gradle builds, iOS simulators, Android emulators, Chrome, AI coding agents in the terminal. Temperature apps tell you the chip is at 95 °C; HeatWatch tells you it's because a Gradle daemon from two hours ago is still sitting on 3 GB of RAM and pushing you into swap.

> UI is currently in Portuguese (pt-BR). English localization is welcome.

## What it shows

- **CPU temperature** in the menu bar (average of all cores, like Stats/iStat Menus), plus the hottest core, GPU, SSD and battery, and a 3-minute trend line
- **Thermal pressure** as reported by macOS (normal → moderate → heavy → critical)
- **Memory, swap and load** — the swap tile shows *activity* (MB/s read/written), not just size: 12 GB of idle swap costs nothing, swap being shuffled to the SSD costs heat
- **Culprits**, grouped the way you think about them, not as 300 raw processes:
  - Apps with all their helpers (e.g. *Google Chrome* = browser + every renderer)
  - *Simuladores iOS*, listing which devices are booted
  - *Emulador Android*, with the AVD name
  - *Gradle (build Android)* / *Compilador Kotlin* — the background daemons, detected from `java` arguments
  - *Build do Xcode (iOS)* for clang/swift compiler processes
- **Plain-language explanations**: every culprit says what it is, how long it's been open, and whether quitting it is safe (green) or interrupts something (orange)
- **Encerrar → Confirmar** quits politely (apps can save, simulators are shut down with `simctl`). If it's still alive after a few seconds, a **Forçar** button sends `SIGKILL`.

System processes (WindowServer, kernel_task, Spotlight…) are shown with an explanation but can't be killed.

## Notifications

- Core average ≥ 88 °C or heavy thermal pressure for 30 s
- Temperature rising fast (≥ 8 °C in a minute, above 75 °C)
- Memory pressure high
- A Gradle/Kotlin daemon, simulator or emulator idle for 10 minutes

Each alert names the top culprit and repeats at most every 15 minutes.

Optional: **auto-close idle Android build daemons** (Gradle/Kotlin) after 15 minutes. Simulators and emulators are never closed automatically — they may be open on purpose.

## Install

Requires macOS 14+ and the Xcode command line tools.

```bash
git clone <this repo>
cd heatwatch
./scripts/build-app.sh --install   # builds, copies to /Applications and launches
```

Tick **Abrir ao iniciar** in the popover to start it at login.

## Debugging

```bash
/Applications/HeatWatch.app/Contents/MacOS/HeatWatch --dump
```

prints the same data the popover shows. Please include it in bug reports.

## How it works

- Core temperatures come from the SMC (`Tp*`/`Te*` = performance/efficiency cores, `Tg*` = GPU), keys enumerated once at launch. On an M4 the average matches the firmware's own `TCMb` value. SSD and battery come from IOKit HID sensors. No root, no kernel extension, no `powermetrics`.
  - Note: the HID `PMU tdie*` sensors many tools read are the power-management IC, not the CPU — on an M4 Air they read 15–35 °C below the cores.
- Thermal pressure comes from the `com.apple.system.thermalpressurelevel` notification.
- Processes come from `ps`; memory per process uses `phys_footprint` (Activity Monitor's *Memory* column) when readable.
- Samples every 3 seconds; the app itself uses ~0% CPU and ~60 MB of RAM.

## Tips that actually help on a fanless Air

- `xcrun simctl shutdown all` when you're not testing iOS; don't run a simulator and an emulator at the same time on 16 GB.
- Make Gradle daemons exit after 15 idle minutes instead of 3 hours — add to `~/.gradle/gradle.properties`:
  `org.gradle.daemon.idletimeout=900000`
- Cap daemon memory in your project's `gradle.properties`:
  `org.gradle.jvmargs=-Xmx3g` and `kotlin.daemon.jvmargs=-Xmx2g`.
- Chrome → Settings → Performance → Memory Saver (maximum).
- External monitor at 60–100 Hz instead of 144/165 Hz means less work for WindowServer and the GPU.
- Lift the Mac off the desk (stand or cooling pad): the bottom case is the heatsink.
