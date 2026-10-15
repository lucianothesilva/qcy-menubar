import Foundation

/// JieLi RCSP engine (service `a002`). This is the protocol the QCY H3 / H3 Pro
/// speaks, and the behaviour here matches what already worked before.
@MainActor
final class RCSPProtocol: HeadsetProtocolEngine {
    let family: ProtocolFamily = .rcsp

    private weak var link: BLELink?
    private var rx: [UInt8] = []
    private var sn: UInt8 = 0
    private var pending: [UInt8: CheckedContinuation<Packet?, Never>] = [:]

    // MARK: - Capabilities

    var capabilities: HeadsetCapabilities {
        HeadsetCapabilities(
            ancOptions: Self.mainANC,
            ancScenes: Self.sceneANC,
            eqBands: EQ.bandFreqs.enumerated().map { pair in
                EQBandInfo(index: pair.offset,
                           freq: pair.element,
                           label: EQ.bandLabels[pair.offset],
                           shortLabel: EQ.bandShortLabels[pair.offset])
            },
            eqPresets: EQ.presetNames,
            supportsGameMode: true,
            batteryStyle: .single
        )
    }

    static let mainANC: [ANCOption] = [
        ANCOption(key: "off", label: "ANC off", symbol: "slash.circle"),
        ANCOption(key: "transparency", label: "Transparency", symbol: "ear"),
        ANCOption(key: "adaptive", label: "Adaptive", symbol: "wand.and.stars"),
        ANCOption(key: "antiwind", label: "Anti-wind", symbol: "wind"),
        ANCOption(key: "low", label: "ANC low", symbol: "speaker.wave.1"),
        ANCOption(key: "medium", label: "ANC medium", symbol: "speaker.wave.2"),
        ANCOption(key: "high", label: "ANC high", symbol: "speaker.wave.3"),
    ]

    static let sceneANC: [ANCOption] = [
        ANCOption(key: "commuting-low", label: "ANC low (commuting)", symbol: "waveform"),
        ANCOption(key: "commuting-medium", label: "ANC medium (commuting)", symbol: "waveform"),
        ANCOption(key: "commuting-high", label: "ANC high (commuting)", symbol: "waveform"),
        ANCOption(key: "indoor-low", label: "ANC low (indoor)", symbol: "waveform"),
        ANCOption(key: "indoor-medium", label: "ANC medium (indoor)", symbol: "waveform"),
        ANCOption(key: "indoor-high", label: "ANC high (indoor)", symbol: "waveform"),
    ]

    // MARK: - Transport

    func attach(to link: BLELink) {
        self.link = link
        link.setNotifyHandler { [weak self] data in self?.ingest(data) }
    }

    private func nextSN() -> UInt8 {
        sn = sn &+ 1
        if sn == 0 { sn = 1 }
        return sn
    }

    private func ingest(_ data: [UInt8]) {
        rx.append(contentsOf: data)
        while true {
            guard let idx = Packet.indexOfHeader(rx) else {
                rx.removeAll()
                return
            }
            if idx > 0 { rx.removeFirst(idx) }
            if rx.count < 8 { return }
            let paramLen = (Int(rx[5]) << 8) | Int(rx[6])
            let total = 7 + paramLen + 1
            if rx.count < total { return }
            let bytes = Array(rx[0..<total])
            rx.removeFirst(total)
            guard let pkt = Packet.decode(bytes) else { continue }
            if let c = pending.removeValue(forKey: pkt.sn) {
                c.resume(returning: pkt)
            }
        }
    }

