#!/usr/bin/env python3
"""Act as the user of both esp32_c6_selftest_ble_smp boards (Windows python.exe + pyserial).

Usage: python ble_smp_user.py --board <port>=<log> --board <port>=<log>
                              [--reset-wdt] [--min-seconds N] [--max-seconds N]

Logs each board's USB Serial/JTAG console with wall-clock stamps and answers
its SMP IO prompts the way a person would, only from what both consoles show:

- `io compare=NNNNNN`: once BOTH boards have shown a number, type `yes` into
  each if the numbers match, otherwise `no`.
- `io input` on one board: type the six digits only after the OTHER board has
  printed `io display=NNNNNN` for this pairing.
- `io cancel`: the board withdrew its outstanding prompt; stop answering it.

A board that waits for its own answer before it lets the peer compute (the
ordering bugs this guards against) therefore times out instead of passing.

--reset-wdt starts both boards together with an RTC watchdog system reset from
ROM download mode (put each in download mode first, e.g. `esptool chip_id
--after no_reset`); if either reset fails, it exits with status 3 before
capturing. Without it, start the boards yourself. Capture reopens a port after
USB loss (the self-test software-resets between its two boots) and ends once
both boards print `DONE pass=` after --min-seconds, or at --max-seconds.

A `DONE` line counts only after the same board has printed its phase line
(`SELFTEST ble_smp phase=N`) during this capture. Each boot prints that line
after opening NVS and starting the controller and, in auto mode, after about
6 s of role discovery, so it is not the first line of a boot. A board that was
not restarted (it repeats the previous run's `DONE` once a second) cannot
pass, and a first boot that fails before its phase line reaches no counted
`DONE`: the capture runs to --max-seconds. A later phase line discards an
earlier `DONE`. Events are handled in text order, also within one line, and
a partial line left by a lost or reopened port is dropped, so text from
before a reset never joins a line printed after it.

Exit status: 0 when both boards printed `DONE pass=N fail=0` after their
second boot's `phase=1` line; 1 when either did not (a failed check, a stale
or missing `DONE`, or --max-seconds reached); 2 for a usage error; 3 when a
--reset-wdt reset failed.
"""
import argparse
import re
import sys
import threading
import time

import serial

# One alternative per console event; matches are handled in text order.
EVENT = re.compile(
    rb'SELFTEST ble_smp (?:'
    rb'io (?P<prompt>compare|display)=(?P<number>\d{6})'
    rb'|io (?P<input>input)'
    rb'|io (?P<cancel>cancel)'
    rb'|DONE pass=(?P<passed>\d+) fail=(?P<failed>\d+)'
    rb'|phase=(?P<phase>\d+) )'
)

EXIT_FAILED = 1
EXIT_RESET_FAILED = 3  # argparse uses 2 for usage errors
QUIET_SECONDS = 5  # a port that reads nothing this long is closed and reopened


def board_spec(spec):
    port, sep, log = spec.partition('=')
    if not (port and sep and log):
        raise argparse.ArgumentTypeError('expected PORT=LOG, got %r' % spec)
    return port, log


def stamp():
    t = time.time()
    return time.strftime('%H:%M:%S', time.localtime(t)) + '.%03d' % int((t % 1) * 1000)


class Board:
    def __init__(self, port, log):
        self.port = port
        self.log = open(log, 'w', encoding='utf-8', errors='replace')
        self.serial = None
        self.compare = None
        self.display = None
        self.input = False
        self.phase = None
        self.done = None
        self.answers = 0

    def note(self, text):
        self.log.write('[%s] --- %s\n' % (stamp(), text))
        self.log.flush()

    def type(self, text):
        # The other reader thread may be reopening this port; wait for it.
        deadline = time.time() + 3
        while self.serial is None and time.time() < deadline:
            time.sleep(0.02)
        port = self.serial
        if port is None:
            self.note('USER could not type %r: port closed' % text)
            return
        port.write(text.encode() + b'\n')
        port.flush()
        self.answers += 1
        self.note('USER typed %r' % text)


def wdt_reset(port):
    import esptool
    esp = esptool.cmds.detect_chip(port, 115200, 'no_reset', False, 3)
    # ESP32-C6 RTC watchdog (LP_WDT) registers, as hw wdt_boot3.py: unlock,
    # 2000-cycle stage 0, system reset action, enable, lock.
    cfg0, cfg1, protect = 0x600B1C00, 0x600B1C04, 0x600B1C18
    esp.write_reg(protect, 0x50D83AA1)
    esp.write_reg(cfg1, 2000)
    esp.write_reg(cfg0, (1 << 31) | (5 << 28) | (1 << 8) | 2)
    esp.write_reg(protect, 0)
    esp._port.close()


