"""GCWAYS1/GCWAYS2 donation reader. No network, game files or input execution.

python ways_donation.py part-*.txt [--json output.json] [--roundtrip]
Input order is immaterial. Identical repeated parts are ignored. A donation
is a submission for manual review, never a player vote or proof of origin.
GCWAYS1 records: (zone, x, y, Paths direction, count, cost, falls, swims).
GCWAYS2 records: (zone, x, y, Paths direction, quantized cost, fall bit).
"""
import argparse
import json
import re
import zlib
from pathlib import Path

MAX_PART, MAX_PARTS, MAX_TOTAL, PAYLOAD = 20000, 64, 1280000, 19800
HEADER = re.compile(r'(GCWAYS[12])\|([A-Za-z0-9.-]{1,24})\|([0-9a-f]{16})\|([1-9][0-9]?)\|([1-9][0-9]?)\|([0-9a-f]{8})\|([0-9a-f]{8})\n')
INT = re.compile(r'0|[1-9][0-9]*')
ZONE_LINE = re.compile(r'Z([1-9][0-9]{0,4}):([A-Za-z0-9_.-]+)')
ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
DIGITS = {c: i for i, c in enumerate(ALPHABET)}
PATH_DIRS = (0, 1, 2, 3, 5, 6, 7, 8)
COSTS = (100, 150, 200, 300)
GRID, LINE_LIMIT = 1024, 1024

def checksum(text):
    return f'{zlib.adler32(text.encode("ascii")):08x}'

def bodies_v1(records):
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
    return bodies


def chain_steps(records):
    remaining = {}
    for zone, x, y, direction, cost, fall in records:
        key = (y * GRID + x) * 9 + direction
        remaining[zone, key] = ALPHABET[PATH_DIRS.index(direction) * 8 + COSTS.index(cost) * 2 + fall]
    for zone, root in sorted(remaining):
        current, continuing = root, False
        while (zone, current) in remaining:
            cell, direction = divmod(current, 9)
            y, x = divmod(cell, GRID)
            yield zone, x, y, remaining.pop((zone, current)), continuing
            target = ((y + direction // 3 - 1) * GRID + x + direction % 3 - 1) * 9
            for next_dir in PATH_DIRS:
                if (zone, target + next_dir) in remaining:
                    current, continuing = target + next_dir, True
                    break
            else:
                break


def bodies_v2(records):
    bodies, tokens = [], []
    size, line_size, last_zone = 0, 0, None
    for zone, x, y, step, continuing in chain_steps(records):
        word = (x * GRID + y) << 4
        start = ''.join(ALPHABET[(word >> shift) & 63] for shift in (18, 12, 6, 0))
        fresh = f'Z{zone}:{start}{step}'
        token = step if continuing else '.' + start + step
        if zone != last_zone or line_size + len(token) > LINE_LIMIT:
            token = ('\n' if tokens else '') + fresh
            line_size = 0
        if size + len(token) + 1 > PAYLOAD:
            bodies.append(''.join(tokens) + '\n')
            tokens, size, line_size = [], 0, 0
            token = fresh
        tokens.append(token)
        size += len(token)
        last_zone = zone
        line_size += len(token.lstrip('\n'))
    if tokens:
        bodies.append(''.join(tokens) + '\n')
    return bodies


def encode(records, version, donation_id, format='GCWAYS2'):
    """Canonical re-encoding for the record layout of the selected format."""
    bodies = {'GCWAYS1': bodies_v1, 'GCWAYS2': bodies_v2}[format](records)
    whole = checksum(''.join(bodies))
    return [f'{format}|{version}|{donation_id}|{i}|{len(bodies)}|{checksum(body)}|{whole}\n{body}'
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
        format, version, identity, number, count, part_sum, whole_sum = h.groups()
        number, count = int(number), int(count)
        if not 1 <= number <= count <= MAX_PARTS:
            raise ValueError('part count')
        key = format, version, identity, count, whole_sum
        if meta is not None and key != meta:
            raise ValueError('mixed donations')
        meta = key
        if number in seen and seen[number] != text:
            raise ValueError('duplicate part number with different content')
        body = text[h.end():]
        if not body.endswith('\n') or checksum(body) != part_sum:
            raise ValueError('part checksum or missing newline')
        seen[number] = text
    if meta is None:
        raise ValueError('missing parts')
    format, version, identity, count, whole_sum = meta
    if set(seen) != set(range(1, count + 1)):
        raise ValueError('missing parts')
    ordered = [seen[i] for i in range(1, count + 1)]
    if sum(map(len, ordered)) > MAX_TOTAL:
        raise ValueError('total size')
    payload = ''.join(p[HEADER.match(p).end():] for p in ordered)
    if checksum(payload) != whole_sum:
        raise ValueError('whole checksum')
    records = decode_v1(payload) if format == 'GCWAYS1' else decode_v2(payload)
    if not records or encode(records, version, identity, format) != ordered:
        raise ValueError('noncanonical payload or part boundaries')
    return {'format': format, 'addon_version': version, 'donation_id': identity,
            'kind': 'submission_for_manual_review', 'records': records}, ordered


def decode_v1(payload):
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
    return records


def decode_v2(payload):
    records, zones, seen = [], {}, set()
    for line in payload[:-1].split('\n'):
        match = ZONE_LINE.fullmatch(line)
        if len(line) > LINE_LIMIT or not match:
            raise ValueError('zone line')
        zone = int(match[1])
        if zone > 65535:
            raise ValueError('zone')
        for chain in match[2].split('.'):
            if len(chain) < 5:
                raise ValueError('empty or short chain')
            start = 0
            for char in chain[:4]:
                start = start * 64 + DIGITS[char]
            if start & 15:
                raise ValueError('chain start padding')
            x, y = divmod(start >> 4, GRID)
            for char in chain[4:]:
                step = DIGITS[char]
                direction = PATH_DIRS[step >> 3]
                nx, ny = x + direction % 3 - 1, y + direction // 3 - 1
                if not (0 <= nx < GRID and 0 <= ny < GRID):
                    raise ValueError('step outside grid')
                key = zone, x, y, direction
                if key in seen:
                    raise ValueError('duplicate piece')
                seen.add(key)
                records.append((*key, COSTS[(step >> 1) & 3], step & 1))
                zones[zone] = zones.get(zone, 0) + 1
                if len(records) > 30000 or len(zones) > 256 or zones[zone] > 8000:
                    raise ValueError('piece/zone limit')
                x, y = nx, ny
    return records

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
        assert encode(data['records'], data['addon_version'], data['donation_id'], data['format']) == ordered
    if args.json:
        # Explicit output only; never replace an existing file.
        with args.json.open('x', encoding='utf8') as f:
            json.dump(data, f, separators=(',', ':'))
    print(f"OK: {len(data['records'])} pieces, {len(ordered)} parts; submission, not a player vote")

if __name__ == '__main__':
    main()
