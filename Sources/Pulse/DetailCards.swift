import SwiftUI
import Charts
import AppKit

extension MemoryPressure {
    var color: Color {
        switch self { case .normal: .cyan; case .warning: .orange; case .critical: .red; case .unknown: .gray }
    }
}
struct MemoryPressureCard: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Memory pressure", systemImage: "memorychip").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(monitor.reading.pressure.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(monitor.reading.pressure.color)
            }
            HStack(spacing: 5) {
                ForEach([MemoryPressure.normal, .warning, .critical], id: \.self) { pressure in
                    Capsule().fill(pressure.color.opacity(pressure == monitor.reading.pressure ? 1 : 0.15))
                }
            }.frame(height: 5)
            Text(monitor.reading.pressure.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Text("Compressed: \(bytes(monitor.reading.compressed))")
                Text("Swap: \(bytes(monitor.reading.swap))")
                Text("Page outs: \(bytes(UInt64(max(0, monitor.reading.pageOutBytesPerSecond))))/s")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}
struct TemperatureHistoryCard: View {
    @ObservedObject var monitor: Monitor
    @State private var minutes = 5
    struct Point: Identifiable {
        let id: UUID
        let time: Date
        let value: Double
        let segment: Int
    }
    var points: [Point] {
        var segment = 0
        var previous: Date?
        return monitor.history.filter { $0.time >= monitor.reading.time.addingTimeInterval(-Double(minutes) * 60) }.compactMap { sample in
            guard let value = sample.temperature else { segment += 1; previous = nil; return nil }
            if let previous, sample.time.timeIntervalSince(previous) > 8 { segment += 1 }
            previous = sample.time
            return Point(id: sample.id, time: sample.time, value: value, segment: segment)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Temperature history").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("History window", selection: $minutes) {
                    Text("2 min").tag(2); Text("5 min").tag(5); Text("15 min").tag(15)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            if points.isEmpty {
                Text("Waiting for readable CPU temperature sensors…").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 130)
            } else {
                Chart {
                    RuleMark(y: .value("High-temperature guide", 90)).foregroundStyle(.red.opacity(0.4)).lineStyle(StrokeStyle(dash: [4, 4]))
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.time), y: .value("Temperature", point.value), series: .value("Segment", point.segment))
                            .foregroundStyle(ocean).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Time", point.time), y: .value("Temperature", point.value))
                            .foregroundStyle(TemperatureBand(reading: point.value).color).symbolSize(8)
                    }
                }.chartYScale(domain: 0...130)
                    .chartXScale(domain: monitor.reading.time.addingTimeInterval(-Double(minutes) * 60)...monitor.reading.time)
                    .chartYAxis { AxisMarks(values: [30, 60, 90, 120]) { value in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel { Text("\(value.as(Int.self) ?? 0)°C").font(.system(size: 9)) } } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9)) } }
                    .frame(height: 150)
            }
            Text("Sensor average · 90°C guide · session history only · gaps mark missing or paused readings")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}