    @discardableResult
    private func send(_ packet: Packet, timeout: TimeInterval = 3.0) async -> Packet? {
        guard let link else { return nil }
        var pkt = packet
        if pkt.sn == 0 { pkt.sn = nextSN() }
        guard pkt.hasResponse == 1 else {
            link.writeRaw(pkt.encode())
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Packet?, Never>) in
            pending[pkt.sn] = cont
            link.writeRaw(pkt.encode())
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let c = self?.pending.removeValue(forKey: pkt.sn) {
                    c.resume(returning: nil)
                }
            }
        }
    }

    private func beBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    // MARK: - Engine API

    func handshake() async {
        _ = await send(Packet(opCode: OpCode.notifyCommunicationWay, params: [0, 0]))
        try? await Task.sleep(for: .milliseconds(200))
    }

    func refresh() async -> HeadsetSnapshot {
        var snap = HeadsetSnapshot()
        if let level = await readBattery() {
            snap.battery = .single(level: level, charging: false)
        }
        snap.ancKey = await readANC()
        snap.gameMode = await readGameMode()
        snap.eqGains = await readEQ()
        return snap
    }

    func applyANC(_ key: String) async -> String? {
        guard let params = ANC.params(for: key) else { return nil }
        await send(Packet(opCode: OpCode.custom, params: params))
        try? await Task.sleep(for: .milliseconds(250))
        return await readANC() ?? key
    }

    func applyGameMode(_ enabled: Bool) async -> Bool? {
        let val: UInt8 = enabled ? 0x02 : 0x01
        await send(Packet(opCode: OpCode.setAdvInfo, params: [0x02, UInt8(AdvType.workMode), val]))
        try? await Task.sleep(for: .milliseconds(250))
        return await readGameMode() ?? enabled
    }

    func applyEQ(gains: [Int]) async -> [Int]? {
        await writeEQ(gains, presetID: EQ.presets["custom"] ?? 0)
        try? await Task.sleep(for: .milliseconds(250))
        return await readEQ()
    }

    func applyPreset(_ name: String) async -> [Int]? {
        guard let id = EQ.presets[name] else { return nil }
        let offsets = EQ.presetOffsets[id] ?? Array(repeating: 0, count: 10)
        await writeEQ(offsets, presetID: id)
        try? await Task.sleep(for: .milliseconds(250))
        return await readEQ()
    }

    // MARK: - RCSP commands

    private func readBattery() async -> Int? {
        let mask = 1 << AdvType.batteryQuantity
        guard let resp = await send(Packet(opCode: OpCode.getAdvInfo, params: beBytes(mask))) else {
            return nil
        }
        for tlv in parseTLV(resp.params) where tlv.type == AdvType.batteryQuantity {
            if let first = tlv.value.first { return Int(first) }
        }
        return nil
    }

    private func readANC() async -> String? {
        guard let resp = await send(Packet(opCode: OpCode.custom, params: [0xFE, 0x01, 0x17])) else {
            return nil
        }
        return ANC.decode(resp.params)
    }

    private func readGameMode() async -> Bool? {
        let mask = 1 << AdvType.workMode
        guard let resp = await send(Packet(opCode: OpCode.getAdvInfo, params: beBytes(mask))) else {
            return nil
        }
        for tlv in parseTLV(resp.params) where tlv.type == AdvType.workMode {
            if let first = tlv.value.first { return first == 0x02 }
        }
        return nil
    }

    private func readEQ() async -> [Int]? {
        guard let resp = await send(Packet(opCode: OpCode.custom, params: [0xFE, 0x01, 0x22])),
              resp.params.count >= 2, resp.params[0] == 0x22 else { return nil }
        let ll = Int(resp.params[1])
        guard resp.params.count >= 2 + ll else { return nil }
        let data = Array(resp.params[2..<(2 + ll)])
        guard data.count >= 3 + 7 * 7 else { return nil }

        var bands: [Int: Int] = [:]
        let count = (data.count - 3) / 7
        for i in 0..<count {
            let base = 3 + i * 7
            let freq = Int(data[base]) | (Int(data[base + 1]) << 8)
            let raw = Int(data[base + 2]) | (Int(data[base + 3]) << 8)
            let dbOff = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
            if EQ.bandFreqs.contains(freq) { bands[freq] = dbOff }
        }
        guard !bands.isEmpty else { return nil }
        return EQ.bandFreqs.map { bands[$0] ?? 0 }
    }

    private func writeEQ(_ offsets: [Int], presetID: Int) async {
        var bandBytes: [UInt8] = []
        for (i, freq) in EQ.bandFreqs.enumerated() {
            let def = EQ.bandDefaults[freq] ?? (0, 2)
            let dbOff = i < offsets.count ? offsets[i] : 0
            bandBytes.append(UInt8(freq & 0xFF))
            bandBytes.append(UInt8((freq >> 8) & 0xFF))
            let raw = UInt16(bitPattern: Int16(clamping: dbOff))
            bandBytes.append(UInt8(raw & 0xFF))
            bandBytes.append(UInt8((raw >> 8) & 0xFF))
            bandBytes.append(UInt8(def.ref & 0xFF))
            bandBytes.append(UInt8((def.ref >> 8) & 0xFF))
            bandBytes.append(UInt8(def.q & 0xFF))
        }
        let header: [UInt8] = [UInt8(presetID & 0xFF), 0x70, 0xFE]
        let dataLen = header.count + bandBytes.count
        let payload: [UInt8] = [0x22, UInt8(dataLen & 0xFF)] + header + bandBytes
        await send(Packet(opCode: OpCode.custom, params: payload))
    }
}
