"""Tests for ways_donation_review.py: no network, no game files, only temporary folders.

  python -I tools/test_ways_donation_review.py [--own-export DIR --own-sv FILE [--sizes F] [--sizes-estimated F]]

With --own-export (the part files of a donation made by tools/ways_donation_export.lua
from a COPY of a SavedVariables backup) and --own-sv (that same copy) the round trip
with real data runs too: the review reads the export like a donation from the form and
must find exactly the pieces of the copy, quantized as the format says. With --sizes
(conversion.json) also the whole review of it: all of it Sven's, no edge piece, no flag.
"""
import csv
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


codec = load('codec', 'ways_donation.py')
review = load('review', 'ways_donation_review.py')

PATH_DIRS = (0, 1, 2, 3, 5, 6, 7, 8)
E, W, N, S = 5, 3, 1, 7          # Paths directions: dx = d % 3 - 1, dy = d // 3 - 1 (north = y - 1)
IDS = ['0123456789abcdef', 'fedcba9876543210', '00000000deadbeef', '1111222233334444', 'aaaabbbbccccdddd']
TODAY = '2026-11-26'
FAILS = []


def check(cond, what):
    if not cond:
        FAILS.append(what)
        print('FAIL', what)
    else:
        print('ok  ', what)


def run_tool(base, *extra, today=TODAY, own=None):
    args = ['--eingang', str(base / 'eingang'), '--pruefung', str(base / 'pruefung'), '--grundnetz', str(base / 'grundnetz'),
            '--sizes', str(base / 'sizes.json'), '--today', today]
    if own:
        args += ['--own', str(own)]
    out = io.StringIO()
    code = review.main(args + list(extra), out=out)
    return code, out.getvalue()


def fresh():
    base = Path(tempfile.mkdtemp(prefix='gc_review_'))
    for d in ('eingang', 'pruefung', 'grundnetz'):
        (base / d).mkdir()
    # zone 1434: 3000 x 2000 yd -> 120 x 80 squares; 1999 has no size
    sizes = {'geometry': {'transforms': [
        {'ui_map_id': 1434, 'target_name': 'Stranglethorn Vale', 'target_bounds': {'left': 0, 'right': 3000, 'top': 0, 'bottom': 2000}},
        {'ui_map_id': 1440, 'target_name': 'Ashenvale', 'target_bounds': {'left': 0, 'right': 1000, 'top': 0, 'bottom': 1000}}]}}
    (base / 'sizes.json').write_text(json.dumps(sizes), encoding='utf-8')
    return base


def walk(zone, x, y, dirs, cost=100, falls=()):
    """records along a walk: one piece per step, (zone, x, y, Paths dir, cost, fall bit)"""
    out = []
    for i, d in enumerate(dirs):
        out.append((zone, x, y, d, cost, 1 if i in falls else 0))
        x, y = x + d % 3 - 1, y + d // 3 - 1
    return out


def parts_of(records, ident, version='0.2.3'):
    return codec.encode(sorted(set(records)), version, ident)


def report_text(base):
    return (base / 'pruefung' / (TODAY + '_pruefbericht.md')).read_text(encoding='utf-8')


def png_info(path, map_from=58):
    """width, height and the colours of the map area (below the label and legend, which hold every colour)"""
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'signature'
    pos, idat, w = 8, b'', None
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        assert zlib.crc32(kind + chunk) & 0xffffffff == struct.unpack('>I', data[pos + 8 + n:pos + 12 + n])[0], 'crc'
        if kind == b'IHDR':
            w, h, depth, colour = struct.unpack('>IIBB', chunk[:10])
            assert depth == 8 and colour == 2
        elif kind == b'IDAT':
            idat += chunk
        pos += 12 + n
    raw = zlib.decompress(idat)
    colours = set()
    stride = 1 + 3 * w
    for row in range(h):
        line = raw[row * stride:(row + 1) * stride]
        assert line[0] == 0
        if row >= map_from:
            for i in range(1, len(line), 3):
                colours.add(line[i:i + 3])
    return w, h, colours


