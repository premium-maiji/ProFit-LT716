#!/usr/bin/env python3
"""Build or send FitPro watch notification packets.

The APK uses a Nordic-UART-like BLE service:

  service: 6e400001-b5a3-f393-e0a9-e50e24dcca9d
  write:   6e400002-b5a3-f393-e0a9-e50e24dcca9d
  notify:  6e400003-b5a3-f393-e0a9-e50e24dcca9d

Sending needs `bleak` installed. Packet generation does not.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import subprocess
import uuid
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9d"
WRITE_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9d"
NOTIFY_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9d"
SCRIPT_DIR = Path(__file__).resolve().parent
HELPERS_DIR = SCRIPT_DIR / "helpers"
STATE_PATH = SCRIPT_DIR / ".fitpro_notify_state.json"

# Values observed in xfkj.fitpro.service.NotifyService.sendNotifyPush().
APP_CODES = {
    "sms": 0x01,
    "qq": 0x02,
    "wechat": 0x03,
    "facebook": 0x04,
    "twitter": 0x05,
    "skype": 0x06,
    "line": 0x07,
    "whatsapp": 0x08,
    "kakaotalk": 0x09,
    "snapchat": 0x0A,
    "tiktok": 0x0B,
    "instagram": 0x10,
    "linkedin": 0x11,
    "telegram": 0x12,
    "ok_ru": 0x13,
    "vk": 0x14,
    "ten_chat": 0x15,
    "viber": 0x16,
    "messenger": 0x17,
}


@dataclass(frozen=True)
class Packet:
    name: str
    data: bytes


def load_state() -> dict[str, Any]:
    try:
        return json.loads(STATE_PATH.read_text())
    except Exception:
        return {}


def save_state(state: dict[str, Any]) -> None:
    STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")


def is_bound(address: str) -> bool:
    return address in set(load_state().get("bound_addresses", []))


def mark_bound(address: str) -> None:
    state = load_state()
    addresses = set(state.get("bound_addresses", []))
    addresses.add(address)
    state["bound_addresses"] = sorted(addresses)
    save_state(state)
    print(f"remembered bound address {address}")


def remember_classic_address(address: str) -> None:
    state = load_state()
    state["classic_address"] = address
    save_state(state)
    print(f"remembered classic address {address}")


def mark_auto_bound_if_needed(args: argparse.Namespace) -> None:
    address = getattr(args, "_auto_bind_address", "")
    if address:
        mark_bound(address)


def truncate_fitpro_text(text: str, limit: int = 300) -> str:
    """Match the APK's rough text limit: ASCII costs 1, non-ASCII costs 2."""
    out: list[str] = []
    remaining = limit
    for ch in text:
        cost = 2 if len(ch.encode("utf-8")) > 1 else 1
        if remaining - cost < 0:
            break
        out.append(ch)
        remaining -= cost
    return "".join(out)


def protocol(command_id: int, key_id: int, payload: bytes) -> bytes:
    total_len = 8 + len(payload)
    body_len = total_len - 3
    return bytes(
        [
            0xCD,
            (body_len >> 8) & 0xFF,
            body_len & 0xFF,
            command_id & 0xFF,
            0x01,
            key_id & 0xFF,
            (len(payload) >> 8) & 0xFF,
            len(payload) & 0xFF,
        ]
    ) + payload


def pair_packet() -> Packet:
    # Same as SendData.getPair(): command 0x12, key 0x0a, value 0x02.
    return Packet("pair", protocol(0x12, 0x0A, bytes([0x02])))


def bind_packet(enabled: bool = True) -> Packet:
    # Same as SendData.getIsBingding(true/false). This packet does not use
    # getProtocol(); the APK sends this compact form after pairing a new device.
    return Packet("bind" if enabled else "unbind", bytes([0xCD, 0x00, 0x02, 0x13 if enabled else 0x14, 0x01]))


def switch_protocol_packet(name: str, command_id: int, key_id: int, value: int) -> Packet:
    # Same as SendData.SwitchProtocol().
    return Packet(name, bytes([0xCD, 0x00, 0x06, command_id & 0xFF, 0x01, key_id & 0xFF, 0x00, 0x01, value & 0xFF]))


def time_packet(now: datetime | None = None) -> Packet:
    # Same bit packing as SendData.getSetTimesValue().
    now = now or datetime.now()
    packed = (
        now.second
        | ((now.year - 2000) << 26)
        | (now.month << 22)
        | (now.day << 17)
        | (now.hour << 12)
        | (now.minute << 6)
    )
    return Packet("time", protocol(0x12, 0x01, packed.to_bytes(4, "big")))


def language_packet(code: int = 8) -> Packet:
    # LanguageUtils maps Japanese ("ja") to 8.
    return switch_protocol_packet("language", 0x12, 0x15, code)


