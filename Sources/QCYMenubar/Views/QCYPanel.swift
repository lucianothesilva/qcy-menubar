import SwiftUI
import AppKit

struct QCYPanel: View {
    @ObservedObject var model: HeadsetModel

    @State private var tab: PanelTab = .noise

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 13).padding(.top, 14).padding(.bottom, 12)
            separator

            if model.connection == .connected {
                statusCard
                    .padding(.horizontal, 13)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                tabBar
                    .padding(.horizontal, 13)
                    .padding(.bottom, 10)
                separator
            }

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
            if let image = Self.productImage(named: model.productImageName) {
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

    private static func productImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: - Scrolling content

    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.connection == .connected {
                    switch tab {
                    case .noise:
                        ancCard
                        if model.supportsGameMode { gameCard }
                    case .equalizer:
                        eqCard
                    case .settings:
                        infoCard
                    }
                } else {
                    connectCard
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(tab == item ? Theme.accent : Theme.mutedInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tab == item ? Theme.accent.opacity(0.18) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7))
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

    // MARK: - Battery card

    private var statusCard: some View {
        PanelCard {
            HStack(spacing: 10) {
                Image(systemName: batterySymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(batteryTint)
                Text("Bateria")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text(model.battery.summary)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 1)
        }
    }

    private var batteryTint: Color {
        guard let level = model.battery.level else { return Theme.mutedInk }
        if model.battery.isCharging { return .green }
        return level <= 20 ? .red : Theme.accent
    }

    private var batterySymbol: String {
        if model.battery.isCharging { return "battery.100.bolt" }
        switch model.battery.level ?? 0 {
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

                if model.ancOptions.isEmpty {
                    Text("Este fone não expôs modos de ruído.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedInk)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                              spacing: 8) {
                        ForEach(model.ancOptions) { option in
                            ancTile(option)
                        }
                    }
                }

                if !model.ancScenes.isEmpty {
                    HStack(spacing: 8) {
                        Text("Cenas").font(.system(size: 11)).foregroundStyle(Theme.mutedInk)
                        Spacer()
                        Menu(sceneLabel) {
                            ForEach(model.ancScenes) { scene in
                                Button(scene.label) { Task { await model.selectANC(scene.key) } }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func ancTile(_ option: ANCOption) -> some View {
        Button {
            Task { await model.selectANC(option.key) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: option.symbol).frame(width: 16)
                Text(option.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .buttonStyle(TileButtonStyle(selected: model.ancMode == option.key))
        .disabled(model.busyCommand)
    }

    private var sceneLabel: String {
        if let mode = model.ancMode, let scene = model.ancScenes.first(where: { $0.key == mode }) {
            return scene.label
        }
        return "Escolher"
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

                if model.eqBands.isEmpty {
                    Text("Este fone não expôs o equalizador.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedInk)
                } else {
                    if !model.eqPresets.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                                  spacing: 6) {
                            ForEach(model.eqPresets, id: \.self) { name in
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
                    }

                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(model.eqBands) { band in
                            VStack(spacing: 3) {
                                Text(String(format: "%+.0f", Double(gain(band.index)) / 100))
                                    .font(.system(size: 9))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.mutedInk)
                                VerticalSlider(value: bandBinding(band.index), range: -12...12, height: 112)
                                Text(band.shortLabel)
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
    }

    private func gain(_ index: Int) -> Int {
        index < model.eqGains.count ? model.eqGains[index] : 0
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

                if let protocolLabel = model.protocolLabel {
                    infoRow("Protocolo", value: protocolLabel)
                }
                if let address = model.connectedAddress {
                    infoRow("BLE", value: address, monospaced: true)
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

    private func infoRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.mutedInk)
            Spacer()
            Text(value)
                .font(.system(size: monospaced ? 9 : 11, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.mutedInk)
                .lineLimit(1)
                .truncationMode(.middle)
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
            get: { Double(gain(i)) / 100.0 },
            set: { newValue in
                guard i < model.eqGains.count else { return }
                model.eqGains[i] = Int((newValue * 100).rounded())
            }
        )
    }
}

private enum PanelTab: String, CaseIterable, Identifiable {
    case noise, equalizer, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noise: return "Ruído"
        case .equalizer: return "Equalizador"
        case .settings: return "Ajustes"
        }
    }

    var symbol: String {
        switch self {
        case .noise: return "waveform"
        case .equalizer: return "slider.vertical.3"
        case .settings: return "gearshape"
        }
    }
}
