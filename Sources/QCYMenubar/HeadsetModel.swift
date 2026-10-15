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

/// Owns the CoreBluetooth central (the transport) and dispatches to a protocol
/// engine once the headset's GATT layout is known. Everything runs on the main
/// queue (`CBCentralManager(queue: .main)`).
@MainActor
final class HeadsetModel: NSObject, ObservableObject {

    // MARK: - Published UI state

    @Published var connection: ConnectionState = .unknown
    @Published var deviceName: String?
    @Published var connectedAddress: String?
    @Published var protocolLabel: String?
    /// Resource name of the product image to show for the connected model.
    @Published var productImageName = "Headset"

    @Published var battery: BatteryReading = .unknown
    @Published var batteryStyle: BatteryStyle = .single

    @Published var ancMode: String?
    @Published var ancOptions: [ANCOption] = []
    @Published var ancScenes: [ANCOption] = []
    @Published var gameMode: Bool?
    @Published var supportsGameMode = false

    @Published var eqGains: [Int] = []
    @Published var eqBands: [EQBandInfo] = []
    @Published var eqPresets: [String] = []
    @Published var currentPreset: String?

    @Published var monitorEnabled = false
    @Published var autoConnectEnabled = true
    @Published var busyCommand = false
    @Published var lastError: String?
    @Published var log: [String] = []

    // MARK: - GATT UUIDs

    /// RCSP (H3 / H3 Pro): service `a002`, write `00000001`, notify `00000002`.
    static let rcspServiceUUID = CBUUID(string: "0000a002-0000-1000-8000-00805f9b34fb")
    static let rcspWriteUUID = CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb")
    static let rcspNotifyUUID = CBUUID(string: "00000002-0000-1000-8000-00805f9b34fb")
    /// QCY standard (most earbuds): write `00001001`, notify `00001002`.
    static let qcyWriteUUID = CBUUID(string: "00001001-0000-1000-8000-00805f9b34fb")
    static let qcyNotifyUUID = CBUUID(string: "00001002-0000-1000-8000-00805f9b34fb")

    static let cachedIdentifierKey = "QCYPeripheralIdentifier"
    static let vendorIdKey = "QCYVendorId"
    static let versionCharUUID = CBUUID(string: "00000007-0000-1000-8000-00805f9b34fb")
    static let batteryCharUUID = CBUUID(string: "00000008-0000-1000-8000-00805f9b34fb")

    // MARK: - Internal BLE plumbing

    private(set) lazy var central: CBCentralManager = CBCentralManager(delegate: self, queue: .main)

    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var notifyHandler: (([UInt8]) -> Void)?
    private var engine: HeadsetProtocolEngine?
    private var charsByUUID: [CBUUID: CBCharacteristic] = [:]
    private var readWaiters: [CBUUID: CheckedContinuation<[UInt8]?, Never>] = [:]
    private var scannedVendorId: Int?

    private var stateCont: CheckedContinuation<CBManagerState, Never>?
    private var scanCont: CheckedContinuation<Void, Never>?
    private var discoveredPeripheral: CBPeripheral?
    private var connectCont: CheckedContinuation<Bool, Never>?
    private var discoveryCont: CheckedContinuation<ProtocolFamily?, Never>?
    private var resolvedFamily: ProtocolFamily?
    private var monitorTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?

    // Service/characteristic discovery accumulators.
    private var discoveredServices: [CBService] = []
    private var discoveredCount = 0
    private var foundQcyWrite: CBCharacteristic?
    private var foundQcyNotify: CBCharacteristic?
    private var foundRcspWrite: CBCharacteristic?
    private var foundRcspNotify: CBCharacteristic?

    private var centralState: CBManagerState = .unknown

