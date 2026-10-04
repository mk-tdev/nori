import SwiftUI
import Charts
import AppKit
import UserNotifications

let ocean = Color(red: 0.24, green: 0.69, blue: 0.98)
let gpuBlue = Color(red: 0.48, green: 0.55, blue: 1.0)
let canvas = Color(red: 0.018, green: 0.065, blue: 0.12)
let panel = Color(red: 0.032, green: 0.115, blue: 0.20)

private enum NoriBrand {
    static let icon: NSImage? = Bundle.main.url(forResource: "Nori", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
}

final class NoriAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NoriBrand.icon { NSApp.applicationIconImage = icon }
        UNUserNotificationCenter.current().delegate = self
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

@main struct NoriApp: App {
    @NSApplicationDelegateAdaptor(NoriAppDelegate.self) private var appDelegate
    init() {
        if CommandLine.arguments.contains("--diagnostics") {
            let collector = Collector()
            _ = collector.collect()
            Thread.sleep(forTimeInterval: 1)
            let r = collector.collect()
            print("CPU: \(r.cpu)% | Memory: \(bytes(r.usedMemory)) | Swap: \(bytes(r.swap))")
            print("Temperature: \(r.temperature) °C (-1 means unavailable) | Processes: \(r.processes.count)")
            print("GPU: \(r.gpu.device)% | Renderer: \(r.gpu.renderer)% | Tiler: \(r.gpu.tiler)% | Cores: \(r.gpu.coreCount) | Memory: \(bytes(r.gpu.inUseMemory))")
            for app in r.gpu.apps.prefix(5) { print("GPU app \(app.name): \(String(format: "%.1f", app.usage))%") }
            print("Memory pressure: \(r.pressure.rawValue) | App groups: \(AppGrouping.groups(r.processes).count)")
            print("Network: \(r.network.status.rawValue) via \(r.network.interfaceType) \(r.network.interfaceName ?? "unknown") | ↓ \(rate(r.network.downloadBytesPerSecond)) | ↑ \(rate(r.network.uploadBytesPerSecond))")
            if CommandLine.arguments.contains("--docker") { let docker = DockerCollector.collect(); print("Docker: \(docker.status)"); for c in docker.containers { print("\(c.name): \(c.cpuText) CPU, \(c.memoryText)") } }
            if CommandLine.arguments.contains("--caches") {
                let snapshot = CacheCollector.scan()
                print("Reclaimable cache: \(bytes(UInt64(max(0, snapshot.bytes(.cache))))) | Tool data: \(bytes(UInt64(max(0, snapshot.bytes(.data))))) | Present: \(snapshot.present.count) | Unmeasured: \(snapshot.unmeasured)")
                for item in snapshot.present.sorted(by: { ($0.bytes ?? 0) > ($1.bytes ?? 0) }) {
                    print("[\(item.location.kind.rawValue)] \(item.location.tool) \(item.location.name): \(item.bytes.map { bytes(UInt64(max(0, $0))) } ?? "unmeasured") · ~/\(item.location.relativePath)")
                }
            }
            print("Core workloads: \(r.cores.map { String(format: "%.1f%%", $0) }.joined(separator: ", "))")
            print("Disk free: \(r.diskFree) | Valid CPU sample: \(r.valid)")
            for p in r.processes.prefix(5) { print("\(p.name): \(String(format: "%.1f", p.cpu))% CPU, \(bytes(p.memory))") }
            exit(r.valid && r.usedMemory > 0 && !r.processes.isEmpty && r.cores.count == ProcessInfo.processInfo.activeProcessorCount && r.cores.allSatisfy { $0.isFinite && (0...100).contains($0) } ? 0 : 1)
        }
    }
    @StateObject private var monitor = Monitor()
    var body: some Scene {
        WindowGroup("Nori", id: "dashboard") {
            Dashboard(monitor: monitor).preferredColorScheme(.dark)
                .frame(minWidth: 950, minHeight: 700)
        }.defaultSize(width: 1160, height: 810)
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: monitor.keepAwake ? "sun.max.fill" : "waveform.path.ecg")
            Text(monitor.reading.valid ? "\(Int(monitor.reading.cpu))%" : "Nori")
        }
    }
}
struct MenuContent: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("CPU: \(Int(monitor.reading.cpu))% · GPU: \(monitor.reading.gpu.available ? "\(Int(monitor.reading.gpu.device))%" : "Unavailable")")
        Text("Memory: \(Int(monitor.reading.memory))%")
        Text("Thermal state: \(monitor.thermalName)")
        Text("Memory pressure: \(monitor.reading.pressure.rawValue)")
        Text("Internet: \(monitor.reading.network.status.rawValue) · ↓ \(rate(monitor.reading.network.downloadBytesPerSecond)) · ↑ \(rate(monitor.reading.network.uploadBytesPerSecond))")
        Text("Sustained-load alerts: \(monitor.alerts.count)")
        if monitor.reading.temperature > 0 { Text("Sensors: \(Int(monitor.reading.temperature))°C") }
        Divider()
        Button("Open Nori") { NSApp.activate(ignoringOtherApps: true); if let window = NSApp.windows.first(where: { $0.title == "Nori" }) { window.makeKeyAndOrderFront(nil) } else { openWindow(id: "dashboard") } }
        Button(monitor.keepAwake ? "Stop Keeping Screen Awake" : "Keep Screen Awake") { monitor.toggleKeepAwake() }
        Button(monitor.paused ? "Resume monitoring" : "Pause monitoring") { monitor.paused.toggle() }
        Divider()
        Button("Quit Nori") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @State private var showCores = false
    private var temperatureBand: TemperatureBand { TemperatureBand(reading: monitor.reading.temperature) }
    var body: some View {
        ScrollViewReader { proxy in
        HStack(spacing: 0) {
            sidebar(proxy: proxy)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header.id("Overview")
                    HStack(spacing: 14) {
                        Button { showCores = true } label: {
                            metric("CPU USAGE  ↗", symbol: "cpu", value: monitor.reading.valid ? "\(Int(monitor.reading.cpu))" : "—", unit: "%", detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores · click to explore", fraction: monitor.reading.cpu / 100, color: ocean)
                        }.buttonStyle(.plain).frame(maxWidth: .infinity)
                            .help("Show live workload for every CPU core")
                            .accessibilityLabel("CPU usage. Show per-core workload")
                        Button { withAnimation { proxy.scrollTo("GPU", anchor: .top) } } label: {
                            metric("GPU USAGE  ↘", symbol: "square.3.layers.3d", value: monitor.reading.gpu.available ? "\(Int(monitor.reading.gpu.device))" : "—", unit: "%", detail: monitor.reading.gpu.available ? "\(monitor.reading.gpu.coreCount) cores · click for apps" : "GPU counters unavailable", fraction: monitor.reading.gpu.available ? monitor.reading.gpu.device / 100 : nil, color: gpuBlue)
                        }.buttonStyle(.plain).frame(maxWidth: .infinity)
                            .help("Show renderer, tiler, memory, and apps using the GPU")
                            .accessibilityLabel("GPU usage. Show GPU details")
                        metric("MEMORY", symbol: "memorychip", value: String(format: "%.1f", Double(monitor.reading.usedMemory) / 1_073_741_824), unit: "GB", detail: "of \(bytes(ProcessInfo.processInfo.physicalMemory)) physical memory", fraction: monitor.reading.memory / 100, color: Color(red: 0.38, green: 0.82, blue: 0.89))
                        temperatureCard
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: monitor.reading.temperature >= 90 || monitor.thermal != .nominal ? "thermometer.sun.fill" : "checkmark.circle.fill").foregroundStyle(monitor.reading.temperature >= 90 ? temperatureBand.color : ocean).font(.title3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(monitor.reading.valid ? monitor.insight : "Taking the first readings…").font(.system(size: 13, weight: .medium))
                            Text("Thermal state: \(monitor.thermalName)   ·   Swap used: \(bytes(monitor.reading.swap))").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(16).background(ocean.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(ocean.opacity(0.13)))
                    KeepAwakeCard(monitor: monitor).id("Awake")
                    NetworkCard(monitor: monitor).id("Network")
                    GPUCard(monitor: monitor).id("GPU")
                    MemoryPressureCard(monitor: monitor).id("Memory")
                    activity
                    TemperatureHistoryCard(monitor: monitor).id("Temperature")
                    AppWorkloadCard(monitor: monitor).id("Apps")
                    DockerCard(monitor: monitor).id("Docker")
                    CacheCard(monitor: monitor).id("Caches")
                    AlertsCard(monitor: monitor).id("Alerts")
                    HStack {
                        Label("All readings stay on your Mac", systemImage: "lock.shield").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(monitor.reading.time.formatted(date: .omitted, time: .standard)) · \(monitor.paused ? "Paused" : "Refreshes every 2s")").foregroundStyle(.secondary)
                    }.font(.system(size: 11))
                }.padding(30)
            }
        }.background(canvas).tint(ocean)
            .sheet(isPresented: $showCores) { CoreWorkloadView(monitor: monitor) }
        }
    }
    func sidebar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 9) {
                if let icon = NoriBrand.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: 40, height: 40).accessibilityLabel("Nori app icon")
                } else {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 25, weight: .medium)).foregroundStyle(ocean)
                }
                Text("nori").font(.system(size: 27, weight: .semibold, design: .rounded))
            }.padding(.top, 34)
            Text("YOUR MAC, AT A GLANCE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(["Overview", "Awake", "Network", "GPU", "Apps", "Docker", "Caches", "Memory", "Temperature", "Alerts"], id: \.self) { section in
                    Button { withAnimation { proxy.scrollTo(section, anchor: .top) } } label: {
                        HStack {
                            Text(section)
                            Spacer()
                            if section == "Alerts", !monitor.alerts.isEmpty { Text("\(monitor.alerts.count)").foregroundStyle(.orange) }
                        }.font(.system(size: 13, weight: .medium)).foregroundStyle(ocean)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ocean.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(Host.current().localizedName ?? "This Mac").font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text("\(ProcessInfo.processInfo.activeProcessorCount) CPU cores\n\(bytes(ProcessInfo.processInfo.physicalMemory)) memory").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
                Divider()
                Text("STORAGE").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                ProgressView(value: max(0, min(1, 1 - Double(monitor.reading.diskFree) / Double(max(1, monitor.reading.diskTotal))))).tint(ocean)
                Text("\(bytes(UInt64(max(0, monitor.reading.diskFree)))) available").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            Text("NORI / 02").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.tertiary)
        }.padding(20).frame(width: 180).frame(maxHeight: .infinity).background(Color.white.opacity(0.018)).overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
    }
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("A little clarity for your Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("System overview").font(.system(size: 28, weight: .semibold))
            }
            Spacer()
            HStack(spacing: 6) { Circle().fill(monitor.paused ? Color.orange : ocean).frame(width: 6, height: 6); Text(monitor.paused ? "PAUSED" : "LIVE").font(.system(size: 10, weight: .semibold)).tracking(1) }.padding(.horizontal, 11).padding(.vertical, 7).background(.white.opacity(0.04), in: Capsule())
            Button { monitor.paused.toggle(); if !monitor.paused { monitor.refresh() } } label: { Image(systemName: monitor.paused ? "play.fill" : "pause.fill").frame(width: 26, height: 26) }.buttonStyle(.borderless).help(monitor.paused ? "Resume monitoring" : "Pause monitoring").accessibilityLabel(monitor.paused ? "Resume monitoring" : "Pause monitoring")
        }
    }
    var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TEMPERATURE").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "thermometer.medium").foregroundStyle(temperatureBand.color)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(monitor.reading.temperature > 0 ? "\(Int(monitor.reading.temperature))" : "—")
                    .font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(temperatureBand.color)
                Text("°C").font(.system(size: 18)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(temperatureBand.rawValue).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(temperatureBand.color).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(temperatureBand.color.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 4) {
                ForEach(TemperatureBand.measured, id: \.self) { band in
                    Capsule().fill(band.color.opacity(band == temperatureBand ? 1 : 0.2))
                }
            }.frame(height: 4)
            Text(monitor.reading.temperature > 0 ? "CPU sensor average · macOS: \(monitor.thermalName)" : "Sensor unavailable on this Mac")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(temperatureBand.color.opacity(0.35)))
            .help("Display bands: Cool below 60°C; Moderate 60–74°C; Warm 75–89°C; Hot 90°C and above. These are visual guides, not hardware safety limits. macOS thermal state is separate.")
            .accessibilityElement(children: .combine)
    }
    func metric(_ title: String, symbol: String, value: String, unit: String, detail: String, fraction: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2); Spacer(); Image(systemName: symbol).font(.system(size: 16)) }.foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) { Text(value).font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit(); Text(unit).font(.system(size: 18)).foregroundStyle(.secondary) }
            if let fraction { GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(.white.opacity(0.06)); Capsule().fill(color).frame(width: g.size.width * max(0, min(1, fraction))) } }.frame(height: 4) }
            else { HStack(spacing: 5) { Circle().fill(monitor.thermal == .nominal ? ocean : .orange).frame(width: 5, height: 5); Text("macOS: \(monitor.thermalName)").font(.system(size: 10)) }.frame(height: 4) }
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.055)))
    }
    var activity: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Activity").font(.system(size: 15, weight: .semibold))
                Text("/ last 2 minutes").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Label("CPU", systemImage: "circle.fill").foregroundStyle(ocean)
                Label("GPU", systemImage: "circle.fill").foregroundStyle(gpuBlue)
                Label("Memory", systemImage: "circle.fill").foregroundStyle(Color(red: 0.38, green: 0.82, blue: 0.89))
            }.font(.system(size: 10))
            Chart {
                ForEach(monitor.history.filter { $0.time >= monitor.reading.time.addingTimeInterval(-120) }) { sample in
                    LineMark(x: .value("Time", sample.time), y: .value("Usage", sample.cpu), series: .value("Metric", "CPU")).foregroundStyle(ocean).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.linear)
                    if let gpu = sample.gpu {
                        LineMark(x: .value("Time", sample.time), y: .value("Usage", gpu), series: .value("Metric", "GPU")).foregroundStyle(gpuBlue).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.linear)
                    }
                    LineMark(x: .value("Time", sample.time), y: .value("Usage", sample.memory), series: .value("Metric", "Memory")).foregroundStyle(Color(red: 0.38, green: 0.82, blue: 0.89)).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.linear)
                }
            }.chartYScale(domain: 0...100).chartXScale(domain: monitor.reading.time.addingTimeInterval(-120)...monitor.reading.time)
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { value in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 9)).foregroundStyle(.secondary) } } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()).font(.system(size: 9)) } }.frame(height: 140)
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct KeepAwakeCard: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: monitor.keepAwake ? "sun.max.fill" : "moon.zzz")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(monitor.keepAwake ? ocean : Color.secondary)
                .frame(width: 38, height: 38)
                .background((monitor.keepAwake ? ocean : Color.white).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("Keep screen awake").font(.system(size: 15, weight: .semibold))
                    if monitor.keepAwake {
                        Text("ACTIVE").font(.system(size: 9, weight: .bold)).tracking(1)
                            .foregroundStyle(ocean).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(ocean.opacity(0.12), in: Capsule())
                    }
                }
                Text(monitor.keepAwake
                     ? "Nori is keeping the display and Mac awake while your work runs."
                     : "Start this before walking away; stop it to restore your normal macOS sleep timer.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let error = monitor.keepAwakeError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                monitor.toggleKeepAwake()
            } label: {
                Label(monitor.keepAwake ? "Stop" : "Start", systemImage: monitor.keepAwake ? "stop.fill" : "play.fill")
                    .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(monitor.keepAwake ? Color.orange : ocean)
            .controlSize(.large)
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .help(monitor.keepAwake ? "Restore normal display and system sleep" : "Keep this Mac awake until stopped or Nori quits")
        }
        .padding(18)
        .background(panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke((monitor.keepAwake ? ocean : Color.white).opacity(monitor.keepAwake ? 0.4 : 0.055)))
        .accessibilityElement(children: .contain)
    }
}

