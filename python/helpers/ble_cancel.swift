import CoreBluetooth
import Foundation

final class Canceller: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager!
    private let targetID: UUID
    private let force: Bool
    private let stopTracking: Bool
    private var didRequestCancel = false

    init(targetID: UUID, force: Bool, stopTracking: Bool) {
        self.targetID = targetID
        self.force = force
        self.stopTracking = stopTracking
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    private func forceCancel(_ peripheral: CBPeripheral) -> Bool {
        let selector = NSSelectorFromString("cancelPeripheralConnection:force:")
        guard manager.responds(to: selector), let imp = manager.method(for: selector) else {
            return false
        }
        typealias ForceCancel = @convention(c) (AnyObject, Selector, CBPeripheral, ObjCBool) -> Void
        let fn = unsafeBitCast(imp, to: ForceCancel.self)
        fn(manager, selector, peripheral, ObjCBool(true))
        return true
    }

    private func stopTrackingPeripheral(_ peripheral: CBPeripheral) -> Bool {
        let selector = NSSelectorFromString("stopTrackingPeripheral:options:")
        guard manager.responds(to: selector) else {
            return false
        }
        manager.perform(selector, with: peripheral, with: [:] as NSDictionary)
        return true
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("central state: \(central.state.rawValue)")
        guard central.state == .poweredOn else {
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        let known = central.retrievePeripherals(withIdentifiers: [targetID])
        guard let peripheral = known.first else {
            print("peripheral not found: \(targetID.uuidString)")
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        print("cancel \(peripheral.identifier.uuidString) name=\(peripheral.name ?? "") state=\(peripheral.state.rawValue)")
        didRequestCancel = true
        if stopTracking {
            if stopTrackingPeripheral(peripheral) {
                print("stop tracking requested")
            } else {
                print("stop tracking unavailable")
            }
        }
        if force {
            if forceCancel(peripheral) {
                print("force cancel requested")
            } else {
                print("force cancel unavailable; falling back to public cancel")
                central.cancelPeripheralConnection(peripheral)
            }
        } else {
            central.cancelPeripheralConnection(peripheral)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("after cancel state=\(peripheral.state.rawValue)")
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("didDisconnect \(peripheral.identifier.uuidString) error=\(String(describing: error))")
        if didRequestCancel {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
}

let args = CommandLine.arguments
let force = args.contains("--force")
let stopTracking = args.contains("--stop-tracking")
guard let uuidString = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
    fputs("usage: swift ble_cancel.swift UUID [--force] [--stop-tracking]\n", stderr)
    exit(2)
}
guard let uuid = UUID(uuidString: uuidString) else {
    fputs("invalid UUID: \(uuidString)\n", stderr)
    exit(2)
}

let canceller = Canceller(targetID: uuid, force: force, stopTracking: stopTracking)
CFRunLoopRun()
_ = canceller