    override init() {
        super.init()
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

    /// The headset announces itself as "QCY H3 Pro-APP" on the control channel;
    /// the "-APP" suffix is dropped for display.
    static func displayName(from raw: String?) -> String {
        var name = raw ?? "QCY"
        if name.lowercased().hasSuffix("-app") {
            name = String(name.dropLast(4))
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "QCY" : name
    }

    /// Product image resource (in Resources/) chosen by the model's vendorId.
    static func productImageName(forVendorId id: Int?) -> String {
        switch id {
        case 23879: return "n60"    // QCY MeloBuds N60
        default: return "Headset"   // QCY H3 / H3 Pro
        }
    }

    // MARK: - User actions

    func refreshAll() async {
        guard let engine else { return }
        let snapshot = await engine.refresh()
        apply(snapshot)
        publishCapabilities()
    }

    func selectANC(_ key: String) async {
        guard let engine else { return }
        busyCommand = true
        defer { busyCommand = false }
        if let applied = await engine.applyANC(key) { ancMode = applied }
        note("ANC -> \(key)")
    }

    func toggleGameMode() async {
        guard let engine else { return }
        busyCommand = true
        defer { busyCommand = false }
        let target = !(gameMode ?? false)
        gameMode = await engine.applyGameMode(target) ?? target
        note("Game mode -> \(gameMode == true ? "on" : "off")")
    }

    func selectPreset(_ name: String) async {
        guard let engine else { return }
        busyCommand = true
        defer { busyCommand = false }
        if let gains = await engine.applyPreset(name) {
            eqGains = gains
            currentPreset = name
        }
        note("Preset EQ -> \(name)")
    }

    func applyCustomEQ() async {
        guard let engine else { return }
        busyCommand = true
        defer { busyCommand = false }
        if let gains = await engine.applyEQ(gains: eqGains) { eqGains = gains }
        currentPreset = eqPresets.contains("custom") ? "custom" : nil
        note("EQ custom aplicado")
    }

    func resetEQ() {
        eqGains = Array(repeating: 0, count: eqBands.count)
    }

    /// Reads per-component diagnostics (battery/version by component, wearing,
    /// ANC calibration, …) for fault hunting. Returns printable lines.
    func runDeepDiagnostics() async -> [String] {
        var lines: [String] = []
        if let v = await readCharacteristic(Self.versionCharUUID) {
            lines.append("versão (char 0007): \(hexStr(v))")
        }
        if let b = await readCharacteristic(Self.batteryCharUUID) {
            lines.append("bateria (char 0008): \(hexStr(b))")
        }
        guard let engine else { return lines }
        let probes: [(String, UInt8)] = [
            ("0x30 versão (L/R)", 0x30),
            ("0x2F bateria (L/R/case)", 0x2F),
            ("0x07 noise value", 0x07),
            ("0x28 ANC calibração", 0x28),
            ("0x29 ANC wear", 0x29),
            ("0x2C detecção de uso", 0x2C),
            ("0x06 in-ear detect", 0x06),
            ("0x48 sensibilidade in-ear", 0x48),
            ("0x32 adaptação ambiente", 0x32),
            ("0x17 ANC atual", 0x17),
            ("0x09 game mode", 0x09),
        ]
        for (label, cmd) in probes {
            let resp = await engine.rawRequest(cmd, timeout: 2)
            lines.append("\(label): \(resp.map(hexStr) ?? "(sem resposta)")")
        }
        return lines
    }

    // MARK: - Monitor / auto-connect

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
                if self.connection == .connected, let engine = self.engine {
                    let snapshot = await engine.refresh()
                    if snapshot.battery != .unknown { self.battery = snapshot.battery }
                }
            }
        }
    }

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

    // MARK: - State helpers

    private func apply(_ snapshot: HeadsetSnapshot) {
        battery = snapshot.battery
        if let k = snapshot.ancKey { ancMode = k }
        if let g = snapshot.gameMode { gameMode = g }
        if let gains = snapshot.eqGains { eqGains = gains }
    }

    private func publishCapabilities() {
        guard let engine else { return }
        let caps = engine.capabilities
        protocolLabel = engine.family.label
        ancOptions = caps.ancOptions
        ancScenes = caps.ancScenes
        gameMode = caps.supportsGameMode ? gameMode : nil
        supportsGameMode = caps.supportsGameMode
        batteryStyle = caps.batteryStyle
        eqBands = caps.eqBands
        eqPresets = caps.eqPresets
        if eqGains.count != caps.eqBands.count {
            eqGains = Array(repeating: 0, count: caps.eqBands.count)
        }
    }
}

// MARK: - BLE transport (what a protocol engine talks to)

extension HeadsetModel: BLELink {
    func writeRaw(_ bytes: [UInt8]) {
        guard let peripheral, let writeChar, peripheral.state == .connected else { return }
        peripheral.writeValue(Data(bytes), for: writeChar, type: .withoutResponse)
    }

    func setNotifyHandler(_ handler: (([UInt8]) -> Void)?) {
        notifyHandler = handler
    }

