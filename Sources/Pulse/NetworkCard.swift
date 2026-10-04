import SwiftUI
import Charts

private let networkUpload = Color(red: 0.49, green: 0.55, blue: 1.0)

struct NetworkCard: View {
    @ObservedObject var monitor: Monitor

    private var network: NetworkReading { monitor.reading.network }
    private var statusColor: Color {
        switch network.status {
        case .connected: ocean
        case .connecting: .orange
        case .offline: .red
        }
    }
    private var connectionDetail: String {
        var parts = [network.interfaceType]
        if let name = network.interfaceName { parts.append(name) }
        if network.isConstrained { parts.append("Low Data Mode") }
        else if network.isExpensive { parts.append("Metered") }
        return parts.joined(separator: " · ")
    }
    private var recent: [Sample] {
        monitor.history.filter { $0.time >= monitor.reading.time.addingTimeInterval(-120) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Label("Internet connection", systemImage: connectionSymbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(network.status.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
                Spacer()
                NetworkActivityIndicator(active: network.active, color: statusColor)
                Text(network.activityName.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(network.active ? statusColor : Color.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(connectionDetail).font(.system(size: 12, weight: .medium))
                    Text(network.connected
                         ? "macOS has an active network path. Throughput is sampled locally from this interface."
                         : "No active internet route is currently available to macOS.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                throughput(title: "DOWNLOAD", symbol: "arrow.down", value: network.downloadBytesPerSecond, color: ocean)
                throughput(title: "UPLOAD", symbol: "arrow.up", value: network.uploadBytesPerSecond, color: networkUpload)
            }

            if network.connected {
                Chart {
                    ForEach(recent) { sample in
                        LineMark(
                            x: .value("Time", sample.time),
                            y: .value("Rate", sample.networkDownload),
                            series: .value("Direction", "Download")
                        )
                        .foregroundStyle(ocean)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.linear)
                        LineMark(
                            x: .value("Time", sample.time),
                            y: .value("Rate", sample.networkUpload),
                            series: .value("Direction", "Upload")
                        )
                        .foregroundStyle(networkUpload)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.linear)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.05))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(rate(amount)).font(.system(size: 9)) }
                        }.foregroundStyle(.secondary)
                    }
                }
                .frame(height: 92)
                HStack {
                    Label("Download", systemImage: "circle.fill").foregroundStyle(ocean)
                    Label("Upload", systemImage: "circle.fill").foregroundStyle(networkUpload)
                    Spacer()
                    Text("Last 2 minutes").foregroundStyle(.secondary)
                }.font(.system(size: 9))
            }

            Text("Live throughput is current traffic, not a maximum internet speed test. Nori does not contact a server to measure it.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(statusColor.opacity(network.connected ? 0.22 : 0.35)))
        .accessibilityElement(children: .contain)
    }

    private var connectionSymbol: String {
        switch network.interfaceType {
        case "Wi-Fi": "wifi"
        case "VPN": "lock.shield"
        case "Ethernet": "cable.connector"
        default: "network"
        }
    }

    private func throughput(title: String, symbol: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(rate(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(network.connected ? color : Color.secondary)
                .contentTransition(.numericText())
        }.frame(width: 145, alignment: .leading)
    }
}

private struct NetworkActivityIndicator: View {
    let active: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: !active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 5
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = active ? (sin(phase + Double(index) * 0.9) + 1) / 2 : 0
                    Capsule().fill(active ? color : Color.secondary.opacity(0.5))
                        .frame(width: 2.5, height: 4 + 9 * wave)
                }
            }.frame(width: 18, height: 14)
        }
        .accessibilityHidden(true)
    }
}

func rate(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0 B/s" }
    let formatted = ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .binary)
    return formatted + "/s"
}
