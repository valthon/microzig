#!/usr/bin/env python3
"""Control the Pico 2 W RAM ESP peer (Windows python.exe + pyserial).

Usage: python pico_peer.py load --port <MicroPython-port> <RAM-UF2>
then python pico_peer.py mode --port <peer-port> <uart|spi|i2s|rmt|parl|lpuart|i2c> <c3|c6>.
Use the pico2_w_ram_esp_peer UF2. Start the matching ESP self-test after
selecting the mode, then run `python pico_peer.py status --port <peer-port>` after ESP DONE.
Wire C6 GPIO0..7 to Pico GP8..15, GPIO18/19 to GP16/17; C3 GPIO0/1/3/10
to Pico GP0/1/2/3. Connect GNDs, power each board from its own USB.
UART uses L0 peer TX/L1 peer RX; SPI L0 MISO/L1 MOSI/L2 SCLK/L3 CS;
I2S L0 ESP DIN/L1 ESP DOUT/L2 BCK/L3 WS; RMT L1 capture/L0 replay;
PARL L0..7 data, GPIO18 clock, GPIO19 valid. L0..3 means C6 GP8..11
or C3 GP0..3. LP UART uses C6 GPIO4 RX <- GP12 TX, GPIO5 TX -> GP13 RX;
I2C uses C6 GPIO6 SDA <-> GP14, GPIO7 SCL <-> GP15, target 0x42.
Require no PEER FAIL, status errors=0, and ESP DONE fail=0 with pass counts
uart=7, spi_dma=8, i2s=8, rmt=3, parl_io=16, lp_uart=5, lp_i2c=7.
Require clk PASS within 1% for UART/LP UART (baud), SPI/I2S/PARL (1 MHz),
uart parity_rx PASS and rmt tx_widths_64/137 PASS (width error <=2 us).

Loading interrupts MicroPython and enters its raw REPL without displaying its
output. The RAM UF2 leaves flash intact; `reset` returns to that flash image.
Peer discovery requires both VID:PID and the product string. --port selects the
initial MicroPython port for load and the peer CDC port for other commands.
No board I/O occurs on import. Every device/volume/reply wait has a deadline.
SPI and I2S require >=100 ms between frames: hold SPI CS high/SCLK idle,
or I2S BCK/WS idle, while the peer decodes and rearms. An early frame is FAIL.
"""
import argparse
import base64
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import serial
from serial.tools import list_ports

PRODUCT = "MicroZig ESP peer"
# Matches hal.usb.Polled's IDs; product string distinguishes other MicroZig CDCs.
VID_PID = (0x2E8A, 0x000F)
MODES = ("idle", "uart", "spi", "i2s", "rmt", "parl", "lpuart", "i2c")
VERDICT = re.compile(r"^PEER \w+ [\w]+: (PASS|FAIL)(?: |$)")
STATUS = re.compile(r"^PEER (?:" + "|".join(MODES) + r") c[36] frames=\d+ bytes=\d+ edges=(?:\d+,){9}\d+ errors=\d+ clk_hz=\d+$")


def open_port(port):
    device = serial.Serial()
    device.port = port
    device.baudrate = 115200
    device.timeout = 0.05
    device.write_timeout = 2
    device.dtr = True
    device.rts = False
    device.open()
    return device


def discover(timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        peers = [p.device for p in list_ports.comports()
                 if (p.vid, p.pid) == VID_PID and is_peer_product(p)]
        if len(peers) > 1:
            raise RuntimeError("multiple ESP peers found; select --port")
        if peers:
            try:
                with open_port(peers[0]):
                    return peers[0]
            except (OSError, serial.SerialException):
                pass  # Windows may list the CDC before usbser can open it.
        time.sleep(0.2)
    raise TimeoutError("ESP peer CDC did not enumerate")


def powershell(script):
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
        capture_output=True, text=True, timeout=15, check=True)
    return result.stdout.strip()


def ps_literal(text):
    return "'" + str(text).replace("'", "''") + "'"


def is_peer_product(port):
    if port.product == PRODUCT:
        return True
    if os.name != "nt":
        return False
    # pyserial 3.5's list_ports_windows.py fills VID/PID, description and
    # manufacturer, but leaves product unset. Read the USB bus-reported
    # description from the CDC node or its composite-device parent.
    pattern = r" \(" + re.escape(port.device) + r"\)$"
    script = (
        "$ErrorActionPreference='Stop'; "
        "$ports=@(Get-PnpDevice -Class Ports -PresentOnly | "
        "Where-Object { $_.FriendlyName -match " + ps_literal(pattern) + " }); "
        "if($ports.Count -ne 1){exit 0}; $id=$ports[0].InstanceId; "
        "for($i=0; $i -lt 3 -and $id; $i++){ "
        r"if($id -notmatch '^USB\\VID_2E8A&PID_000F'){break}; "
        "(Get-PnpDeviceProperty -InstanceId $id "
        "-KeyName DEVPKEY_Device_BusReportedDeviceDesc "
        "-ErrorAction SilentlyContinue).Data; "
        "$id=(Get-PnpDeviceProperty -InstanceId $id "
        "-KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue).Data }"
    )
    return PRODUCT in powershell(script).splitlines()


