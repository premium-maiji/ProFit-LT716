import CoreBluetooth
import Darwin
import Foundation

@MainActor
final class FitProBLEManager: NSObject, ObservableObject {
    enum SendMode: String, CaseIterable, Identifiable {
        case notification = "Notification"
        case call = "Call"

        var id: String { rawValue }
    }

    struct DiscoveredDevice: Identifiable {
        let id: UUID
        let name: String
        let rssi: Int
        let serviceSummary: String
        let isMatch: Bool
    }

    private struct PendingSMS {
        let text: String
        let asciiOnly: Bool
    }

    @Published var status = "Idle"
    @Published var logLines: [String] = []
    @Published var isConnected = false
    @Published var isReady = false
    @Published var isConnectionBusy = false
    @Published var isSMSBusy = false
    @Published var isCommandBusy = false
    @Published var targetName = "LT716"
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var isVibrationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isVibrationEnabled, forKey: Self.vibrationEnabledKey)
            guard oldValue != isVibrationEnabled else {
                return
            }
            appendLog("vibration \(isVibrationEnabled ? "on" : "off")")
            sendVibrationSettingIfReady()
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var isNotifyEnabled = false
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var queue: [FitProPacket] = []
    private var currentPacket: FitProPacket?
    private var currentChunks: [Data] = []
    private var currentPacketName = ""
    private var currentPacketAcked = false
    private var isWaitingForCurrentAck = false
    private var isWritingChunk = false
    private var ackTimeoutGeneration = 0
    private var didSendSetup = false
    private var scanGeneration = 0
    private var pendingScanAfterPowerOn = false
    private var pendingDisconnect = false
    private var pendingSMS: PendingSMS?
    private var isPendingSMSFlushScheduled = false
    private var pendingSMSFlushGeneration = 0
    private let lastPeripheralKey = "lastPeripheralID"
    private let boundPeripheralIDsKey = "boundPeripheralIDs"
    private static let vibrationEnabledKey = "vibrationEnabled"

    override init() {
        if UserDefaults.standard.object(forKey: Self.vibrationEnabledKey) == nil {
            isVibrationEnabled = true
        } else {
            isVibrationEnabled = UserDefaults.standard.bool(forKey: Self.vibrationEnabledKey)
        }
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scanAndConnect() {
        appendLog("scan requested state=\(central.state.rawValue)")
        guard !isConnectionBusy else {
            appendLog("connect already in progress")
            return
        }
        isConnectionBusy = true
        guard central.state == .poweredOn else {
            isConnectionBusy = false
            pendingScanAfterPowerOn = false
            status = "Bluetooth not ready"
            appendLog("central state \(central.state.rawValue)")
            return
        }
        startScanAndConnect()
    }

    private func startScanAndConnect() {
        pendingScanAfterPowerOn = false
        resetConnectionState()
        isConnectionBusy = true
        discoveredDevices.removeAll()
        discoveredPeripherals.removeAll()
        scanGeneration += 1
        let generation = scanGeneration
        status = "Searching"
        let service = CBUUID(nsuuid: FitProProtocol.serviceUUID)
        if connectFirstMatch(central.retrieveConnectedPeripherals(withServices: [service]), source: "connected") {
            return
        }
        if let idString = UserDefaults.standard.string(forKey: lastPeripheralKey),
           let uuid = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(known, source: "known")
            return
        }
        status = "Scanning"
        appendLog("scan start broad")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, generation == self.scanGeneration, self.central.isScanning, !self.isConnected else {
                return
            }
            self.central.stopScan()
            self.isConnectionBusy = false
            self.pendingSMS = nil
            self.isSMSBusy = false
            self.status = "Scan finished"
            self.appendLog("scan timeout found=\(self.discoveredDevices.count)")
        }
    }

    func disconnect() {
        pendingScanAfterPowerOn = false
        pendingSMS = nil
        isSMSBusy = false
        pendingDisconnect = true
        central.stopScan()
        appendLog("disconnect requested")
        guard isReady else {
            cancelConnection()
            return
        }
        enqueue([FitProProtocol.realtimeStep(false)])
        processPendingDisconnectIfNeeded()
    }

    func connect(deviceID: UUID) {
        guard let peripheral = discoveredPeripherals[deviceID] else {
            appendLog("device not found \(deviceID.uuidString)")
            return
        }
        connect(peripheral, source: "manual")
    }

    func sendNotification(text: String, app: FitProNotifyApp, asciiOnly: Bool) {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        let prepared = asciiOnly ? text.map { $0.isASCII ? $0 : "?" }.map(String.init).joined() : text
        enqueue(notificationPrepPackets() + [FitProProtocol.notification(text: prepared, app: app)])
    }

    func sendSMSNotification(text: String, asciiOnly: Bool) {
        guard !text.isEmpty else {
            appendLog("sms empty")
            return
        }
        if isSMSBusy {
            pendingSMS = PendingSMS(text: text, asciiOnly: asciiOnly)
            status = "Waiting to send"
            appendLog("sms busy replace pending")
            return
        }
        isSMSBusy = true
        if isReady && isQueueIdle {
            status = "Sending"
            appendLog("send sms now")
            enqueue(smsNotificationPackets(text: text, asciiOnly: asciiOnly))
            return
        }
        pendingSMS = PendingSMS(text: text, asciiOnly: asciiOnly)
        status = isConnected ? "Waiting to send" : "Waiting for connection"
        appendLog(isReady ? "pending sms queued busy" : "pending sms queued")
        if !isConnected {
            if !isConnectionBusy {
                scanAndConnect()
            }
        } else {
            flushPendingSMSIfReady()
        }
    }

    func enableVibration() {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        isVibrationEnabled = true
    }

    func sendCommonNotificationTests(text: String, asciiOnly: Bool) {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        let prepared = asciiOnly ? text.map { $0.isASCII ? $0 : "?" }.map(String.init).joined() : text
        let apps: [FitProNotifyApp] = [.sms, .line, .whatsapp, .wechat, .telegram, .instagram, .messenger]
        enqueue(notificationPrepPackets() + apps.map { app in
            FitProProtocol.notification(text: "\(app.label) \(prepared)", app: app)
        })
    }

    func sendRaw(hex: String) {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        guard let packet = FitProProtocol.raw(hex: hex) else {
            appendLog("invalid raw hex")
            return
        }
        enqueue([packet])
    }

    func send(text: String, mode: SendMode, asciiOnly: Bool) {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        let prepared = asciiOnly ? text.map { $0.isASCII ? $0 : "?" }.map(String.init).joined() : text
        switch mode {
        case .notification:
            enqueue([FitProProtocol.notification(text: prepared)])
        case .call:
            enqueue([FitProProtocol.call(text: prepared, state: 1)])
        }
    }

    func sendCallDiagnostic(text: String, asciiOnly: Bool) {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        let prepared = asciiOnly ? text.map { $0.isASCII ? $0 : "?" }.map(String.init).joined() : text
        enqueue([
            FitProProtocol.call(text: prepared.isEmpty ? "TEST" : prepared, state: 1),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.enqueue([FitProProtocol.call(text: "", state: 0)])
        }
    }

    func endCall() {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        enqueue([FitProProtocol.call(text: "", state: 0)])
    }

    func resendSetup() {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        enqueue(sessionSetupPackets())
    }

    func unbindAndDisconnect() {
        guard isReady else {
            appendLog("not ready connected=\(isConnected) write=\(writeCharacteristic != nil) notify=\(notifyCharacteristic != nil) notifyOn=\(isNotifyEnabled)")
            return
        }
        pendingDisconnect = true
        enqueue([FitProProtocol.unbind()])
    }

    private func resetConnectionState() {
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        isNotifyEnabled = false
        queue.removeAll()
        currentPacket = nil
        currentChunks.removeAll()
        currentPacketName = ""
        currentPacketAcked = false
        isWaitingForCurrentAck = false
        isWritingChunk = false
        ackTimeoutGeneration += 1
        didSendSetup = false
        pendingDisconnect = false
        isSMSBusy = pendingSMS != nil
        isConnectionBusy = false
        isPendingSMSFlushScheduled = false
        pendingSMSFlushGeneration += 1
        isConnected = false
        isReady = false
        refreshCommandBusy()
    }

    private func enqueue(_ packets: [FitProPacket]) {
        queue.append(contentsOf: packets)
        refreshCommandBusy()
        processQueueIfNeeded()
    }

    private func processQueueIfNeeded() {
        guard currentPacket == nil, currentChunks.isEmpty else {
            refreshCommandBusy()
            return
        }
        if queue.isEmpty {
            refreshCommandBusy()
            if isReady,
               pendingSMS == nil,
               !isPendingSMSFlushScheduled,
               !pendingDisconnect,
               status == "Setting up" {
                status = "Connected"
            }
            flushPendingSMSIfReady()
            processPendingDisconnectIfNeeded()
            return
        }
        guard let peripheral, let writeCharacteristic, let packet = queue.first else {
            refreshCommandBusy()
            return
        }
        queue.removeFirst()
        currentPacket = packet
        currentPacketName = packet.name
        currentPacketAcked = false
        isWaitingForCurrentAck = false
        isWritingChunk = false
        currentChunks = packet.data.chunks(size: 20)
        refreshCommandBusy()
        appendLog("tx \(packet.name) \(packet.data.hexString)")
        writeNextChunk(peripheral: peripheral, characteristic: writeCharacteristic)
    }

    private func writeNextChunk(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard !currentChunks.isEmpty else {
            waitForCurrentAckIfNeeded()
            return
        }
        let chunk = currentChunks.removeFirst()
        let type = writeType(for: characteristic)
        appendLog("chunk \(currentPacketName) len=\(chunk.count) type=\(type == .withResponse ? "resp" : "noresp")")
        isWritingChunk = type == .withResponse
        peripheral.writeValue(chunk, for: characteristic, type: type)
        if type == .withoutResponse {
            isWritingChunk = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak peripheral, weak characteristic] in
                guard let self, let peripheral, let characteristic else {
                    return
                }
                self.writeNextChunk(peripheral: peripheral, characteristic: characteristic)
            }
        }
    }

    private func waitForCurrentAckIfNeeded() {
        guard let packet = currentPacket else {
            processQueueIfNeeded()
            return
        }
        if currentPacketAcked {
            finishCurrentPacket()
            return
        }
        guard !isWaitingForCurrentAck else {
            return
        }
        isWaitingForCurrentAck = true
        ackTimeoutGeneration += 1
        let generation = ackTimeoutGeneration
        appendLog("wait ack \(packet.name)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self,
                  self.ackTimeoutGeneration == generation,
                  let current = self.currentPacket,
                  current.name == packet.name,
                  !self.currentPacketAcked else {
                return
            }
            self.appendLog("ack timeout \(packet.name)")
            self.finishCurrentPacket()
        }
    }

    private func handleAckIfNeeded(_ data: Data) {
        guard let packet = currentPacket, ackMatches(packet: packet, data: data) else {
            return
        }
        currentPacketAcked = true
        appendLog("ack \(packet.name)")
        if packet.name == "bind" {
            markCurrentPeripheralBoundIfNeeded()
        }
        if packet.name == "unbind" {
            forgetCurrentPeripheralBoundIfNeeded()
        }
        if currentChunks.isEmpty, !isWritingChunk {
            finishCurrentPacket()
        }
    }

    private func finishCurrentPacket() {
        let finishedName = currentPacketName
        currentPacket = nil
        currentChunks.removeAll()
        currentPacketName = ""
        currentPacketAcked = false
        isWaitingForCurrentAck = false
        isWritingChunk = false
        ackTimeoutGeneration += 1
        if finishedName == "notify:SMS" {
            isSMSBusy = false
            if status == "Waiting to send" || status == "Sending" {
                status = isConnected ? "Connected" : "Disconnected"
            }
        }
        refreshCommandBusy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.processQueueIfNeeded()
        }
    }

    private func sessionSetupPackets() -> [FitProPacket] {
        guard let peripheral else {
            return FitProProtocol.setupPackets(includeBind: true, vibrationEnabled: isVibrationEnabled)
        }
        let id = peripheral.identifier.uuidString
        appendLog("bind: forcing bind for \(id)")
        return FitProProtocol.setupPackets(includeBind: true, vibrationEnabled: isVibrationEnabled)
    }

    private func notificationPrepPackets() -> [FitProPacket] {
        [
            FitProProtocol.bind(),
            FitProProtocol.disturbOff(),
            FitProProtocol.pushSwitches(count: 11),
            FitProProtocol.vibration(enabled: isVibrationEnabled),
        ]
    }

    private func sendVibrationSettingIfReady() {
        guard isReady else {
            appendLog("vibration saved; apply on connect")
            return
        }
        enqueue([FitProProtocol.vibration(enabled: isVibrationEnabled)])
    }

    private func boundPeripheralIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: boundPeripheralIDsKey) ?? [])
    }

    private func markCurrentPeripheralBoundIfNeeded() {
        guard let peripheral else {
            return
        }
        var ids = boundPeripheralIDs()
        let id = peripheral.identifier.uuidString
        if ids.insert(id).inserted {
            UserDefaults.standard.set(Array(ids).sorted(), forKey: boundPeripheralIDsKey)
            appendLog("remembered bound address \(id)")
        }
    }

    private func forgetCurrentPeripheralBoundIfNeeded() {
        guard let peripheral else {
            return
        }
        var ids = boundPeripheralIDs()
        let id = peripheral.identifier.uuidString
        if ids.remove(id) != nil {
            UserDefaults.standard.set(Array(ids).sorted(), forKey: boundPeripheralIDsKey)
            appendLog("forgot bound address \(id)")
        }
        UserDefaults.standard.removeObject(forKey: lastPeripheralKey)
    }

    private func ackMatches(packet: FitProPacket, data: Data) -> Bool {
        guard data.count >= 4, data[0] == 0xDC || data[0] == 0xCD else {
            return false
        }
        guard packet.data.count >= 4, data[3] == packet.data[3] else {
            return false
        }
        if data[0] == 0xCD {
            return packet.data.count >= 6 && data.count >= 6 && data[5] == packet.data[5]
        }
        if packet.data.count >= 6, packet.data[4] == 0x01 {
            return data.count >= 5 && data[4] == packet.data[5]
        }
        return true
    }

    private func appendLog(_ line: String) {
        let timestamp = DateFormatter.fitProLog.string(from: Date())
        let formatted = "\(timestamp) \(line)"
        print("FITPRO \(formatted)")
        fflush(stdout)
        logLines.append(formatted)
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }

    private func connectFirstMatch(_ peripherals: [CBPeripheral], source: String) -> Bool {
        guard let match = peripherals.first(where: { peripheralMatches($0, localName: nil) }) else {
            return false
        }
        connect(match, source: source)
        return true
    }

    private func connect(_ peripheral: CBPeripheral, source: String) {
        let name = peripheral.name ?? peripheral.identifier.uuidString
        appendLog("\(source) \(name)")
        isConnectionBusy = true
        status = "Connecting"
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    private func cancelConnection() {
        guard let peripheral else {
            status = "Disconnected"
            appendLog("disconnect no peripheral")
            resetConnectionState()
            return
        }
        appendLog("cancel connection state=\(peripheral.state.rawValue)")
        central.cancelPeripheralConnection(peripheral)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak peripheral] in
            guard let self, self.pendingDisconnect, self.peripheral === peripheral else {
                return
            }
            self.appendLog("disconnect callback timeout; local reset")
            self.status = "Disconnected"
            self.resetConnectionState()
        }
    }

    private func processPendingDisconnectIfNeeded() {
        guard pendingDisconnect, currentChunks.isEmpty, queue.isEmpty else {
            return
        }
        cancelConnection()
    }

    private func writeType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        if characteristic.properties.contains(.write) {
            return .withResponse
        }
        return .withoutResponse
    }

    private func updateReadyIfPossible() {
        guard writeCharacteristic != nil, notifyCharacteristic != nil, isNotifyEnabled else {
            return
        }
        if !isReady {
            isReady = true
            isConnectionBusy = false
            status = pendingSMS == nil ? "Setting up" : "Waiting to send"
            appendLog("ready")
        }
        if !didSendSetup {
            didSendSetup = true
            enqueue(sessionSetupPackets())
        }
        flushPendingSMSIfReady()
    }

    private func smsNotificationPackets(text: String, asciiOnly: Bool) -> [FitProPacket] {
        let prepared = asciiOnly ? text.map { $0.isASCII ? $0 : "?" }.map(String.init).joined() : text
        return [FitProProtocol.notification(text: prepared, app: .sms)]
    }

    private func flushPendingSMSIfReady() {
        guard isReady, pendingSMS != nil else {
            return
        }
        guard isQueueIdle else {
            return
        }
        guard !isPendingSMSFlushScheduled else {
            return
        }
        isPendingSMSFlushScheduled = true
        refreshCommandBusy()
        pendingSMSFlushGeneration += 1
        let generation = pendingSMSFlushGeneration
        status = "Waiting to send"
        appendLog("pending sms wait settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.pendingSMSFlushGeneration == generation else {
                return
            }
            self.isPendingSMSFlushScheduled = false
            self.refreshCommandBusy()
            guard self.isReady, let pendingSMS = self.pendingSMS else {
                return
            }
            guard self.isQueueIdle else {
                self.flushPendingSMSIfReady()
                return
            }
            self.pendingSMS = nil
            self.status = "Sending"
            self.appendLog("send pending sms")
            self.enqueue(self.smsNotificationPackets(text: pendingSMS.text, asciiOnly: pendingSMS.asciiOnly))
        }
    }

    private var isQueueIdle: Bool {
        queue.isEmpty && currentPacket == nil && currentChunks.isEmpty && !isWritingChunk && !isWaitingForCurrentAck
    }

    private func refreshCommandBusy() {
        isCommandBusy = !isQueueIdle || isPendingSMSFlushScheduled
    }

    private func peripheralMatches(_ peripheral: CBPeripheral, localName: String?) -> Bool {
        let name = peripheral.name ?? localName ?? ""
        return targetName.isEmpty || name.localizedCaseInsensitiveContains(targetName)
    }

    private func advertisedServices(from advertisementData: [String: Any]) -> [CBUUID] {
        let keys = [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey,
        ]
        return keys.flatMap { advertisementData[$0] as? [CBUUID] ?? [] }
    }

    private func updateDiscoveredDevice(_ peripheral: CBPeripheral, localName: String?, rssi: NSNumber, services: [CBUUID], isMatch: Bool) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        let name = peripheral.name ?? localName ?? "(no name)"
        let serviceSummary = services.prefix(3).map(\.uuidString).joined(separator: ",")
        let device = DiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: rssi.intValue,
            serviceSummary: serviceSummary.isEmpty ? "-" : serviceSummary,
            isMatch: isMatch
        )
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
            discoveredDevices.sort { lhs, rhs in
                if lhs.isMatch != rhs.isMatch {
                    return lhs.isMatch && !rhs.isMatch
                }
                return lhs.rssi > rhs.rssi
            }
            appendLog("adv \(name) rssi=\(rssi) svc=\(device.serviceSummary)")
        }
    }
}

