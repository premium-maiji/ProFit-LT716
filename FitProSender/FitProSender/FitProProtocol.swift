import Foundation

struct FitProPacket {
    let name: String
    let data: Data
}

enum FitProNotifyApp: UInt8, CaseIterable, Identifiable {
    case sms = 0x01
    case qq = 0x02
    case wechat = 0x03
    case facebook = 0x04
    case twitter = 0x05
    case skype = 0x06
    case line = 0x07
    case whatsapp = 0x08
    case kakaotalk = 0x09
    case snapchat = 0x0A
    case tiktok = 0x0B
    case instagram = 0x10
    case linkedin = 0x11
    case telegram = 0x12
    case okRu = 0x13
    case vk = 0x14
    case tenChat = 0x15
    case viber = 0x16
    case messenger = 0x17

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .sms: return "SMS"
        case .qq: return "QQ"
        case .wechat: return "WeChat"
        case .facebook: return "Facebook"
        case .twitter: return "Twitter"
        case .skype: return "Skype"
        case .line: return "LINE"
        case .whatsapp: return "WhatsApp"
        case .kakaotalk: return "KakaoTalk"
        case .snapchat: return "Snapchat"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .linkedin: return "LinkedIn"
        case .telegram: return "Telegram"
        case .okRu: return "OK.ru"
        case .vk: return "VK"
        case .tenChat: return "TenChat"
        case .viber: return "Viber"
        case .messenger: return "Messenger"
        }
    }
}

enum FitProProtocol {
    static let serviceUUID = UUID(uuidString: "6E400001-B5A3-F393-E0A9-E50E24DCCA9D")!
    static let writeUUID = UUID(uuidString: "6E400002-B5A3-F393-E0A9-E50E24DCCA9D")!
    static let notifyUUID = UUID(uuidString: "6E400003-B5A3-F393-E0A9-E50E24DCCA9D")!

    static func packet(command: UInt8, key: UInt8, payload: [UInt8]) -> Data {
        let totalLength = 8 + payload.count
        let bodyLength = totalLength - 3
        var data = Data([
            0xCD,
            UInt8((bodyLength >> 8) & 0xFF),
            UInt8(bodyLength & 0xFF),
            command,
            0x01,
            key,
            UInt8((payload.count >> 8) & 0xFF),
            UInt8(payload.count & 0xFF),
        ])
        data.append(contentsOf: payload)
        return data
    }

    static func switchPacket(_ name: String, command: UInt8, key: UInt8, value: UInt8) -> FitProPacket {
        FitProPacket(name: name, data: Data([0xCD, 0x00, 0x06, command, 0x01, key, 0x00, 0x01, value]))
    }

    static func pair() -> FitProPacket {
        switchPacket("pair", command: 0x12, key: 0x0A, value: 0x02)
    }

    static func bind() -> FitProPacket {
        FitProPacket(name: "bind", data: Data([0xCD, 0x00, 0x02, 0x13, 0x01]))
    }

    static func unbind() -> FitProPacket {
        FitProPacket(name: "unbind", data: Data([0xCD, 0x00, 0x02, 0x14, 0x01]))
    }

    static func time(now: Date = Date()) -> FitProPacket {
        let calendar = Calendar.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = UInt32(max(0, (c.year ?? 2000) - 2000))
        let month = UInt32(c.month ?? 1)
        let day = UInt32(c.day ?? 1)
        let hour = UInt32(c.hour ?? 0)
        let minute = UInt32(c.minute ?? 0)
        let second = UInt32(c.second ?? 0)
        var packed = second
        packed |= year << 26
        packed |= month << 22
        packed |= day << 17
        packed |= hour << 12
        packed |= minute << 6
        return FitProPacket(
            name: "time",
            data: packet(
                command: 0x12,
                key: 0x01,
                payload: [
                    UInt8((packed >> 24) & 0xFF),
                    UInt8((packed >> 16) & 0xFF),
                    UInt8((packed >> 8) & 0xFF),
                    UInt8(packed & 0xFF),
                ]
            )
        )
    }

    static func languageJapanese() -> FitProPacket {
        switchPacket("language", command: 0x12, key: 0x15, value: 0x08)
    }

    static func phoneType() -> FitProPacket {
        FitProPacket(name: "phone-type", data: packet(command: 0x12, key: 0xFF, payload: [0x01]))
    }

