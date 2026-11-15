"""Host-only completeness checks; no serial port or board needed."""
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from pio_hwtest import CYW43_BOARD, CYW43_TEST, EXPECTED, SELFTEST_SRC, cmd_run, table_names, verdict


def transcript(board):
    """A complete run; its first TEST line (lines[1]) is the CYW43 test."""
    chip, package, count, skips = EXPECTED[board]
    cyw43 = "PASS" if board == CYW43_BOARD else "SKIP"
    other_skips = skips - (cyw43 == "SKIP")
    return [f"BOARD {board} chip={chip} package={package} sys_hz=150000000",
            f"TEST {CYW43_TEST} {cyw43} detail"] + [
        f"TEST case_{i} {'SKIP' if i < other_skips else 'PASS'} detail"
        for i in range(count - 1)
    ] + [f"SUMMARY pass={count - skips} fail=0 skip={skips} board={board}"]


def flip(line):
    return line.replace("PASS", "SKIP") if " PASS " in line else line.replace("SKIP", "PASS")


def consistent_summary(lines, board):
    outcomes = [line.split()[2] for line in lines if line.startswith("TEST ")]
    lines[-1] = (f"SUMMARY pass={outcomes.count('PASS')} fail={outcomes.count('FAIL')} "
                 f"skip={outcomes.count('SKIP')} board={board}")


class VerdictTests(unittest.TestCase):
    def test_all_boards_complete(self):
        for board in EXPECTED:
            with self.subTest(board=board):
                self.assertEqual(verdict(transcript(board)), (0, []))

    def test_cyw43_skips_cannot_be_swapped_with_other_tests(self):
        # Keep the total SKIPs and SUMMARY correct: the wireless case itself
        # must pass only on Pico 2 W, even when no source table is available.
        for board in EXPECTED:
            with self.subTest(board=board):
                lines = transcript(board)
                cyw43 = lines[1].split()[2]
                other = next(i for i, l in enumerate(lines) if l.startswith("TEST ") and l.split()[2] != cyw43)
                lines[1], lines[other] = flip(lines[1]), flip(lines[other])
                consistent_summary(lines, board)
                rc, problems = verdict(lines)
                self.assertEqual(rc, 1)
                self.assertEqual(len(problems), 1)
                self.assertIn("CYW43 outcome", problems[0])

    def test_cyw43_line_cannot_be_missing(self):
        # Without the source table, 39 unique names with the right counts
        # must still include the CYW43 test.
        for board in EXPECTED:
            with self.subTest(board=board):
                lines = transcript(board)
                lines[1] = lines[1].replace(CYW43_TEST, "case_extra")
                rc, problems = verdict(lines)
                self.assertEqual(rc, 1)
                self.assertEqual(problems, [f"0 {CYW43_TEST} lines, want 1"])

    def test_incomplete_and_duplicate_runs(self):
        for board in EXPECTED:
            lines = transcript(board)
            with self.subTest(board=board):
                self.assertEqual(verdict(lines[:-1])[0], 2)
                self.assertEqual(verdict(lines[:1] + lines[2:])[0], 1)
                lines[2] = lines[1]
                self.assertEqual(verdict(lines)[0], 1)

    def test_incorrect_package_or_skips(self):
        for board in EXPECTED:
            with self.subTest(board=board):
                lines = transcript(board)
                lines[0] = lines[0].replace("package=", "missing=")
                self.assertEqual(verdict(lines)[0], 1)
                lines = transcript(board)
                lines[1] = lines[1].replace("PASS", "SKIP") if "PASS" in lines[1] else lines[1].replace("SKIP", "PASS")
                self.assertEqual(verdict(lines)[0], 1)

    def test_fail_unknown_outcome_board_and_summary(self):
        board = next(iter(EXPECTED))
        for bad in ("TEST case_0 FAIL broken", "TEST case_0 UNKNOWN broken"):
            lines = transcript(board)
            lines[1] = bad
            self.assertEqual(verdict(lines)[0], 1)
        lines = transcript(board)
        lines[0] = "BOARD unknown chip=RP2350 package=RP2350B"
        self.assertEqual(verdict(lines)[0], 1)
        lines = transcript(board)
        lines[-1] = lines[-1].replace(f"board={board}", "board=other")
        self.assertEqual(verdict(lines)[0], 1)

    def test_board_count_with_consistent_summary(self):
        for board in EXPECTED:
            with self.subTest(board=board):
                lines = transcript(board)
                del lines[-2]  # Remove one PASS, preserving the expected SKIPs.
                consistent_summary(lines, board)
                rc, problems = verdict(lines)
                self.assertEqual(rc, 1)
                self.assertEqual(len(problems), 1)
                self.assertIn("TEST lines, want", problems[0])

    def test_board_skips_with_consistent_summary(self):
        for board in EXPECTED:
            with self.subTest(board=board):
                lines = transcript(board)
                lines[-2] = lines[-2].replace("PASS", "SKIP")
                consistent_summary(lines, board)
                rc, problems = verdict(lines)
                self.assertEqual(rc, 1)
                self.assertEqual(len(problems), 1)
                self.assertIn("SKIP, want", problems[0])

    def test_fail_with_consistent_summary(self):
        for board in EXPECTED:
            with self.subTest(board=board):
                lines = transcript(board)
                lines[-2] = lines[-2].replace("PASS", "FAIL")
                consistent_summary(lines, board)
                rc, problems = verdict(lines)
                self.assertEqual(rc, 1)
                self.assertEqual(len(problems), 1)
                self.assertTrue(problems[0].startswith("FAIL:"))

    def test_summary_counts_with_valid_test_lines(self):
        for board in EXPECTED:
            for field in ("pass", "fail", "skip"):
                with self.subTest(board=board, field=field):
                    lines = transcript(board)
                    # Only this SUMMARY field is wrong; all TEST lines are valid.
                    fields = lines[-1].split()
                    i = next(i for i, word in enumerate(fields) if word.startswith(field + "="))
                    fields[i] = f"{field}={int(fields[i].split('=')[1]) + 1}"
                    lines[-1] = " ".join(fields)
                    rc, problems = verdict(lines)
                    self.assertEqual(rc, 1)
                    self.assertEqual(len(problems), 1)
                    self.assertTrue(problems[0].startswith(f"SUMMARY {field}="))

    def test_names_must_match_the_table(self):
        board = next(iter(EXPECTED))
        lines = transcript(board)
        table = [l.split()[1] for l in lines if l.startswith("TEST ")]
        self.assertEqual(verdict(lines, table), (0, []))
        lines[-2] = lines[-2].replace(table[-1], "not_in_table")
        self.assertEqual(verdict(lines, table)[0], 1)

    def test_table_names_reads_the_firmware_table(self):
        names = table_names()
        self.assertIsNotNone(names)
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(len(names), EXPECTED[next(iter(EXPECTED))][2])


