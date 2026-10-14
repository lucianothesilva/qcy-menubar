// RCSP (Remote Control Service Protocol) - JieLi BLE protocol.
//
// Direct Swift port of the framing used by the Python CLI in
// qcy-h3-control (qcy/rcsp.py and qcy/device.py). Keep the two in sync when
// the protocol changes.
//
// Packet format:
//
//   [FE DC BA]  header              (3B)
//   [flag]      1B   bit7 = type (1 = command, 0 = response)
//                    bit6 = has_response
//   [opCode]    1B
//   [paramLen]  2B   big-endian
//   [status]    1B   present ONLY if type == 0 (response)
//   [sn]        1B   sequence number
//   [xmOpCode]  1B   present ONLY if opCode == 1
//   [params]    N bytes
//   [EF]        footer              (1B)

import Foundation

enum RCSP {
    static let header: [UInt8] = [0xFE, 0xDC, 0xBA]
    static let footer: UInt8 = 0xEF
    static let typeResponse: UInt8 = 0
    static let typeCommand: UInt8 = 1
}

struct Packet {
    var opCode: UInt8
    var type: UInt8 = RCSP.typeCommand
    var hasResponse: UInt8 = 1
    var status: UInt8 = 0
    var sn: UInt8 = 0
    var xmOpCode: UInt8?
    var params: [UInt8] = []

    func encode() -> [UInt8] {
        let flag = ((type & 1) << 7) | ((hasResponse & 1) << 6)
        var body: [UInt8] = []
        if type == RCSP.typeResponse {
            body.append(status & 0xFF)
        }
        body.append(sn & 0xFF)
        if opCode == 1, let xm = xmOpCode {
            body.append(xm & 0xFF)
        }
        body.append(contentsOf: params)

        let paramLen = body.count
        var out: [UInt8] = RCSP.header
        out.append(flag)
        out.append(opCode & 0xFF)
        out.append(UInt8((paramLen >> 8) & 0xFF))
        out.append(UInt8(paramLen & 0xFF))
        out.append(contentsOf: body)
        out.append(RCSP.footer)
        return out
    }

    /// Decode a full frame. Returns nil when the bytes are not a valid packet.
    static func decode(_ data: [UInt8]) -> Packet? {
        guard data.count >= 8 else { return nil }
        guard let idx = indexOfHeader(data) else { return nil }
        let d = Array(data[idx...])
        guard d.count >= 8 else { return nil }

        let flag = d[3]
        let opCode = d[4]
        let paramLen = (Int(d[5]) << 8) | Int(d[6])
        let total = 7 + paramLen + 1
        guard d.count >= total else { return nil }
        guard d[total - 1] == RCSP.footer else { return nil }

        let ptype = (flag >> 7) & 1
        let hasResp = (flag >> 6) & 1

        var i = 7
        var status: UInt8 = 0
        if ptype == RCSP.typeResponse {
            status = d[i]
            i += 1
        }
        let sn = d[i]
        i += 1
        var xm: UInt8?
        if opCode == 1 {
            xm = d[i]
            i += 1
        }
        let params = Array(d[i..<(total - 1)])

        return Packet(opCode: opCode, type: ptype, hasResponse: hasResp,
                      status: status, sn: sn, xmOpCode: xm, params: params)
    }

    /// Index of the RCSP header inside `data`, if present.
    static func indexOfHeader(_ data: [UInt8]) -> Int? {
        guard data.count >= 3 else { return nil }
        var i = 0
        while i <= data.count - 3 {
            if data[i] == 0xFE && data[i + 1] == 0xDC && data[i + 2] == 0xBA {
                return i
            }
            i += 1
        }
        return nil
    }
}

enum OpCode {
    static let data: UInt8 = 1
    static let getTargetFeatureMap: UInt8 = 2
    static let getTargetInfo: UInt8 = 3
    static let getSysInfo: UInt8 = 7
    static let notifyCommunicationWay: UInt8 = 11
    static let setAdvInfo: UInt8 = 192
    static let getAdvInfo: UInt8 = 193
    static let custom: UInt8 = 255
}

enum AdvType {
    static let batteryQuantity = 0
    static let workMode = 5
}

func hexStr(_ data: [UInt8]) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: "-")
}

/// Parse a sequence of `[L:1B][T:1B][V:L-1 bytes]` entries.
func parseTLV(_ data: [UInt8]) -> [(type: Int, value: [UInt8])] {
    var out: [(type: Int, value: [UInt8])] = []
    var i = 0
    let n = data.count
    while i < n {
        if i + 1 >= n { break }
        let length = Int(data[i])
        if length < 1 || i + 1 + length > n { break }
        let typeByte = Int(data[i + 1])
        let value = Array(data[(i + 2)..<(i + 1 + length)])
        out.append((typeByte, value))
        i += 1 + length
    }
    return out
}

// ---------------------------------------------------------------------------
// Noise-control (ANC) modes -- sub-protocol 0x17
// params = [0x17, 0x03, sub, group, level]
// ---------------------------------------------------------------------------

struct ANCMode {
    let key: String
    let aliases: [String]
    let label: String
    let params: [UInt8]
}

