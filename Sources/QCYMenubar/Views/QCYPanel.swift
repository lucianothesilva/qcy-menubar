import SwiftUI
import AppKit

struct QCYPanel: View {
    @ObservedObject var model: HeadsetModel

    private let mainModeKeys = ["off", "transparency", "adaptive", "antiwind", "low", "medium", "high"]
    private let sceneModeKeys = ["commuting-low", "commuting-medium", "commuting-high",
                                 "indoor-low", "indoor-medium", "indoor-high"]

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 13).padding(.top, 14).padding(.bottom, 12)
            separator
            contentScroll
            separator
            footer.padding(.horizontal, 13).padding(.vertical, 10)
        }
        .background(Theme.gradient)
        .foregroundStyle(Theme.ink)
        .font(.system(size: 12))
        .tint(Theme.accent)
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            headsetMark

            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName ?? "QCY H3 Control")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.3)
                HStack(spacing: 5) {
                    StatusDot(state: model.connection)
                    Text(model.connection.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.mutedInk)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if model.connection.isBusy {
                ProgressView().controlSize(.small)
            }

            Menu {
                if model.connection == .connected {
                    Button("Desconectar") { model.disconnect() }
                }
                Button("Atualizar agora") { Task { await model.refreshAll() } }
                    .disabled(model.connection != .connected)
                Divider()
                Toggle("Conectar automaticamente", isOn: autoBinding)
                Toggle("Monitorar bateria", isOn: monitorBinding)
                Divider()
                Button("Sair do QCY H3 Control") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 30)
                    .foregroundStyle(Theme.mutedInk)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var headsetMark: some View {
        Group {
            if let image = Self.headsetImage {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.18))
                    Image(systemName: model.gameMode == true ? "gamecontroller.fill" : "headphones")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 42, height: 42)
    }

    private static let headsetImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Headset", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    // MARK: - Scrolling content

    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.connection == .connected {
                    statusCard
                    ancCard
                    gameCard
                    eqCard
                    infoCard
                } else {
                    connectCard
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Connect

    private var connectCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Procurando o fone...").font(.system(size: 12, weight: .semibold))
                }
                Text("Ligue o fone e deixe-o por perto. O app conecta sozinho assim que ele aparecer.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: autoBinding) {
                    Text("Conectar automaticamente").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if !model.autoConnectEnabled {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text("Conectar agora")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(TileButtonStyle(selected: true))
                    .disabled(model.connection.isBusy)

                    if let error = model.lastError, !model.connection.isBusy {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        PanelCard {
            HStack(spacing: 10) {
                Image(systemName: batterySymbol(model.battery))
                    .font(.system(size: 18))
                    .foregroundStyle(batteryTint)
                Text("Bateria")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text(model.battery.map { "\($0)%" } ?? "n/d")
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.vertical, 1)
        }
    }

    private var batteryTint: Color {
        guard let level = model.battery else { return Theme.mutedInk }
        return level <= 20 ? .red : Theme.accent
    }

    private func batterySymbol(_ level: Int?) -> String {
        guard let level else { return "battery.0" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: - ANC

    private var ancCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Modo de ruído", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(mainModeKeys, id: \.self) { key in
                        ancTile(key)
                    }
                }

                HStack(spacing: 8) {
                    Text("Cenas").font(.system(size: 11)).foregroundStyle(Theme.mutedInk)
                    Spacer()
                    Menu(sceneLabel) {
                        ForEach(sceneModeKeys, id: \.self) { key in
                            Button(ANC.label(for: key)) { Task { await model.selectANC(key) } }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private func ancTile(_ key: String) -> some View {
        Button {
            Task { await model.selectANC(key) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: ancSymbol(key)).frame(width: 16)
                Text(ancTileLabel(key))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .buttonStyle(TileButtonStyle(selected: model.ancMode == key))
        .disabled(model.busyCommand)
    }

    private var sceneLabel: String {
        if let mode = model.ancMode, sceneModeKeys.contains(mode) {
            return ANC.label(for: mode)
        }
        return "Escolher"
    }

    /// Shorter labels for the tile grid (the "(noisy)" suffix does not fit).
    private func ancTileLabel(_ key: String) -> String {
        switch key {
        case "low": return "ANC low"
        case "medium": return "ANC medium"
        case "high": return "ANC high"
        default: return ANC.label(for: key)
        }
    }

    private func ancSymbol(_ key: String) -> String {
        switch key {
        case "off": return "slash.circle"
        case "transparency": return "ear"
        case "adaptive": return "wand.and.stars"
        case "antiwind": return "wind"
        case "low": return "speaker.wave.1"
        case "medium": return "speaker.wave.2"
        case "high": return "speaker.wave.3"
        default: return "waveform"
        }
    }

    // MARK: - Game mode

    private var gameCard: some View {
        PanelCard {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller")
                    .foregroundStyle(model.gameMode == true ? Theme.accent : Theme.mutedInk)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Game mode").font(.system(size: 12, weight: .semibold))
                    Text("Baixa latência para jogos").font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                }
                Spacer()
                Toggle("", isOn: gameBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.busyCommand)
            }
        }
    }

    // MARK: - EQ

    private var eqCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Equalizador", systemImage: "slider.vertical.3")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("banda custom, dB")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.mutedInk)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                          spacing: 6) {
                    ForEach(EQ.presetNames, id: \.self) { name in
                        Button {
                            Task { await model.selectPreset(name) }
                        } label: {
                            Text(name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(TileButtonStyle(selected: model.currentPreset == name))
                        .disabled(model.busyCommand)
                    }
                }

                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<EQ.bandFreqs.count, id: \.self) { i in
                        VStack(spacing: 3) {
                            Text(String(format: "%+.0f", Double(model.eqBands[i]) / 100))
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(Theme.mutedInk)
                            VerticalSlider(value: bandBinding(i), range: -12...12, height: 112)
                            Text(EQ.bandShortLabels[i])
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.mutedInk)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    Button {
                        model.resetEQ()
                    } label: {
                        Text("Zerar")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(TileButtonStyle())

                    Spacer()

                    Button {
                        Task { await model.applyCustomEQ() }
                    } label: {
                        Text("Aplicar custom")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(TileButtonStyle(selected: true))
                    .disabled(model.busyCommand)
                }
            }
        }
    }

    // MARK: - Info / settings

    private var infoCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Ajustes e diagnóstico", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .semibold))

                Toggle(isOn: monitorBinding) {
                    Text("Monitorar bateria a cada 15s").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if let address = model.connectedAddress {
                    HStack(spacing: 6) {
                        Text("BLE").font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
                        Spacer()
                        Text(address)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.mutedInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if !model.log.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LOG").font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Theme.mutedInk)
                        ForEach(Array(model.log.suffix(6).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.mutedInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Button {
                    model.disconnect()
                } label: {
                    Text("Desconectar")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(TileButtonStyle())
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            StatusDot(state: model.connection)
            Text(model.connection.label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedInk)
                .lineLimit(1)
            Spacer()
            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mutedInk)
            .disabled(model.connection != .connected)
            .help("Atualizar agora")
            Text("v0.1")
                .font(.system(size: 10))
                .foregroundStyle(Theme.mutedInk.opacity(0.7))
        }
    }

    // MARK: - Bindings

    private var gameBinding: Binding<Bool> {
        Binding(
            get: { model.gameMode ?? false },
            set: { _ in Task { await model.toggleGameMode() } }
        )
    }

    private var monitorBinding: Binding<Bool> {
        Binding(
            get: { model.monitorEnabled },
            set: { model.setMonitor($0) }
        )
    }

    private var autoBinding: Binding<Bool> {
        Binding(
            get: { model.autoConnectEnabled },
            set: { model.setAutoConnect($0) }
        )
    }

    private func bandBinding(_ i: Int) -> Binding<Double> {
        Binding(
            get: {
                guard i < model.eqBands.count else { return 0 }
                return Double(model.eqBands[i]) / 100.0
            },
            set: { newValue in
                guard i < model.eqBands.count else { return }
                model.eqBands[i] = Int((newValue * 100).rounded())
            }
        )
    }
}