def phone_type_packet() -> Packet:
    # Same as SendData.getPhoneTypeValue(); the Android app sends 1.
    return Packet("phone-type", protocol(0x12, 0xFF, bytes([0x01])))


def user_info_packet(gender: int = 1, age: int = 25, height: int = 170, weight: int = 65, unit: int = 0) -> Packet:
    # Same defaults as SendData.getSetUinfoValue().
    packed = ((gender & 0x01) << 31) | ((age & 0x7F) << 24) | ((height & 0x1FF) << 15) | ((weight & 0x3FF) << 5) | (unit & 0x1F)
    return Packet("user-info", protocol(0x12, 0x04, packed.to_bytes(4, "big")))


def step_goal_packet(steps: int = 5000) -> Packet:
    return Packet("step-goal", protocol(0x12, 0x03, int(steps).to_bytes(4, "big")))


def realtime_step_packet(enabled: bool = True) -> Packet:
    return switch_protocol_packet("realtime-step", 0x15, 0x06, 1 if enabled else 0)


def info_request_packet(key_id: int, name: str | None = None) -> Packet:
    # Same as SendData.getSetInfoByKey(): getNoValueProtocol(0x1a, key).
    return Packet(name or f"info:{key_id}", protocol(0x1A, key_id, b""))


def raw_packet(hex_string: str) -> Packet:
    compact = "".join(hex_string.split()).removeprefix("0x")
    return Packet("raw", bytes.fromhex(compact))


def notification_packet(app: str, text: str) -> Packet:
    app_code = APP_CODES[app]
    msg = truncate_fitpro_text(text).encode("utf-8")
    payload = bytes([app_code, 0x00, 0x00]) + msg
    # Same as SendData.getSendPushRemindValue(1, payload):
    # command 0x12, key 0x12.
    return Packet(f"notify:{app}", protocol(0x12, 0x12, payload))


def call_packet(state: int, text: str) -> Packet:
    msg = truncate_fitpro_text(text).encode("utf-8")
    payload = bytes([state & 0xFF, 0x00]) + msg
    # Same as SendData.getSendPushRemindValue(0, payload):
    # command 0x12, key 0x11.
    # APK CallService maps Android phone states as: 1=ringing, 2=offhook, 0=idle/end.
    return Packet("call", protocol(0x12, 0x11, payload))


def switch_packet(enabled_count: int = 11) -> Packet:
    # Mirrors SendData.getSetCallRemindValue(). The first 11 switches are:
    # call, sms, wechat, qq, facebook, twitter, skype, line, whatsapp,
    # kakaotalk, instagram. Newer firmware may expose more, up to 20.
    enabled_count = max(1, min(enabled_count, 20))
    return Packet("push-switches", protocol(0x12, 0x07, bytes([1] * enabled_count)))


def reminder_packet(shock: int = 1, bright: int = 0, sleep: int = 0, heart: int = 0) -> Packet:
    # Mirrors SendData.getSetWatchRemindValue(): SHOCK, BRIGHT, SLEEP, HEART.
    payload = bytes([shock & 0xFF, bright & 0xFF, sleep & 0xFF, heart & 0xFF])
    return Packet("reminders", protocol(0x12, 0x08, payload))


def chunks(data: bytes, size: int) -> list[bytes]:
    return [data[i : i + size] for i in range(0, len(data), size)]


async def scan(all_devices: bool = False, timeout: float = 8.0) -> None:
    from bleak import BleakScanner

    found = await BleakScanner.discover(
        timeout=timeout,
        service_uuids=None if all_devices else [SERVICE_UUID],
        return_adv=True,
    )
    for device, adv in found.values():
        uuids = ",".join(adv.service_uuids or [])
        mfids = ",".join(f"0x{k:04x}" for k in (adv.manufacturer_data or {}).keys())
        connectable = ""
        if adv.platform_data and len(adv.platform_data) > 1:
            raw_adv = adv.platform_data[1]
            if hasattr(raw_adv, "get"):
                value = raw_adv.get("kCBAdvDataIsConnectable")
                if value is not None:
                    connectable = f"\tconnectable={value}"
        print(
            f"{device.address}\t{device.name or adv.local_name or ''}"
            f"\trssi={adv.rssi}{connectable}\tservices={uuids}\tmf={mfids}"
        )


def ack_matches(packet: Packet, data: bytes) -> bool:
    if len(packet.data) < 4 or len(data) < 4 or data[0] != 0xDC:
        if len(packet.data) >= 6 and len(data) >= 6 and data[0] == 0xCD:
            return data[3] == packet.data[3] and data[5] == packet.data[5]
        return False
    if data[3] != packet.data[3]:
        return False
    # getProtocol()/SwitchProtocol packets put the command key at byte 5.
    # Their ACKs put that key at byte 4.
    if len(packet.data) >= 6 and packet.data[4] == 0x01:
        return len(data) >= 5 and data[4] == packet.data[5]
    return True


