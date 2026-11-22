"""GEEK debugprobe UART echo peer (Windows python.exe + pyserial).

python.exe geek_uart_peer.py --port <GEEK-port> --seconds 30
python3 geek_uart_peer.py --selftest

Wire XIAO ESP32-C6 D6/GPIO16 TX -> GEEK GP5 RX, D2/GPIO2 RX <-
GEEK GP4 TX, GND -> GND. Keep debugprobe firmware on the GEEK, start
this script on its UART CDC port before starting selftest_uart on the XIAO ESP32-C6.
Require SELFTEST uart DONE pass=7 fail=0, PEER uart parity_rx: PASS,
no peer FAIL and script exit 0. Echo baud phases: P0=115200 8N1, P1=1M 8N1,
P2=115200 8E1. >=300 bytes followed by 50 ms idle advances P0/P1.
Short probes do not advance. Exit after --seconds or 2 s idle in P2
(the Pico instead returns to P0 at that point).

CDC exposes bytes, not per-byte UART parity error flags. parity_rx reports
receipt of expected control bytes with CDC configured for even parity;
the ESP parity_mismatch/parity_match cases verify parity on the wire.
The state-machine self-check needs neither pyserial nor hardware.
"""
import argparse
from dataclasses import dataclass, replace
import sys
import time


@dataclass(frozen=True)
class State:
    phase: int = 0
    burst: int = 0
    last_rx: float | None = None
    parity_rx: bool = False
    bad_control: bool = False
    done: bool = False

    @property
    def settings(self):
        return ((115200, "N"), (1_000_000, "N"), (115200, "E"))[self.phase]


def step(state, now, data=b""):
    """Pure step returning (state, echo bytes, optional verdict).

    Call at least every 5 ms, including while idle; now is monotonic seconds.
    Detect burst boundaries before consuming the next chunk so separated short
    bursts cannot accumulate to trigger a transition.
    """
    if state.done:
        return state, b"", None
    verdict = None
    if state.last_rx is not None:
        idle = now - state.last_rx
        if state.phase == 2 and idle >= 2.0:
            return replace(state, done=True), b"", None
        if state.phase < 2 and idle >= 0.050:
            phase = state.phase + (state.burst >= 300)
            state = replace(state, phase=phase, burst=0,
                            last_rx=now if phase == 2 else None)
    if data:
        if state.phase == 2:
            bad = any(byte not in (0x55, 0xAA) for byte in data)
            if bad and not state.bad_control:
                verdict = "FAIL"
            elif not bad and not state.parity_rx and not state.bad_control:
                verdict = "PASS"
            state = replace(state, parity_rx=state.parity_rx or not bad,
                            bad_control=state.bad_control or bad)
        state = replace(state, burst=state.burst + len(data), last_rx=now)
    return state, data, verdict


def selftest():
    s, echo, verdict = step(State(), 0.0, b"Z")
    assert echo == b"Z" and verdict is None
    s, _, _ = step(s, 0.060)
    assert s.phase == 0 and s.burst == 0
    s, _, _ = step(s, 0.1, bytes(299))
    s, _, _ = step(s, 0.16)
    assert s.phase == 0 and s.burst == 0
    s, _, _ = step(s, 0.2, bytes(128))
    s, _, _ = step(s, 0.21, bytes(172))
    s, _, _ = step(s, 0.259)
    assert s.phase == 0 and s.burst == 300
    s, _, _ = step(s, 0.261)
    assert s.phase == 1 and s.settings == (1_000_000, "N")
    s, echo, _ = step(s, 0.3, bytes(301))
    assert len(echo) == 301
    s, _, _ = step(s, 0.351)
    assert s.phase == 2 and s.settings == (115200, "E")
    s, echo, verdict = step(s, 0.4, b"\x55")
    assert echo == b"\x55" and verdict == "PASS"
    s, echo, verdict = step(s, 0.5, b"\xaa")
    assert echo == b"\xaa" and verdict is None
    assert not step(s, 2.499)[0].done
    s, echo, verdict = step(s, 2.5)
    assert s.done and not echo and verdict is None
    assert step(s, 2.6, b"Z")[1] == b""
    bad, echo, verdict = step(State(phase=2), 0, b"\x54")
    assert echo == b"\x54" and verdict == "FAIL" and bad.bad_control
    assert step(bad, 0.1, b"\x55")[2] is None
    short, _, _ = step(State(), 0, bytes(150))
    short, _, _ = step(short, 0.1, bytes(150))
    assert short.phase == 0 and short.burst == 150
    assert step(State(phase=2, last_rx=0), 2)[0].done
    print("UART peer selftest: PASS")


def run(port, seconds):
    import serial

    state = State()
    end = time.monotonic() + seconds
    # Match peers/scripts: DTR asserted, RTS deasserted; bounded reads/writes.
    with serial.Serial(port, 115200, timeout=0.005, write_timeout=0.25,
                       parity=serial.PARITY_NONE, rtscts=False,
                       dsrdtr=False) as peer:
        peer.dtr = True
        peer.rts = False
        while time.monotonic() < end:
            state, _, _ = step(state, time.monotonic())
            if state.done:
                break
            baud, parity = state.settings
            if peer.baudrate != baud:
                peer.baudrate = baud
            if peer.parity != parity:
                peer.parity = parity
            data = peer.read(max(1, min(peer.in_waiting, 4096)))
            state, echo, verdict = step(state, time.monotonic(), data)
            if echo and peer.write(echo) != len(echo):
                raise OSError("short serial write")
            if verdict:
                print(f"PEER uart parity_rx: {verdict}", flush=True)
        if not state.parity_rx and not state.bad_control:
            print("PEER uart parity_rx: FAIL error=Timeout", flush=True)
        return 0 if state.parity_rx and not state.bad_control else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port")
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    if not args.port:
        parser.error("--port is required unless --selftest is used")
    if not 0 < args.seconds < float("inf"):
        parser.error("--seconds must be finite and positive")
    try:
        return run(args.port, args.seconds)
    except (OSError, ValueError, ImportError) as exc:
        print(f"PEER uart parity_rx: FAIL error={type(exc).__name__}", flush=True)
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
