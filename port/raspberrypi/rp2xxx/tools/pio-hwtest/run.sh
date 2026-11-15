#!/usr/bin/env bash
# Run pio_hwtest.py from WSL with a Windows Python that can see the board's COM
# port and BOOTSEL drive. usage: run.sh <pio_hwtest.py subcommand> ARGS...
# PIO_HWTEST_PYTHON overrides the interpreter (a Windows path to a python.exe
# with pyserial installed).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python=${PIO_HWTEST_PYTHON:-python.exe}
# cmd.exe cannot start in a WSL directory; any Windows directory will do.
cd /mnt/c
exec cmd.exe /c "$python" "$(wslpath -w "$here/pio_hwtest.py")" "$@"