    static func userInfo(gender: UInt32 = 1, age: UInt32 = 25, height: UInt32 = 170, weight: UInt32 = 65, unit: UInt32 = 0) -> FitProPacket {
        let packed = ((gender & 0x01) << 31)
            | ((age & 0x7F) << 24)
            | ((height & 0x1FF) << 15)
            | ((weight & 0x3FF) << 5)
            | (unit & 0x1F)
        return FitProPacket(
            name: "user-info",
            data: packet(
                command: 0x12,
                key: 0x04,
                payload: [
                    UInt8((packed >> 24) & 0xFF),
                    UInt8((packed >> 16) & 0xFF),
                    UInt8((packed >> 8) & 0xFF),
                    UInt8(packed & 0xFF),
                ]
            )
        )
    }

    static func stepGoal(_ steps: UInt32 = 5000) -> FitProPacket {
        FitProPacket(
            name: "step-goal",
            data: packet(
                command: 0x12,
                key: 0x03,
                payload: [
                    UInt8((steps >> 24) & 0xFF),
                    UInt8((steps >> 16) & 0xFF),
                    UInt8((steps >> 8) & 0xFF),
                    UInt8(steps & 0xFF),
                ]
            )
        )
    }

    static func realtimeStep(_ enabled: Bool) -> FitProPacket {
        switchPacket("realtime-step", command: 0x15, key: 0x06, value: enabled ? 1 : 0)
    }

    static func pushSwitches(count: Int = 11) -> FitProPacket {
        let enabled = [UInt8](repeating: 1, count: max(1, min(count, 20)))
        return FitProPacket(name: "push-switches", data: packet(command: 0x12, key: 0x07, payload: enabled))
    }

    static func reminders() -> FitProPacket {
        FitProPacket(name: "reminders", data: packet(command: 0x12, key: 0x08, payload: [1, 0, 0, 0]))
    }

    static func vibration(enabled: Bool) -> FitProPacket {
        FitProPacket(
            name: enabled ? "vibration-on" : "vibration-off",
            data: packet(command: 0x12, key: 0x08, payload: [enabled ? 1 : 0, 0, 0, 0])
        )
    }

    static func vibrationOn() -> FitProPacket {
        vibration(enabled: true)
    }

    static func vibrationOff() -> FitProPacket {
        vibration(enabled: false)
    }

    static func disturbOff() -> FitProPacket {
        // APK default payload for disturb_status=0, start=22:00, end=08:00.
        FitProPacket(name: "disturb-off", data: packet(command: 0x12, key: 0x14, payload: [0x00, 0x05, 0x28, 0x01, 0xE0]))
    }

    static func setupPackets(includeBind: Bool, vibrationEnabled: Bool = true) -> [FitProPacket] {
        var packets = [pair()]
        if includeBind {
            packets.append(bind())
        }
        packets.append(contentsOf: [
            time(),
            languageJapanese(),
            phoneType(),
            userInfo(),
            stepGoal(),
            realtimeStep(true),
            disturbOff(),
            pushSwitches(count: 11),
            vibration(enabled: vibrationEnabled),
        ])
        return packets
    }

    static func notification(text: String, app: FitProNotifyApp = .sms) -> FitProPacket {
        var payload: [UInt8] = [app.rawValue, 0x00, 0x00]
        payload.append(contentsOf: limitedUTF8(text))
        return FitProPacket(name: "notify:\(app.label)", data: packet(command: 0x12, key: 0x12, payload: payload))
    }

    static func raw(hex: String) -> FitProPacket? {
        let compact = hex
            .replacingOccurrences(of: "0x", with: "")
            .filter { !$0.isWhitespace }
        guard compact.count % 2 == 0 else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return FitProPacket(name: "raw", data: Data(bytes))
    }

    static func call(text: String, state: UInt8 = 1) -> FitProPacket {
        var payload: [UInt8] = [state, 0x00]
        payload.append(contentsOf: limitedUTF8(text))
        let name = state == 0 ? "call-end" : "call-ring"
        return FitProPacket(name: name, data: packet(command: 0x12, key: 0x11, payload: payload))
    }

    private static func limitedUTF8(_ text: String, limit: Int = 300) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(limit, text.utf8.count))
        for scalar in text.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if out.count + bytes.count > limit {
                break
            }
            out.append(contentsOf: bytes)
        }
        return out
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
