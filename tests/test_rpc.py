#!/usr/bin/env python3
"""Exercise the real Swift JSONL transport against a synthetic subprocess."""
import os
from pathlib import Path
import subprocess
import sys
import time

binary = str(Path(sys.argv[1]).resolve())
fixture = str(Path(__file__).with_name('fixtures') / 'rpc-server.py')
for mode in ['normal', 'eof', 'timeout']:
    env = dict(os.environ, RESET_FIXTURE_MODE=mode)
    started = time.monotonic()
    result = subprocess.run([binary, '--check-account', fixture], env=env,
                            capture_output=True, text=True, timeout=20)
    elapsed = time.monotonic() - started
    if mode == 'normal':
        if result.returncode != 0 or 'availableCount=0' not in result.stdout:
            raise SystemExit(f'FAIL fragmented JSONL: {result.stdout} {result.stderr}')
    else:
        limit = 4 if mode == 'eof' else 15
        expected = '输出流已关闭' if mode == 'eof' else '请求超时'
        if result.returncode != 1 or elapsed >= limit or expected not in result.stdout:
            raise SystemExit(f'FAIL {mode}: {elapsed:.2f}s {result.stdout} {result.stderr}')
    print(f'PASS RPC {mode}: {elapsed:.2f}s')