def read_until(device, marker, timeout):
    deadline = time.monotonic() + timeout
    received = bytearray()
    while time.monotonic() < deadline:
        received.extend(device.read(512))
        if marker in received:
            return
        if len(received) > 16384:
            del received[:-len(marker)]
    raise TimeoutError("MicroPython raw REPL acknowledgement missing")


def load(uf2, initial_port):
    if os.name != "nt":
        raise RuntimeError("load requires Windows python.exe and PowerShell")
    image = Path(uf2).resolve(strict=True)
    if image.suffix.lower() != ".uf2":
        raise ValueError("load expects a UF2 file")
    device = open_port(initial_port)
    try:
        device.write(b"\x03\x03")
        time.sleep(0.3)
        device.reset_input_buffer()
        device.write(b"\x01")
        read_until(device, b"raw REPL; CTRL-B to exit\r\n>", 3)
        device.write(b"import machine\nmachine.bootloader()\n\x04")
        try:
            read_until(device, b"OK", 3)
        except serial.SerialException:
            # The reset into BOOTSEL can remove the CDC port before "OK" is
            # read; the volume wait below is what confirms the bootloader.
            pass
    finally:
        try:
            device.close()
        except (serial.SerialException, OSError):
            pass
    deadline = time.monotonic() + 30
    drive = None
    while time.monotonic() < deadline:
        volumes = powershell("$ErrorActionPreference='Stop'; Get-Volume -FileSystemLabel 'RP2350' -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter }").splitlines()
        volumes = [v.strip() for v in volumes if re.fullmatch(r"[A-Za-z]", v.strip())]
        if len(volumes) > 1:
            raise RuntimeError("multiple RP2350 volumes; refusing ambiguous copy")
        if volumes:
            drive = volumes[0]
            break
        time.sleep(0.3)
    if drive is None:
        raise TimeoutError("RP2350 BOOTSEL volume did not appear")
    powershell("$ErrorActionPreference='Stop'; Copy-Item -LiteralPath " +
               ps_literal(image) + " -Destination " + ps_literal(drive + ":\\" + image.name))
    port = discover(30)
    print("peer port=" + port)
    # Confirm the running firmware, not just successful copying/enumeration.
    return exchange(port, "mode idle c6", "OK mode idle c6", 5)


def lines(device, seconds):
    deadline = time.monotonic() + seconds
    pending = bytearray()
    while time.monotonic() < deadline:
        data = device.read(512)
        for byte in data:
            if byte == 10:
                yield pending.decode("ascii", "replace").rstrip("\r")
                pending.clear()
            else:
                pending.append(byte)
                if len(pending) > 4096:
                    raise RuntimeError("overlong peer console line")


def exchange(port, command, expected, timeout=3):
    with open_port(port) as device:
        # Do not clear pending unsolicited verdicts when reopening the port.
        device.write((command + "\n").encode("ascii"))
        failed = False
        for line in lines(device, timeout):
            if line.startswith(("OK ", "PEER ", "ERR ")):
                print(line, flush=True)
            verdict = VERDICT.match(line)
            failed |= verdict is not None and verdict.group(1) == "FAIL"
            if line.startswith("ERR "):
                return 1
            if (expected is None and STATUS.fullmatch(line)) or line == expected:
                if expected is None:
                    failed |= " errors=0 " not in line
                return int(failed)
    raise TimeoutError("expected peer reply missing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("load", "mode", "status", "reset", "boot", "log"):
        sub = commands.add_parser(name, description=__doc__)
        sub.add_argument("--port", required=True)
        if name == "load":
            sub.add_argument("uf2")
        elif name == "mode":
            sub.add_argument("mode", choices=MODES)
            sub.add_argument("bank", choices=("c3", "c6"))
        elif name == "log":
            sub.add_argument("seconds", type=float)
    args = parser.parse_args()
    if args.command == "load":
        return load(args.uf2, args.port)
    port = args.port
    if args.command == "log":
        if not 0 < args.seconds <= 3600:
            raise ValueError("log duration must be in (0, 3600] seconds")
        seen = False
        failed = False
        with open_port(port) as device:
            for line in lines(device, args.seconds):
                if line.startswith(("OK ", "PEER ", "ERR ")):
                    print(line, flush=True)
                verdict = VERDICT.match(line)
                seen |= verdict is not None or STATUS.fullmatch(line) is not None
                failed |= (verdict is not None and verdict.group(1) == "FAIL") or line.startswith("ERR ")
                failed |= STATUS.fullmatch(line) is not None and " errors=0 " not in line
        return int(not seen or failed)
    if args.command == "mode":
        command = "mode " + args.mode + " " + args.bank
        return exchange(port, command, "OK " + command)
    return exchange(port, args.command, None if args.command == "status" else "OK " + args.command)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, TimeoutError, serial.SerialException,
            subprocess.SubprocessError) as error:
        # No raw REPL contents or captured PowerShell output in diagnostics.
        print("pico_peer: " + str(error), file=sys.stderr)
        sys.exit(1)
