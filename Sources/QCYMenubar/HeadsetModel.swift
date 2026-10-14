import Foundation
import CoreBluetooth
import Combine

/// High-level connection state shown in the UI.
enum ConnectionState: Equatable {
    case unknown
    case poweredOff
    case unauthorized
    case disconnected
    case scanning
    case connecting
    case connected
    case failed(String)

    var isBusy: Bool { self == .scanning || self == .connecting }

    var label: String {
        switch self {
        case .unknown: return "Iniciando Bluetooth..."
        case .poweredOff: return "Bluetooth desligado"
        case .unauthorized: return "Sem permissão de Bluetooth"
        case .disconnected: return "Desconectado"
        case .scanning: return "Procurando o fone..."
        case .connecting: return "Conectando..."
        case .connected: return "Conectado"
        case .failed(let msg): return msg
        }
    }
}

/// Owns the CoreBluetooth central and the headset state. Everything runs on the
/// main queue (`CBCentralManager(queue: .main)`), which is the model CoreBluetooth
/// was designed around, so delegate callbacks and UI updates share one thread.
@MainActor
final class HeadsetModel: NSObject, ObservableObject {

    // MARK: - Published UI state

    @Published var connection: ConnectionState = .unknown
    @Published var deviceName: String?
    @Published var connectedAddress: String?
    @Published var battery: Int?
    @Published var ancMode: String?
    @Published var gameMode: Bool?
    /// 10 band offsets in 1/100 dB.
    @Published var eqBands: [Int] = Array(repeating: 0, count: 10)
    @Published var currentPreset: String?
    @Published var monitorEnabled = false
    @Published var autoConnectEnabled = true
    @Published var busyCommand = false
    @Published var lastError: String?
    @Published var log: [String] = []

    // MARK: - GATT

    static let serviceUUID = CBUUID(string: "0000a002-0000-1000-8000-00805f9b34fb")
    static let writeUUID = CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb")
    static let notifyUUID = CBUUID(string: "00000002-0000-1000-8000-00805f9b34fb")
    static let cachedIdentifierKey = "QCYPeripheralIdentifier"

    // MARK: - Internal BLE plumbing

    private(set) lazy var central: CBCentralManager = CBCentralManager(delegate: self, queue: .main)

    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var rxBuffer: [UInt8] = []
    private var sn: UInt8 = 0

    private var pending: [UInt8: CheckedContinuation<Packet?, Never>] = [:]
    private var stateCont: CheckedContinuation<CBManagerState, Never>?
    private var scanCont: CheckedContinuation<Void, Never>?
    private var discoveredPeripheral: CBPeripheral?
    private var connectCont: CheckedContinuation<Bool, Never>?
    private var discoveryCont: CheckedContinuation<Bool, Never>?
    private var commandTimeout: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?

    private var centralState: CBManagerState = .unknown

    override init() {
        super.init()
        // Touch the lazy manager so it (and its delegate callbacks) come to life.
        _ = central
    }

    // MARK: - Logging

    private func note(_ message: String) {
        guard message != lastNote else { return }
        lastNote = message
        let stamp = Self.timeFormatter.string(from: Date())
        let line = "\(stamp)  \(message)"
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        Self.appendToLogFile(line + "\n")
    }

    private var lastNote: String?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// `~/Library/Application Support/QCYMenubar/log.txt`, useful to inspect the
    /// GUI run from the terminal.
    static let logFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("QCYMenubar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("log.txt")
    }()