def reset_boards(ports):
    """WDT-reset every port at once; return {port: exception} for the failures."""
    errors = {}

    def run(port):
        try:
            wdt_reset(port)
        except BaseException as e:
            errors[port] = e

    threads = [threading.Thread(target=run, args=(port,)) for port in ports]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--board', action='append', required=True, type=board_spec, help='PORT=LOG, twice')
    parser.add_argument('--reset-wdt', action='store_true')
    parser.add_argument('--min-seconds', type=float, default=20)
    parser.add_argument('--max-seconds', type=float, default=100)
    args = parser.parse_args()
    if len(args.board) != 2:
        parser.error('exactly two --board PORT=LOG')
    boards = [Board(port, log) for port, log in args.board]
    lock = threading.Lock()

    def decide():
        a, b = boards
        if a.compare is not None and b.compare is not None:
            shown = (a.compare, b.compare)
            answer = 'yes' if shown[0] == shown[1] else 'no'
            for board in boards:
                board.compare = None
                board.note('USER saw compare %06d / %06d' % shown)
                board.type(answer)
        for me, other in ((a, b), (b, a)):
            if me.input and other.display is not None:
                me.note('USER saw display %06d on %s' % (other.display, other.port))
                me.type('%06d' % other.display)
                me.input = False
                other.display = None

    def line(board, text):
        with lock:
            for m in EVENT.finditer(text):
                if m.group('phase') is not None:
                    board.phase = int(m.group('phase'))
                    board.done = None
                elif m.group('cancel'):
                    board.compare = None
                    board.input = False
                    # The pairing is over: the other board's passkey is stale.
                    for other in boards:
                        if other is not board:
                            other.display = None
                    board.note('USER saw the prompt withdrawn')
                elif m.group('passed') is not None:
                    if board.phase is None:
                        board.note('USER ignored DONE: no phase line yet in this capture')
                        continue
                    board.done = (int(m.group('passed')), int(m.group('failed')))
                    board.display = None
                else:
                    if m.group('prompt') == b'compare':
                        board.compare = int(m.group('number'))
                    elif m.group('prompt') == b'display':
                        board.display = int(m.group('number'))
                    else:
                        board.input = True
                    decide()

    if args.reset_wdt:
        errors = reset_boards([b.port for b in boards])
        for b in boards:
            error = errors.get(b.port)
            if error is None:
                b.note('reset issued')
            else:
                b.note('reset FAILED: %s: %s' % (type(error).__name__, error))
                print('%s reset FAILED: %s: %s' % (b.port, type(error).__name__, error))
        if errors:
            for b in boards:
                b.log.close()
            return EXIT_RESET_FAILED
    start = time.time()
    stop = threading.Event()

    def reader(board):
        pending = b''
        last = time.time()

        def drop_port(why):
            # A partial line cannot be completed by what the next connection
            # reads (the board may have reset in between): log and drop it.
            nonlocal pending
            board.note('%s +%.2fs' % (why, time.time() - start))
            if pending:
                board.note('dropped partial line %r' % pending.decode('utf-8', 'replace'))
                pending = b''
            try:
                board.serial.close()
            except Exception:
                pass
            board.serial = None

        while not stop.is_set():
            if board.serial is None:
                try:
                    s = serial.Serial()
                    s.port = board.port
                    s.baudrate = 115200
                    s.timeout = 0.05
                    s.dtr = False
                    s.rts = False
                    s.open()
                    board.serial = s
                    last = time.time()
                    board.note('open +%.2fs' % (time.time() - start))
                except Exception:
                    time.sleep(0.05)
                    continue
            try:
                data = board.serial.read(4096)
            except Exception as e:
                drop_port('lost port (%s)' % type(e).__name__)
                continue
            if not data:
                if time.time() - last > QUIET_SECONDS:
                    drop_port('quiet %g s, reopening' % QUIET_SECONDS)
                continue
            last = time.time()
            pending += data
            while b'\n' in pending:
                text, pending = pending.split(b'\n', 1)
                board.log.write('[%s +%.1f] %s\n' % (stamp(), time.time() - start, text.decode('utf-8', 'replace').rstrip('\r')))
                board.log.flush()
                line(board, text)

    threads = [threading.Thread(target=reader, args=(b,), daemon=True) for b in boards]
    for t in threads:
        t.start()
    while True:
        elapsed = time.time() - start
        if elapsed >= args.max_seconds:
            break
        if elapsed >= args.min_seconds and all(b.done is not None for b in boards):
            break
        time.sleep(0.1)
    stop.set()
    for t in threads:
        t.join(1)
    ok = True
    for b in boards:
        result = 'DONE pass=%d fail=%d' % b.done if b.done else 'NO DONE'
        b.note('capture end +%.2fs %s answers=%d' % (time.time() - start, result, b.answers))
        print('%s %s answers=%d' % (b.port, result, b.answers))
        ok = ok and b.done is not None and b.done[1] == 0 and b.phase == 1
        if b.serial is not None:
            b.serial.close()
        b.log.close()
    return 0 if ok else EXIT_FAILED


if __name__ == '__main__':
    sys.exit(main())
