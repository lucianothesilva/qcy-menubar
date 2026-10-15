import Foundation

/// Control-panel definition fetched from the QCY server for a given model
/// (vendorId from the BLE manufacturer data). This is the same source the
/// official app uses, and it holds the real ANC command ids and EQ bands.
struct QCYPanelInfo {
    var ancOptions: [ANCOption] = []
    var ancScenes: [ANCOption] = []
    var eqFreqs: [Int] = []
    var eqTypes: [UInt8] = []
    var eqQ: [Int] = []
    var eqPresets: [String] = []

    var isEmpty: Bool { ancOptions.isEmpty && ancScenes.isEmpty && eqFreqs.isEmpty }
}

enum QCYPanelAPI {
    private static let headers = [
        "lang": "en",
        "country": "US",
        "sys_": "android",
        "app_version": "4.0.7_695",
    ]

    /// ANC keys look like "cmd:66816" so the engine can rebuild the 3-byte
    /// packed value (mode<<16 | sub<<8 | noise) the device expects.
    static func key(for cmd: Int) -> String { "cmd:\(cmd)" }

    static func cmd(for key: String) -> Int? {
        guard key.hasPrefix("cmd:") else { return nil }
        return Int(key.dropFirst(4))
    }

    static func fetch(vendorId: Int) async -> QCYPanelInfo? {
        guard let url = URL(string: "https://api.watch.qcy.com/product/findControlPanels") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = "modelId=\(vendorId)&firmwareVersion=".data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let panel = dataObj["controlPanel"] as? [String: Any],
              let layouts = panel["layouts"] as? [[String: Any]] else {
            return nil
        }
        return parse(layouts: layouts)
    }

    private static func parse(layouts: [[String: Any]]) -> QCYPanelInfo {
        var info = QCYPanelInfo()
        for layout in layouts {
            switch layout["type"] as? Int {
            case 9:
                parseANC(layout, into: &info)
            case 2:
                parseEQ(layout, into: &info)
            default:
                break
            }
        }
        return info
    }

    private static func parseANC(_ layout: [String: Any], into info: inout QCYPanelInfo) {
        guard let modes = layout["modes"] as? [[String: Any]] else { return }
        for mode in modes {
            let modeName = (mode["name"] as? String) ?? ""
            let defaultCmd = mode["defaultcmd"] as? Int
            let start = mode["startcmdid"] as? Int
            let end = mode["endcmdid"] as? Int

            if modeName == "Normal", let start {
                info.ancOptions.append(ANCOption(key: key(for: start), label: "ANC off", symbol: "slash.circle"))
                continue
            }
            if modeName.lowercased().contains("transparency") {
                if let defaultCmd {
                    info.ancOptions.append(ANCOption(key: key(for: defaultCmd), label: "Transparency", symbol: "ear"))
                }
                if let start, let end, end >= start {
                    for cmd in start...min(end, start + 6) {
                        info.ancScenes.append(ANCOption(key: key(for: cmd),
                                                        label: "Transparência \(cmd - start + 1)",
                                                        symbol: "ear"))
                    }
                }
                continue
            }

            // canceling mode: items with ranges (levels) or single commands
            for item in (mode["items"] as? [[String: Any]]) ?? [] {
                let name = (item["name"] as? String) ?? ""
                guard let s = item["startcmdid"] as? Int, let e = item["endcmdid"] as? Int else { continue }
                if s == e {
                    let isPrimary = name.lowercased().contains("adaptive") || name.lowercased().contains("anti-wind")
                    let option = ANCOption(key: key(for: s), label: localized(name), symbol: symbol(for: name))
                    if isPrimary { info.ancOptions.append(option) } else { info.ancScenes.append(option) }
                } else {
                    for cmd in s...e {
                        info.ancScenes.append(ANCOption(key: key(for: cmd),
                                                        label: "\(localized(name)) \(cmd - s + 1)",
                                                        symbol: symbol(for: name)))
                    }
                }
            }
        }
    }

    private static func parseEQ(_ layout: [String: Any], into info: inout QCYPanelInfo) {
        if let freqs = (layout["freq"] as? String)?
            .split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            info.eqFreqs = freqs
        }
        if let types = (layout["iitType"] as? String)?
            .split(separator: ",").compactMap({ UInt8($0.trimmingCharacters(in: .whitespaces)) }) {
            info.eqTypes = types
        }
        if let qs = (layout["q"] as? String)?
            .split(separator: ",").compactMap({ Int(Double($0.trimmingCharacters(in: .whitespaces)) ?? 1) }) {
            info.eqQ = qs
        }
        if let presets = layout["sys_eq"] as? [[String: Any]] {
            info.eqPresets = presets.compactMap { $0["name"] as? String }
        }
    }

    private static func localized(_ name: String) -> String {
        switch name.lowercased() {
        case let n where n.contains("adaptive"): return "Adaptive"
        case let n where n.contains("anti-wind"): return "Anti-wind"
        case let n where n.contains("indoor"): return "Ambiente silencioso"
        case let n where n.contains("commuting"): return "Deslocamento"
        case let n where n.contains("noisy"): return "Ambiente barulhento"
        default: return name
        }
    }

    private static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("adaptive") { return "wand.and.stars" }
        if n.contains("anti-wind") { return "wind" }
        if n.contains("indoor") { return "house" }
        if n.contains("commuting") { return "tram" }
        if n.contains("noisy") { return "speaker.wave.3" }
        return "waveform"
    }
}
