#!/usr/bin/env python3
"""Test the actual packaged adapter, without binding DJ or lighting sockets."""
import json
import select
import subprocess
import sys
import time
from pathlib import Path

root = Path(__file__).resolve().parent.parent
helper = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Vendor/BeatLinkHelper'
launcher = helper / 'Contents/MacOS/Beat Link Trigger'
result = subprocess.run([str(launcher), '--protocol-test'], capture_output=True, text=True, check=True, timeout=10)
assert len(result.stdout.splitlines()) == 1
assert result.stdout.startswith('LSBLT ')
event = json.loads(result.stdout[6:])
assert event['type'] == 'device' and event['deck'] == 2 and event['present'] is True
assert event['name'] == 'XDJ"XZ\\\n\x01 ☀', 'Network names must stay valid JSON'
assert abs(event['timestamp'] - time.time()) < 5

proc = subprocess.Popen([str(launcher), '--memory-check'], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert select.select([proc.stdout], [], [], 10)[0], 'No startup event'
    ready = json.loads(proc.stdout.readline()[6:])
    assert ready['type'] == 'ready' and ready['state'] == 'self-test'
    assert proc.poll() is None
    started = time.monotonic()
    proc.stdin.close()
    assert proc.wait(timeout=5) == 0
    print(f'PASS: JSON framing/escaping, startup, parent EOF cleanup ({time.monotonic() - started:.2f}s)')
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
