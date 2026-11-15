#!/usr/bin/env python3
"""Host side of the rp2xxx PIO self-test (examples/raspberrypi/rp2xxx/src/pio_selftest.zig).

Needs pyserial. Runs wherever the board's COM port and BOOTSEL drive are visible
(on WSL: through Windows Python, see run.sh).

    pio_hwtest.py find                         COM ports of RP2xxx boards and BOOTSEL drives
    pio_hwtest.py wait-drive --chip RP2350     wait for a BOOTSEL drive, print its root
    pio_hwtest.py backup --drive E: --out X    save the drive's CURRENT.UF2, print size and sha256
    pio_hwtest.py copy --drive E: --uf2 F      copy a UF2 onto a BOOTSEL drive
    pio_hwtest.py wait-port                    wait for the self-test's COM port, print it
    pio_hwtest.py run --log F                  run every test, save the log; exit 0 only for
                                               every expected test, no FAIL, no unexpected SKIP
    pio_hwtest.py send --cmd b                 send one command byte (b, q, i, P, H, F)

The self-test enumerates as a USB CDC port with serial PIOSELFTEST.

Build (in examples/raspberrypi/rp2xxx):
    zig build -Doptimize=ReleaseSafe -Dexample=pio-selftest
gives nine UF2 files under zig-out/firmware/:
    xiao_rp2040_ram_pio-selftest{,-nousb,-exit}.uf2  Seeed XIAO RP2040
    xiao_rp2350_ram_pio-selftest{,-nousb,-exit}.uf2  Seeed XIAO RP2350 (RP2350A)
    pizero_rp2350_ram_pio-selftest{,-nousb,-exit}.uf2  Waveshare RP2350-PiZero (RP2350B)
The BOARD line identifies the board, chip and package. All boards report 38 tests:
RP2040 skips 18, RP2350A skips 6, and RP2350B skips none. The PiZero tests drive
only bare header GPIO 9-12, 16-17, 20-21 and HDMI TMDS GPIO 32-39; leave those
connections unloaded. GPIO 28-31 and 40-47 retain their reset function and OE.
They are RAM images: copying one to a BOOTSEL drive never writes flash, and a
normal reset returns the board to the firmware in flash.

    pio-selftest        the test firmware
    pio-selftest-nousb  never starts USB: shows the 10 s fall-back to BOOTSEL
    pio-selftest-exit   reboots straight into the flash firmware

Sequence: BOOTSEL drive -> copy pio-selftest -> wait-port -> run -> send q
(back to the flash firmware) or send b (back to BOOTSEL). Panics, faults and a
USB that does not come up within 10 s reboot into BOOTSEL; on RP2350 a watchdog
timeout (3 s) does too. On RP2040 a watchdog timeout boots the flash firmware,
because its bootrom has no BOOTSEL watchdog boot type. A test that does not
return within 1 s is reported as FAIL by name, and the board then reboots into
BOOTSEL without a SUMMARY line (exit 2).
"""
import argparse
import hashlib
import os
import re
import shutil
import string
import sys
import time

SELFTEST_SERIAL = "PIOSELFTEST"
SUMMARY = "SUMMARY "


def selftest_ports(serial_number=SELFTEST_SERIAL):
    from serial.tools import list_ports
    return [p.device for p in list_ports.comports() if (p.serial_number or "").upper() == serial_number]


def drive_roots():
    if os.name == "nt":
        return [f"{letter}:\\" for letter in string.ascii_uppercase[3:]]
    return [os.path.join("/media", d) for d in os.listdir("/media")] if os.path.isdir("/media") else []


# INFO_UF2.TXT's Board-ID line per chip. The RP2040 bootrom says
# "Model: Raspberry Pi RP2" and "Board-ID: RPI-RP2"; RP2350's says RP2350 in both.
BOARD_IDS = {"RP2040": "RPI-RP2", "RP2350": "RP2350"}


def bootsel_drives(chip=None):
    """BOOTSEL drives as (root, INFO_UF2.TXT text); chip filters on the Board-ID line."""
    found = []
    for root in drive_roots():
        try:
            with open(os.path.join(root, "INFO_UF2.TXT"), errors="replace") as f:
                info = f.read(512)
        except OSError:
            continue
        if chip is None or f"Board-ID: {BOARD_IDS[chip]}" in info.splitlines():
            found.append((root, info))
    return found


def wait_for(what, check, timeout):
    end = time.monotonic() + timeout
    while True:
        got = check()
        if got:
            return got
        if time.monotonic() >= end:
            raise SystemExit(f"timed out after {timeout} s waiting for {what}")
        time.sleep(0.5)


def cmd_find(args):
    from serial.tools import list_ports
    for p in list_ports.comports():
        if p.vid in (0x2E8A, 0x1209):
            print(f"port {p.device} {p.vid:04X}:{p.pid:04X} serial={p.serial_number}")
    for root, info in bootsel_drives():
        model = next((l for l in info.splitlines() if l.startswith("Model")), "")
        print(f"drive {root} {model}")


