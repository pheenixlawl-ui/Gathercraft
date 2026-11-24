"""GCWAYS1 donation reader. No network, no game files, no execution of input.

python ways_donation.py part-*.txt [--json output.json] [--roundtrip]
Input order is immaterial. Identical repeated parts are ignored. A donation
is a submission for manual review, never a player vote or proof of origin.
"""
import argparse
import json
import re
import zlib
from pathlib import Path

MAX_PART, MAX_PARTS, MAX_TOTAL, PAYLOAD = 20000, 64, 1280000, 19800
HEADER = re.compile(r'GCWAYS1\|([A-Za-z0-9.-]{1,24})\|([0-9a-f]{16})\|([1-9][0-9]?)\|([1-9][0-9]?)\|([0-9a-f]{8})\|([0-9a-f]{8})\n')
INT = re.compile(r'0|[1-9][0-9]*')

def checksum(text):
    return f'{zlib.adler32(text.encode("ascii")):08x}'

def encode(records, version, donation_id):
    """Canonical re-encoding, including repeated zone at every part start."""
    bodies, lines, size, zone = [], [], 0, None
    for r in records:
        z, x, y, d, n, cost, falls, swims = r
        prefix = f'Z,{z}\n' if zone != z else ''
        line = f'E,{x},{y},{d},{n},{cost},{falls},{swims}\n'
        if size + len(prefix) + len(line) > PAYLOAD:
            bodies.append(''.join(lines)); lines, size, zone = [], 0, None
            prefix = f'Z,{z}\n'
        lines.extend((prefix, line)); size += len(prefix) + len(line); zone = z
    if lines:
        bodies.append(''.join(lines))
    whole = checksum(''.join(bodies))
    return [f'GCWAYS1|{version}|{donation_id}|{i}|{len(bodies)}|{checksum(body)}|{whole}\n{body}'
            for i, body in enumerate(bodies, 1)]

def decode(parts):
    seen, meta, total_input = {}, None, 0
    for raw in parts:
        # Text editors may change LF to CRLF. Nothing else is normalized.
        if len(raw) > MAX_PART * 2:
            raise ValueError('part too long')
        text = raw.replace('\r\n', '\n')
        total_input += len(text)
        if total_input > MAX_TOTAL * 2:
            raise ValueError('input limit (including duplicate parts)')
        if len(text) > MAX_PART or not text.isascii() or '\r' in text:
            raise ValueError('part length or character set')
        h = HEADER.match(text)
        if not h:
            raise ValueError('invalid header')
        version, identity, number, count, part_sum, whole_sum = h.groups()
        number, count = int(number), int(count)
        if not 1 <= number <= count <= MAX_PARTS:
            raise ValueError('part count')
        key = version, identity, count, whole_sum
        if meta is not None and key != meta:
            raise ValueError('mixed donations')
        meta = key
        if number in seen and seen[number] != text:
            raise ValueError('duplicate part number with different content')
        body = text[h.end():]
        if not body.endswith('\n') or checksum(body) != part_sum:
            raise ValueError('part checksum or missing newline')
        seen[number] = text
    if meta is None or set(seen) != set(range(1, meta[2] + 1)):
        raise ValueError('missing parts')
    ordered = [seen[i] for i in range(1, meta[2] + 1)]
    if sum(map(len, ordered)) > MAX_TOTAL:
        raise ValueError('total size')
    payload = ''.join(p[HEADER.match(p).end():] for p in ordered)
    if checksum(payload) != meta[3]:
        raise ValueError('whole checksum')
    records, zones, previous, zone = [], {}, None, None
    for line in payload.splitlines():
        fields = line.split(',')
        if any(len(s) > 5 or not INT.fullmatch(s) for s in fields[1:]):
            raise ValueError('noncanonical integer')
        if fields[0] == 'Z' and len(fields) == 2:
            zone = int(fields[1])
            if not 1 <= zone <= 65535:
                raise ValueError('zone')
        elif fields[0] == 'E' and len(fields) == 8 and zone is not None:
            x, y, d, n, cost, falls, swims = map(int, fields[1:])
            if not (0 <= x < 1024 and 0 <= y < 1024 and 0 <= d < 9 and d != 4
                    and 1 <= n <= 255 and 0 <= cost <= 1023 and 0 <= falls <= n and 0 <= swims <= n
                    and 0 <= x + d % 3 - 1 < 1024 and 0 <= y + d // 3 - 1 < 1024):
                raise ValueError('piece bounds')
            key = zone, (y * 1024 + x) * 9 + d
            if previous is not None and key <= previous:
                raise ValueError('duplicate or unsorted piece')
            previous = key
            records.append((zone, x, y, d, n, cost, falls, swims))
            zones[zone] = zones.get(zone, 0) + 1
            if len(records) > 30000 or len(zones) > 256 or zones[zone] > 8000:
                raise ValueError('piece/zone limit')
        else:
            raise ValueError('record type/length')
    if not records or encode(records, meta[0], meta[1]) != ordered:
        raise ValueError('noncanonical payload or part boundaries')
    return {'format': 'GCWAYS1', 'addon_version': meta[0], 'donation_id': meta[1],
            'kind': 'submission_for_manual_review', 'records': records}, ordered

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('parts', nargs='+', type=Path)
    parser.add_argument('--json', type=Path)
    parser.add_argument('--roundtrip', action='store_true')
    args = parser.parse_args()
    def inputs():
        for p in args.parts:
            if p.stat().st_size > MAX_PART * 2:
                raise ValueError('file too large')
            yield p.read_bytes().decode('ascii')
    data, ordered = decode(inputs())
    if args.roundtrip:
        assert encode(data['records'], data['addon_version'], data['donation_id']) == ordered
    if args.json:
        # Explicit output only; never replace an existing file.
        with args.json.open('x', encoding='utf8') as f:
            json.dump(data, f, separators=(',', ':'))
    print(f"OK: {len(data['records'])} pieces, {len(ordered)} parts; submission, not a player vote")

if __name__ == '__main__':
    main()
