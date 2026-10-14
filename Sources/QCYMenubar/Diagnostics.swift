import Foundation

/// Headless diagnostic mode (`QCYMenubar --diagnose`).
///
/// Connects to the headset with the exact same Swift BLE stack the GUI uses and
/// prints the resulting state, so the app can be verified from the terminal
/// without clicking anything. Mirrors the `--self-check` / `--diagnose` idea
/// from LGwebOS-menubar.
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
        print("Bateria        : \(model.battery.map { "\($0)%" } ?? "n/d")")
        print("ANC            : \(model.ancMode.map { "\($0) (\(ANC.label(for: $0)))" } ?? "n/d")")
        print("Game mode      : \(model.gameMode.map { $0 ? "on" : "off" } ?? "n/d")")
        print("EQ (1/100 dB)  : " + model.eqBands.map(String.init).joined(separator: ", "))

        // Exercise a write round-trip only if asked, to avoid changing the
        // user's headset settings unexpectedly.
        if CommandLine.arguments.contains("--write-test") {
            await model.writeSelfTest()
        }

        model.disconnect()
        print("RESULTADO: OK")
    }

    @MainActor
    private static func dumpLog(_ model: HeadsetModel) {
        print("----------------------------------------")
        print("Log interno:")
        for line in model.log { print("  \(line)") }
    }
}