def sv_text(zones):
    """a small SavedVariables file in the client's style, with other data around paths"""
    lines = ['', 'GathercraftDB = {', '["profileKeys"] = {', '["Testspieler - Testrealm"] = "Default",', '},',
             '["notes"] = "say \\"hi\\"\\n -- not a comment",', '["list"] = {', '"a", -- [1]', '"b", -- [2]', '},',
             '["paths"] = {', '["zones"] = {']
    for zone, edges in zones.items():
        lines += ['[%d] = {' % zone, '["e"] = {']
        lines += ['[%d] = %d,' % (k, v) for k, v in edges.items()]
        lines += ['},', '},']
    lines += ['},', '["version"] = 3,', '},', '["float"] = 1.5e+3,', '["neg"] = -7,', '["flag"] = true,', '}', '']
    return '\n'.join(lines)


def value(count, cost, falls=0, swims=0, day=12000):      # the day field has 14 bits
    return (((swims * 256 + falls) * 1024 + cost) * 256 + count) * 16384 + day


def key(x, y, d):
    return (y * 1024 + x) * 9 + d


# ---------------------------------------------------------------- the SavedVariables reader
def t_sv_reader():
    base = fresh()
    sv = base / 'sv.lua'
    sv.write_text(sv_text({1434: {key(10, 20, E): value(3, 100), key(11, 20, E): value(2, 260, falls=2)}}), encoding='utf-8')
    data = review.read_sv(sv)
    check(data['GathercraftDB']['notes'] == 'say "hi"\n -- not a comment', 'SV reader: strings with escapes and a "--" inside')
    check(data['GathercraftDB']['list'] == {1: 'a', 2: 'b'}, 'SV reader: list entries with their "-- [n]" comments')
    check(data['GathercraftDB']['float'] == 1500.0 and data['GathercraftDB']['neg'] == -7 and data['GathercraftDB']['flag'] is True,
          'SV reader: numbers and booleans')
    own = review.own_ways(sv)
    check(own == {(1434, 10, 20, E): (100, 0), (1434, 11, 20, E): (300, 1)},
          'own ways: quantized like the donation (cost 260 -> 300, all rides with a fall -> fall bit)')
    shutil.rmtree(base)


# ---------------------------------------------------------------- reading, assembling, rejecting
def t_txt_and_edges():
    base = fresh()
    records = walk(1434, 10, 10, [E] * 20, falls={5}) + walk(1434, 118, 40, [E, E])   # 119 -> 120 is off the grid
    records += walk(1999, 5, 5, [S] * 3)                                                  # a zone without a size
    (base / 'eingang' / 'spende-a.txt').write_text(''.join(parts_of(records, IDS[0])), encoding='ascii')
    code, out = run_tool(base)
    text = report_text(base)
    check(code == 0, 'review: exit 0')
    check('## Nr. 1' in text, 'review: the donation has number 1')
    check(re.search(r'Randstücke[^\n]*\b1\b', text) is not None, 'review: one edge piece sorted out (119 -> 120 off a 120-square grid)')
    check('1999' in text and 'Größe unbekannt' in text, 'review: zone without size named')
    for i in IDS:
        check(i not in text and i not in out, 'review: export id %s nowhere in report or output' % i)
    check('0.2.3' not in text, 'review: the addon version is not shown either')
    imgs = sorted((base / 'pruefung').glob(TODAY + '_bilder/nr1_zone*.png'))
    check([p.name for p in imgs] == ['nr1_zone1434.png', 'nr1_zone1999.png'], 'pictures: one PNG per zone of the donation')
    w, h, colours = png_info(imgs[0])
    check(review.COLOURS['spende'] in colours and review.COLOURS['sturz'] in colours and review.COLOURS['rand'] in colours,
          'picture: donation, fall and edge piece colours drawn')
    check((base / 'eingang' / 'spende-a.txt').exists(), 'review deletes nothing in eingang')
    check(not any((base / 'grundnetz').iterdir()), 'review writes nothing into grundnetz')
    shutil.rmtree(base)


def big_records():
    # 4,680 single north steps on every second row of zone 1434 (120 x 80): each its own chain -> two parts
    return [(1434, x, y, N, 100, 0) for y in range(2, 80, 2) for x in range(120)]


