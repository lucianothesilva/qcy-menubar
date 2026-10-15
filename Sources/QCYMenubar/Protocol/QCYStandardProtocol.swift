import Foundation
import CoreBluetooth

/// QCY standard GATT protocol engine. Used by most QCY earbuds (e.g. MeloBuds).
///
/// Framing: `[0xFF] [bodyLen] [cmd] [paramLen] [params...] ` written to `1001`,
/// responses on `1002` in the same shape. The real capabilities (ANC command
/// ids, EQ bands) come from the QCY control-panel API for the model's vendorId.
@MainActor
final class QCYStandardProtocol: HeadsetProtocolEngine {
    let family: ProtocolFamily = .qcyStandard

    private let vendorId: Int?
    private weak var link: BLELink?
    private var rx: [UInt8] = []
    private var waiters: [UInt8: CheckedContinuation<[UInt8]?, Never>] = [:]
    private var panel: QCYPanelInfo?

    private static let batteryChar = CBUUID(string: "00000008-0000-1000-8000-00805f9b34fb")

    init(vendorId: Int?) {
        self.vendorId = vendorId
    }

    // MARK: - Capabilities

    var capabilities: HeadsetCapabilities {
        HeadsetCapabilities(
            ancOptions: panel?.ancOptions ?? [],
            ancScenes: panel?.ancScenes ?? [],
            eqBands: [],          // EQ for this protocol is still being mapped
            eqPresets: [],
            supportsGameMode: true,
            batteryStyle: .split
        )
    }

    // MARK: - Transport

    func attach(to link: BLELink) {
        self.link = link
        link.setNotifyHandler { [weak self] data in self?.ingest(data) }
    }

    private func frame(_ body: [UInt8]) -> [UInt8] {
        [0xFF, UInt8(body.count & 0xFF)] + body
    }

    private static func parseBlocks(_ body: [UInt8]) -> [(cmd: UInt8, params: [UInt8])] {
        var out: [(UInt8, [UInt8])] = []
        var i = 0
        while i + 1 < body.count {
            let cmd = body[i]
            let plen = Int(body[i + 1])
            let start = i + 2
            let end = start + plen
            guard end <= body.count else { break }
            out.append((cmd, Array(body[start..<end])))
            i = end
        }
        return out
    }

    private func ingest(_ data: [UInt8]) {
        rx.append(contentsOf: data)
        while rx.count >= 2 {
            guard rx[0] == 0xFF else {
                rx.removeFirst()
                continue
            }
            let total = 2 + Int(rx[1])
            if rx.count < total { return }
            let body = Array(rx[2..<total])
            rx.removeFirst(total)
            for block in Self.parseBlocks(body) {
                if let c = waiters.removeValue(forKey: block.cmd) {
                    c.resume(returning: block.params)
                }
            }
        }
    }

    private func expect(_ cmd: UInt8, body: [UInt8], timeout: TimeInterval = 3.0) async -> [UInt8]? {
        guard let link else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            waiters[cmd] = cont
            link.writeRaw(frame(body))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let c = self?.waiters.removeValue(forKey: cmd) {
                    c.resume(returning: nil)
                }
            }
        }
    }

    /// Generic "request current value" (cmd `0xFE`). Params come back without
    /// the leading length byte (parseBlocks already strips `plen`).
    private func requestValue(_ cmd: UInt8, timeout: TimeInterval = 3.0) async -> [UInt8]? {
        await expect(cmd, body: [0xFE, 0x01, cmd], timeout: timeout)
    }

    private func send(_ body: [UInt8]) {
        link?.writeRaw(frame(body))
    }

    // MARK: - Engine API

    func handshake() async {
        if let vendorId, let fetched = await QCYPanelAPI.fetch(vendorId: vendorId) {
            panel = fetched
        }
        _ = await readBattery()
    }

    func refresh() async -> HeadsetSnapshot {
        var snap = HeadsetSnapshot()
        if let battery = await readBattery() { snap.battery = battery }
        snap.ancKey = await readANC()
        snap.gameMode = await readGameMode()
        return snap
    }

    func applyANC(_ key: String) async -> String? {
        guard let cmd = QCYPanelAPI.cmd(for: key) else { return nil }
        let bytes: [UInt8] = [UInt8((cmd >> 16) & 0xFF), UInt8((cmd >> 8) & 0xFF), UInt8(cmd & 0xFF)]
        send([0x17, 0x03] + bytes)
        try? await Task.sleep(for: .milliseconds(300))
        return await readANC() ?? key
    }

    func applyGameMode(_ enabled: Bool) async -> Bool? {
        send([0x09, 0x01, enabled ? 0x01 : 0x02])
        try? await Task.sleep(for: .milliseconds(300))
        return await readGameMode() ?? enabled
    }

    func applyEQ(gains: [Int]) async -> [Int]? { nil }
    func applyPreset(_ name: String) async -> [Int]? { nil }

    // MARK: - Commands

    private func readBattery() async -> BatteryReading? {
        guard let link, let value = await link.readCharacteristic(Self.batteryChar), value.count >= 3 else {
            return nil
        }
        func decode(_ byte: UInt8) -> (Int, Bool) { (Int(byte & 0x7F), byte & 0x80 != 0) }
        let (l, lc) = decode(value[0])
        let (r, rc) = decode(value[1])
        let (b, bc) = decode(value[2])
        return .split(left: l, right: r, box: b, charging: lc || rc || bc)
    }

    private func readGameMode() async -> Bool? {
        guard let p = await requestValue(0x09), let first = p.first else { return nil }
        return first == 0x01
    }

    private func readANC() async -> String? {
        guard let p = await requestValue(0x17), p.count >= 3 else { return nil }
        let cmd = (Int(p[0]) << 16) | (Int(p[1]) << 8) | Int(p[2])
        return QCYPanelAPI.key(for: cmd)
    }
}