    private static func appendToLogFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logFileURL)
        }
    }

    // MARK: - Framing / transport

    private func nextSN() -> UInt8 {
        sn = sn &+ 1
        if sn == 0 { sn = 1 }
        return sn
    }

    /// Send a command and await its response (matched by sequence number).
    @discardableResult
    func send(_ packet: Packet, timeout: TimeInterval = 3.0) async -> Packet? {
        guard let peripheral, let writeChar, peripheral.state == .connected else {
            note("send ignorado: não conectado")
            return nil
        }
        var pkt = packet
        if pkt.sn == 0 { pkt.sn = nextSN() }
        let data = Data(pkt.encode())

        guard pkt.hasResponse == 1 else {
            peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
            return nil
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Packet?, Never>) in
            pending[pkt.sn] = cont
            peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
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

    /// The headset announces itself as "QCY H3 Pro-APP" on the control channel;
    /// the "-APP" suffix is dropped for display.
    static func displayName(from raw: String?) -> String {
        var name = raw ?? "QCY H3 Pro"
        if name.lowercased().hasSuffix("-app") {
            name = String(name.dropLast(4))
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "QCY H3 Pro" : name
    }

    // MARK: - Commands

    @discardableResult
    private func notifyCommunicationWay() async -> Packet? {
        await send(Packet(opCode: OpCode.notifyCommunicationWay, params: [0, 0]))
    }

    func fetchBattery() async -> Int? {
        let mask = 1 << AdvType.batteryQuantity
        guard let resp = await send(Packet(opCode: OpCode.getAdvInfo, params: beBytes(mask))) else {
            return nil
        }
        for tlv in parseTLV(resp.params) where tlv.type == AdvType.batteryQuantity {
            if let first = tlv.value.first { return Int(first) }
        }
        return nil
    }

    func fetchANCMode() async -> String? {
        let resp = await send(Packet(opCode: OpCode.custom, params: [0xFE, 0x01, 0x17]))
        guard let resp else { return nil }
        return ANC.decode(resp.params)
    }

    func fetchGameMode() async -> Bool? {
        let mask = 1 << AdvType.workMode
        guard let resp = await send(Packet(opCode: OpCode.getAdvInfo, params: beBytes(mask))) else {
            return nil
        }
        for tlv in parseTLV(resp.params) where tlv.type == AdvType.workMode {
            if let first = tlv.value.first { return first == 0x02 }
        }
        return nil
    }

    func fetchEQ() async -> [Int]? {
        let resp = await send(Packet(opCode: OpCode.custom, params: [0xFE, 0x01, 0x22]))
        guard let resp, resp.params.count >= 2, resp.params[0] == 0x22 else { return nil }
        let ll = Int(resp.params[1])
        guard resp.params.count >= 2 + ll else { return nil }
        let data = Array(resp.params[2..<(2 + ll)])
        guard data.count >= 3 + 7 * 7 else { return nil }

        var bands: [Int: Int] = [:]
        let numEntries = (data.count - 3) / 7
        for i in 0..<numEntries {
            let base = 3 + i * 7
            let freq = Int(data[base]) | (Int(data[base + 1]) << 8)
            let raw = Int(data[base + 2]) | (Int(data[base + 3]) << 8)
            let dbOff = Int16(bitPattern: UInt16(truncatingIfNeeded: raw))
            if EQ.bandFreqs.contains(freq) { bands[freq] = Int(dbOff) }
        }
        guard !bands.isEmpty else { return nil }
        return EQ.bandFreqs.map { bands[$0] ?? 0 }
    }

    private func setANC(_ key: String) async {
        guard let params = ANC.params(for: key) else { return }
        await send(Packet(opCode: OpCode.custom, params: params))
    }

    /// Apply a preset by id (1...6) using its default offsets.
    private func applyPreset(id: Int) async {
        let offsets = EQ.presetOffsets[id] ?? Array(repeating: 0, count: 10)
        await setEQ(offsets, presetID: id)
    }

    func setEQ(_ offsets: [Int], presetID: Int) async {
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

    func setGameMode(_ enabled: Bool) async {
        let val: UInt8 = enabled ? 0x02 : 0x01
        await send(Packet(opCode: OpCode.setAdvInfo,
                          params: [0x02, UInt8(AdvType.workMode), val]))
    }

    // MARK: - User actions

    func refreshAll() async {
        if let b = await fetchBattery() { battery = b }
        if let a = await fetchANCMode() { ancMode = a }
        if let g = await fetchGameMode() { gameMode = g }
        if let eq = await fetchEQ() { eqBands = eq; currentPreset = nil }
    }

    func selectANC(_ key: String) async {
        busyCommand = true
        defer { busyCommand = false }
        await setANC(key)
        try? await Task.sleep(for: .milliseconds(250))
        if let a = await fetchANCMode() { ancMode = a } else { ancMode = key }
        note("ANC -> \(key)")
    }

    func toggleGameMode() async {
        busyCommand = true
        defer { busyCommand = false }
        let target = !(gameMode ?? false)
        await setGameMode(target)
        try? await Task.sleep(for: .milliseconds(250))
        gameMode = (await fetchGameMode()) ?? target
        note("Game mode -> \(gameMode == true ? "on" : "off")")
    }

    func selectPreset(_ name: String) async {
        guard let id = EQ.presets[name] else { return }
        busyCommand = true
        defer { busyCommand = false }
        await applyPreset(id: id)
        currentPreset = name
        if let eq = await fetchEQ() { eqBands = eq }
        note("Preset EQ -> \(name)")
    }

    func applyCustomEQ() async {
        busyCommand = true
        defer { busyCommand = false }
        await setEQ(eqBands, presetID: EQ.presets["custom"] ?? 0)
        currentPreset = "custom"
        note("EQ custom aplicado")
    }

    func resetEQ() {
        eqBands = Array(repeating: 0, count: 10)
    }

    /// Round-trip write test used by `--diagnose --write-test`. It re-applies the
    /// current values, so it does not change what the headset is doing.
    func writeSelfTest() async {
        print("--- self-test de escrita (re-aplica os valores atuais) ---")

        if let anc = ancMode {
            await setANC(anc)
            try? await Task.sleep(for: .milliseconds(300))
            let back = await fetchANCMode()
            print("ANC   write \(anc) -> \(back ?? "n/d")  \(back == anc ? "OK" : "DIVERGE")")
        }

        if let game = gameMode {
            await setGameMode(game)
            try? await Task.sleep(for: .milliseconds(300))
            let back = await fetchGameMode()
            let label = back.map { $0 ? "on" : "off" } ?? "n/d"
            print("Game  write \(game ? "on" : "off") -> \(label)  \(back == game ? "OK" : "DIVERGE")")
        }

        print("EQ    write: re-aplicando as 10 bandas como custom")
        await setEQ(eqBands, presetID: EQ.presets["custom"] ?? 0)
        try? await Task.sleep(for: .milliseconds(300))
        let back = await fetchEQ()
        print("EQ    -> " + (back?.map(String.init).joined(separator: ", ") ?? "n/d"))
    }

    func setMonitor(_ enabled: Bool) {
        monitorEnabled = enabled
        if enabled {
            startMonitor()
        } else {
            monitorTask?.cancel()
            monitorTask = nil
        }
    }

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if self.connection == .connected {
                    if let b = await self.fetchBattery() { self.battery = b }
                }
            }
        }
    }

    // MARK: - Auto-connect

    /// Turn the automatic connection loop on or off.
    func setAutoConnect(_ enabled: Bool) {
        autoConnectEnabled = enabled
        if enabled {
            startAutoConnect()
        } else {
            autoTask?.cancel()
            autoTask = nil
        }
    }

    /// Keeps trying to connect (and reconnects after a drop) without any button.
    func startAutoConnect() {
        guard autoConnectEnabled, autoTask == nil else { return }
        autoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                guard let self, self.autoConnectEnabled else { return }
                switch self.connection {
                case .connected:
                    try? await Task.sleep(for: .seconds(3))
                case .scanning, .connecting:
                    try? await Task.sleep(for: .seconds(1))
                case .poweredOff, .unauthorized:
                    try? await Task.sleep(for: .seconds(5))
                default:
                    await self.connect()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        }
    }
}