def t_csv_two_parts_and_damage():
    base = fresh()
    parts = parts_of(big_records(), IDS[1])
    check(len(parts) == 2, 'fixture: the big donation has two parts')
    rows = [['Zeitstempel', 'Name im Spiel', 'Deine Wege']]
    # Forms: CRLF line ends, the last LF of a part trimmed, parts in two answers, other columns around
    rows.append(['26.11.2026 10:00:00', 'Testspieler-Testrealm', parts[1].replace('\n', '\r\n').rstrip('\r\n')])
    rows.append(['26.11.2026 10:01:00', 'Testspieler-Testrealm', '  ' + parts[0].rstrip('\n') + '  '])
    buf = io.StringIO()
    csv.writer(buf).writerows(rows)
    (base / 'eingang' / 'formular.csv').write_text(buf.getvalue(), encoding='utf-8')
    # broken: one character of the body changed
    broken = parts_of(walk(1434, 30, 30, [N] * 10), IDS[2])[0]
    head, body = broken.split('\n', 1)
    body = body[:6] + ('A' if body[6] != 'A' else 'B') + body[7:]
    (base / 'eingang' / 'kaputt.txt').write_text(head + '\n' + body, encoding='ascii')
    # incomplete: only part 1 of 2
    other = parts_of([(z, x, y + 1, d, c, f) for z, x, y, d, c, f in big_records() if y < 70], IDS[3])
    (base / 'eingang' / 'halb.txt').write_text(other[0], encoding='ascii')
    code, out = run_tool(base)
    text = report_text(base)
    check('abgelehnt: Teil-Prüfsumme stimmt nicht' in text, 'damaged part -> "abgelehnt: Teil-Prüfsumme stimmt nicht"')
    check('abgelehnt: unvollständig, Teil 2 von 2 fehlt' in text, 'missing part -> "abgelehnt: unvollständig, Teil 2 von 2 fehlt"')
    check('4.680 in 1 Zonen' in text, 'CSV: two parts in two answers, CRLF and trimmed ends -> 4,680 pieces')
    for bad in ('26.11.2026 10:0', 'Testspieler', 'Testrealm', 'Zeitstempel'):
        check(bad not in text and bad not in out and bad not in (base / 'pruefung' / 'stand.json').read_text(encoding='utf-8'),
              'CSV: "%s" (another column) is not in the report or the state' % bad)
    shutil.rmtree(base)