def cmd_wait_drive(args):
    drives = wait_for(f"a {args.chip} BOOTSEL drive", lambda: bootsel_drives(args.chip), args.timeout)
    if len(drives) > 1:
        raise SystemExit(f"several {args.chip} BOOTSEL drives: {[d for d, _ in drives]}")
    print(drives[0][0])


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_backup(args):
    src = os.path.join(args.drive, "CURRENT.UF2")
    if os.path.exists(args.out):
        raise SystemExit(f"{args.out} exists; refusing to overwrite a backup")
    shutil.copyfile(src, args.out)
    print(f"backup {args.out} size={os.path.getsize(args.out)} sha256={sha256(args.out)}")


def cmd_copy(args):
    dest = os.path.join(args.drive, os.path.basename(args.uf2))
    try:
        with open(args.uf2, "rb") as src, open(dest, "wb") as dst:
            shutil.copyfileobj(src, dst)
            dst.flush()
            os.fsync(dst.fileno())
    except OSError as e:
        # The bootloader reboots as the last block lands and the drive can go
        # away under the final flush; the board's state tells whether it worked.
        print(f"copy ended with: {e}")
    print(f"copied {os.path.basename(args.uf2)} sha256={sha256(args.uf2)}")


def cmd_wait_port(args):
    ports = wait_for("the self-test COM port", selftest_ports, args.timeout)
    print(ports[0])


def open_port(args):
    import serial
    port = args.port or wait_for("the self-test COM port", selftest_ports, 10)[0]
    return serial.Serial(port, 115200, timeout=0.2)


def read_lines(ser, until, timeout, echo):
    """Lines until one starts with `until` (or the timeout); returns them all."""
    lines, pending = [], b""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            # Take bytes as soon as they arrive: a line sent just before a
            # reboot is lost with the port if it waits in a 256-byte read.
            chunk = ser.read(max(1, ser.in_waiting))
        except Exception as e:  # the port vanishes when the board reboots
            lines.append(f"# port closed: {e}")
            break
        pending += chunk
        while b"\n" in pending:
            raw, pending = pending.split(b"\n", 1)
            line = raw.decode(errors="replace").rstrip("\r")
            lines.append(line)
            if echo:
                print(line, flush=True)
            if until and line.startswith(until):
                return lines
    return lines


def cmd_send(args):
    ser = open_port(args)
    ser.reset_input_buffer()
    try:
        ser.write(args.cmd.encode())
        ser.flush()
    except Exception as e:
        # b, q, P, H and F reboot the board, which can take the port away
        # before the write completes; whether it acted shows in what appears next.
        print(f"# port closed during write: {e}")
        return
    read_lines(ser, None, args.listen, True)
    try:
        ser.close()
    except Exception:
        pass


# Exact board identities and (chip, package, total tests, expected SKIPs).
EXPECTED = {
    "Seeed XIAO RP2040 (ram image)": ("RP2040", "RP2040", 39, 19),
    "Seeed XIAO RP2350 (ram image)": ("RP2350", "RP2350A", 39, 7),
    "Raspberry Pi Pico 2 W (ram image)": ("RP2350", "RP2350A", 39, 6),
    "Waveshare RP2350-PiZero (ram image)": ("RP2350", "RP2350B", 39, 1),
}
# The one board whose CYW43 test must PASS; every other board must SKIP it.
CYW43_BOARD = "Raspberry Pi Pico 2 W (ram image)"
CYW43_TEST = "cyw43_init_mac_led_scan"


# The firmware's test table, when this runner sits in its MicroZig checkout.
SELFTEST_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..",
                            "examples", "raspberrypi", "rp2xxx", "src", "pio_selftest", "selftest.zig")


def table_names(path=SELFTEST_SRC):
    """Test names in selftest.zig's `tests` table, or None if unavailable."""
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except OSError:
        return None
    # Zig comments run to the end of the line, including commented-out entries.
    src = re.sub(r"//[^\n]*", "", src)
    _, start, table = src.partition("const tests = [_]Test{")
    table, end, _ = table.partition("\n};")
    if not start or not end:
        return None
    return re.findall(r'\.name = "([A-Za-z0-9_]+)"', table)


