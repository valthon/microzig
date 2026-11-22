#!/usr/bin/env python3
"""Windows python.exe can_echo.py --esp COMxx --can COMyy [--log file].

Requires pyserial, no python-can. Start after loading the ESP RAM image.
Load selftest_twai on the ESP before starting this script. Wire C6 GPIO20
TX -> CAN Pal TX, GPIO17 RX <- CAN Pal RX (C3: GPIO4 TX, GPIO7 RX).
CAN Pal VCC -> 3V3, GND -> ESP GND, CANH/CANL -> adapter CANH/CANL;
use common GND and enable 120-ohm termination at both bus ends.
The script opens SLCAN at each requested bitrate before releasing the ESP
with a host byte. Data/RTR frames echo with ID XOR 1, preserving format,
raw DLC and payload, except DLC 9..15 data frames: those get a DLC 8 reply
with ID XOR 1, their first seven bytes and the received DLC as byte 8 (not
every adapter can send a classic DLC above 8). Control ID 0x7e0 starts
listen-only traffic: ID 0x7e1 frames until the ESP prints info listen_done,
then a 200 ms channel close and a host byte. Nothing acknowledges those
frames; an adapter that sends each frame once becomes error passive after
16 (TEC 128), so later frames stay valid (ESP32-C3 TRM v1.4 §31.4.7 /
ESP32-C6 TRM v1.2 §33.4.7).
Success requires ESP DONE fail=0 with pass=12 (C3) or pass=24 (C6,
both CAN controllers), then script exit 0.
Bus-off uses 500 kbit/s on both ends: the ESP switches RX to constant
dominant 90 us after its TX request, within the data field [38, 166) us
(ISO 11898-1 classic data frame: ID 0x555, DLC 8, no stuff bits before
the data). Info recover_ready requests a channel restart and a host byte
before recover. USJ is reopened after disconnect with an eight-second
deadline.
--selftest uses only the standard library. No reset/flash is performed.
"""
import argparse
from collections import deque
from dataclasses import dataclass, replace
import re
import sys
import time


@dataclass(frozen=True)
class Frame:
    identifier: int
    extended: bool = False
    rtr: bool = False
    dlc: int = 0
    data: bytes = b""


FD_LENGTHS = (0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64)


def encode(frame, rtr_padding=False):
    if not 0 <= frame.identifier <= (0x1fffffff if frame.extended else 0x7ff):
        raise ValueError("identifier out of range")
    if not 0 <= frame.dlc <= 15:
        raise ValueError("DLC out of range")
    if len(frame.data) != (0 if frame.rtr else min(frame.dlc, 8)):
        raise ValueError("payload length does not match raw DLC")
    prefix = ("R" if frame.rtr else "T") if frame.extended else ("r" if frame.rtr else "t")
    width = 8 if frame.extended else 3
    data = bytes(min(frame.dlc, 8)) if frame.rtr and rtr_padding else frame.data
    return f"{prefix}{frame.identifier:0{width}X}{frame.dlc:X}{data.hex().upper()}\r".encode("ascii")


def reply(frame):
    """Echo with ID XOR 1; DLC 9..15 data frames get DLC 8 with the raw DLC in byte 8."""
    if frame.dlc > 8 and not frame.rtr:
        return Frame(frame.identifier ^ 1, frame.extended, False, 8, frame.data[:7] + bytes([frame.dlc]))
    return replace(frame, identifier=frame.identifier ^ 1)


def decode(line):
    text = line.decode("ascii").rstrip("\r")
    if not text or text[0] not in "tTrR":
        raise ValueError("not a classic SLCAN frame")
    extended, rtr = text[0] in "TR", text[0] in "rR"
    width = 8 if extended else 3
    if len(text) < width + 2 or any(c not in "0123456789abcdefABCDEF" for c in text[1:]):
        raise ValueError("invalid SLCAN header or hex")
    identifier, dlc = int(text[1:width + 1], 16), int(text[width + 1], 16)
    # Classic DLC 9..15 carries 8 bytes. RTR frames carry none. Some adapters (WeAct
    # USB2CANFD) still print padding: DLC bytes after an RTR header, and the CAN FD
    # length for DLC 9..15 (8 real bytes, then zeros). Accept and drop the padding.
    payload = (len(text) - width - 2) // 2
    sizes = {0} if rtr else {min(dlc, 8)}
    sizes.add(FD_LENGTHS[dlc])
    if (len(text) - width) % 2 or payload not in sizes:
        raise ValueError("invalid payload length; timestamps must be disabled")
    data = b"" if rtr else bytes.fromhex(text[width + 2:width + 2 + 2 * min(dlc, 8)])
    frame = Frame(identifier, extended, rtr, dlc, data)
    encode(frame)
    return frame


