#!/usr/bin/env python3
"""Read-only Claude plan limits via Claude Code's get_usage request; never starts a model turn."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import time

CANDIDATES = ('~/.local/bin/claude', '~/.claude/local/claude', '/opt/homebrew/bin/claude', '/usr/local/bin/claude')
REQUEST_ID = 'usage-gauge'


class UsageUnavailable(RuntimeError):
    """A temporary transport or service failure, eligible for one bounded retry."""


class AuthenticationRequired(RuntimeError):
    code = 'auth_required'


def find_claude():
    found = shutil.which('claude')
    if found:
        return found
    for candidate in CANDIDATES:
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def organization():
    # Only the organization id is read, to keep history per account; tokens stay with Claude Code.
    config_dir = os.environ.get('CLAUDE_CONFIG_DIR')
    paths = ([Path(config_dir) / '.claude.json'] if config_dir else []) + [Path.home() / '.claude.json']
    for path in paths:
        try:
            account = json.loads(path.read_text()).get('oauthAccount') or {}
        except (OSError, ValueError, AttributeError):
            continue
        value = account.get('organizationUuid')
        if isinstance(value, str) and value:
            return value
    return None


def read_usage(cwd, timeout=30):
    binary = find_claude()
    if not binary:
        raise RuntimeError('Claude Code is not installed.')
    # No prompt is ever sent: the control request is answered without a model call.
    proc = subprocess.Popen([binary, '-p', '--input-format', 'stream-json', '--output-format', 'stream-json',
                             '--verbose', '--no-session-persistence', '--strict-mcp-config',
                             '--setting-sources', 'project'],
                            cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    buffer = b''
    try:
        request = {'type': 'control_request', 'request_id': REQUEST_ID,
                   'request': {'subtype': 'get_usage', 'skip_behaviors': True}}
        proc.stdin.write((json.dumps(request) + '\n').encode())
        proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not selector.select(0.25):
                if proc.poll() is not None:
                    raise UsageUnavailable('Claude Code exited before reporting usage. Update Claude Code or try again.')
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise UsageUnavailable('Claude Code closed the usage connection.')
            buffer += chunk
            while b'\n' in buffer:
                raw, buffer = buffer.split(b'\n', 1)
                try:
                    message = json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    continue
                response = message.get('response') if message.get('type') == 'control_response' else None
                if not isinstance(response, dict) or response.get('request_id') != REQUEST_ID:
                    continue
                if response.get('subtype') != 'success':
                    raise UsageUnavailable('Claude Code could not read usage. Update Claude Code or try again.')
                return response.get('response') or {}
        raise UsageUnavailable('Claude Code usage request timed out.')
    finally:
        selector.close()
        try:
            proc.stdin.close()
        except OSError:
            pass
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def collect_usage(cwd, attempts=2):
    account = organization()
    if not account:
        raise AuthenticationRequired('Claude Code account is unknown. Run claude and sign in.')
    for attempt in range(attempts):
        try:
            result = read_usage(cwd)
            limits = result.get('rate_limits')
            if not result.get('rate_limits_available') or not isinstance(limits, dict):
                # An unavailable response can be a provider failure, not a signed-out account.
                raise UsageUnavailable('Claude usage is temporarily unavailable. Try again; if it persists, update Claude Code and check its sign-in.')
            if organization() != account:
                raise RuntimeError('Claude account changed during the read. Refresh again.')
            return {'ok': True, 'organization': account, 'plan': result.get('subscription_type'), 'usage': limits}
        except UsageUnavailable:
            if attempt + 1 == attempts:
                raise
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cwd', type=Path, default=Path.home())
    args = parser.parse_args()
    try:
        print(json.dumps(collect_usage(args.cwd)))
        return 0
    except Exception as error:
        print(json.dumps({'ok': False, 'error': str(error), 'errorCode': getattr(error, 'code', 'unavailable')}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