def verdict(lines, names=None):
    """(exit code, problems) for one run's lines: 0 only for a complete run
    with the expected test count, no FAIL and no SKIP beyond the board's own.
    With names (the firmware's test table), the TEST lines must be exactly those."""
    board = next((l for l in lines if l.startswith("BOARD ")), None)
    chip = next((w[5:] for w in (board or "").split() if w.startswith("chip=")), None)
    package = next((w[8:] for w in (board or "").split() if w.startswith("package=")), None)
    board_name = (board or "")[6:].split(" chip=", 1)[0]
    tests = [l.split(" ", 3) for l in lines if l.startswith("TEST ")]
    outcomes = [t[2] if len(t) > 2 else "?" for t in tests]
    summary = next((l for l in lines if l.startswith(SUMMARY)), None)
    problems = [f"FAIL: {' '.join(t)}" for t in tests if len(t) > 2 and t[2] == "FAIL"]
    problems += [f"unknown outcome: {' '.join(t)}" for t, o in zip(tests, outcomes) if o not in ("PASS", "FAIL", "SKIP")]
    if board_name not in EXPECTED:
        problems.append(f"no BOARD line with a known board (got {board!r})")
    else:
        expected_chip, expected_package, count, skips = EXPECTED[board_name]
        if (chip, package) != (expected_chip, expected_package):
            problems.append(f"board chip/package {chip}/{package}, want {expected_chip}/{expected_package}")
        if len(tests) != count:
            problems.append(f"{len(tests)} TEST lines, want {count} on {board_name}")
        if outcomes.count("SKIP") != skips:
            problems.append(f"{outcomes.count('SKIP')} SKIP, want {skips} on {board_name}")
    if board_name in EXPECTED:
        cyw43_outcome = "PASS" if board_name == CYW43_BOARD else "SKIP"
        cyw43 = [t for t in tests if len(t) > 1 and t[1] == CYW43_TEST]
        if len(cyw43) != 1:
            problems.append(f"{len(cyw43)} {CYW43_TEST} lines, want 1")
        for test in cyw43:
            if len(test) > 2 and test[2] != cyw43_outcome:
                problems.append(f"CYW43 outcome {test[2]}, want {cyw43_outcome} on {board_name}")
    table = names
    names = [t[1] for t in tests if len(t) > 1]
    if len(names) != len(set(names)):
        problems.append("duplicate TEST names")
    if table is not None and sorted(names) != sorted(table):
        missing = sorted(set(table) - set(names))
        unknown = sorted(set(names) - set(table))
        problems.append(f"TEST names differ from the firmware's table: missing {missing}, unknown {unknown}")
    if summary is None:
        problems.append("no SUMMARY line: the run did not finish")
        return 2, problems
    if not summary.endswith(f" board={board_name}"):
        problems.append("SUMMARY board does not match BOARD identity")
    fields = dict(w.split("=", 1) for w in summary.split()[1:4] if "=" in w)
    for key, outcome in (("pass", "PASS"), ("fail", "FAIL"), ("skip", "SKIP")):
        if fields.get(key) != str(outcomes.count(outcome)):
            problems.append(f"SUMMARY {key}={fields.get(key)} but {outcomes.count(outcome)} {outcome} lines")
    return (1 if problems else 0), problems


def cmd_run(args):
    ser = open_port(args)
    ser.reset_input_buffer()
    lines = []
    ser.write(b"i")
    lines += read_lines(ser, "BOARD", 3, True)
    ser.write(b"r")
    lines += read_lines(ser, SUMMARY, args.timeout, True)
    try:
        ser.close()
    except Exception:
        pass
    table = table_names()
    source = os.path.abspath(SELFTEST_SRC)
    name_check = (f"# test names checked against {source}" if table is not None else
                  f"# test names not checked: no table available at {source}")
    print(name_check)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open(args.log, "w", newline="\n") as f:
        f.write(f"# pio self-test {stamp} port={ser.port}\n")
        f.write(name_check + "\n")
        f.write("\n".join(lines) + "\n")
    rc, problems = verdict(lines, table)
    tests = [l for l in lines if l.startswith("TEST ")]
    print(f"log {args.log}: {len(tests)} tests, exit {rc}")
    for p in problems:
        print(p)
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("find").set_defaults(run=cmd_find)
    p = sub.add_parser("wait-drive")
    p.add_argument("--chip", default="RP2350", choices=sorted(BOARD_IDS), help="matched on INFO_UF2.TXT's Board-ID line")
    p.add_argument("--timeout", type=float, default=30)
    p.set_defaults(run=cmd_wait_drive)
    p = sub.add_parser("backup")
    p.add_argument("--drive", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(run=cmd_backup)
    p = sub.add_parser("copy")
    p.add_argument("--drive", required=True)
    p.add_argument("--uf2", required=True)
    p.set_defaults(run=cmd_copy)
    p = sub.add_parser("wait-port")
    p.add_argument("--timeout", type=float, default=20)
    p.set_defaults(run=cmd_wait_port)
    for name, fn in (("run", cmd_run), ("send", cmd_send)):
        p = sub.add_parser(name)
        p.add_argument("--port", help="COM port; default: the one with serial PIOSELFTEST")
        p.set_defaults(run=fn)
    sub.choices["run"].add_argument("--log", required=True)
    sub.choices["run"].add_argument("--timeout", type=float, default=60)
    sub.choices["send"].add_argument("--cmd", required=True)
    sub.choices["send"].add_argument("--listen", type=float, default=1.5)
    args = ap.parse_args()
    sys.exit(args.run(args) or 0)


if __name__ == "__main__":
    main()
