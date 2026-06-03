# FitProSender

iPhoneからLT716へFitPro互換BLEパケットで任意文字を送る最小アプリです。

## Build

```bash
cd FitProSender
xcodegen generate
open FitProSender.xcodeproj
```

実機で使うため、Xcodeで `Signing & Capabilities` のTeamを設定してください。
Team IDは個人情報扱いのため、プロジェクトには保存していません。
SimulatorではCoreBluetoothの実機BLE接続は確認できません。

## Notes

- 通知モードは `command=0x12,key=0x12` を送ります。
- LT716ファームによっては日本語UTF-8本文を表示できない可能性があります。
