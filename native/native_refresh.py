#!/usr/bin/env python3
"""Native app collector. Only account reads; no inference, reset, or purchases."""
import argparse
import fcntl
import json
from pathlib import Path
import signal
import sys
import time

from bridge import merge, read_account_limits, save


def interrupted(signum, frame):
    raise SystemExit(128 + signum)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, required=True)
    args = parser.parse_args()
    args.state_dir.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, interrupted)
    with (args.state_dir / 'refresh.lock').open('w') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        path = args.state_dir / 'state.json'
        try:
            state = json.loads(path.read_text()) if path.exists() else {}
        except (ValueError, OSError):
            state = {}
        try:
            fresh = read_account_limits()
            state = merge(state, fresh)
            save(path, state)
            save(args.state_dir / 'last-refresh.json', {'ok': True, 'observedAt': fresh['fetchedAt']})
            print(json.dumps({'ok': True, 'observedAt': fresh['fetchedAt']}))
            return 0
        except Exception as error:
            state['error'] = str(error)
            state['attemptedAt'] = time.time()
            save(path, state)
            save(args.state_dir / 'last-refresh.json', {'ok': False, 'attemptedAt': state['attemptedAt'], 'error': str(error)})
            print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
            return 1


if __name__ == '__main__':
    sys.exit(main())
