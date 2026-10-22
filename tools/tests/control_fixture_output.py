"""Continuous dummy output for the private control-client lifecycle fixture."""
import sys
import time

sequence = 0
while True:
    sys.stdout.write(("fixture-output-%d " % sequence) + ("x" * 8192) + "\n")
    sys.stdout.flush()
    sequence += 1
    time.sleep(0.02)
