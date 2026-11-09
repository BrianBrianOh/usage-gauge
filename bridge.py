#!/usr/bin/env python3
"""Read-only Codex account allowance snapshots; never starts an inference turn."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent


class UsageReadError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def read_account_limits(timeout=25):
    binary = shutil.which('codex')
    if not binary:
        candidates = [
            '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
            '/Applications/Codex.app/Contents/Resources/codex',
        ]
        binary = next((p for p in candidates if Path(p).is_file()), None)
    if not binary:
        raise RuntimeError('Codex executable not found. Install the CLI or desktop app.')
    proc = subprocess.Popen([binary, 'app-server', '--stdio'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    buffer = b''
    account = None
    limits = None
    def send(value):
        proc.stdin.write((json.dumps(value) + '\n').encode())
        proc.stdin.flush()
    try:
        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'usage_gauge', 'title': 'Usage Gauge', 'version': '0.1.0'}}})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not selector.select(0.25):
                if proc.poll() is not None:
                    raise RuntimeError('Codex exited before reporting usage. Check its sign-in.')
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError('Codex closed the usage connection.')
            buffer += chunk
            while b'\n' in buffer:
                raw, buffer = buffer.split(b'\n', 1)
                try:
                    message = json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    continue
                if 'method' in message and 'id' in message:
                    # This observer never grants permissions or handles auth secrets.
                    send({'id': message['id'], 'error': {'code': -32601, 'message': 'Read-only observer'}})
                    continue
                if message.get('id') in (1, 2, 3) and 'error' in message:
                    raise RuntimeError('Codex could not read usage. Check its sign-in.')
                if message.get('id') == 1:
                    send({'method': 'initialized', 'params': {}})
                    send({'id': 2, 'method': 'account/read', 'params': {'refreshToken': False}})
                    send({'id': 3, 'method': 'account/rateLimits/read'})
                elif message.get('id') == 2:
                    account = message.get('result', {}).get('account') or {}
                    if not account:
                        raise UsageReadError('auth_required', 'Sign in to Codex to read subscription usage.')
                elif message.get('id') == 3:
                    limits = message.get('result', {})
                if account is not None and limits is not None:
                    identity = json.dumps(account, sort_keys=True)
                    return normalize(limits, time.time(), hashlib.sha256(identity.encode()).hexdigest()[:16])
        raise RuntimeError('Codex usage request timed out.')
    finally:
        selector.close()
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def normalize(raw, now, account_key):
    buckets = raw.get('rateLimitsByLimitId')
    if not isinstance(buckets, dict) or not buckets:
        legacy = raw.get('rateLimits')
        buckets = {legacy.get('limitId') or 'codex': legacy} if isinstance(legacy, dict) else {}
    windows = []
    invalid = False
    for bucket_id, bucket in buckets.items():
        if not isinstance(bucket, dict):
            continue
        for slot in ('primary', 'secondary'):
            window = bucket.get(slot)
            if not isinstance(window, dict):
                continue
            used, duration, reset = [window.get(k) for k in ('usedPercent', 'windowDurationMins', 'resetsAt')]
            if not all(isinstance(v, (float, int)) and not isinstance(v, bool) for v in (used, duration, reset)):
                invalid = True
                continue
            if not all(math.isfinite(v) for v in (used, duration, reset)) or duration <= 0 or reset <= 0:
                invalid = True
                continue
            windows.append({'id': bucket_id + ':' + slot,
                            'name': bucket.get('limitName') or bucket_id,
                            'durationMinutes': duration, 'resetAt': reset,
                            'remaining': max(0, min(100, 100 - used)), 'observedAt': now})
    if not windows:
        raise UsageReadError('invalid_data' if invalid else 'no_limits', 'Invalid subscription usage data.' if invalid else 'No subscription usage limits are available.')
    return {'accountKey': account_key, 'fetchedAt': now, 'windows': windows, 'error': None, 'errorCode': None}


def merge(state, fresh):
    same_account = state.get('accountKey') == fresh['accountKey']
    previous = {x['id']: x for x in state.get('windows', [])} if same_account else {}
    for window in fresh['windows']:
        old = previous.get(window['id'], {})
        same_cycle = old.get('resetAt') == window['resetAt'] and old.get('durationMinutes') == window['durationMinutes']
        points = list(old.get('points', [])) if same_cycle else []
        start = window['resetAt'] - window['durationMinutes'] * 60
        points = [p for p in points if start <= p['t'] <= fresh['fetchedAt']]
        points.append({'t': fresh['fetchedAt'], 'remaining': window['remaining']})
        # Keep last observation per 10-minute bin, plus the first sample.
        bins = {int(p['t'] // 600): p for p in sorted(points, key=lambda p: p['t'])}
        compact = sorted(bins.values(), key=lambda p: p['t'])
        if points and compact and points[0]['t'] < compact[0]['t']:
            compact.insert(0, points[0])
        window['points'] = compact
    return fresh


def save(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False))
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, default=ROOT)
    args = parser.parse_args()
    target = args.state_dir
    target.mkdir(parents=True, exist_ok=True)
    path = target / 'state.json'
    try:
        state = json.loads(path.read_text()) if path.exists() else {}
    except (ValueError, OSError):
        state = {}
    try:
        fresh = read_account_limits()
        result = merge(state, fresh)
        save(path, result)
        print(json.dumps({'ok': True, 'windows': [{k:v for k,v in w.items() if k != 'points'} for w in result['windows']]}))
    except Exception as error:
        state['error'] = str(error)
        state['errorCode'] = getattr(error, 'code', 'unavailable')
        state['attemptedAt'] = time.time()
        save(path, state)
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