def selftest():
    count = 0
    for extended in (False, True):
        for identifier in (0, 0x1fffffff if extended else 0x7ff):
            for rtr in (False, True):
                for dlc in range(16):
                    frame = Frame(identifier, extended, rtr, dlc, b"" if rtr else bytes(range(min(dlc, 8))))
                    assert decode(encode(frame)) == frame
                    echo = replace(frame, identifier=identifier ^ 1)
                    assert decode(encode(echo)) == echo
                    count += 1
    assert decode(b"t1239AABBCCDDEEFF0011") == Frame(0x123, dlc=9, data=bytes.fromhex("AABBCCDDEEFF0011"))
    assert decode(b"R12345678F") == Frame(0x12345678, True, True, 15)
    assert encode(Frame(0x123, rtr=True, dlc=8)) == b"r1238\r"
    assert decode(b"r123100") == Frame(0x123, rtr=True, dlc=1)  # WeAct RTR padding
    assert encode(Frame(0x123, rtr=True, dlc=2), rtr_padding=True) == b"r12320000\r"
    assert reply(Frame(0x123, dlc=9, data=bytes(range(8)))) == Frame(0x122, dlc=8, data=bytes(range(7)) + b"\x09")
    assert decode(b"t1239" + b"11" * 8 + b"00" * 4) == Frame(0x123, dlc=9, data=b"\x11" * 8)  # FD length
    for bad in (b"t8000", b"T200000000", b"t1239AA", b"r12310", b"r1232AA", b"t1230FFFF", b"t12", b"t12G0"):
        try:
            decode(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"accepted malformed frame {bad!r}")
    selftest_commands()
    selftest_listen()
    print(f"SLCAN selftest PASS: {count} std/ext data/RTR DLC 0..15 round trips")


def open_port(serial, name, timeout):
    port = serial.Serial()
    port.port, port.baudrate = name, 115200
    port.timeout, port.write_timeout = timeout, 1
    port.dtr, port.rts = True, False
    port.open()
    return port


def write(port, data):
    if port.write(data) != len(data):
        raise OSError("short serial write")


class Slcan:
    rates = {125000: b"S4", 250000: b"S5", 500000: b"S6", 1000000: b"S8"}

    def __init__(self, port):
        self.port = port
        self.buffer = bytearray()
        self.frames = deque()
        self.channel_open = False
        self.sent = deque(maxlen=8)
        self.bells = 0
        self.rtr_padding = False  # adapter prints padded RTR frames: send them alike

    def write(self, data):
        self.sent.append(data)
        write(self.port, data)

    def read_lines(self):
        self.buffer.extend(self.port.read(4096))
        # BEL is the SLCAN error reply. Some adapters (WeAct USB2CANFD) also send it
        # unsolicited while frames arrive, so retain the count for diagnostics.
        self.bells += self.buffer.count(b"\x07")
        self.buffer = self.buffer.replace(b"\x07", b"")
        if len(self.buffer) > 8192:
            raise RuntimeError("SLCAN line buffer overflow")
        lines = []
        while b"\r" in self.buffer:
            line, _, rest = self.buffer.partition(b"\r")
            self.buffer = bytearray(rest)
            lines.append(bytes(line))
        return lines

    def command(self, command, optional=False):
        self.write(command + b"\r")
        bells = self.bells
        end = time.monotonic() + 2
        while time.monotonic() < end:
            acknowledged = False
            for line in self.read_lines():
                if not line:
                    acknowledged = True
                    continue
                if line[:1] in (b"t", b"T", b"r", b"R"):
                    self.frames.append(self.decode(line))
                    if len(self.frames) > 256:
                        raise RuntimeError("SLCAN frame queue overflow")
                elif line not in (b"z", b"Z"):
                    raise RuntimeError(f"unexpected SLCAN reply {line!r}")
            if acknowledged:
                return
        if self.bells != bells:
            if optional:
                return
            raise RuntimeError(
                f"SLCAN rejected {command!r}: no ack within 2 s; "
                f"BEL={self.bells} (+{self.bells - bells}); last sent: {list(self.sent)}")
        raise TimeoutError(f"SLCAN command {command!r} timed out; BEL={self.bells}")

    def close_channel(self):
        self.command(b"C")
        self.channel_open = False
        self.frames.clear()

    def open_channel(self, rate):
        self.command(self.rates[rate])
        self.command(b"O")
        self.channel_open = True

    def restart(self, rate):
        if self.channel_open:
            self.close_channel()
        self.open_channel(rate)

    def decode(self, line):
        frame = decode(line)
        header = (9 if frame.extended else 4) + 1
        if frame.rtr and frame.dlc and len(line) > header:
            self.rtr_padding = True
        return frame

    def send(self, frame):
        self.write(encode(frame, self.rtr_padding))

    def receive(self):
        for line in self.read_lines():
            if line[:1] in (b"t", b"T", b"r", b"R"):
                self.frames.append(self.decode(line))
            elif line not in (b"", b"z", b"Z"):
                raise RuntimeError(f"unexpected SLCAN reply {line!r}")
        if len(self.frames) > 256:
            raise RuntimeError("SLCAN frame queue overflow")
        frames = list(self.frames)
        self.frames.clear()
        return frames