enum ANC {
    static let modes: [ANCMode] = [
        ANCMode(key: "off", aliases: ["anc-off", "disable"], label: "ANC off",
                params: [0x17, 0x03, 0x02, 0x00, 0x00]),
        ANCMode(key: "transparency", aliases: ["trans", "ambient"], label: "Transparency",
                params: [0x17, 0x03, 0x03, 0x01, 0x04]),
        ANCMode(key: "low", aliases: ["noise-low"], label: "ANC low (noisy)",
                params: [0x17, 0x03, 0x01, 0x01, 0x00]),
        ANCMode(key: "medium", aliases: ["med", "noise-medium"], label: "ANC medium (noisy)",
                params: [0x17, 0x03, 0x01, 0x01, 0x01]),
        ANCMode(key: "high", aliases: ["noise-high"], label: "ANC high (noisy)",
                params: [0x17, 0x03, 0x01, 0x01, 0x02]),
        ANCMode(key: "adaptive", aliases: ["auto"], label: "Adaptive",
                params: [0x17, 0x03, 0x01, 0x05, 0x00]),
        ANCMode(key: "commuting-low", aliases: [], label: "ANC low (commuting)",
                params: [0x17, 0x03, 0x01, 0x02, 0x00]),
        ANCMode(key: "commuting-medium", aliases: [], label: "ANC medium (commuting)",
                params: [0x17, 0x03, 0x01, 0x02, 0x01]),
        ANCMode(key: "commuting-high", aliases: [], label: "ANC high (commuting)",
                params: [0x17, 0x03, 0x01, 0x02, 0x02]),
        ANCMode(key: "indoor-low", aliases: [], label: "ANC low (indoor)",
                params: [0x17, 0x03, 0x01, 0x03, 0x00]),
        ANCMode(key: "indoor-medium", aliases: [], label: "ANC medium (indoor)",
                params: [0x17, 0x03, 0x01, 0x03, 0x01]),
        ANCMode(key: "indoor-high", aliases: [], label: "ANC high (indoor)",
                params: [0x17, 0x03, 0x01, 0x03, 0x02]),
        ANCMode(key: "antiwind", aliases: ["wind"], label: "Anti-wind",
                params: [0x17, 0x03, 0x01, 0x04, 0x00]),
    ]

    /// A curated subset shown in the quick picker (the full list is available too).
    static let quickKeys = ["off", "transparency", "high", "adaptive", "antiwind"]

    static func params(for name: String) -> [UInt8]? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let m = modes.first(where: { $0.key == key }) { return m.params }
        if let m = modes.first(where: { $0.aliases.contains(key) }) { return m.params }
        return nil
    }

    static func label(for key: String?) -> String {
        guard let key else { return "n/d" }
        return modes.first(where: { $0.key == key })?.label ?? key
    }

    /// Best-effort decode of a GET 0x17 response into a mode key.
    static func decode(_ params: [UInt8]) -> String? {
        guard params.count >= 5 else { return nil }
        let sub = params[2], group = params[3], level = params[4]
        if sub == 0x02 { return "off" }
        if sub == 0x03 { return "transparency" }
        if sub == 0x01 {
            let table: [Pair: String] = [
                Pair(0x01, 0x00): "low",
                Pair(0x01, 0x01): "medium",
                Pair(0x01, 0x02): "high",
                Pair(0x02, 0x00): "commuting-low",
                Pair(0x02, 0x01): "commuting-medium",
                Pair(0x02, 0x02): "commuting-high",
                Pair(0x03, 0x00): "indoor-low",
                Pair(0x03, 0x01): "indoor-medium",
                Pair(0x03, 0x02): "indoor-high",
                Pair(0x04, 0x00): "antiwind",
                Pair(0x05, 0x00): "adaptive",
            ]
            return table[Pair(group, level)]
        }
        return nil
    }

    struct Pair: Hashable {
        let a: UInt8
        let b: UInt8
        init(_ a: UInt8, _ b: UInt8) { self.a = a; self.b = b }
    }
}

// ---------------------------------------------------------------------------
// EQ -- 10 bands, sub-protocol 0x22
// ---------------------------------------------------------------------------

enum EQ {
    static let bandFreqs: [Int] = [0x0037, 0x00DC, 0x01F4, 0x03E8, 0x0708,
                                   0x0AF0, 0x1194, 0x1D4C, 0x2710, 0x55F0]
    static let bandLabels = ["55 Hz", "220 Hz", "500 Hz", "1 kHz", "1.8 kHz",
                             "2.8 kHz", "4.5 kHz", "7.5 kHz", "10 kHz", "22 kHz"]
    static let bandShortLabels = ["55", "220", "500", "1k", "1.8k",
                                  "2.8k", "4.5k", "7.5k", "10k", "22k"]

    /// (ref_gain, Q) per frequency, from the device GET response.
    static let bandDefaults: [Int: (ref: Int, q: Int)] = [
        0x0037: (40, 2),
        0x00DC: (120, 2),
        0x01F4: (150, 2),
        0x03E8: (150, 2),
        0x0708: (120, 2),
        0x0AF0: (80, 2),
        0x1194: (130, 2),
        0x1D4C: (120, 2),
        0x2710: (120, 2),
        0x55F0: (80, 2),
    ]

    static let presets: [String: Int] = [
        "custom": 0x00,
        "default": 0x01,
        "pop": 0x02,
        "heavy-bass": 0x03,
        "rock": 0x04,
        "soft": 0x05,
        "classic": 0x06,
    ]

    static let presetNames = ["default", "pop", "heavy-bass", "rock", "soft", "classic"]

    /// Default band offsets per preset, in 1/100 dB (10 bands).
    static let presetOffsets: [Int: [Int]] = [
        0x01: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        0x02: [0, 150, 150, 100, 0, 100, 200, 200, 150, 100],
        0x03: [500, 400, 200, 0, -100, 0, 0, 100, 200, 100],
        0x04: [400, 300, 0, -200, -100, 0, 200, 300, 400, 200],
        0x05: [100, 100, 100, 100, 100, 100, 100, 100, 100, 100],
        0x06: [0, 0, 100, 300, 300, 300, 200, 100, 100, 0],
    ]
}
