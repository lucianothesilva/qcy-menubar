import Foundation
import CoreBluetooth

/// Which control protocol family a headset speaks.
enum ProtocolFamily {
    /// JieLi RCSP over service `a002` (QCY H3 / H3 Pro).
    case rcsp
    /// QCY standard GATT protocol over characteristics `00001001`/`00001002`
    /// (MeloBuds and most QCY earbuds).
    case qcyStandard

    var label: String {
        switch self {
        case .rcsp: return "JieLi RCSP"
        case .qcyStandard: return "QCY padrão"
        }
    }
}

/// A selectable ANC mode/scene.
struct ANCOption: Identifiable, Hashable {
    let key: String
    let label: String
    let symbol: String
    var id: String { key }
}

/// A single EQ band, as reported by the device.
struct EQBandInfo: Identifiable, Hashable {
    let index: Int
    let freq: Int
    let label: String
    let shortLabel: String
    var id: Int { index }

    static func label(for freq: Int) -> String {
        freq >= 1000
            ? (Double(freq) / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz"
            : "\(freq) Hz"
    }

    static func shortLabel(for freq: Int) -> String {
        freq >= 1000
            ? (Double(freq) / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k"
            : "\(freq)"
    }
}

enum BatteryStyle { case single, split }

/// Battery reading, which differs between protocols (single level vs L/R/case).
enum BatteryReading: Equatable {
    case unknown
    case single(level: Int?, charging: Bool)
    case split(left: Int?, right: Int?, box: Int?, charging: Bool)

    /// Highest level to show in the menu bar / compact row.
    var level: Int? {
        switch self {
        case .unknown: return nil
        case .single(let level, _): return level
        case .split(let l, let r, let b, _): return [l, r, b].compactMap { $0 }.min()
        }
    }

    var isCharging: Bool {
        switch self {
        case .unknown: return false
        case .single(_, let c): return c
        case .split(_, _, _, let c): return c
        }
    }

    var summary: String {
        switch self {
        case .unknown:
            return "n/d"
        case .single(let level, let charging):
            guard let level else { return "n/d" }
            return charging ? "\(level)% (carregando)" : "\(level)%"
        case .split(let l, let r, let b, let charging):
            var parts: [String] = []
            if let l { parts.append("L \(l)%") }
            if let r { parts.append("R \(r)%") }
            if let b { parts.append("est. \(b)%") }
            if parts.isEmpty { return "n/d" }
            return parts.joined(separator: "   ") + (charging ? "  (carregando)" : "")
        }
    }
}

/// What a protocol engine can do, so the UI can adapt.
struct HeadsetCapabilities {
    var ancOptions: [ANCOption] = []
    var ancScenes: [ANCOption] = []
    var eqBands: [EQBandInfo] = []
    var eqPresets: [String] = []
    var supportsGameMode = false
    var batteryStyle: BatteryStyle = .single
}

/// Everything read back from the headset in one pass.
struct HeadsetSnapshot {
    var battery: BatteryReading = .unknown
    var ancKey: String?
    var gameMode: Bool?
    var eqGains: [Int]?
}

/// The BLE transport a protocol engine writes through.
@MainActor
protocol BLELink: AnyObject {
    func writeRaw(_ bytes: [UInt8])
    func setNotifyHandler(_ handler: (([UInt8]) -> Void)?)
    /// Read a characteristic's current value (used for battery/version).
    func readCharacteristic(_ uuid: CBUUID) async -> [UInt8]?
}

/// A protocol engine: encodes/decodes the headset's own framing and exposes a
/// uniform API to the app.
@MainActor
protocol HeadsetProtocolEngine: AnyObject {
    var family: ProtocolFamily { get }
    var capabilities: HeadsetCapabilities { get }
    func attach(to link: BLELink)
    func handshake() async
    func refresh() async -> HeadsetSnapshot
    func applyANC(_ key: String) async -> String?
    func applyGameMode(_ enabled: Bool) async -> Bool?
    func applyEQ(gains: [Int]) async -> [Int]?
    func applyPreset(_ name: String) async -> [Int]?
    /// Raw diagnostic request (`0xFE 0x01 <cmd>` for the QCY standard protocol).
    func rawRequest(_ cmd: UInt8, timeout: TimeInterval) async -> [UInt8]?
}