extension FitProBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            appendLog("central state \(central.state.rawValue)")
            switch central.state {
            case .poweredOn:
                status = "Idle"
                pendingScanAfterPowerOn = false
                if pendingSMS != nil {
                    startScanAndConnect()
                }
            case .poweredOff:
                pendingScanAfterPowerOn = false
                resetForBluetoothUnavailable(statusText: "Disconnected")
            case .resetting:
                resetForBluetoothUnavailable(statusText: "Disconnected")
            case .unauthorized, .unsupported:
                pendingScanAfterPowerOn = false
                resetForBluetoothUnavailable(statusText: "Bluetooth not ready")
            case .unknown:
                status = "Bluetooth not ready"
            @unknown default:
                pendingScanAfterPowerOn = false
                resetForBluetoothUnavailable(statusText: "Bluetooth not ready")
            }
        }
    }

    private func resetForBluetoothUnavailable(statusText: String) {
        if central.isScanning {
            central.stopScan()
        }
        discoveredDevices.removeAll()
        discoveredPeripherals.removeAll()
        pendingSMS = nil
        isSMSBusy = false
        resetConnectionState()
        status = statusText
        appendLog("bluetooth unavailable; local disconnect reset")
    }

    private func cancelConnectedFitProPeripherals(reason: String) {
        guard central.state == .poweredOn else {
            return
        }
        let service = CBUUID(nsuuid: FitProProtocol.serviceUUID)
        var candidates = central.retrieveConnectedPeripherals(withServices: [service])
        if let peripheral {
            candidates.append(peripheral)
        }
        if let idString = UserDefaults.standard.string(forKey: lastPeripheralKey),
           let uuid = UUID(uuidString: idString) {
            candidates.append(contentsOf: central.retrievePeripherals(withIdentifiers: [uuid]))
        }
        var seen = Set<UUID>()
        for candidate in candidates where seen.insert(candidate.identifier).inserted {
            guard candidate.state != .disconnected else {
                continue
            }
            appendLog("\(reason): cancel \(candidate.identifier.uuidString) state=\(candidate.state.rawValue)")
            central.cancelPeripheralConnection(candidate)
        }
        resetConnectionState()
        status = "Disconnected"
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let services = advertisedServices(from: advertisementData)
            let serviceMatch = services.contains(CBUUID(nsuuid: FitProProtocol.serviceUUID))
            let nameMatch = peripheralMatches(peripheral, localName: localName)
            updateDiscoveredDevice(peripheral, localName: localName, rssi: RSSI, services: services, isMatch: serviceMatch || nameMatch)
            guard serviceMatch || nameMatch else { return }
            let name = peripheral.name ?? localName ?? peripheral.identifier.uuidString
            appendLog("found \(name) rssi=\(RSSI)")
            connect(peripheral, source: "scan")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            isConnected = true
            status = "Discovering services"
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralKey)
            appendLog("connected \(peripheral.identifier.uuidString)")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            pendingSMS = nil
            isSMSBusy = false
            status = "Connection failed"
            appendLog("connect failed \(error?.localizedDescription ?? "")")
            resetConnectionState()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            status = "Disconnected"
            appendLog("disconnected \(error?.localizedDescription ?? "")")
            resetConnectionState()
        }
    }
}

