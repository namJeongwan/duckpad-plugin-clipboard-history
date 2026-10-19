#!/usr/bin/env python3
"""Validate every packaged locale, including the image-search label."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('en', 'ko', 'ja', 'zh-Hans', 'de', 'fr', 'it', 'pt-BR')
STRING = r'"(?:\\.|[^"\\])*"'
ENTRY = re.compile(rf'({STRING})\s*=\s*({STRING})\s*;')
FORMAT = re.compile(r'%(?:(\d+)\$)?(ld|lu|lld|llu|@|d|u|f)')


def read(path):
    source = re.sub(r'/\*.*?\*/', '', path.read_text(), flags=re.S)
    result = {}
    for match in ENTRY.finditer(source):
        key, value = map(json.loads, match.groups())
        assert key not in result and value, f'{path}: duplicate or empty key {key}'
        result[key] = value
    assert not ENTRY.sub('', source).strip(), f'{path}: malformed .strings'
    return result


def main():
    resources = ROOT / 'native/Resources'
    tables = {language: read(resources / f'locale-{language}.strings') for language in LANGUAGES}
    english = tables['en']
    assert 'Image' in english, 'Localized image search needs an explicit image label'
    for language, table in tables.items():
        assert table.keys() == english.keys(), f'{language}: missing or extra keys'
        for key, value in table.items():
            assert FORMAT.findall(value) == FORMAT.findall(english[key]), f'{language}: format mismatch for {key}'
    calls = re.compile(rf'(?:\.text|localized)\(\s*({STRING})')
    for path in (ROOT / 'native/Sources').glob('*.swift'):
        for match in calls.finditer(path.read_text()):
            assert json.loads(match[1]) in english, f'{path}: uncataloged key {match[1]}'
    print(f'PASS: {len(english)} localized keys and matching formats in all eight plugin languages')


if __name__ == '__main__':
    main()
