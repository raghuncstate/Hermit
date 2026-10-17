"""Raw-key TUI fixture, run ONLY inside the runner's private tmux socket."""
import os
import select
import shutil
import sys
import termios
import tty


def main():
    original = termios.tcgetattr(sys.stdin.fileno())
    tty.setraw(sys.stdin.fileno())
    buffer = bytearray()
    pending = bytearray()
    enters = shifts = tick = 0
    try:
        while True:
            if select.select([sys.stdin], [], [], 0.15)[0]:
                part = os.read(sys.stdin.fileno(), 4096)
                if not part:
                    return
                pending.extend(part)
                while pending:
                    if pending[0] == 27:
                        if len(pending) < 3 or pending[-1] in b"[;0123456789":
                            break
                        end = next((i for i, b in enumerate(pending[2:], 2) if 64 <= b <= 126), None)
                        if end is None:
                            break
                        sequence = bytes(pending[:end + 1])
                        del pending[:end + 1]
                        if sequence == b"\x1b[1;2D":
                            shifts += 1
                        continue
                    byte = pending.pop(0)
                    if byte in (10, 13):
                        enters += 1
                        buffer.clear()
                    elif byte in (8, 127):
                        if buffer:
                            buffer.pop()
                    elif byte == 21:
                        buffer.clear()
                    elif byte >= 32:
                        buffer.append(byte)
            columns, rows = shutil.get_terminal_size((80, 24))
            tick += 1
            frame = ["HERMIT_TERMINAL_TEST", "BUFFER=" + buffer.decode("utf-8", errors="replace"),
                     "SHIFT_LEFT=" + str(shifts), "ENTER=" + str(enters),
                     "SIZE=" + str(columns) + "x" + str(rows), "TICK=" + str(tick)]
            if rows < 7:
                frame = [frame[1], frame[2] + " " + frame[3], frame[4] + " " + frame[5]][:rows - 1]
            output = "\x1b[2J\x1b[H" + "\r\n".join(frame)
            output += "\x1b[" + str(rows) + ";" + str(max(1, columns - 6)) + "HSTATUS"
            sys.stdout.write(output)
            sys.stdout.flush()
    finally:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, original)


if __name__ == "__main__":
    main()