struct AppWorkloadCard: View {
    @ObservedObject var monitor: Monitor
    @State private var search = ""
    @State private var sortMemory = false
    @State private var selected: String?
    @State private var showAll = false
    var groups: [AppWorkload] {
        let matches = AppGrouping.groups(monitor.reading.processes).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let sorted = sortMemory ? matches.sorted { $0.memory > $1.memory } : matches
        return showAll || !search.isEmpty ? sorted : Array(sorted.prefix(8))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Workload by app").font(.system(size: 15, weight: .semibold))
                Spacer()
                TextField("Find an app", text: $search).textFieldStyle(.roundedBorder).frame(width: 150)
                Picker("Sort apps", selection: $sortMemory) { Text("CPU").tag(false); Text("Memory").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            HStack { Text("APP / PROCESSES"); Spacer(); Text("CPU").frame(width: 80, alignment: .trailing); Text("MEMORY").frame(width: 90, alignment: .trailing) }
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            ForEach(groups) { group in
                Button { selected = group.name } label: {
                    HStack(spacing: 10) {
                        Image(systemName: group.name == "Docker" ? "shippingbox" : "app.connected.to.app.below.fill").foregroundStyle(ocean).frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name).font(.system(size: 12, weight: .medium))
                            Text("\(group.processes.count) processes · click to inspect").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f%%", group.cpu)).foregroundStyle(ocean).frame(width: 80, alignment: .trailing)
                        Text(bytes(group.memory)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    }.font(.system(size: 12, design: .monospaced)).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
            if groups.isEmpty { Text("No matching apps").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Text("100% CPU = one core. Memory sums resident pages; shared pages may be counted more than once.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(showAll ? "Show less" : "Show all") { showAll.toggle() }.font(.system(size: 11))
            }
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
            .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                AppProcessSheet(monitor: monitor, name: selected ?? "App")
            }
    }
}
struct AppProcessSheet: View {
    @ObservedObject var monitor: Monitor
    let name: String
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(name).font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Live processes belonging to this app").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                let processes = monitor.reading.processes.filter { $0.app == name }
                if processes.isEmpty { Text("This app has no running processes.").foregroundStyle(.secondary) }
                ForEach(processes) { p in
                    HStack {
                        VStack(alignment: .leading) { Text(p.name); Text("PID \(p.id)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(String(format: "%.1f%%", p.cpu)).foregroundStyle(ocean).frame(width: 85, alignment: .trailing)
                        Text(bytes(p.memory)).frame(width: 95, alignment: .trailing)
                    }.font(.system(size: 12)).padding(.vertical, 6)
                    Divider()
                }
            }.frame(height: 350)
            Text("Owned helper bundles and identifiable child processes are included. Unattributed processes remain under their executable name.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 580).background(canvas).preferredColorScheme(.dark)
    }
}
struct DockerCard: View {
    @ObservedObject var monitor: Monitor
    @State private var sortMemory = false
    var containers: [ContainerReading] {
        sortMemory ? monitor.docker.containers.sorted { $0.memory > $1.memory } : monitor.docker.containers
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Docker containers", systemImage: "shippingbox").font(.system(size: 15, weight: .semibold))
                Spacer()
                if monitor.dockerLoading { ProgressView().controlSize(.small) }
                Picker("Sort containers", selection: $sortMemory) { Text("CPU").tag(false); Text("Memory %").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 145)
                Button("Refresh") { monitor.refreshDocker() }.disabled(monitor.dockerLoading || monitor.paused)
            }
            Text(monitor.docker.status).font(.system(size: 12)).foregroundStyle(monitor.docker.available ? ocean : .secondary)
            ForEach(containers) { container in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(container.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(container.cpuText + " CPU").foregroundStyle(ocean)
                        Text(container.memoryText).foregroundStyle(.secondary)
                    }.font(.system(size: 11, design: .monospaced))
                    HStack(spacing: 18) {
                        Text("Memory \(container.memoryPercent)")
                        Text("Network \(container.network)")
                        Text("Disk I/O \(container.disk)")
                        Text("\(container.pids) PIDs")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(12).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            }
            if let date = monitor.docker.date {
                Text("Updated \(date.formatted(date: .omitted, time: .standard)) · \(monitor.paused ? "paused" : "every 10s")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Local Docker only · CPU 100% = one VM core · network and disk I/O are cumulative · container memory is part of Docker’s host workload; do not add the totals together.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CacheCard: View {
    @ObservedObject var monitor: Monitor
    @State private var showAll = false
    @State private var expanded = true
    private func rows(_ kind: CacheKind) -> [CacheMeasurement] {
        monitor.caches.present.filter { $0.location.kind == kind }.sorted { first, second in
            let a = first.bytes ?? -1, b = second.bytes ?? -1
            return a == b ? first.location.tool < second.location.tool : a > b
        }
    }
    private func size(_ item: CacheMeasurement) -> String {
        switch item.state {
        case .measured(let value, let partial): bytes(UInt64(max(0, value))) + (partial ? " +" : "")
        case .pending: "—"
        case .absent: "not present"
        case .unreadable: "unreadable"
        case .timedOut: "timed out"
        }
    }
    private func row(_ item: CacheMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.location.tool).font(.system(size: 12, weight: .semibold))
                Text(item.location.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(size(item)).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(item.bytes == nil ? Color.secondary : (item.location.kind == .cache ? ocean : Color(red: 0.38, green: 0.82, blue: 0.89)))
                if item.location.kind == .cache {
                    Button {
                        monitor.cleanCache(item)
                    } label: {
                        if monitor.cacheCleaning.contains(item.id) {
                            ProgressView().controlSize(.small).frame(width: 46)
                        } else {
                            Text("Clean").frame(width: 46)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(monitor.cacheScanning || monitor.cacheCleaning.contains(item.id))
                    .help("Delete only ~/\(item.location.relativePath). The tool can rebuild this cache.")
                    .accessibilityLabel("Clean \(item.location.tool) \(item.location.name)")
                }
            }
            HStack {
                Text("~/" + item.location.relativePath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.location.hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let message = monitor.cacheMessages[item.id] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }.padding(12).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(item.location.path(home: NSHomeDirectory()), inFileViewerRootedAtPath: NSHomeDirectory()) }
                Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.location.path(home: NSHomeDirectory()), forType: .string) }
            }
    }
    private func section(_ kind: KindSection) -> some View {
        let items = rows(kind.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Text(bytes(UInt64(max(0, monitor.caches.bytes(kind.kind))))).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(kind.color)
            }
            Text(kind.kind.explanation).font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(showAll ? items : Array(items.prefix(6))) { row($0) }
            if !showAll, items.count > 6 { Text("\(items.count - 6) more").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
    private struct KindSection { let kind: CacheKind; let title: String; let color: Color }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        Label("Developer caches", systemImage: "internaldrive")
                            .font(.system(size: 15, weight: .semibold))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(expanded ? "Minimize developer caches" : "Expand developer caches")
                Spacer()
                if !expanded {
                    Text(bytes(UInt64(max(0, monitor.caches.bytes(.cache)))))
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(ocean)
                }
                if monitor.cacheScanning { ProgressView().controlSize(.small) }
                Button(monitor.cacheScanning ? "Scanning…" : monitor.caches.scanned == nil ? "Scan" : "Rescan") { monitor.scanCaches() }
                    .disabled(monitor.cacheScanning || !monitor.cacheCleaning.isEmpty)
                    .help("Measure the size of every known cache location. Nothing is deleted.")
            }
            if let message = monitor.cacheLastAction {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
            }
            if expanded, monitor.caches.present.isEmpty {
                Text("No known developer cache locations found in your home directory.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if expanded {
                Text(monitor.caches.scanned == nil
                     ? "\(monitor.caches.present.count) locations found. Sizes are measured only when you scan."
                     : "\(monitor.caches.present.count) locations · \(monitor.caches.unmeasured) unmeasured")
                    .font(.system(size: 12)).foregroundStyle(monitor.caches.scanned == nil ? .secondary : ocean)
                section(KindSection(kind: .cache, title: "RECLAIMABLE CACHE", color: ocean))
                section(KindSection(kind: .data, title: "TOOL DATA — NOT CACHE", color: Color(red: 0.38, green: 0.82, blue: 0.89)))
                HStack {
                    if let date = monitor.caches.scanned {
                        Text("Measured \(date.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if rows(.cache).count > 6 || rows(.data).count > 6 {
                        Button(showAll ? "Show less" : "Show all") { showAll.toggle() }.font(.system(size: 11))
                    }
                }
            }
            if expanded { Text("Sizes are allocated blocks measured with du at scan time, not live values\(monitor.caches.partial ? " · + marks a total with unreadable subdirectories" : ""). Clean deletes only the selected rebuildable cache directory. Tool data is protected and has no Clean button. Locations outside this catalog are not measured.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}
struct AlertsCard: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Sustained-load alerts", systemImage: "bell.badge").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("Monitor alerts", isOn: $monitor.alertsEnabled).toggleStyle(.switch).controlSize(.small)
            }
            Text("CPU ≥85%, temperature ≥90°C, or elevated memory pressure for 60 continuous seconds. One alert per episode; recovery re-arms it. Pauses and sleep reset the timer.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Text(monitor.notificationStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if monitor.notificationsEnabled {
                    Button("Disable notifications") { monitor.notificationsEnabled = false; monitor.notificationStatus = "Notification Center alerts disabled" }
                } else { Button("Enable notifications") { monitor.enableNotifications() } }
            }
            if monitor.alerts.isEmpty {
                Text(monitor.alertsEnabled ? "No sustained-load alerts this session." : "Alert monitoring is off.")
                    .font(.system(size: 12)).foregroundStyle(ocean).padding(.vertical, 8)
            }
            ForEach(monitor.alerts.prefix(6)) { alert in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(alert.title).font(.system(size: 12, weight: .semibold)); Spacer(); Text(alert.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text(alert.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(12).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if !monitor.alerts.isEmpty { Button("Clear alert history") { monitor.alerts.removeAll() }.font(.caption) }
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}