# ---------------------------------------------------------------- duplicates, accept, reject, the base net
def t_duplicate_accept_reject():
    base = fresh()
    a = walk(1434, 10, 10, [E] * 10, cost=100, falls={5, 6}) + walk(1434, 119, 50, [E])     # with one edge piece
    a += walk(1999, 1, 1, [S, S])                                                           # zone without size
    b = walk(1434, 15, 10, [E] * 10, cost=300, falls={0})                                   # overlaps a on 5 pieces
    (base / 'eingang' / '1.txt').write_text(''.join(parts_of(a, IDS[0])), encoding='ascii')
    (base / 'eingang' / '2.txt').write_text(''.join(parts_of(a, IDS[1], version='0.2.4-a8')), encoding='ascii')   # same content, new id
    (base / 'eingang' / '3.txt').write_text(''.join(parts_of(b, IDS[2])), encoding='ascii')
    code, out = run_tool(base)
    text = report_text(base)
    check('## Nr. 1' in text and '## Nr. 2' in text and '## Nr. 3' in text, 'three submissions, three numbers')
    check('Duplikat von Nr. 1' in text, 'same content with a new export id -> "Duplikat von Nr. 1"')
    code, out = run_tool(base, '--accept', '2')
    check(code != 0 and 'Duplikat' in out and not (base / 'grundnetz' / 'grundnetz.json').exists(),
          'accepting the duplicate is refused, nothing written')
    code, out = run_tool(base, '--accept', '1')
    check(code == 0 and 'Rohtext Nr. 1 kann gelöscht werden (Formular und eingang)' in out, 'accept 1: the deletion notice')
    net = json.loads((base / 'grundnetz' / 'grundnetz.json').read_text(encoding='utf-8'))
    pieces = net['zonen']['1434']
    check(len(pieces) == 10 and '1999' not in net['zonen'], 'accept: 10 pieces, no edge piece, nothing of the zone without size')
    k0 = str(key(10, 10, E))
    check(pieces[k0] == [E, 100, 0, 1] and pieces[str(key(15, 10, E))] == [E, 100, 1, 1],
          'accept: key -> [direction, cost step, fall, donations]')
    code, out = run_tool(base, '--accept', '1')
    check(code != 0 and 'schon angenommen' in out, 'accepting twice is refused')
    code, out = run_tool(base, '--accept', '2')
    check(code != 0 and 'Duplikat' in out, 'the duplicate of an accepted donation is refused')
    code, out = run_tool(base, '--accept', '3')
    net = json.loads((base / 'grundnetz' / 'grundnetz.json').read_text(encoding='utf-8'))
    pieces = net['zonen']['1434']
    check(len(pieces) == 15, 'accept 3: 5 new pieces, 5 shared ones')
    check(pieces[str(key(15, 10, E))] == [E, 300, 1, 2], 'shared piece, both with a fall: cost 300 (max), fall stays, 2 donations')
    check(pieces[str(key(16, 10, E))] == [E, 300, 0, 2], 'shared piece, one ridden without a fall: normal wins (F3 §6.3)')
    # the order of accepting does not matter
    base2 = fresh()
    for name in ('1.txt', '3.txt'):
        shutil.copy(base / 'eingang' / name, base2 / 'eingang' / name)
    run_tool(base2)
    run_tool(base2, '--accept', '2')
    run_tool(base2, '--accept', '1')
    check((base2 / 'grundnetz' / 'grundnetz.json').read_bytes() == (base / 'grundnetz' / 'grundnetz.json').read_bytes(),
          'accepting in the other order gives the same grundnetz.json, byte for byte')
    shutil.rmtree(base2)
    # nothing that identifies a donation, a time or a person in the base net
    raw = (base / 'grundnetz' / 'grundnetz.json').read_text(encoding='utf-8')
    check(not re.search(r'[0-9a-f]{16}', raw), 'grundnetz.json: no 16-hex export id')
    check(not re.search(r'\d{4}-\d{2}-\d{2}|\d{1,2}\.\d{1,2}\.\d{4}|\d{2}:\d{2}', raw), 'grundnetz.json: no date or time')
    check(not re.search(r'(?i)name|realm|spieler|kennung|id"|zeit|datum|version|0\.2\.', raw), 'grundnetz.json: no name, id, time or version field')
    # reject
    (base / 'eingang' / '4.txt').write_text(''.join(parts_of(walk(1434, 40, 40, [N] * 4), IDS[3])), encoding='ascii')
    run_tool(base)
    before = (base / 'grundnetz' / 'grundnetz.json').read_bytes()
    code, out = run_tool(base, '--reject', '4')
    check(code == 0 and 'Rohtext Nr. 4 sofort löschen (Formular und eingang)' in out, 'reject: "sofort löschen"')
    check((base / 'grundnetz' / 'grundnetz.json').read_bytes() == before, 'reject: the base net unchanged')
    code, out = run_tool(base, '--accept', '4')
    check(code != 0 and 'abgelehnt' in out, 'a rejected donation cannot be accepted')
    state = (base / 'pruefung' / 'stand.json').read_text(encoding='utf-8')
    check(not any(i in state for i in IDS), 'stand.json: no export id')
    # numbers stay when new donations arrive and raw texts go
    (base / 'eingang' / '1.txt').unlink()      # Sven deleted it after acceptance
    (base / 'eingang' / '0.txt').write_text(''.join(parts_of(walk(1434, 60, 60, [W] * 4), IDS[4])), encoding='ascii')
    run_tool(base)
    text = report_text(base)
    check('## Nr. 5' in text and '## Nr. 3' in text and '## Nr. 1\n' not in text, 'numbers stay: the new one is 5, 3 is still 3')
    check('Nr. 1: angenommen, Rohtext gelöscht' in text, 'report: an accepted donation whose raw text is gone')
    state = json.loads((base / 'pruefung' / 'stand.json').read_text(encoding='utf-8'))
    check(all('seit' not in e for e in state['angenommen']), 'stand.json: no date kept for an accepted donation whose raw text is gone')
    shutil.rmtree(base)