def selftest_commands():
    from unittest.mock import patch

    class Port:
        def __init__(self, reads):
            self.reads = deque(reads)
            self.now = 0

        def write(self, data):
            return len(data)

        def read(self, size):
            delay, data = self.reads.popleft() if self.reads else (0.1, b"")
            self.now += delay
            return data

    port = Port([(0.1, b"t1230\r\rt1240\r")])
    can = Slcan(port)
    with patch.object(time, "monotonic", lambda: port.now):
        can.command(b"O")
    assert list(can.frames) == [Frame(0x123), Frame(0x124)]

    # An unsolicited BEL must not shorten the two-second acknowledgement window.
    port = Port([(0.1, b"\x07"), (0.1, b""), (1.7, b"\r")])
    can = Slcan(port)
    with patch.object(time, "monotonic", lambda: port.now):
        can.command(b"O")
    assert can.bells == 1 and port.now < 2

    for response, error in ((b"\x07", RuntimeError), (b"", TimeoutError)):
        port = Port([(0.1, response)])
        can = Slcan(port)
        with patch.object(time, "monotonic", lambda: port.now):
            try:
                can.command(b"O")
            except error as exc:
                assert "BEL=" in str(exc) and port.now >= 2
            else:
                raise AssertionError("accepted command without acknowledgement")

    can = Slcan(Port([(0.1, b"\x07t1230\r")]))
    assert can.receive() == [Frame(0x123)] and can.bells == 1


def selftest_listen():
    from contextlib import redirect_stderr, redirect_stdout
    import io
    from types import SimpleNamespace
    from unittest.mock import patch

    class Esp:
        def __init__(self):
            self.step = 0
            self.now = 0

        def read(self, size):
            self.step += 1
            self.now += 0.1
            return {
                1: b"SELFTEST twai ready 500000 controller=0 controllers=1\n",
                2: b"SELFTEST twai info listen_done\n",
                7: b"SELFTEST twai DONE pass=12 fail=0\n",
            }.get(self.step, b"")

        def write(self, data):
            return len(data)

        def close(self):
            pass

    esp = Esp()
    can = Slcan(None)
    control = Frame(0x7e0, dlc=1, data=b"\x01")

    def receive():
        # The second control arrives after listen_done and channel reopen.
        if esp.step in (1, 5):
            assert can.channel_open
            return [control]
        return []

    args = SimpleNamespace(log=None, can="adapter", esp="esp")
    serial = SimpleNamespace(SerialException=OSError)
    with patch(__name__ + ".open_port", return_value=esp), \
            patch(__name__ + ".Slcan", return_value=can), \
            patch.object(time, "monotonic", lambda: esp.now), \
            patch.object(can, "command"), \
            patch.object(can, "receive", side_effect=receive), \
            patch.object(can, "send") as send, \
            redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        # Keep the simulated ESP log, including its DONE line, out of the output.
        assert run(args, serial) == 0
    send.assert_not_called()