    func readCharacteristic(_ uuid: CBUUID) async -> [UInt8]? {
        guard let peripheral, let ch = charsByUUID[uuid], peripheral.state == .connected else { return nil }
        if let value = ch.value, !value.isEmpty { return [UInt8](value) }
        return await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            readWaiters[uuid] = cont
            peripheral.readValue(for: ch)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let c = self?.readWaiters.removeValue(forKey: uuid) {
                    c.resume(returning: nil)
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
            target = await scan(services: [Self.rcspServiceUUID], timeout: 5)
        }
        if target == nil {
            note("Tentando por nome / manufacturer data...")
            target = await scan(services: nil, timeout: 6)
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

        guard let family = await discoverAndSetup(peripheral) else {
            connection = .disconnected
            lastError = "Protocolo não reconhecido neste fone."
            note("Nenhum protocolo conhecido encontrado.")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        let vendorId = scannedVendorId
            ?? UserDefaults.standard.object(forKey: Self.vendorIdKey) as? Int
        productImageName = Self.productImageName(forVendorId: vendorId)
        let newEngine: HeadsetProtocolEngine = (family == .rcsp)
            ? RCSPProtocol()
            : QCYStandardProtocol(vendorId: vendorId)
        newEngine.attach(to: self)
        engine = newEngine
        note("Protocolo: \(family.label)")

        await newEngine.handshake()

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

    // MARK: - Async bridges

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

    /// Discovers every service/characteristic and decides which protocol family
    /// the headset speaks.
    private func discoverAndSetup(_ p: CBPeripheral) async -> ProtocolFamily? {
        discoveredServices = []
        discoveredCount = 0
        foundQcyWrite = nil
        foundQcyNotify = nil
        foundRcspWrite = nil
        foundRcspNotify = nil
        resolvedFamily = nil
        return await withCheckedContinuation { (cont: CheckedContinuation<ProtocolFamily?, Never>) in
            discoveryCont = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, let c = self.discoveryCont else { return }
                self.discoveryCont = nil
                c.resume(returning: nil)
            }
            p.discoverServices(nil)
        }
    }

    private func cleanupConnection() {
        notifyHandler = nil
        engine = nil
        writeChar = nil
        notifyChar = nil
        peripheral = nil
        resolvedFamily = nil
        charsByUUID.removeAll()
        for (_, c) in readWaiters { c.resume(returning: nil) }
        readWaiters.removeAll()
        scannedVendorId = nil
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
        if let md = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 4 {
            let company = UInt16(md[md.startIndex]) | (UInt16(md[md.startIndex + 1]) << 8)
            if company == 0x521C {
                let vid = (Int(md[md.startIndex + 2]) << 8) | Int(md[md.startIndex + 3])
                scannedVendorId = vid
                UserDefaults.standard.set(vid, forKey: Self.vendorIdKey)
            }
        }
        guard matchesHeadset(name: name, advertisement: advertisementData) else { return }
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
        guard let services = peripheral.services, !services.isEmpty else {
            finishDiscovery(.none)
            return
        }
        discoveredServices = services
        discoveredCount = 0
        for svc in services {
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        discoveredCount += 1
        for ch in service.characteristics ?? [] {
            charsByUUID[ch.uuid] = ch
            if ch.uuid == Self.qcyWriteUUID { foundQcyWrite = ch }
            if ch.uuid == Self.qcyNotifyUUID { foundQcyNotify = ch }
            if service.uuid == Self.rcspServiceUUID {
                if ch.uuid == Self.rcspWriteUUID { foundRcspWrite = ch }
                if ch.uuid == Self.rcspNotifyUUID { foundRcspNotify = ch }
            }
        }
        if discoveredCount >= discoveredServices.count {
            // Prefer the QCY standard layout when both are somehow present.
            if foundQcyWrite != nil, foundQcyNotify != nil {
                writeChar = foundQcyWrite
                notifyChar = foundQcyNotify
                subscribe(peripheral, notifyChar)
                finishDiscovery(.qcyStandard)
            } else if foundRcspWrite != nil, foundRcspNotify != nil {
                writeChar = foundRcspWrite
                notifyChar = foundRcspNotify
                subscribe(peripheral, notifyChar)
                finishDiscovery(.rcsp)
            } else {
                finishDiscovery(.none)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let c = readWaiters.removeValue(forKey: characteristic.uuid), let value = characteristic.value {
            c.resume(returning: [UInt8](value))
            return
        }
        guard characteristic.uuid == notifyChar?.uuid, let data = characteristic.value else { return }
        notifyHandler?([UInt8](data))
    }

    private func subscribe(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic?) {
        guard let characteristic else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }
}

// MARK: - Discovery bookkeeping (stored as free helpers on the model)

extension HeadsetModel {
    /// Called once discovery finishes; decides the family and resumes the caller.
    fileprivate func finishDiscovery(_ family: ProtocolFamily?) {
        resolvedFamily = family
        guard let c = discoveryCont else { return }
        discoveryCont = nil
        c.resume(returning: family)
    }

    /// A device is a candidate if the name looks like QCY or it advertises the
    /// QCY manufacturer ID (0x521C).
    fileprivate func matchesHeadset(name: String, advertisement: [String: Any]) -> Bool {
        let n = name.lowercased()
        if n.contains("qcy") || n.contains("-app") { return true }
        if let md = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 2 {
            let company = UInt16(md[md.startIndex]) | (UInt16(md[md.startIndex + 1]) << 8)
            if company == 0x521C { return true }
        }
        return false
    }
}