// MARK: - Connect / disconnect / discovery

extension HeadsetModel {

    func connect() async {
        guard !connection.isBusy, connection != .connected else { return }
        lastError = nil

        let st = await ensurePoweredOn()
        guard st == .poweredOn else {
            connection = mapState(st)
            return
        }

        connection = .scanning
        note("Procurando o fone...")

        var target: CBPeripheral?
        if let idStr = UserDefaults.standard.string(forKey: Self.cachedIdentifierKey),
           let uuid = UUID(uuidString: idStr),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            target = known
            note("Fone conhecido: \(known.name ?? "sem nome")")
        }
        if target == nil {
            target = await scan(services: [Self.serviceUUID], timeout: 5)
        }
        if target == nil {
            note("Não achou pelo serviço a002; tentando por nome...")
            target = await scan(services: nil, timeout: 5)
        }
        guard let peripheral = target else {
            connection = .disconnected
            lastError = "Fone não encontrado. Ligue o fone e tente de novo."
            note("Fone não encontrado.")
            return
        }

        self.peripheral = peripheral
        peripheral.delegate = self
        connection = .connecting
        note("Conectando em \(peripheral.name ?? peripheral.identifier.uuidString)...")

        guard await connectPeripheral(peripheral) else {
            connection = .disconnected
            lastError = "Falha ao conectar."
            return
        }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.cachedIdentifierKey)

        guard await discoverAndSetup(peripheral) else {
            connection = .disconnected
            lastError = "Serviço RCSP (a002) não encontrado."
            note("Serviço RCSP não encontrado.")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        // Mandatory handshake before the device answers commands.
        _ = await send(Packet(opCode: OpCode.notifyCommunicationWay, params: [0, 0]))
        try? await Task.sleep(for: .milliseconds(200))

        deviceName = Self.displayName(from: peripheral.name)
        connectedAddress = peripheral.identifier.uuidString
        connection = .connected
        note("Conectado.")
        await refreshAll()
        if monitorEnabled { setMonitor(true) }
    }

    func disconnect() {
        monitorTask?.cancel()
        monitorTask = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        cleanupConnection()
        connection = .disconnected
        note("Desconectado pelo usuário.")
    }

    // MARK: - Async bridges over the CoreBluetooth callbacks

    private func ensurePoweredOn() async -> CBManagerState {
        if centralState == .poweredOn { return .poweredOn }
        if centralState != .unknown && centralState != .resetting { return centralState }
        return await withCheckedContinuation { (cont: CheckedContinuation<CBManagerState, Never>) in
            stateCont = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let c = self.stateCont else { return }
                self.stateCont = nil
                c.resume(returning: self.centralState)
            }
        }
    }

    private func scan(services: [CBUUID]?, timeout: TimeInterval) async -> CBPeripheral? {
        discoveredPeripheral = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            scanCont = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let c = self.scanCont else { return }
                self.scanCont = nil
                self.central.stopScan()
                c.resume()
            }
            central.scanForPeripherals(
                withServices: services,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        return discoveredPeripheral
    }

    private func connectPeripheral(_ p: CBPeripheral) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connectCont = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let c = self.connectCont else { return }
                self.connectCont = nil
                self.central.cancelPeripheralConnection(p)
                c.resume(returning: false)
            }
            central.connect(p, options: nil)
        }
    }

    private func discoverAndSetup(_ p: CBPeripheral) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            discoveryCont = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, let c = self.discoveryCont else { return }
                self.discoveryCont = nil
                c.resume(returning: false)
            }
            p.discoverServices([Self.serviceUUID])
        }
    }

    private func cleanupConnection() {
        for (_, c) in pending { c.resume(returning: nil) }
        pending.removeAll()
        rxBuffer.removeAll()
        writeChar = nil
        notifyChar = nil
        peripheral = nil
    }

    private func mapState(_ s: CBManagerState) -> ConnectionState {
        switch s {
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .failed("Bluetooth indisponível neste Mac")
        case .poweredOn: return .disconnected
        default: return .unknown
        }
    }

    private func looksLikeHeadset(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("qcy") || n.contains("-app")
    }

    private func handleNotify(_ data: [UInt8]) {
        rxBuffer.append(contentsOf: data)
        while true {
            guard let idx = Packet.indexOfHeader(rxBuffer) else {
                rxBuffer.removeAll()
                return
            }
            if idx > 0 { rxBuffer.removeFirst(idx) }
            if rxBuffer.count < 8 { return }
            let paramLen = (Int(rxBuffer[5]) << 8) | Int(rxBuffer[6])
            let total = 7 + paramLen + 1
            if rxBuffer.count < total { return }
            let pktBytes = Array(rxBuffer[0..<total])
            rxBuffer.removeFirst(total)
            guard let pkt = Packet.decode(pktBytes) else { continue }
            if let c = pending.removeValue(forKey: pkt.sn) {
                c.resume(returning: pkt)
            }
        }
    }
}