def t_deadline_and_patterns():
    base = fresh()
    old = base / 'eingang' / 'alt.txt'
    old.write_text(''.join(parts_of(walk(1434, 10, 10, [E] * 5), IDS[0])), encoding='ascii')
    then = time.mktime(time.strptime('2026-10-30', '%Y-%m-%d'))
    os.utime(old, (then, then))
    # a straight line across the whole zone (120 squares wide) and a dense scribble
    line = walk(1434, 0, 70, [E] * 119)
    scribble = []
    for x in range(50, 54):
        for y in range(20, 24):
            for d in PATH_DIRS:
                scribble.append((1434, x, y, d, 100, 0))
    (base / 'eingang' / 'muster.txt').write_text(''.join(parts_of(line + scribble, IDS[1])), encoding='ascii')
    run_tool(base)
    text = report_text(base)
    top = text.split('## Nr.')[0]
    check('älter als 25 Tage' in top and 'Nr. 1' in top and '2026-11-29' in top,
          'deadline: a raw text from 30.10. is named at the top, deleting by 29.11.')
    check('Zone 1434: gerade Linie über 119 Felder' in text, 'pattern: a straight line across the zone is named')
    check('Zone 1434: dicht' in text, 'pattern: a dense block of pieces is named')
    shutil.rmtree(base)


def t_own_overlap():
    base = fresh()
    sv = base / 'sv.lua'
    own = walk(1434, 10, 10, [E] * 4)
    sv.write_text(sv_text({1434: {key(x, y, d): value(1, 100) for _, x, y, d, _, _ in own}}), encoding='utf-8')
    don = walk(1434, 12, 10, [E] * 4)      # 2 of 4 pieces are Sven's
    (base / 'eingang' / 'a.txt').write_text(''.join(parts_of(don, IDS[0])), encoding='ascii')
    run_tool(base, own=sv)
    text = report_text(base)
    check('Überlappung mit Svens Wegen:** 50 % (in einer der beiden Richtungen 50 %)' in text, 'overlap with Sven\'s ways: 50 %')
    w, h, colours = png_info(base / 'pruefung' / (TODAY + '_bilder') / 'nr1_zone1434.png')
    check(review.COLOURS['eigen'] in colours, 'picture: Sven\'s ways drawn grey')
    shutil.rmtree(base)


def t_own_roundtrip(export_dir, sv_copy, sizes=(), estimated=()):
    base = fresh()
    files = sorted(Path(export_dir).glob('part-*.txt'))
    check(len(files) >= 1, 'own donation: part files there')
    # the parts as one answer each, the way the form gives them
    for i, f in enumerate(files, 1):
        shutil.copy(f, base / 'eingang' / ('teil-%d.txt' % i))
    found = review.collect(base / 'eingang')
    groups = review.assemble(found)
    check(len(groups) == 1 and groups[0].error is None, 'own donation: one complete donation, no error')
    got = {(z, x, y, d): (c, f) for z, x, y, d, c, f in groups[0].records}
    want = review.own_ways(Path(sv_copy))
    check(got == want, 'own donation: the decoded pieces = the pieces of the copy, quantized (%d pieces)' % len(want))
    ordered = [f.read_text(encoding='ascii') for f in files]
    data, back = codec.decode(ordered)
    check(codec.encode(data['records'], data['addon_version'], data['donation_id']) == back, 'own donation: re-encoded byte for byte')
    if sizes:
        out = io.StringIO()
        review.main(['--eingang', str(base / 'eingang'), '--pruefung', str(base / 'pruefung'), '--grundnetz', str(base / 'grundnetz'),
                     '--today', TODAY, '--own', str(sv_copy)] + [a for s in sizes for a in ('--sizes', s)] + [a for s in estimated for a in ('--sizes-estimated', s)], out=out)
        text = report_text(base)
        check('Überlappung mit Svens Wegen:** 100 % (in einer der beiden Richtungen 100 %)' in text, 'own donation: 100 % of it is Sven\'s')
        check('**Randstücke (außerhalb des Zonenrasters, aussortiert):** 0' in text, 'own donation: no edge piece')
        check('**Auffällig:** nichts nach den festen Schwellen' in text, 'own donation: the thresholds name nothing in Sven\'s own ways')
    shutil.rmtree(base)


