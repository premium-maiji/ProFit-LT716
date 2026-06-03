# ProFit LT716

Tools for sending FitPro-compatible BLE notification packets to an LT716 watch.

This repository contains two implementations:

- `FitProSender/`: an iOS SwiftUI app that connects to the watch and sends text.
- `python/`: a Python BLE command-line tool used for protocol testing, scanning,
  sending notifications, and optional macOS Bluetooth cleanup.

## iOS App

The iOS app uses CoreBluetooth and the FitPro UART-style BLE service. Pair the
watch in iOS Bluetooth settings first, then open the app, tap `Connect`, and use
`Send` to transmit the text in the editor.

Build notes:

```sh
cd FitProSender
xcodegen generate
open FitProSender.xcodeproj
```

Set your own Apple Signing Team in Xcode before building for a real iPhone. The
project intentionally does not store a development team ID.

## Python Tools

Install the Python dependency:

```sh
python3 -m pip install -r python/requirements.txt
```

Show available CLI options:

```sh
python3 python/fitpro_notify.py --help
```

The Python tool stores local watch identifiers in
`python/.fitpro_notify_state.json` when needed. That file is intentionally
ignored and should not be committed.

## Protocol Notes

The watch uses a Nordic-UART-like BLE layout:

- service: `6e400001-b5a3-f393-e0a9-e50e24dcca9d`
- write: `6e400002-b5a3-f393-e0a9-e50e24dcca9d`
- notify: `6e400003-b5a3-f393-e0a9-e50e24dcca9d`

Notification messages are sent with FitPro command `0x12`, key `0x12`, using
the SMS app code by default.

## Privacy

Generated files, build products, local Python state, decompiled APK output,
Apple signing team IDs, and device-specific Bluetooth identifiers are excluded
from the repository.
