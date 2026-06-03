import CoreBluetooth
import Foundation

final class Diag: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager!
    private let serviceUUIDs = [
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9D"),
        CBUUID(string: "180F"),
        CBUUID(string: "180A"),
    ]

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("central state: \(central.state.rawValue)")
        guard central.state == .poweredOn else {
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }

        let connected = central.retrieveConnectedPeripherals(withServices: serviceUUIDs)
        if connected.isEmpty {
            print("connected peripherals: none")
        } else {
            print("connected peripherals:")
            for peripheral in connected {
                print("  \(peripheral.identifier.uuidString) name=\(peripheral.name ?? "") state=\(peripheral.state.rawValue)")
            }
        }

        let knownIDs = CommandLine.arguments.dropFirst().compactMap(UUID.init(uuidString:))
        if !knownIDs.isEmpty {
            let known = central.retrievePeripherals(withIdentifiers: knownIDs)
            if known.isEmpty {
                print("known identifiers: not in CoreBluetooth cache")
            } else {
                print("known identifiers:")
                for peripheral in known {
                    print("  \(peripheral.identifier.uuidString) name=\(peripheral.name ?? "") state=\(peripheral.state.rawValue)")
                }
            }
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

let diag = Diag()
CFRunLoopRun()
_ = diag