# ---------------------------------------------------------------- zone sizes asked in the game (Sven, 26.11.2026)
def t_game_sizes():
    # C_Map.GetWorldPosFromMapPos(m, (0,0)) and (1,1); read as HereBeDragons reads them: the width from y, the height from x
    sizes = review.load_sizes([], [])
    s = sizes.get(2652)
    check(s is not None and abs(s[0] - 2050.0) < 1e-6 and abs(s[1] - 1366.666015625) < 1e-6 and s[2] == "Shen'dralas"
          and s[3] == 'Spiel-API, Sven, 26.11.', "game sizes: Shen'dralas 2652 is 2050 x 1366.67 yd, source the game API")
    s = sizes.get(2482)
    check(s is not None and abs(s[0] - 3472.91796875) < 1e-6 and abs(s[1] - 2314.5830078125) < 1e-6 and s[2] == 'Mount Hyjal',
          'game sizes: Mount Hyjal 2482 is 3472.92 x 2314.58 yd')
    check(1415 not in sizes, 'game sizes: the continent 1415 is no zone of the table')
    base = fresh()
    # conversion.json (exact) wins over the game table; an estimate never wins over it
    exact = {'geometry': {'transforms': [{'ui_map_id': 2652, 'target_name': 'X', 'target_bounds': {'left': 0, 'right': 500, 'top': 0, 'bottom': 500}}]}}
    (base / 'exact.json').write_text(json.dumps(exact), encoding='utf-8')
    (base / 'est.lua').write_text('return {\n[2482] = { 9000.0, 6000.0 },\n}\n', encoding='utf-8')
    sizes = review.load_sizes([base / 'exact.json'], [base / 'est.lua'])
    check(sizes[2652][:2] == (500, 500) and sizes[2652][3] == 'genau', 'game sizes: conversion.json comes first')
    check(abs(sizes[2482][0] - 3472.91796875) < 1e-6 and sizes[2482][3] == 'Spiel-API, Sven, 26.11.', 'game sizes: an estimate does not overwrite the game value')
    # a donation on 2652: checked on its grid of 82 x 55 squares, a step off it is an edge piece
    records = walk(2652, 70, 30, [E] * 11) + walk(2652, 81, 40, [E])                     # 81 -> 82 is off an 82-square grid
    (base / 'eingang' / 'spende-s.txt').write_text(''.join(parts_of(records, IDS[1])), encoding='ascii')
    code, out = run_tool(base)
    text = report_text(base)
    check(code == 0 and "| 2652 | Shen'dralas | 82 × 55 (Spiel-API, Sven, 26.11.) |" in text, 'game sizes: the review shows the zone with its grid and its source')
    check('Größe unbekannt' not in text, 'game sizes: 2652 is no zone without size any more')
    check(re.search(r'Randstücke[^\n]*\b1\b', text) is not None, 'game sizes: the step off the grid is the one edge piece')
    shutil.rmtree(base)


def main():
    args = sys.argv[1:]
    t_sv_reader()
    t_txt_and_edges()
    t_csv_two_parts_and_damage()
    t_duplicate_accept_reject()
    t_deadline_and_patterns()
    t_own_overlap()
    t_game_sizes()
    if '--own-export' in args:
        opt = lambda name: [args[i + 1] for i, a in enumerate(args) if a == name]
        t_own_roundtrip(args[args.index('--own-export') + 1], args[args.index('--own-sv') + 1], opt('--sizes'), opt('--sizes-estimated'))
    print('FAILED: %d' % len(FAILS) if FAILS else 'ALL OK')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
