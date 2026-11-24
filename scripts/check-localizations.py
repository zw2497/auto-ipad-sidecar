#!/usr/bin/env python3
"""Check translation coverage and format arguments without touching the user account."""
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]

def catalog(language):
    text = (root / 'app/Resources' / f'{language}.lproj/Localizable.strings').read_text()
    pairs = re.findall(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', text)
    return {json.loads(key): json.loads(value) for key, value in pairs}

en, zh = catalog('en'), catalog('zh-Hans')
assert en.keys() == zh.keys(), 'Translation keys differ'
for key in en:
    placeholders = lambda value: re.findall(r'%(?:\d+\$)?[@df]', value)
    assert placeholders(en[key]) == placeholders(zh[key]), f'Format mismatch: {key}'
for path in (root / 'app').glob('*.swift'):
    keys = re.findall(r'\bLF?\(("(?:\\.|[^"\\])*")', path.read_text())
    for raw in keys:
        key = json.loads(raw)
        assert key in en, f'Missing key: {key}'
print(f'PASS: {len(en)} localized strings, source coverage, and matching format arguments')