def handle_rx_data(data: bytes) -> None:
    if len(data) < 8 or data[0] != 0xCD:
        return
    command_id = data[3]
    key_id = data[5]
    payload_len = (data[6] << 8) | data[7]
    payload = data[8 : 8 + payload_len]
    if command_id != 0x1A:
        return
    if key_id == 0x0A and len(payload) >= 6:
        classic_address = ":".join(f"{byte:02X}" for byte in payload[:6])
        print(f"classic-address {classic_address}")
        remember_classic_address(classic_address)
    elif key_id == 0x0C and payload:
        print(f"classic-name-code {payload.hex()}")
    elif key_id == 0x13 and payload:
        try:
            print(f"classic-name {payload[1:].decode('utf-8', errors='replace')}")
        except Exception:
            print(f"classic-name-raw {payload.hex()}")


async def start_notify_queue(client: Any) -> asyncio.Queue[bytes]:
    ack_queue: asyncio.Queue[bytes] = asyncio.Queue()

    def on_notify(_: Any, data: bytearray) -> None:
        data_bytes = bytes(data)
        print(f"rx {data_bytes.hex()}")
        handle_rx_data(data_bytes)
        if data_bytes and data_bytes[0] == 0xDC:
            ack_queue.put_nowait(data_bytes)
        elif data_bytes and data_bytes[0] == 0xCD:
            ack_queue.put_nowait(data_bytes)

    try:
        await client.start_notify(NOTIFY_UUID, on_notify)
    except Exception:
        # Some devices still accept writes before notify subscription succeeds.
        pass
    return ack_queue


async def write_packets(
    client: Any,
    packets: list[Packet],
    chunk_size: int,
    delay: float,
    wait_ack: bool,
    ack_timeout: float,
    ack_queue: asyncio.Queue[bytes],
) -> None:
    for packet in packets:
        while not ack_queue.empty():
            ack_queue.get_nowait()
        for i, chunk in enumerate(chunks(packet.data, chunk_size), start=1):
            print(f"tx {packet.name}[{i}] {chunk.hex()}")
            await client.write_gatt_char(WRITE_UUID, chunk, response=True)
            await asyncio.sleep(delay)
        if wait_ack:
            deadline = asyncio.get_running_loop().time() + ack_timeout
            while True:
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    print(f"ack timeout {packet.name}")
                    break
                try:
                    ack = await asyncio.wait_for(ack_queue.get(), timeout=remaining)
                except asyncio.TimeoutError:
                    print(f"ack timeout {packet.name}")
                    break
                if ack_matches(packet, ack):
                    print(f"ack {packet.name}")
                    break


async def send(
    address: str,
    packets: list[Packet],
    chunk_size: int,
    delay: float,
    wait_ack: bool,
    ack_timeout: float,
    cleanup_packets: list[Packet] | None = None,
    reset_bluetoothd_args: argparse.Namespace | None = None,
) -> None:
    from bleak import BleakClient

    async with BleakClient(address) as client:
        await send_with_client(
            client,
            packets,
            chunk_size,
            delay,
            wait_ack,
            ack_timeout,
            disconnect=True,
            cleanup_packets=cleanup_packets,
            reset_bluetoothd_args=reset_bluetoothd_args,
        )


async def clean_disconnect(client: Any) -> None:
    try:
        await client.stop_notify(NOTIFY_UUID)
        print("notify stopped")
    except Exception:
        pass
    try:
        if getattr(client, "is_connected", False):
            await client.disconnect()
            print("disconnected")
    except Exception as exc:
        print(f"disconnect failed {type(exc).__name__}: {exc}")


def reset_bluetoothd_if_requested(args: argparse.Namespace) -> None:
    if not getattr(args, "reset_bluetoothd_on_disconnect", False):
        return
    if platform.system() != "Darwin":
        print("bluetoothd reset skipped: not macOS")
        return
    pgrep = subprocess.run(["pgrep", "-x", "bluetoothd"], capture_output=True, text=True, check=False)
    pids = [line.strip() for line in pgrep.stdout.splitlines() if line.strip()]
    if not pids:
        print("bluetoothd reset skipped: no bluetoothd pid")
        return
    for pid in pids:
        result = subprocess.run(["sudo", "kill", pid], check=False)
        if result.returncode == 0:
            print(f"bluetoothd reset pid={pid}")
        else:
            print(f"bluetoothd reset failed pid={pid}; run: sudo kill {pid}")


def reset_btle_if_requested(args: argparse.Namespace) -> None:
    if not getattr(args, "reset_btle_on_disconnect", False):
        return
    if platform.system() != "Darwin":
        print("BTLEServer reset skipped: not macOS")
        return
    pgrep = subprocess.run(["pgrep", "-x", "BTLEServer"], capture_output=True, text=True, check=False)
    pids = [line.strip() for line in pgrep.stdout.splitlines() if line.strip()]
    if not pids:
        print("BTLEServer reset skipped: no BTLEServer pid")
        return
    for pid in pids:
        result = subprocess.run(["sudo", "kill", pid], check=False)
        if result.returncode == 0:
            print(f"BTLEServer reset pid={pid}")
        else:
            print(f"BTLEServer reset failed pid={pid}; run: sudo kill {pid}")


