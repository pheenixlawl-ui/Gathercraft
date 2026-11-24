"""Run with the 30,000-step Lua fixture and optional legacy fixture directory."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('codec', Path(__file__).with_name('ways_donation.py'))
codec = importlib.util.module_from_spec(spec); spec.loader.exec_module(codec)
parts = [p.read_text(encoding='ascii') for p in sorted(Path(sys.argv[1]).glob('part-*.txt'))]
assert parts
data, ordered = codec.decode(reversed(parts))
assert data['format'] == 'GCWAYS2'
expected = set()
for zone, count in zip(range(1401, 1405), (8000, 8000, 8000, 6000)):
    for i in range(count):
        row, col = divmod(i, 1000)
        east = row % 2 == 0
        x = col if east else 999 - col
        direction = 7 if col == 999 else 5 if east else 3
        expected.add((zone, x, row + 1, direction, 300, 1))
assert len(data['records']) == len(expected) == 30000
assert set(data['records']) == expected
assert codec.encode(data['records'], data['addon_version'], data['donation_id']) == ordered
assert codec.decode(parts + [parts[0]])[0] == data
assert codec.decode([p.replace('\n','\r\n') for p in parts])[0] == data

def bad(values, reason):
    try:
        codec.decode(values)
    except ValueError as error:
        assert str(error) == reason, (error, reason)
        print('caught:', reason)
        return
    raise AssertionError('accepted: ' + reason)

changed = parts[0].replace('Z', 'X', 1)
bad([changed] + parts[1:], 'part checksum or missing newline')
bad(parts + [changed], 'duplicate part number with different content')
bad(parts[1:], 'missing parts')
bad(['x'*20001], 'part length or character set')
bad([parts[0].replace('GCWAYS2', 'GCWAYS3', 1)] + parts[1:], 'invalid header')
bad([parts[0].replace('GCWAYS2', 'GCWAYS1', 1)] + parts[1:], 'mixed donations')
bad([parts[0].replace(data['donation_id'], 'ffffffffffffffff', 1)] + parts[1:], 'mixed donations')
bad([part[:codec.HEADER.match(part).end()-9] + '00000000\n'
     + part[codec.HEADER.match(part).end():] for part in parts], 'whole checksum')


def wrap(body):
    checksum = codec.checksum(body)
    return [f'GCWAYS2|0.2.3-a13|0123456789abcdef|1|1|{checksum}|{checksum}\n{body}']


sample = wrap('Z1434:AoFAg\n')
assert codec.decode(sample)[0]['records'] == [(1434, 10, 20, 5, 100, 0)]
bad(wrap('Z1434:AoFBg\n'), 'chain start padding')
bad(wrap('Z1434:___wg\n'), 'step outside grid')
bad(wrap('Z1434:AoFAg..AoFAg\n'), 'empty or short chain')
bad(wrap('Z1434:AoFAg.AoFAg\n'), 'duplicate piece')
bad(wrap('Z1434:AoFAg.AsFAg\n'), 'noncanonical payload or part boundaries')
bad(wrap('Z1434:AoFAg;\n'), 'zone line')
bad(wrap('Z1434:AoFA' + 'g'*1015 + '\n'), 'zone line')
bad(wrap('Z65536:AoFAg\n'), 'zone')

if len(sys.argv) > 2:
    legacy = [p.read_bytes().decode('ascii') for p in Path(sys.argv[2]).glob('part-*.txt')]
    old, old_ordered = codec.decode(legacy)
    assert old['format'] == 'GCWAYS1' and len(old['records']) == 30000
    assert codec.encode(old['records'], old['addon_version'], old['donation_id'], old['format']) == old_ordered
    print('PASS: existing GCWAYS1 fixtures still decode and roundtrip')
print('PASS: all 30,000 quantized records match the Lua fixture, roundtrip, CRLF and invalid inputs')
