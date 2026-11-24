"""Run with a directory of Lua-produced part-N.txt files (30,000 pieces)."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('codec', Path(__file__).with_name('ways_donation.py'))
codec = importlib.util.module_from_spec(spec); spec.loader.exec_module(codec)
parts = [p.read_text(encoding='ascii') for p in sorted(Path(sys.argv[1]).glob('part-*.txt'))]
assert parts
data, ordered = codec.decode(reversed(parts))
assert len(data['records']) == 30000
assert codec.encode(data['records'], data['addon_version'], data['donation_id']) == ordered
assert codec.decode(parts + [parts[0]])[0] == data
assert codec.decode([p.replace('\n','\r\n') for p in parts])[0] == data

def bad(values, reason):
    try:
        codec.decode(values)
    except ValueError:
        print('caught:', reason)
        return
    raise AssertionError('accepted: ' + reason)

changed = parts[0].replace('E,', 'X,', 1)
bad([changed] + parts[1:], 'changed byte / part checksum')
bad(parts + [changed], 'conflicting duplicate part')
bad(parts[1:], 'missing part')
bad(['x'*20001], 'oversized part')
bad([parts[0].replace('GCWAYS1', 'GCWAYS2', 1)] + parts[1:], 'unknown format')
bad([parts[0].replace(data['donation_id'], 'ffffffffffffffff', 1)] + parts[1:], 'mixed donation')
h = codec.HEADER.match(parts[0]); fields = h.group().rstrip('\n').split('|')
fields[-1] = '00000000'
bad(['|'.join(fields)+'\n'+parts[0][h.end():]]+parts[1:], 'whole checksum disagreement')
altered = [tuple(r) for r in data['records']]
altered[0] = (altered[0][0], 1024, *altered[0][2:])
bad(codec.encode(altered,data['addon_version'],data['donation_id']), 'coordinate beyond grid with valid checksums')
altered = [data['records'][0], *data['records']]
bad(codec.encode(altered,data['addon_version'],data['donation_id']), 'duplicate piece with valid checksums')
print('PASS: roundtrip, shuffled/identical duplicate/CRLF parts, nine invalid cases')