def run(args, serial):
    log = open(args.log, "ab") if args.log else None
    esp = adapter = can = None
    try:
        adapter = open_port(serial, args.can, 0.001)
        can = Slcan(adapter)
        can.close_channel()
        # Lawicel timestamp reporting off. Some adapters (WeAct USB2CANFD) reject Z
        # and never send timestamps; decode() refuses a timestamped frame either way.
        can.command(b"Z0", optional=True)
        esp_buffer = bytearray()
        connect_end = time.monotonic() + 8
        run_end = time.monotonic() + 1200
        active = expected = burst = reopen_at = None
        recovery_ack = listen_ack = False
        while time.monotonic() < run_end:
            if esp is None:
                try:
                    esp = open_port(serial, args.esp, 0.005)
                    esp_buffer.clear()
                except serial.SerialException:
                    if time.monotonic() >= connect_end:
                        raise TimeoutError("ESP USJ did not re-enumerate within 8 s")
                    time.sleep(0.05)
                    continue
            try:
                data = esp.read(4096)
            except (serial.SerialException, OSError):
                esp.close()
                esp = None
                connect_end = time.monotonic() + 8
                active = burst = reopen_at = None
                recovery_ack = listen_ack = False
                if can.channel_open:
                    can.close_channel()
                continue
            if data:
                sys.stdout.write(data.decode("utf-8", "replace"))
                sys.stdout.flush()
                if log:
                    log.write(data)
                    log.flush()
                esp_buffer.extend(data)
                if len(esp_buffer) > 65536:
                    raise RuntimeError("ESP line buffer overflow")
                while b"\n" in esp_buffer:
                    raw, _, rest = esp_buffer.partition(b"\n")
                    esp_buffer = bytearray(rest)
                    line = raw.decode("utf-8", "replace")
                    ready = re.search(r"SELFTEST twai ready (\d+) controller=(\d+) controllers=(\d+)", line)
                    if ready:
                        rate, controller, controllers = map(int, ready.groups())
                        if controllers not in (1, 2) or not 0 <= controller < controllers:
                            raise ValueError("invalid controller count")
                        expected = controllers * 12
                        block = (controller, rate)
                        if active != block:
                            can.restart(rate)
                            write(esp, b"!")
                            active = block
                            recovery_ack = listen_ack = False
                    if "SELFTEST twai info listen_done" in line and not listen_ack:
                        listen_ack = True
                        burst = None
                        if can.channel_open:
                            can.close_channel()
                        reopen_at = time.monotonic() + 0.200
                    if "SELFTEST twai info recover_ready" in line and not recovery_ack:
                        can.restart(500000)
                        write(esp, b"!")
                        recovery_ack = True
                    if "SELFTEST twai info rate_done" in line:
                        can.close_channel()
                        active = None
                    done = re.search(r"SELFTEST twai DONE pass=(\d+) fail=(\d+)", line)
                    if done:
                        passed, failed = map(int, done.groups())
                        return 0 if expected is not None and passed == expected and failed == 0 else 1
            for frame in can.receive():
                if not can.channel_open:
                    continue
                if not frame.extended and frame.identifier == 0x7e0:
                    if not listen_ack and not frame.rtr and frame.data[:1] == b"\x01":
                        if burst is not None or reopen_at is not None:
                            raise RuntimeError("duplicate listen-only control")
                        burst = (time.monotonic() + 0.050, 0)
                elif not 0x7e0 <= frame.identifier <= 0x7ef:
                    can.send(reply(frame))
            now = time.monotonic()
            if burst is not None and now >= burst[0] and burst[1] < 200:
                can.send(Frame(0x7e1))
                burst = (time.monotonic() + 0.005, burst[1] + 1)
            if reopen_at is not None and time.monotonic() >= reopen_at:
                can.open_channel(500000)
                reopen_at = None
                write(esp, b"!")
        raise TimeoutError(f"no expected TWAI DONE within 1200 s; BEL={can.bells}")
    finally:
        if can is not None:
            print(f"SLCAN final diagnostics: BEL={can.bells}; last sent: {list(can.sent)}",
                  file=sys.stderr)
        try:
            if can is not None and can.channel_open:
                try:
                    can.close_channel()
                except (RuntimeError, TimeoutError, OSError):
                    pass  # keep the error that ended the run
        finally:
            if esp is not None:
                esp.close()
            if adapter is not None:
                adapter.close()
            if log:
                log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esp")
    parser.add_argument("--can")
    parser.add_argument("--log")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    if not args.esp or not args.can:
        parser.error("--esp and --can are required unless --selftest is used")
    import serial
    try:
        return run(args, serial)
    except (OSError, ValueError, RuntimeError, serial.SerialException) as exc:
        print(f"can_echo: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
