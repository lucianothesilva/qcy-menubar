import AppKit

let helpText = """
QCY H3 Control — app de barra de menus para o headset QCY H3 / H3 Pro.

Uso:
  QCYMenubar                 Abre o painel na barra de menus.
  QCYMenubar --background    Inicia sem abrir o painel.
  QCYMenubar --diagnose      Conecta pelo mesmo stack BLE e imprime o estado.
  QCYMenubar --diagnose --write-test
                             Também re-aplica os valores atuais (ANC/game/EQ)
                             para testar a escrita, sem mudar nada no fone.
  QCYMenubar --help          Mostra esta ajuda.
"""

let app = NSApplication.shared

if CommandLine.arguments.contains("--help") {
    print(helpText)
    exit(0)
} else if CommandLine.arguments.contains("--diagnose") {
    Task { @MainActor in
        await Diagnostics.run()
        exit(0)
    }
    RunLoop.main.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
