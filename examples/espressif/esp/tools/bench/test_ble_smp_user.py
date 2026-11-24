"""Unit tests for ble_smp_user.py with fake serial ports and resets (no boards).

Run: python3 -I -m unittest discover -s examples/espressif/esp/tools/bench -p 'test_ble_smp_user.py'
"""
import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).with_name('ble_smp_user.py')
PORTS = ('COM38', 'COM42')


def selftest_line(text):
    return b'[1.000000] info: SELFTEST ble_smp ' + text + b'\r\n'


BOOT0 = selftest_line(b'phase=0 role=central central=true method=just_works')
BOOT1 = selftest_line(b'phase=1 role=central central=true method=just_works')
DONE_OK = selftest_line(b'DONE pass=10 fail=0')
LOST = OSError('ClearCommError failed')  # a read that raises: USB went away


class FakeSerial:
    """pyserial's Serial as the script uses it; reads come from `output[port]`.

    A None chunk is one read timeout with no data; an exception chunk is raised
    by that read, as pyserial does when the USB device disappears.
    The open attempts of a port numbered in `failing_opens[port]` (from 1)
    raise, as while USB is still coming back.
    """

    output = {}
    opened = []
    attempts = {}
    failing_opens = {}

    def __init__(self):
        self.port = None
        self.baudrate = None
        self.timeout = 0.05
        self.dtr = None
        self.rts = None

    def open(self):
        attempt = FakeSerial.attempts.get(self.port, 0) + 1
        FakeSerial.attempts[self.port] = attempt
        if attempt in FakeSerial.failing_opens.get(self.port, ()):
            raise OSError('could not open port %s' % self.port)
        FakeSerial.opened.append(self.port)

    def read(self, size):
        chunks = FakeSerial.output[self.port]
        if chunks and isinstance(chunks[0], BaseException):
            raise chunks.pop(0)
        if chunks and chunks[0] is not None:
            return chunks.pop(0)
        if chunks:
            chunks.pop(0)
        time.sleep(self.timeout)
        return b''

    def write(self, data):
        return len(data)

    def flush(self):
        pass

    def close(self):
        pass


