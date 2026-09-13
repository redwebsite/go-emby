#!/usr/bin/env python3
"""Check tracked files without printing secret values. Not a substitute for review."""
import ipaddress
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
problems = []
ip_pattern = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
patterns = [
    re.compile(r'gh[pousr]_[A-Za-z0-9]{30,}'),
    re.compile(r'github_pat_[A-Za-z0-9_]{30,}'),
    re.compile(r'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----'),
    re.compile(r'https?://[^\s/@]+:[^\s/@]+@'),
]
for name in filter(None, files):
    p = root / name
    if not p.is_file():
        continue
    if (p.name.startswith('.env') and p.name != '.env.example') or p.name.endswith('.env') or 'credentials' in p.name.lower() or '.key.' in p.name or any(
        part in {'secrets', 'data', 'backups', 'node_modules', '.cache'} for part in p.parts
    ) or p.suffix in {'.key', '.pem', '.crt', '.p12', '.pfx', '.dump', '.db', '.log', '.bak', '.zip', '.gz'}:
        problems.append((name, 'excluded file type/path'))
    content = p.read_text(errors='replace')
    for pattern in patterns:
        if pattern.search(content):
            problems.append((name, 'possible credential'))
    ip_content = re.sub(r'"Version":\s*"[0-9.]+"', '"Version":""', content)
    for value in ip_pattern.findall(ip_content):
        try:
            address = ipaddress.ip_address(value)
        except ValueError:
            continue
        if address.is_global:
            problems.append((name, 'public IP literal'))
for name, reason in sorted(set(problems)):
    print(f'{name}: {reason}')
print(f'Public-file audit: {len(list(filter(None, files)))} files, {len(set(problems))} findings')
sys.exit(bool(problems))