struct CoreWorkloadView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inside your CPU").font(.system(size: 26, weight: .semibold))
                    Text("Live workload · each bar represents one logical core")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Label(monitor.paused ? "Paused" : "Live · updates every 2 seconds", systemImage: monitor.paused ? "pause.circle" : "waveform.path")
                Spacer()
                Text("System total: \(Int(monitor.reading.cpu))%")
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(ocean)
            ScrollView {
                if monitor.reading.cores.isEmpty {
                    ContentUnavailableView("Waiting for core readings", systemImage: "cpu", description: Text("Per-core workloads appear after two successful samples. Resume monitoring if paused."))
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(Array(monitor.reading.cores.enumerated()), id: \.offset) { index, usage in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Core \(index + 1)").font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text("\(Int(usage))%").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(ocean)
                                }
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.07))
                                        Capsule().fill(LinearGradient(colors: [Color(red: 0.12, green: 0.4, blue: 0.86), ocean], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: geometry.size.width * max(0, min(1, usage / 100)))
                                    }
                                }.frame(height: 7)
                                Text(usage >= 80 ? "Busy" : usage >= 30 ? "Active" : "Light workload")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(16).background(panel, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Core \(index + 1), \(Int(usage)) percent utilization")
                        }
                    }
                }
            }.frame(maxHeight: 420)
            Text("100% means a fully occupied core. Core numbers follow macOS processor order; performance and efficiency types are not inferred.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(width: 620).background(canvas).preferredColorScheme(.dark).tint(ocean)
    }
}
