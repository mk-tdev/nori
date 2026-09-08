import SwiftUI

// Display thresholds, not hardware safety limits or macOS thermal-state thresholds.
enum TemperatureBand: String, CaseIterable {
    case unavailable = "Unavailable", cool = "Cool", moderate = "Moderate", warm = "Warm", hot = "Hot"
    static let measured: [TemperatureBand] = [.cool, .moderate, .warm, .hot]
    init(reading: Double) {
        if !reading.isFinite || reading <= 0 { self = .unavailable }
        else if reading < 60 { self = .cool }
        else if reading < 75 { self = .moderate }
        else if reading < 90 { self = .warm }
        else { self = .hot }
    }
    var color: Color {
        switch self {
        case .unavailable: .gray
        case .cool: Color(red: 0.28, green: 0.72, blue: 1)
        case .moderate: Color(red: 0.36, green: 0.83, blue: 0.77)
        case .warm: Color(red: 1, green: 0.69, blue: 0.28)
        case .hot: Color(red: 1, green: 0.35, blue: 0.38)
        }
    }
}
