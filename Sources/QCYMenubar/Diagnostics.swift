import Foundation

/// Headless diagnostic mode (`QCYMenubar --diagnose`).
///
/// Connects to the headset with the exact same Swift BLE stack the GUI uses and
/// prints the resulting state, so the app can be verified from the terminal
/// without clicking anything.
enum Diagnostics {

    @MainActor
    static func run() async {
        print("QCY H3 Control — diagnóstico")
        print("----------------------------------------")

        let model = HeadsetModel()
        print("Estado inicial : \(model.connection.label)")

        await model.connect()

        print("Conexão        : \(model.connection.label)")
        if let error = model.lastError, model.connection != .connected {
            print("Erro           : \(error)")
        }

        guard model.connection == .connected else {
            dumpLog(model)
            print("RESULTADO: falhou")
            return
        }

        print("Dispositivo    : \(model.deviceName ?? "?")")
        print("Protocolo      : \(model.protocolLabel ?? "?")")
        print("Bateria        : \(model.battery.summary)")
        print("ANC            : \(model.ancMode ?? "n/d")")
        print("Game mode      : \(model.gameMode.map { $0 ? "on" : "off" } ?? "n/d")")
        print("Bandas EQ      : \(model.eqBands.count)")
        print("EQ (1/100 dB)  : " + (model.eqGains.isEmpty ? "n/d" : model.eqGains.map(String.init).joined(separator: ", ")))

        if CommandLine.arguments.contains("--write-test") {
            await writeSelfTest(model)
        }

        model.disconnect()
        print("RESULTADO: OK")
    }

    /// Re-applies the current values, so it does not change what the headset is doing.
    @MainActor
    private static func writeSelfTest(_ model: HeadsetModel) async {
        print("--- self-test de escrita (re-aplica os valores atuais) ---")

        if let anc = model.ancMode {
            await model.selectANC(anc)
            print("ANC   write \(anc) -> \(model.ancMode ?? "n/d")  \(model.ancMode == anc ? "OK" : "DIVERGE")")
        }

        if model.supportsGameMode, let original = model.gameMode {
            await model.toggleGameMode()
            await model.toggleGameMode()
            print("Game  toggle 2x -> \(model.gameMode.map { $0 ? "on" : "off" } ?? "n/d")  \(model.gameMode == original ? "OK" : "DIVERGE")")
        }

        if !model.eqBands.isEmpty {
            let before = model.eqGains
            await model.applyCustomEQ()
            print("EQ    re-aplicado -> \(model.eqGains == before ? "igual" : "mudou")")
        }
    }

    @MainActor
    private static func dumpLog(_ model: HeadsetModel) {
        print("----------------------------------------")
        print("Log interno:")
        for line in model.log { print("  \(line)") }
    }
}