def load_script():
    fake = types.ModuleType('serial')
    fake.Serial = FakeSerial
    with mock.patch.dict(sys.modules, {'serial': fake}):
        spec = importlib.util.spec_from_file_location('ble_smp_user_under_test', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


class HarnessTest(unittest.TestCase):
    def setUp(self):
        self.module = load_script()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        FakeSerial.output = {}
        FakeSerial.opened = []
        FakeSerial.attempts = {}
        FakeSerial.failing_opens = {}
        self.reset_calls = []

    def run_harness(self, output, failing_resets=(), max_seconds=1.5):
        FakeSerial.output = {port: list(chunks) for port, chunks in output.items()}

        def wdt_reset(port):
            self.reset_calls.append(port)
            if port in failing_resets:
                raise OSError('could not open port %s' % port)

        self.module.wdt_reset = wdt_reset
        argv = ['ble_smp_user.py', '--reset-wdt', '--min-seconds', '0', '--max-seconds', str(max_seconds)]
        for port in PORTS:
            argv += ['--board', '%s=%s' % (port, pathlib.Path(self.tmp.name, port + '.log'))]
        with mock.patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
            return self.module.main()

    def test_normal_run_passes(self):
        output = {port: [BOOT0, BOOT1, DONE_OK, DONE_OK] for port in PORTS}
        self.assertEqual(self.run_harness(output, max_seconds=5), 0)
        self.assertEqual(sorted(self.reset_calls), sorted(PORTS))

    def log(self, port):
        return pathlib.Path(self.tmp.name, port + '.log').read_text(encoding='utf-8')

    def test_both_resets_failing_exits_before_capture(self):
        # Both boards still repeat the previous run's DONE.
        output = {port: [DONE_OK] * 5 for port in PORTS}
        self.assertEqual(self.run_harness(output, failing_resets=PORTS), 3)
        self.assertEqual(FakeSerial.opened, [])

    def test_one_reset_failing_exits_before_capture(self):
        output = {port: [BOOT1, DONE_OK] for port in PORTS}
        self.assertEqual(self.run_harness(output, failing_resets=('COM42',)), 3)
        self.assertEqual(FakeSerial.opened, [])

    def test_done_before_the_phase_line_is_stale(self):
        # Reset "succeeded" but the board was not restarted: only old DONE lines.
        output = {port: [DONE_OK] * 5 for port in PORTS}
        self.assertEqual(self.run_harness(output), 1)

    def test_phase_line_discards_an_earlier_done(self):
        # A stale DONE, then the board reboots and never finishes. COM42
        # passes, after COM38 has printed everything.
        output = {'COM38': [BOOT1 + DONE_OK + BOOT0 + BOOT1], 'COM42': [None] * 10 + [BOOT1, DONE_OK]}
        self.assertEqual(self.run_harness(output), 1)

    def test_done_on_the_first_boot_does_not_pass(self):
        output = {port: [BOOT0, DONE_OK] for port in PORTS}
        self.assertEqual(self.run_harness(output), 1)

    def test_lost_port_reopens_and_passes(self):
        output = {port: [BOOT0, LOST, BOOT1, DONE_OK] for port in PORTS}
        self.assertEqual(self.run_harness(output, max_seconds=5), 0)
        self.assertEqual(sorted(FakeSerial.opened), sorted(PORTS * 2))

    def test_line_split_across_reads_passes(self):
        output = {port: [BOOT0, BOOT1, DONE_OK[:20], None, DONE_OK[20:]] for port in PORTS}
        self.assertEqual(self.run_harness(output, max_seconds=5), 0)

    def test_partial_done_before_a_lost_port_does_not_pass(self):
        # COM38's first boot DONE is cut off by the reset; the second boot's
        # phase line must not complete it.
        output = {'COM38': [BOOT0, DONE_OK[:-2], LOST, BOOT1], 'COM42': [BOOT0, BOOT1, DONE_OK]}
        self.assertEqual(self.run_harness(output), 1)
        self.assertIn('dropped partial line', self.log('COM38'))

    def test_done_then_phase_line_in_one_line_does_not_pass(self):
        # Handled in text order: the phase line after the DONE discards it.
        output = {'COM38': [BOOT0, DONE_OK[:-2] + BOOT1], 'COM42': [BOOT0, BOOT1, DONE_OK]}
        self.assertEqual(self.run_harness(output), 1)

    def test_board_without_log_is_a_usage_error(self):
        argv = ['ble_smp_user.py', '--board', 'COM38', '--board', 'COM42']
        with mock.patch.object(sys, 'argv', argv), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                self.module.main()
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(FakeSerial.opened, [])

    def test_partial_done_before_a_quiet_reopen_does_not_pass(self):
        # COM38 goes quiet mid-line for longer than the quiet period; the line
        # end read after the reopen must not complete the stale DONE.
        self.module.QUIET_SECONDS = 0.3
        output = {'COM38': [BOOT0, BOOT1, DONE_OK[:-2]] + [None] * 10 + [b'\r\n'],
                  'COM42': [BOOT0, BOOT1, DONE_OK]}
        self.assertEqual(self.run_harness(output), 1)
        self.assertIn('quiet 0.3 s, reopening', self.log('COM38'))
        self.assertIn('dropped partial line', self.log('COM38'))
        # No counted DONE, so the capture runs on and keeps reopening the quiet port.
        self.assertGreaterEqual(FakeSerial.opened.count('COM38'), 2)

    def test_quiet_reopen_after_a_failed_open_passes(self):
        # USB is still away at the first reopen; the next one reads the second boot.
        self.module.QUIET_SECONDS = 0.3
        output = {'COM38': [BOOT0, b'[1.0'] + [None] * 10 + [BOOT1, DONE_OK],
                  'COM42': [BOOT0, BOOT1, DONE_OK]}
        FakeSerial.failing_opens = {'COM38': {2}}
        self.assertEqual(self.run_harness(output, max_seconds=5), 0)
        self.assertIn('dropped partial line', self.log('COM38'))
        # A slow host can add another quiet reopen, so these are lower bounds.
        self.assertGreaterEqual(FakeSerial.attempts['COM38'], 3)
        self.assertGreaterEqual(FakeSerial.opened.count('COM38'), 2)


if __name__ == '__main__':
    unittest.main()