class TableNamesTests(unittest.TestCase):
    def test_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(table_names(Path(directory) / "missing.zig"))

    def test_absent_or_unterminated_table(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "selftest.zig"
            for source in ("const unrelated = 0;", "const tests = [_]Test{\n"):
                with self.subTest(source=source):
                    path.write_text(source)
                    self.assertIsNone(table_names(path))

    def test_commented_out_names(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "selftest.zig"
            path.write_text('''const tests = [_]Test{
    // .{ .name = "disabled", .run = disabled },
    .{ .name = "active", .run = active }, // .name = "comment"
};
''')
            self.assertEqual(table_names(path), ["active"])


class SavedLogTests(unittest.TestCase):
    def test_name_check_provenance(self):
        board = next(iter(EXPECTED))
        lines = transcript(board)
        names = [line.split()[1] for line in lines if line.startswith("TEST ")]
        for table in (names, None):
            with self.subTest(checked=table is not None), tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "run.log"
                args = SimpleNamespace(log=log, timeout=60)
                with patch("pio_hwtest.open_port", return_value=MagicMock(port="test-port")), \
                        patch("pio_hwtest.read_lines", side_effect=[lines[:1], lines[1:]]), \
                        patch("pio_hwtest.table_names", return_value=table), \
                        patch("builtins.print"):
                    self.assertEqual(cmd_run(args), 0)
                saved = log.read_text()
                expected = ("# test names checked against " if table is not None else
                            "# test names not checked: no table available at ")
                self.assertIn(expected + str(Path(SELFTEST_SRC).resolve()), saved)
                self.assertIn(lines[-1], saved)


if __name__ == "__main__":
    unittest.main()
