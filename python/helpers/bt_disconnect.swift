import Foundation
import IOBluetooth

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("usage: swift bt_disconnect.swift <classic-mac-address>\n", stderr)
    exit(2)
}

let address = args[1].replacingOccurrences(of: "-", with: ":").uppercased()
guard let device = IOBluetoothDevice(addressString: address) else {
    fputs("device not found: \(address)\n", stderr)
    exit(1)
}

print("device \(device.nameOrAddress ?? address) connected=\(device.isConnected())")
let result = device.closeConnection()
print("closeConnection result=\(result)")