def disconnect_classic_if_requested(args: argparse.Namespace) -> None:
    if not getattr(args, "disconnect_classic_on_disconnect", False):
        return
    if platform.system() != "Darwin":
        print("classic disconnect skipped: not macOS")
        return
    address = getattr(args, "classic_address", "") or load_state().get("classic_address", "")
    if not address:
        print("classic disconnect skipped: no classic address; use --read-classic-info or --classic-address")
        return
    env = dict(os.environ)
    env["CLANG_MODULE_CACHE_PATH"] = "/private/tmp/clang-module-cache"
    result = subprocess.run(
        ["swift", str(HELPERS_DIR / "bt_disconnect.swift"), address],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    output = (result.stdout + result.stderr).strip()
    if output:
        print(output)
    if result.returncode != 0:
        print(f"classic disconnect failed for {address}")


async def reset_bluetoothd_if_requested_async(args: argparse.Namespace) -> None:
    await asyncio.to_thread(reset_bluetoothd_if_requested, args)


async def reset_btle_if_requested_async(args: argparse.Namespace) -> None:
    await asyncio.to_thread(reset_btle_if_requested, args)


async def disconnect_classic_if_requested_async(args: argparse.Namespace) -> None:
    await asyncio.to_thread(disconnect_classic_if_requested, args)


def corebluetooth_cancel_if_requested(args: argparse.Namespace) -> None:
    if not (
        getattr(args, "corebluetooth_cancel_on_disconnect", False)
        or getattr(args, "corebluetooth_force_cancel_on_disconnect", False)
        or getattr(args, "corebluetooth_stop_tracking_on_disconnect", False)
    ):
        return
    if platform.system() != "Darwin":
        print("CoreBluetooth cancel skipped: not macOS")
        return
    address = getattr(args, "device_address", None) or getattr(args, "address", None) or ""
    if not address:
        print("CoreBluetooth cancel skipped: no BLE UUID")
        return
    try:
        uuid.UUID(address)
    except ValueError:
        print(f"CoreBluetooth cancel skipped: BLE address is not a macOS UUID: {address}")
        return
    env = dict(os.environ)
    env["CLANG_MODULE_CACHE_PATH"] = "/private/tmp/clang-module-cache"
    command = ["swift", str(HELPERS_DIR / "ble_cancel.swift"), address]
    if getattr(args, "corebluetooth_force_cancel_on_disconnect", False):
        command.append("--force")
    if getattr(args, "corebluetooth_stop_tracking_on_disconnect", False):
        command.append("--stop-tracking")
    result = subprocess.run(
        command,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    output = (result.stdout + result.stderr).strip()
    if output:
        print(output)
    if result.returncode != 0:
        print(f"CoreBluetooth cancel failed for {address}")


async def corebluetooth_cancel_if_requested_async(args: argparse.Namespace) -> None:
    await asyncio.to_thread(corebluetooth_cancel_if_requested, args)


def disconnect_cleanup_packets(args: argparse.Namespace) -> list[Packet]:
    if getattr(args, "no_disconnect_cleanup", False):
        return []
    # The APK turns realtime-step off when the app goes to background. It does
    # not unbind the watch on normal close.
    return [realtime_step_packet(False)]


async def write_disconnect_cleanup(
    client: Any,
    cleanup_packets: list[Packet],
    chunk_size: int,
    delay: float,
    wait_ack: bool,
    ack_timeout: float,
    ack_queue: asyncio.Queue[bytes],
) -> None:
    if not cleanup_packets or not getattr(client, "is_connected", False):
        return
    try:
        await write_packets(client, cleanup_packets, chunk_size, delay, wait_ack, ack_timeout, ack_queue)
    except Exception as exc:
        print(f"disconnect cleanup failed {type(exc).__name__}: {exc}")


async def send_with_client(
    client: Any,
    packets: list[Packet],
    chunk_size: int,
    delay: float,
    wait_ack: bool,
    ack_timeout: float,
    disconnect: bool = False,
    cleanup_packets: list[Packet] | None = None,
    reset_bluetoothd_args: argparse.Namespace | None = None,
) -> None:
    ack_queue = await start_notify_queue(client)
    try:
        await write_packets(client, packets, chunk_size, delay, wait_ack, ack_timeout, ack_queue)
    finally:
        if disconnect:
            await write_disconnect_cleanup(client, cleanup_packets or [], chunk_size, delay, wait_ack, ack_timeout, ack_queue)
            await clean_disconnect(client)
            if reset_bluetoothd_args is not None:
                await corebluetooth_cancel_if_requested_async(reset_bluetoothd_args)
                await disconnect_classic_if_requested_async(reset_bluetoothd_args)
                await reset_btle_if_requested_async(reset_bluetoothd_args)
                await reset_bluetoothd_if_requested_async(reset_bluetoothd_args)


async def send_interactive(address: str, args: argparse.Namespace) -> None:
    from bleak import BleakClient

    async with BleakClient(address) as client:
        await interactive_with_client(client, args)


async def send_server(address: str, args: argparse.Namespace) -> None:
    from bleak import BleakClient

    async with BleakClient(address) as client:
        await serve_with_client(client, args)


async def interactive_with_client(client: Any, args: argparse.Namespace) -> None:
    ack_queue = await start_notify_queue(client)
    try:
        setup_packets = build_packets(args, include_message=False)
        if setup_packets:
            await write_packets(client, setup_packets, args.chunk_size, args.delay, args.wait_ack, args.ack_timeout, ack_queue)
        print("session ready; type a message per line, /time for current time, /init to resend setup, /quit to disconnect")
        while True:
            try:
                text = await asyncio.to_thread(input, "msg> ")
            except EOFError:
                break
            text = text.strip()
            if text in {"/q", "/quit", "/exit"}:
                break
            if text == "/time":
                text = datetime.now().strftime("T %H:%M")
            elif text == "/init":
                setup_packets = build_packets(args, include_message=False)
                if setup_packets:
                    await write_packets(client, setup_packets, args.chunk_size, args.delay, args.wait_ack, args.ack_timeout, ack_queue)
                continue
            if not text:
                continue
            await write_packets(
                client,
                [message_packet(args, text)],
                args.chunk_size,
                args.delay,
                args.wait_ack,
                args.ack_timeout,
                ack_queue,
            )
    finally:
        await write_disconnect_cleanup(
            client,
            disconnect_cleanup_packets(args),
            args.chunk_size,
            args.delay,
            args.wait_ack,
            args.ack_timeout,
            ack_queue,
        )
        await clean_disconnect(client)
        await corebluetooth_cancel_if_requested_async(args)
        await disconnect_classic_if_requested_async(args)
        await reset_btle_if_requested_async(args)
        await reset_bluetoothd_if_requested_async(args)


async def serve_with_client(client: Any, args: argparse.Namespace) -> None:
    ack_queue = await start_notify_queue(client)
    send_lock = asyncio.Lock()
    stop_event = asyncio.Event()

    async def send_text(text: str) -> str:
        if text == "/time":
            text = datetime.now().strftime("T %H:%M")
        if text == "/init":
            packets = build_packets(args, include_message=False)
        else:
            packets = [message_packet(args, text)]
        async with send_lock:
            await write_packets(client, packets, args.chunk_size, args.delay, args.wait_ack, args.ack_timeout, ack_queue)
        return "ok"

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue
                if text in {"/q", "/quit", "/exit", "/shutdown"}:
                    writer.write(b"ok disconnecting\n")
                    await writer.drain()
                    stop_event.set()
                    break
                try:
                    result = await send_text(text)
                    writer.write(f"{result}\n".encode("utf-8"))
                except Exception as exc:
                    writer.write(f"error {type(exc).__name__}: {exc}\n".encode("utf-8"))
                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    try:
        setup_packets = build_packets(args, include_message=False)
        if setup_packets:
            await write_packets(client, setup_packets, args.chunk_size, args.delay, args.wait_ack, args.ack_timeout, ack_queue)
        server = await asyncio.start_server(handle, args.local_host, args.local_port)
        print(f"server ready on {args.local_host}:{args.local_port}; send lines with --send-local, stop with /quit")
        async with server:
            await stop_event.wait()
            server.close()
            await server.wait_closed()
    finally:
        await write_disconnect_cleanup(
            client,
            disconnect_cleanup_packets(args),
            args.chunk_size,
            args.delay,
            args.wait_ack,
            args.ack_timeout,
            ack_queue,
        )
        await clean_disconnect(client)
        await corebluetooth_cancel_if_requested_async(args)
        await disconnect_classic_if_requested_async(args)
        await reset_btle_if_requested_async(args)
        await reset_bluetoothd_if_requested_async(args)


async def send_local(args: argparse.Namespace) -> None:
    reader, writer = await asyncio.open_connection(args.local_host, args.local_port)
    writer.write((args.send_local + "\n").encode("utf-8"))
    await writer.drain()
    response = await reader.readline()
    if response:
        print(response.decode("utf-8", errors="replace").rstrip())
    writer.close()
    await writer.wait_closed()


def looks_like_candidate(device: Any, adv: Any) -> bool:
    if adv.platform_data and len(adv.platform_data) > 1:
        raw_adv = adv.platform_data[1]
        if hasattr(raw_adv, "get") and str(raw_adv.get("kCBAdvDataIsConnectable")) == "0":
            return False
    name = (device.name or adv.local_name or "").lower()
    if any(skip in name for skip in ("soundcore", "epcube", "cityfinder")):
        return False
    service_uuids = set(adv.service_uuids or [])
    if SERVICE_UUID in service_uuids:
        return True
    manufacturer_ids = set((adv.manufacturer_data or {}).keys())
    if manufacturer_ids == {0x004C}:
        return False
    return bool(name) or bool(service_uuids) or bool(manufacturer_ids)


async def scan_probe_send(args: argparse.Namespace) -> None:
    from bleak import BleakClient, BleakScanner

    found = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    candidates = [
        (device, adv)
        for device, adv in found.values()
        if looks_like_candidate(device, adv)
    ]
    candidates.sort(key=lambda item: item[1].rssi, reverse=True)
    for device, adv in candidates:
        name = device.name or adv.local_name or ""
        print(f"candidate {device.address}\t{name}\trssi={adv.rssi}")
        try:
            async with BleakClient(device, timeout=8.0) as client:
                services = list(client.services)
                has_write = any(
                    char.uuid.lower() == WRITE_UUID
                    for service in services
                    for char in service.characteristics
                )
                for service in services:
                    print(f"  service {service.uuid.lower()}")
                    for char in service.characteristics:
                        props = ",".join(char.properties)
                        print(f"    char {char.uuid.lower()} [{props}]")
                if not has_write:
                    print("  no FitPro write characteristic")
                    continue
                print("  FitPro write characteristic found, sending")
                args.device_address = device.address
                if args.disconnect_only:
                    await send_with_client(
                        client,
                        [],
                        args.chunk_size,
                        args.delay,
                        args.wait_ack,
                        args.ack_timeout,
                        disconnect=True,
                        cleanup_packets=disconnect_cleanup_packets(args),
                        reset_bluetoothd_args=args,
                    )
                elif args.serve:
                    await serve_with_client(client, args)
                    mark_auto_bound_if_needed(args)
                elif args.interactive:
                    await interactive_with_client(client, args)
                    mark_auto_bound_if_needed(args)
                else:
                    await send_with_client(
                        client,
                        build_packets(args),
                        args.chunk_size,
                        args.delay,
                        args.wait_ack,
                        args.ack_timeout,
                        disconnect=True,
                        cleanup_packets=disconnect_cleanup_packets(args),
                        reset_bluetoothd_args=args,
                    )
                    mark_auto_bound_if_needed(args)
                return
        except Exception as exc:
            print(f"  failed {type(exc).__name__}: {exc}")
    print("no writable FitPro UART candidate found")


async def live_send(args: argparse.Namespace) -> None:
    from bleak import BleakClient, BleakScanner

    queue: asyncio.Queue[tuple[Any, Any]] = asyncio.Queue()

    def on_detect(device: Any, adv: Any) -> None:
        queue.put_nowait((device, adv))

    scanner = BleakScanner(on_detect)
    seen: set[str] = set()
    await scanner.start()
    deadline = asyncio.get_running_loop().time() + args.timeout
    try:
        while asyncio.get_running_loop().time() < deadline:
            timeout = max(0.1, deadline - asyncio.get_running_loop().time())
            try:
                device, adv = await asyncio.wait_for(queue.get(), timeout=timeout)
            except asyncio.TimeoutError:
                break
            name = device.name or adv.local_name or ""
            if args.target_name and args.target_name.lower() not in name.lower():
                continue
            if not args.target_name and not looks_like_candidate(device, adv):
                continue
            if device.address in seen:
                continue
            seen.add(device.address)
            print(f"live candidate {device.address}\t{name}\trssi={adv.rssi}")
            await scanner.stop()
            try:
                async with BleakClient(device, timeout=10.0) as client:
                    services = list(client.services)
                    has_write = any(
                        char.uuid.lower() == WRITE_UUID
                        for service in services
                        for char in service.characteristics
                    )
                    for service in services:
                        print(f"  service {service.uuid.lower()}")
                        for char in service.characteristics:
                            props = ",".join(char.properties)
                            print(f"    char {char.uuid.lower()} [{props}]")
                    if not has_write:
                        print("  no FitPro write characteristic")
                    else:
                        print("  FitPro write characteristic found, sending")
                        args.device_address = device.address
                        if args.disconnect_only:
                            await send_with_client(
                                client,
                                [],
                                args.chunk_size,
                                args.delay,
                                args.wait_ack,
                                args.ack_timeout,
                                disconnect=True,
                                cleanup_packets=disconnect_cleanup_packets(args),
                                reset_bluetoothd_args=args,
                            )
                        elif args.serve:
                            await serve_with_client(client, args)
                            mark_auto_bound_if_needed(args)
                        elif args.interactive:
                            await interactive_with_client(client, args)
                            mark_auto_bound_if_needed(args)
                        else:
                            await send_with_client(
                                client,
                                build_packets(args),
                                args.chunk_size,
                                args.delay,
                                args.wait_ack,
                                args.ack_timeout,
                                disconnect=True,
                                cleanup_packets=disconnect_cleanup_packets(args),
                                reset_bluetoothd_args=args,
                            )
                            mark_auto_bound_if_needed(args)
                        return
            except Exception as exc:
                print(f"  failed {type(exc).__name__}: {exc}")
            await scanner.start()
    finally:
        try:
            await scanner.stop()
        except Exception:
            pass
    print("no writable FitPro UART candidate found")


async def probe(addresses: list[str]) -> None:
    from bleak import BleakClient

    for address in addresses:
        print(f"probe {address}")
        try:
            async with BleakClient(address, timeout=8.0) as client:
                service_uuids = [service.uuid.lower() for service in client.services]
                marker = " FITPRO_UART" if SERVICE_UUID in service_uuids else ""
                print(f"  connected{marker}")
                for service in client.services:
                    print(f"  service {service.uuid.lower()}")
                    for char in service.characteristics:
                        props = ",".join(char.properties)
                        print(f"    char {char.uuid.lower()} [{props}]")
        except Exception as exc:
            print(f"  failed {type(exc).__name__}: {exc}")


def message_packet(args: argparse.Namespace, text: str) -> Packet:
    if args.call_state is not None:
        return call_packet(args.call_state, text)
    return notification_packet(args.app, text)


def build_packets(args: argparse.Namespace, include_message: bool = True) -> list[Packet]:
    packets: list[Packet] = []
    if args.raw:
        packets.extend(raw_packet(item) for item in args.raw)
    if args.pair:
        packets.append(pair_packet())
    address = getattr(args, "device_address", None) or args.address or ""
    auto_bind = args.auto_bind and address and not is_bound(address)
    if auto_bind:
        args._auto_bind_address = address
        print(f"auto-bind: {address} is not remembered as bound")
    else:
        args._auto_bind_address = ""
        if args.auto_bind and address:
            print(f"auto-bind: {address} already remembered; skipping bind")
    if args.bind or auto_bind:
        packets.append(bind_packet(True))
    if args.unbind:
        if not args.force_unbind:
            raise SystemExit("--unbind requires --force-unbind")
        packets.append(bind_packet(False))
    if args.init:
        packets.extend(
            [
                time_packet(),
                language_packet(args.language),
                phone_type_packet(),
                user_info_packet(args.gender, args.age, args.height, args.weight, args.unit),
                step_goal_packet(args.steps),
                realtime_step_packet(True),
            ]
        )
    if args.switches:
        packets.append(switch_packet(args.switch_count))
    if args.reminders:
        packets.append(reminder_packet(args.shock, args.bright, args.sleep, args.heart))
    if args.read_classic_info:
        packets.extend(
            [
                info_request_packet(0x0C, "classic-name-code"),
                info_request_packet(0x0A, "classic-address"),
            ]
        )
    if include_message and not args.no_message:
        packets.append(message_packet(args, args.text))
    return packets


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scan", action="store_true", help="scan for FitPro UART devices")
    parser.add_argument("--all", action="store_true", help="scan all nearby BLE devices")
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--probe", nargs="+", help="connect and list GATT services for addresses")
    parser.add_argument("--auto-send", action="store_true", help="scan, probe candidates, and send to the FitPro UART device")
    parser.add_argument("--live-send", action="store_true", help="connect immediately when a matching advertisement is seen")
    parser.add_argument("--target-name", help="only live-send to a device whose name contains this")
    parser.add_argument("--address", help="BLE address/UUID to connect to")
    parser.add_argument("--app", choices=sorted(APP_CODES), default="sms")
    parser.add_argument("--text", default="hello world")
    parser.add_argument("--raw", action="append", help="append a raw hex packet before normal setup/message packets")
    parser.add_argument("--call-state", type=int, choices=[0, 1, 2], help="send call packet instead: 1 ringing, 2 offhook, 0 idle/end")
    parser.add_argument("--pair", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--bind", action="store_true", help="send FitPro bind-complete packet after pairing")
    parser.add_argument("--auto-bind", action="store_true", help="send bind only once per remembered watch address")
    parser.add_argument("--unbind", action="store_true", help="send FitPro unbind packet")
    parser.add_argument("--force-unbind", action="store_true", help="required with --unbind because it clears watch pairing/binding state")
    parser.add_argument("--init", action="store_true", help="send non-query connection initialization settings before notification")
    parser.add_argument("--language", type=int, default=8, help="watch language code; 8 is Japanese")
    parser.add_argument("--gender", type=int, default=1)
    parser.add_argument("--age", type=int, default=25)
    parser.add_argument("--height", type=int, default=170)
    parser.add_argument("--weight", type=int, default=65)
    parser.add_argument("--unit", type=int, default=0)
    parser.add_argument("--steps", type=int, default=5000)
    parser.add_argument("--switches", action="store_true", help="send push switch enable packet before the notification")
    parser.add_argument("--switch-count", type=int, default=11)
    parser.add_argument("--reminders", action="store_true", help="send device reminder settings before the notification")
    parser.add_argument("--shock", type=int, default=1)
    parser.add_argument("--bright", type=int, default=0)
    parser.add_argument("--sleep", type=int, default=0)
    parser.add_argument("--heart", type=int, default=0)
    parser.add_argument("--chunk-size", type=int, default=20)
    parser.add_argument("--delay", type=float, default=0.12)
    parser.add_argument("--wait-ack", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--ack-timeout", type=float, default=2.0)
    parser.add_argument("--interactive", action="store_true", help="keep the BLE connection open and send one stdin line per notification")
    parser.add_argument("--session", action="store_true", help="convenience mode: keep connection open and use safe FitPro setup defaults")
    parser.add_argument("--serve", action="store_true", help="keep BLE connected and accept local TCP messages")
    parser.add_argument("--local-host", default="127.0.0.1")
    parser.add_argument("--local-port", type=int, default=9876)
    parser.add_argument("--send-local", help="send one line to a running --serve process instead of using BLE directly")
    parser.add_argument("--disconnect-only", action="store_true", help="connect to the watch, stop notifications, and disconnect without writes")
    parser.add_argument("--no-disconnect-cleanup", action="store_true", help="skip APK-like realtime-step off before disconnect")
    parser.add_argument("--read-classic-info", action="store_true", help="read FitPro classic Bluetooth name code and address")
    parser.add_argument("--classic-address", help="classic Bluetooth MAC to close on disconnect")
    parser.add_argument("--corebluetooth-cancel-on-disconnect", action="store_true", help="macOS only: issue an extra CoreBluetooth cancelPeripheralConnection for this BLE UUID after disconnect")
    parser.add_argument("--corebluetooth-force-cancel-on-disconnect", action="store_true", help="macOS only: use CoreBluetooth private cancelPeripheralConnection:force: for this BLE UUID after disconnect")
    parser.add_argument("--corebluetooth-stop-tracking-on-disconnect", action="store_true", help="macOS only: use CoreBluetooth private stopTrackingPeripheral:options: for this BLE UUID after disconnect")
    parser.add_argument("--disconnect-classic-on-disconnect", action="store_true", help="macOS only: close the watch's classic Bluetooth connection without restarting bluetoothd")
    parser.add_argument("--reset-btle-on-disconnect", action="store_true", help="macOS only: sudo-kill BTLEServer after disconnect to clear stuck BLE connection state without restarting bluetoothd")
    parser.add_argument("--reset-bluetoothd-on-disconnect", action="store_true", help="macOS only: sudo-kill bluetoothd after disconnect to clear stuck watch connection icon")
    parser.add_argument("--no-message", action="store_true", help="do not append the final notification/call message packet")
    args = parser.parse_args()

    if args.send_local is not None:
        asyncio.run(send_local(args))
        return

    if args.disconnect_classic_on_disconnect and not args.classic_address:
        args.read_classic_info = True

    if args.session:
        args.interactive = True
        args.auto_bind = True
        args.init = True
        args.switches = True
        args.reminders = True
        if not args.address and not args.auto_send and not args.live_send:
            args.live_send = True

    if args.serve:
        args.auto_bind = True
        args.init = True
        args.switches = True
        args.reminders = True
        if not args.address and not args.auto_send and not args.live_send:
            args.live_send = True

    if args.scan:
        asyncio.run(scan(args.all, args.timeout))
        return
    if args.probe:
        asyncio.run(probe(args.probe))
        return
    if args.auto_send:
        asyncio.run(scan_probe_send(args))
        return
    if args.live_send:
        asyncio.run(live_send(args))
        return

    if args.address:
        args.device_address = args.address
    packets = build_packets(args)
    if not args.address:
        for packet in packets:
            print(f"{packet.name}\t{packet.data.hex()}")
        return

    if args.disconnect_only:
        asyncio.run(
            send(
                args.address,
                [],
                args.chunk_size,
                args.delay,
                args.wait_ack,
                args.ack_timeout,
                cleanup_packets=disconnect_cleanup_packets(args),
                reset_bluetoothd_args=args,
            )
        )
    elif args.serve:
        asyncio.run(send_server(args.address, args))
        mark_auto_bound_if_needed(args)
    elif args.interactive:
        asyncio.run(send_interactive(args.address, args))
        mark_auto_bound_if_needed(args)
    else:
        asyncio.run(
            send(
                args.address,
                packets,
                args.chunk_size,
                args.delay,
                args.wait_ack,
                args.ack_timeout,
                cleanup_packets=disconnect_cleanup_packets(args),
                reset_bluetoothd_args=args,
            )
        )
        mark_auto_bound_if_needed(args)


if __name__ == "__main__":
    main()