// MARK: - CoreBluetooth delegates

extension HeadsetModel: @preconcurrency CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = central.state
        if let c = stateCont {
            stateCont = nil
            c.resume(returning: central.state)
        }
        if central.state != .poweredOn, connection == .connected {
            connection = mapState(central.state)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard looksLikeHeadset(name) else { return }
        guard let c = scanCont else { return }
        scanCont = nil
        discoveredPeripheral = peripheral
        central.stopScan()
        c.resume()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let c = connectCont {
            connectCont = nil
            c.resume(returning: true)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        note("Falha ao conectar: \(error?.localizedDescription ?? "desconhecido")")
        if let c = connectCont {
            connectCont = nil
            c.resume(returning: false)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        note("Dispositivo desconectou.")
        cleanupConnection()
        if connection == .connected || connection == .connecting {
            connection = .disconnected
        }
    }
}

extension HeadsetModel: @preconcurrency CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services,
              let svc = services.first(where: { $0.uuid == Self.serviceUUID }) else {
            if let c = discoveryCont { discoveryCont = nil; c.resume(returning: false) }
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for ch in chars {
            if ch.uuid == Self.writeUUID { writeChar = ch }
            if ch.uuid == Self.notifyUUID {
                notifyChar = ch
                peripheral.setNotifyValue(true, for: ch)
            }
        }
        if let c = discoveryCont, writeChar != nil, notifyChar != nil {
            discoveryCont = nil
            c.resume(returning: true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.notifyUUID, let data = characteristic.value else { return }
        handleNotify([UInt8](data))
    }
}
