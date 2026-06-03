# FitProSender

A minimal iOS app for sending FitPro-compatible BLE notification text to an
LT716 watch.

Pair the watch in iOS Bluetooth settings first. Then open the app, tap
`Connect`, wait until the status becomes connected, and tap `Send`.

## Build

```sh
cd FitProSender
xcodegen generate
open FitProSender.xcodeproj
```

Set your own Team in Xcode under `Signing & Capabilities` before building for a
real iPhone. The project intentionally does not store a development team ID.

The iOS Simulator cannot test the real BLE watch connection.

## Notes

- The app sends FitPro notification packets with `command=0x12,key=0x12`.
- Some LT716 firmware versions may not render non-ASCII UTF-8 text correctly.
- The target watch name is fixed to `LT716`.
