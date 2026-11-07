#!/usr/bin/env python3
"""Check the public source set; never print sensitive matching contents."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
excluded = {'dist', '.git', '.swift-module-cache', '__pycache__'}
patterns = [
    re.compile(r'/' + r'Users/[^/\s]+/'),
    re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
    re.compile(r'\bsk-(?:ant-|proj-)[A-Za-z0-9_-]{12,}'),
    re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
    re.compile(r'\bgithub_pat_[A-Za-z0-9_]{20,}'),
]
forbidden = {'state.json', 'history.json', 'seed-state.json', 'claude-state.json', 'last-refresh.json', 'automation.json', 'auth.json', '.env'}
errors = []
paths = [p for p in ROOT.rglob('*') if p.is_file() and not any(part in excluded for part in p.relative_to(ROOT).parts)]
for path in paths:
    if path.name in forbidden:
        errors.append(f'Private runtime file: {path.relative_to(ROOT)}')
    if path.suffix in {'.gif', '.png', '.icns'}:
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        errors.append(f'Unexpected binary: {path.relative_to(ROOT)}')
        continue
    if any(pattern.search(text) for pattern in patterns):
        errors.append(f'Potential private content: {path.relative_to(ROOT)}')
if (ROOT / '.git').exists():
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    for name in filter(None, tracked):
        p = Path(name)
        if p.name in forbidden or any(part in excluded for part in p.parts):
            errors.append(f'Forbidden tracked path: {name}')
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print(f'PASS: checked {len(paths)} publication files; no private runtime files or matching credential patterns.')
