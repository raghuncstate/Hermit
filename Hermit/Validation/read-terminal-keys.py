"""Run only in a disposable tmux window named 'keys', on a hermit-test- socket."""

import os
import select
import sys
import termios
import tty


fd = sys.stdin.fileno()
original = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(sys.stdout.fileno(), b"HERMIT_KEY_TEST_READY\r\n")
    sequence = 0
    while True:
        data = os.read(fd, 64)
        if not data:
            break
        # Collect bytes from the same terminal key even if the PTY splits them.
        while select.select([fd], [], [], 0.02)[0]:
            data += os.read(fd, 64)
        sequence += 1
        os.write(sys.stdout.fileno(), f"KEY_{sequence}={data.hex()}\r\n".encode())
finally:
    termios.tcsetattr(fd, termios.TCSANOW, original)