extension FitProBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                isConnectionBusy = false
                pendingSMS = nil
                isSMSBusy = false
                status = "Service discovery failed"
                appendLog("services error \(error.localizedDescription)")
                return
            }
            for service in peripheral.services ?? [] {
                appendLog("service \(service.uuid.uuidString)")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                isConnectionBusy = false
                pendingSMS = nil
                isSMSBusy = false
                status = "Characteristic discovery failed"
                appendLog("characteristics error \(error.localizedDescription)")
                return
            }
            for characteristic in service.characteristics ?? [] {
                appendLog("char \(characteristic.uuid.uuidString) props=\(characteristic.properties.fitProDescription)")
                if characteristic.uuid == CBUUID(nsuuid: FitProProtocol.writeUUID) {
                    writeCharacteristic = characteristic
                    appendLog("write char")
                }
                if characteristic.uuid == CBUUID(nsuuid: FitProProtocol.notifyUUID) {
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    appendLog("notify char")
                }
            }
            updateReadyIfPossible()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            isWritingChunk = false
            if let error {
                appendLog("write error \(error.localizedDescription)")
                currentPacket = nil
                currentChunks.removeAll()
                currentPacketName = ""
                currentPacketAcked = false
                isWaitingForCurrentAck = false
                processQueueIfNeeded()
                return
            }
            appendLog("write ok \(currentPacketName)")
            guard let writeCharacteristic else {
                return
            }
            writeNextChunk(peripheral: peripheral, characteristic: writeCharacteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                appendLog("notify state error \(error.localizedDescription)")
                return
            }
            appendLog("notify state \(characteristic.isNotifying)")
            if characteristic.uuid == CBUUID(nsuuid: FitProProtocol.notifyUUID) {
                isNotifyEnabled = characteristic.isNotifying
                updateReadyIfPossible()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                appendLog("rx error \(error.localizedDescription)")
                return
            }
            guard let data = characteristic.value else {
                return
            }
            appendLog("rx \(data.hexString)")
            handleAckIfNeeded(data)
        }
    }
}

private extension Data {
    func chunks(size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { start in
            subdata(in: start..<Swift.min(start + size, count))
        }
    }
}

private extension DateFormatter {
    static let fitProLog: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension CBCharacteristicProperties {
    var fitProDescription: String {
        var items: [String] = []
        if contains(.read) { items.append("read") }
        if contains(.write) { items.append("write") }
        if contains(.writeWithoutResponse) { items.append("writeNoResp") }
        if contains(.notify) { items.append("notify") }
        if contains(.indicate) { items.append("indicate") }
        return items.isEmpty ? rawValue.description : items.joined(separator: ",")
    }
}
