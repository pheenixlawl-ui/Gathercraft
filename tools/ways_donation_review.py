"""Review of ways donations (GCWAYS2) for Sven's eyes. A tool, no addon code; no network, no game files.

  python -I tools/ways_donation_review.py --eingang DIR --pruefung DIR --grundnetz DIR
         --sizes conversion.json [--sizes-estimated zonesizes.lua] [--own SV-COPY]
         [--today YYYY-MM-DD] [--accept N | --reject N]

Without --accept/--reject: reads every .csv (the form's export; only cells holding a
donation are read, every other column is ignored) and .txt in eingang, puts the parts of a
donation together by their envelope, checks part and whole checksums and decodes with
tools/ways_donation.py. Writes <today>_pruefbericht.md and <today>_bilder/ into pruefung
and keeps the running numbers in pruefung/stand.json.

Rules (order 2026-11-26_claude_auftrag_spenden-auswertung.md):
- A donation is a submission for Sven's review: never a vote, a player count or a sync id.
- Only the ways are used. The export id, the addon version, the form's columns and times
  are never stored, shown or evaluated; the export id only groups the parts in memory.
- Edge pieces outside the zone's grid (ceil(size / 25) squares, F4 §C) are sorted out.
- --accept N takes donation N's pieces into grundnetz/grundnetz.json (key -> direction,
  cost step, fall, number of donations), without id or date; --reject N takes nothing.
  Raw texts are deleted by Sven (form and eingang); this tool deletes nothing.
- Arrival = the day the file lay in eingang (file date), kept in stand.json only while
  the raw text is there; a warning at the top after 25 days, deletion by day 30.
"""
import argparse
import csv
import datetime
import hashlib
import importlib.util
import io
import json
import math
import os
import re
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('ways_donation', HERE / 'ways_donation.py')
codec = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codec)

TILE, GRID = 25, 1024
PATH_DIRS = (0, 1, 2, 3, 5, 6, 7, 8)
WARN_DAYS, DELETE_DAYS = 25, 30
# Thresholds for "look here" (no verdict). Set on Sven's own 19,401 pieces (backup of 26.11.2026), which trip none:
# his longest straight run is 20 squares, his densest 100 x 100 yd hold 63 pieces.
STRAIGHT_SHARE, STRAIGHT_ABS, STRAIGHT_MIN = 0.6, 40, 80   # 60 % of the zone and 40+ squares (80 where the size is unknown)
DENSE_BOX, DENSE_PIECES = 4, 80               # 100 x 100 yd with 80+ pieces: five directions per square on average
OFF_WAY = 2                                   # squares from the nearest known way
STATE_FORMAT, NET_FORMAT = 'gathercraft-spenden-stand-1', 'gathercraft-grundnetz-1'
NAMES = {2548: 'Riverglades', 2482: 'Mount Hyjal', 2521: 'Zephras Isle'}
COLOURS = {
    'grund': bytes((24, 26, 31)), 'raster': bytes((36, 39, 46)), 'rahmen': bytes((47, 106, 160)), 'text': bytes((205, 208, 214)),
    'eigen': bytes((112, 117, 128)), 'netz': bytes((62, 140, 84)), 'spende': bytes((74, 163, 255)),
    'sturz': bytes((255, 74, 61)), 'rand': bytes((255, 176, 0)),
}
ERRORS = {
    'part too long': 'Teil zu lang', 'part length or character set': 'Teil zu lang oder mit fremden Zeichen',
    'input limit (including duplicate parts)': 'zu viel Text', 'invalid header': 'Kopfzeile kaputt',
    'part count': 'Teilzahl ungültig', 'total size': 'zu groß', 'whole checksum': 'Gesamtprüfsumme stimmt nicht',
    'noncanonical payload or part boundaries': 'nicht so, wie das Addon exportiert (Inhalt oder Teilgrenzen)',
    'duplicate part number with different content': 'zwei verschiedene Fassungen desselben Teils',
}


# ---------------------------------------------------------------- SavedVariables (a copy) -> Sven's own ways
_TOKEN = re.compile(r'''(?P<space>\s+)|(?P<comment>--\[\[.*?\]\]|--[^\n]*)|(?P<str>"(?:[^"\\\n]|\\.)*")
    |(?P<num>-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?))
    |(?P<name>[A-Za-z_][A-Za-z0-9_]*)|(?P<sym>[{}\[\]=,;])''', re.S | re.X)
_ESC = {'n': '\n', 't': '\t', 'r': '\r', 'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v', '\\': '\\', '"': '"', "'": "'", '\n': '\n'}


def _unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != '\\':
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        if n.isdigit():
            m = re.match(r'\d{1,3}', s[i + 1:]).group()
            out.append(chr(int(m)))
            i += 1 + len(m)
        else:
            out.append(_ESC.get(n, n))
            i += 2
    return ''.join(out)


def read_sv(path):
    """the globals of a SavedVariables file (Lua table syntax as the client writes it), read only"""
    text = Path(path).read_text(encoding='utf-8', errors='replace')
    tokens = []
    pos = 0
    for m in _TOKEN.finditer(text):
        if m.start() != pos:
            raise ValueError('SavedVariables: unreadable at %d' % pos)
        pos = m.end()
        kind = m.lastgroup
        if kind in ('space', 'comment'):
            continue
        tokens.append((kind, m.group()))
    if pos != len(text):
        raise ValueError('SavedVariables: unreadable at %d' % pos)
    at = [0]

    def take(want=None):
        kind, val = tokens[at[0]]
        if want and val != want:
            raise ValueError('SavedVariables: "%s" expected, "%s" found' % (want, val))
        at[0] += 1
        return kind, val

    def value():
        kind, val = take()
        if kind == 'str':
            return _unescape(val[1:-1])
        if kind == 'num':
            if re.fullmatch(r'-?0[xX][0-9a-fA-F]+', val):
                return int(val, 16)
            return float(val) if re.search(r'[.eE]', val) else int(val)
        if kind == 'name':
            return {'true': True, 'false': False}.get(val)
        if val == '{':
            t, n = {}, 1
            while tokens[at[0]][1] != '}':
                if tokens[at[0]][1] == '[':
                    take('[')
                    k = value()
                    take(']')
                    take('=')
                    t[k] = value()
                elif tokens[at[0]][0] == 'name' and tokens[at[0] + 1][1] == '=':
                    k = take()[1]
                    take('=')
                    t[k] = value()
                else:
                    t[n] = value()
                    n += 1
                if tokens[at[0]][1] in (',', ';'):
                    take()
            take('}')
            return t
        raise ValueError('SavedVariables: unexpected "%s"' % val)

    out = {}
    while at[0] < len(tokens):
        kind, name = take()
        if kind != 'name':
            raise ValueError('SavedVariables: name expected')
        take('=')
        out[name] = value()
    return out


def quantize(key, v):
    """(x, y, dir, cost step, fall bit) of a Paths piece as the donation encoder does it, None where it skips it"""
    if not (isinstance(key, int) and isinstance(v, int)) or not (0 <= key < GRID * GRID * 9) or not (0 <= v < 2 ** 48):
        return None
    d, cell = key % 9, key // 9
    x, y = cell % GRID, cell // GRID
    v //= 16384                       # the recorded day is not used
    count, v = v % 256, v // 256
    cost, v = v % 1024, v // 1024
    falls, swims = v % 256, v // 256
    if (d == 4 or not (0 <= x + d % 3 - 1 < GRID and 0 <= y + d // 3 - 1 < GRID)
            or count == 0 or cost < 100 or falls > count or swims > count):
        return None
    step = 100 if cost < 125 else 150 if cost < 175 else 200 if cost < 250 else 300
    return x, y, d, step, 1 if falls >= 1 and falls == count else 0


def own_ways(path):
    """Sven's ways from a COPY of his SavedVariables: {(zone, x, y, dir): (cost step, fall bit)}; only paths.zones is used"""
    db = read_sv(path).get('GathercraftDB') or {}
    zones = ((db.get('paths') or {}).get('zones')) or {}
    out = {}
    for zone, z in zones.items():
        if not isinstance(zone, int) or not isinstance(z, dict) or not isinstance(z.get('e'), dict):
            continue
        for key, v in z['e'].items():
            q = quantize(key, v)
            if q:
                out[zone, q[0], q[1], q[2]] = (q[3], q[4])
    return out


# ---------------------------------------------------------------- zone sizes and the grid (F4 §C)
def load_sizes(exact, estimated):
    sizes = {}
    for path, source in [(p, 'genau') for p in exact] + [(p, 'geschätzt') for p in estimated]:
        text = Path(path).read_text(encoding='utf-8')
        if str(path).lower().endswith('.json'):
            for t in json.loads(text)['geometry']['transforms']:
                b = t['target_bounds']
                zone = int(t['ui_map_id'])
                if zone not in sizes:
                    sizes[zone] = (abs(b['left'] - b['right']), abs(b['top'] - b['bottom']), t.get('target_name') or NAMES.get(zone, ''), source)
        else:
            for m in re.finditer(r'\[(\d+)\]\s*=\s*\{\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\}', text):
                zone = int(m[1])
                if zone not in sizes:
                    sizes[zone] = (float(m[2]), float(m[3]), NAMES.get(zone, ''), source)
    return sizes


def grid_of(sizes, zone):
    s = sizes.get(zone)
    if not s or s[0] <= 0 or s[1] <= 0:
        return None
    w, h = math.ceil(s[0] / TILE), math.ceil(s[1] / TILE)
    return (w, h) if w <= GRID and h <= GRID else None


def in_grid(x, y, d, wh):
    w, h = wh
    tx, ty = x + d % 3 - 1, y + d // 3 - 1
    return d != 4 and 0 <= x < w and 0 <= y < h and 0 <= tx < w and 0 <= ty < h


# ---------------------------------------------------------------- eingang: finding and assembling parts
_START = re.compile(r'GCWAYS[12]\|')
_BODY_LINE = re.compile(r'Z\d+:[A-Za-z0-9_.\-]*')


class Found:
    def __init__(self, text, source, day):
        self.text, self.source, self.day = text, source, day


def _chunks(cell):
    """the parts in one answer or file: from each 'GCWAYS…|' on, the header line and the zone lines after it; the
    outer white space and a lost last LF are mended (the checksums say whether that was right), nothing else"""
    cell = cell.replace('\r\n', '\n').replace('\r', '\n')
    starts = [m.start() for m in _START.finditer(cell)] + [len(cell)]
    for a, b in zip(starts, starts[1:]):
        lines = cell[a:b].strip().split('\n')
        keep = [lines[0].strip()]
        for line in lines[1:]:
            line = line.strip()
            if not line:
                continue              # a blank line (doubled line ends of a form or editor): never part of a body
            if not _BODY_LINE.fullmatch(line):
                break                 # text after the donation (a greeting): not part of it
            keep.append(line)
        yield '\n'.join(keep) + '\n'


def collect(eingang):
    found, skipped = [], []
    for path in sorted(Path(eingang).iterdir(), key=lambda p: p.name.lower()):
        if not path.is_file() or path.name.startswith(('.', '~')):
            continue
        day = datetime.date.fromtimestamp(path.stat().st_mtime).isoformat()
        suffix = path.suffix.lower()
        if suffix == '.csv' and path.stat().st_size <= 64 * 1024 * 1024:
            with open(path, encoding='utf-8-sig', errors='replace', newline='') as f:
                rows = list(csv.reader(f))
            for r, row in enumerate(rows):
                for cell in row:
                    if 'GCWAYS' in cell:
                        for chunk in _chunks(cell):
                            found.append(Found(chunk, '%s, Zeile %d' % (path.name, r + 1), day))
        elif suffix == '.txt' and path.stat().st_size <= codec.MAX_TOTAL * 2:
            for chunk in _chunks(path.read_text(encoding='utf-8', errors='replace')):
                found.append(Found(chunk, path.name, day))
        else:
            skipped.append(path.name)
    collect.skipped = skipped
    return found


class Group:
    def __init__(self):
        self.texts, self.sources, self.days = [], [], []
        self.error, self.records, self.rawkey, self.content = None, None, None, None


def assemble(found):
    """one Group per donation (by its envelope); the export id groups the parts here and goes no further"""
    groups, bykey = [], {}
    for f in found:
        h = codec.HEADER.match(f.text)
        if not h:
            g = Group()
            g.texts, g.error = [f.text], 'Kopfzeile kaputt'
            groups.append(g)
            bykey[object()] = g
        else:
            form, version, ident, num, count, psum, whole = h.groups()
            k = (form, version, ident, count, whole)
            g = bykey.get(k)
            if g is None:
                g = bykey[k] = Group()
                groups.append(g)
            if f.text not in g.texts:
                g.texts.append(f.text)
        if f.source not in g.sources:
            g.sources.append(f.source)
        g.days.append(f.day)
    for g in groups:
        g.rawkey = hashlib.sha256('\x00'.join(sorted(g.texts)).encode('utf-8', 'replace')).hexdigest()
        if g.error:
            g.texts = None
            continue
        g.error = _check(g.texts)
        if not g.error:
            try:
                data, _ = codec.decode(g.texts)
                g.records = sorted(data['records'])
                if data['format'] != 'GCWAYS2':
                    g.records = sorted({(z, x, y, d, 100 if c < 125 else 150 if c < 175 else 200 if c < 250 else 300,
                                         1 if fa >= 1 and fa == n else 0) for z, x, y, d, n, c, fa, s in g.records})
                g.content = hashlib.sha256(json.dumps(g.records, separators=(',', ':')).encode()).hexdigest()
            except ValueError as e:
                g.error = ERRORS.get(str(e), 'Inhalt kaputt (%s)' % e)
        g.texts = None        # the raw text stays in eingang only
    return groups


def _check(texts):
    numbers, count = {}, None
    for t in texts:
        h = codec.HEADER.match(t)
        n, count, psum = int(h[4]), int(h[5]), h[6]
        if not t.isascii() or len(t) > codec.MAX_PART:
            return 'Teil zu lang oder mit fremden Zeichen'
        if codec.checksum(t[h.end():]) != psum:
            return 'Teil-Prüfsumme stimmt nicht (Teil %d von %d)' % (n, count)
        if n in numbers:
            return 'zwei verschiedene Fassungen von Teil %d' % n
        numbers[n] = t
    if not 1 <= count <= codec.MAX_PARTS or any(not 1 <= n <= count for n in numbers):
        return 'Teilzahl ungültig'
    missing = [n for n in range(1, count + 1) if n not in numbers]
    if missing:
        if len(missing) == 1:
            return 'unvollständig, Teil %d von %d fehlt' % (missing[0], count)
        return 'unvollständig, Teile %s von %d fehlen' % (', '.join(map(str, missing)), count)
    return None


# ---------------------------------------------------------------- state (running numbers) and the base net
def load_state(pruefung):
    p = Path(pruefung) / 'stand.json'
    if p.exists():
        s = json.loads(p.read_text(encoding='utf-8'))
        assert s.get('format') == STATE_FORMAT, 'stand.json: unknown format'
        return s
    return {'format': STATE_FORMAT, 'naechste': 1, 'einsendungen': {}, 'angenommen': []}


def save_json(path, data):
    tmp = Path(str(path) + '.tmp')
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    os.replace(tmp, path)


def number(state, groups, today):
    """the running number of every submission now in eingang; entries whose raw text is gone are dropped (an accepted
    one keeps only its number and content hash in 'angenommen')"""
    seen = {}
    natural = lambda s: re.sub(r'\d+', lambda m: m.group().zfill(9), s.lower())
    for g in sorted(groups, key=lambda g: (natural(g.sources[0]), g.rawkey)):
        e = state['einsendungen'].get(g.rawkey)
        arrived = min(g.days + [today])
        if e is None:
            e = {'nr': state['naechste'], 'seit': arrived, 'status': 'offen'}
            state['naechste'] += 1
        else:
            e['seit'] = min(e['seit'], arrived)
        e['inhalt'] = g.content
        seen[g.rawkey] = e
        g.nr, g.state = e['nr'], e
    state['einsendungen'] = seen
    return state


def accepted_content(state):
    return {a['inhalt']: a['nr'] for a in state['angenommen']}


def duplicate_of(g, groups, state):
    if not g.content:
        return None
    acc = accepted_content(state)
    if g.content in acc and acc[g.content] != g.nr:
        return acc[g.content], True
    for o in groups:
        if o is not g and o.content == g.content and o.nr < g.nr and o.state['status'] != 'abgelehnt':
            return o.nr, o.state['status'] == 'angenommen'
    return None


def load_net(grundnetz):
    p = Path(grundnetz) / 'grundnetz.json'
    if p.exists():
        n = json.loads(p.read_text(encoding='utf-8'))
        assert n.get('format') == NET_FORMAT, 'grundnetz.json: unknown format'
        return n
    return {'format': NET_FORMAT, 'zonen': {}}


def net_pieces(net):
    out = {}
    for zone, pieces in net['zonen'].items():
        for k, (d, cost, fall, n) in pieces.items():
            cell = int(k) // 9
            out[int(zone), cell % GRID, cell // GRID, d] = (cost, fall)
    return out


def split(records, sizes):
    """(kept, edge, unknown): pieces inside a known grid, edge pieces outside it, pieces of zones without a size"""
    kept, edge, unknown = [], [], []
    for r in records:
        wh = grid_of(sizes, r[0])
        if wh is None:
            unknown.append(r)
        elif in_grid(r[1], r[2], r[3], wh):
            kept.append(r)
        else:
            edge.append(r)
    return kept, edge, unknown


# ---------------------------------------------------------------- what to look at
def analyse(g, groups, sizes, own, net):
    kept, edge, unknown = split(g.records, sizes)
    usable = kept + unknown
    a = {'kept': kept, 'edge': edge, 'unknown': unknown, 'zones': {}}
    keys = {(z, x, y, d) for z, x, y, d, c, f in usable}
    undirected = lambda z, x, y, d: (z, x + d % 3 - 1, y + d // 3 - 1, 8 - d)
    a['falls'] = sum(f for *_, f in usable)
    a['steps'] = {c: sum(1 for r in usable if r[4] == c) for c in (100, 150, 200, 300)}

    def share(other):
        if not usable:
            return 0, 0
        same = sum(1 for k in keys if k in other)
        either = sum(1 for k in keys if k in other or undirected(*k) in other)
        return round(100 * same / len(keys)), round(100 * either / len(keys))
    a['own'] = share(own) if own is not None else None
    a['net'] = share(net) if net else None
    best = (0, None)
    for o in groups:
        if o is g or not o.records:
            continue
        ok = {(z, x, y, d) for z, x, y, d, c, f in o.records}
        if keys:
            p = round(100 * len(keys & ok) / len(keys))
            if p > best[0]:
                best = (p, o.nr)
    a['other'] = best
    # off every known way: no square of Sven's ways or the base net within OFF_WAY squares
    known = {}
    for src in (own or {}), (net or {}):
        for z, x, y, d in src:
            known.setdefault(z, set()).update({(x, y), (x + d % 3 - 1, y + d // 3 - 1)})
    a['off'] = None
    if known:
        off = 0
        for z, x, y, d in keys:
            cells = known.get(z, ())
            if not any((x + i, y + j) in cells for i in range(-OFF_WAY, OFF_WAY + 1) for j in range(-OFF_WAY, OFF_WAY + 1)):
                off += 1
        a['off'] = round(100 * off / len(keys)) if keys else 0
    chains = sum(1 for *_, continuing in codec.chain_steps(g.records) if not continuing)
    a['chains'] = chains
    for zone in sorted({r[0] for r in g.records}):
        rows = [r for r in usable if r[0] == zone]
        zk = {(x, y, d) for z, x, y, d, c, f in rows}
        wh = grid_of(sizes, zone)
        # the longest straight run: pieces in one direction, each starting where the one before ends
        best_run, best_dir = 0, None
        for x, y, d in zk:
            if (x - (d % 3 - 1), y - (d // 3 - 1), d) in zk:
                continue                          # not the start of a run
            n, cx, cy = 0, x, y
            while (cx, cy, d) in zk:
                n += 1
                cx, cy = cx + d % 3 - 1, cy + d // 3 - 1
            if n > best_run:
                best_run, best_dir = n, d
        extent = None
        if wh and best_dir is not None:
            extent = wh[0] if best_dir in (3, 5) else wh[1] if best_dir in (1, 7) else min(wh)
        straight = best_run >= (max(STRAIGHT_ABS, STRAIGHT_SHARE * extent) if extent else STRAIGHT_MIN)
        # dense: 4 x 4 squares (100 x 100 yd) holding 48+ pieces
        per = {}
        for x, y, d in zk:
            per[x, y] = per.get((x, y), 0) + 1
        boxes = {}
        for (x, y), n in per.items():
            for i in range(DENSE_BOX):
                for j in range(DENSE_BOX):
                    boxes[x - i, y - j] = boxes.get((x - i, y - j), 0) + n
        dense = [n for n in boxes.values() if n >= DENSE_PIECES]
        stars = sum(1 for n in per.values() if n >= 6)
        a['zones'][zone] = {
            'pieces': sum(1 for r in g.records if r[0] == zone), 'kept': len(rows), 'edge': sum(1 for r in edge if r[0] == zone),
            'grid': wh, 'size': sizes.get(zone), 'run': best_run, 'extent': extent, 'straight': straight,
            'dense': len(dense), 'densest': max(boxes.values()) if boxes else 0, 'stars': stars,
        }
    return a


# ---------------------------------------------------------------- pictures (own drawing, no game graphics)
_FONT = {
    '0': '111101101101111', '1': '010110010010111', '2': '111001111100111', '3': '111001111001111', '4': '101101111001001',
    '5': '111100111001111', '6': '111100111101111', '7': '111001010010010', '8': '111101111101111', '9': '111101111001111',
    'A': '010101111101101', 'B': '110101110101110', 'C': '011100100100011', 'D': '110101101101110', 'E': '111100110100111',
    'F': '111100110100100', 'G': '011100101101011', 'H': '101101111101101', 'I': '111010010010111', 'J': '001001001101010',
    'K': '101101110101101', 'L': '100100100100111', 'M': '101111111101101', 'N': '110101101101101', 'O': '010101101101010',
    'P': '110101110100100', 'Q': '010101101111011', 'R': '110101110101101', 'S': '011100010001110', 'T': '111010010010010',
    'U': '101101101101111', 'V': '101101101101010', 'W': '101101111111101', 'X': '101101010101101', 'Y': '101101010010010',
    'Z': '111001010100111', '-': '000000111000000', '.': '000000000000010', ' ': '000000000000000', ':': '000010000010000',
}
_PLAIN = str.maketrans({'Ä': 'A', 'Ö': 'O', 'Ü': 'U', 'ß': 'S', '×': 'X'})


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = bytearray(COLOURS['grund'] * (w * h))

    def dot(self, x, y, c, t=1):
        for i in range(t):
            for j in range(t):
                xx, yy = x + i - t // 2, y + j - t // 2
                if 0 <= xx < self.w and 0 <= yy < self.h:
                    p = 3 * (yy * self.w + xx)
                    self.px[p:p + 3] = c

    def line(self, x0, y0, x1, y1, c, t=1):
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            self.dot(x0, y0, c, t)
            if x0 == x1 and y0 == y1:
                return
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def text(self, x, y, s, c, scale=2):
        for ch in s.upper().translate(_PLAIN):
            glyph = _FONT.get(ch, _FONT[' '])
            for r in range(5):
                for k in range(3):
                    if glyph[r * 3 + k] == '1':
                        for i in range(scale):
                            for j in range(scale):
                                self.dot(x + k * scale + i, y + r * scale + j, c)
            x += 4 * scale
        return x

    def png(self, path):
        raw = b''.join(b'\x00' + bytes(self.px[3 * y * self.w:3 * (y + 1) * self.w]) for y in range(self.h))

        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
        Path(path).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', self.w, self.h, 8, 2, 0, 0, 0))
                               + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def picture(path, nr, zone, a, g, sizes, own, net):
    wh = grid_of(sizes, zone)
    mine = [r for r in g.records if r[0] == zone]
    if wh:
        x0, y0, gw, gh = 0, 0, wh[0], wh[1]
    else:
        xs = [r[1] for r in mine] + [r[1] + r[3] % 3 - 1 for r in mine]
        ys = [r[2] for r in mine] + [r[2] + r[3] // 3 - 1 for r in mine]
        x0, y0 = max(0, min(xs) - 5), max(0, min(ys) - 5)
        gw, gh = max(xs) + 6 - x0, max(ys) + 6 - y0
    s = max(1, min(8, 1400 // max(gw, gh)))
    pad, head = 12, 46
    c = Canvas(gw * s + 2 * pad, gh * s + 2 * pad + head)
    ox, oy = pad, pad + head
    for k in range(0, gw + 1, 10):
        c.line(ox + k * s, oy, ox + k * s, oy + gh * s, COLOURS['raster'])
    for k in range(0, gh + 1, 10):
        c.line(ox, oy + k * s, ox + gw * s, oy + k * s, COLOURS['raster'])
    if wh:
        for (ax, ay, bx, by) in ((0, 0, gw, 0), (0, gh, gw, gh), (0, 0, 0, gh), (gw, 0, gw, gh)):
            c.line(ox + ax * s, oy + ay * s, ox + bx * s, oy + by * s, COLOURS['rahmen'])

    def piece(x, y, d, colour, t):
        cx, cy = ox + (x - x0) * s + s // 2, oy + (y - y0) * s + s // 2
        c.line(cx, cy, cx + (d % 3 - 1) * s, cy + (d // 3 - 1) * s, colour, t)
        return cx + (d % 3 - 1) * s, cy + (d // 3 - 1) * s
    for (z, x, y, d) in (own or {}):
        if z == zone:
            piece(x, y, d, COLOURS['eigen'], 1)
    for (z, x, y, d) in (net or {}):
        if z == zone:
            piece(x, y, d, COLOURS['netz'], 1)
    t = 2 if s >= 3 else 1
    for z, x, y, d, cost, fall in mine:
        if not fall:
            piece(x, y, d, COLOURS['spende'], t)
    for z, x, y, d, cost, fall in mine:
        if fall:
            ex, ey = piece(x, y, d, COLOURS['sturz'], t)
            c.dot(ex, ey, COLOURS['sturz'], t + 2)
    edge = {(r[1], r[2], r[3]) for r in a['edge'] if r[0] == zone}
    for x, y, d in edge:
        piece(x, y, d, COLOURS['rand'], t + 1)
    size = sizes.get(zone)
    name = size[2] if size else NAMES.get(zone, '')
    label = 'NR %d  ZONE %d %s' % (nr, zone, name)
    label += '  %dX%d FELDER' % (gw, gh) if wh else '  GROESSE UNBEKANNT'
    c.text(pad, 8, label, COLOURS['text'])
    x = pad
    for key, word in (('eigen', 'SVEN'), ('netz', 'GRUNDNETZ'), ('spende', 'SPENDE'), ('sturz', 'STURZ'), ('rand', 'RAND')):
        for i in range(14):
            c.dot(x + i, 32, COLOURS[key], 3)
        x = c.text(x + 20, 27, word, COLOURS['text']) + 18
    c.png(path)


# ---------------------------------------------------------------- the report
def fmt(n):
    return '{:,}'.format(n).replace(',', '.')


def report(path, pics, groups, state, sizes, own, net, today, skipped, own_given):
    t = datetime.date.fromisoformat(today)
    L = ['# Spenden – Prüfbericht vom %s' % today, '']
    L.append('Ausgabe von `tools/ways_donation_review.py`. Eine Spende ist eine **Einreichung zur Sichtprüfung**, keine Stimme '
             'und keine Spielerzahl. Gezeigt werden nur die Wege; Export-Kennung, Addon-Version und alle anderen Formularspalten '
             'liest das Werkzeug nicht aus. Eingang = Tag, an dem die Datei in `eingang` lag (Dateidatum), nicht die Formularzeit.')
    L.append('')
    warn = []
    for g in sorted(groups, key=lambda g: g.nr):
        days = (t - datetime.date.fromisoformat(g.state['seit'])).days
        if days > WARN_DAYS:
            until = datetime.date.fromisoformat(g.state['seit']) + datetime.timedelta(days=DELETE_DAYS)
            warn.append('- **Nr. %d:** seit %d Tagen im Eingang (älter als %d Tage), Rohtext spätestens am %s löschen (Formular und eingang).'
                        % (g.nr, days, WARN_DAYS, until.isoformat()))
    if warn:
        L += ['## Frist', ''] + warn + ['']
    gone = sorted(a['nr'] for a in state['angenommen'] if a['nr'] not in {g.nr for g in groups})
    counts = {'offen': 0, 'angenommen': 0, 'abgelehnt': 0}
    for g in groups:
        counts[g.state['status']] += 1
    L.append('**Im Eingang:** %d Einsendungen (offen %d, angenommen %d, abgelehnt %d). Angenommen insgesamt: %d.'
             % (len(groups), counts['offen'], counts['angenommen'], counts['abgelehnt'], len(state['angenommen'])))
    if not groups:
        L.append('')
        L.append('Der Eingang ist leer.')
    if skipped:
        L.append('')
        L.append('Nicht gelesen (nur .csv und .txt): ' + ', '.join('`%s`' % s for s in skipped) + '.')
    L.append('')
    L.append('**Vergleich:** ' + ('Svens Wege aus einer Kopie der Sicherung (%s Stücke)' % fmt(len(own)) if own_given else 'keine Kopie von Svens Wegen angegeben')
             + '; Grundnetz: %s Stücke.' % fmt(len(net)))
    L.append('')
    L.append('**Bilder:** Svens Wege grau, Grundnetz grün, Spende blau, Sturz rot (Punkt am unteren Ende), Randstücke orange; '
             'Raster alle 10 Felder (250 yd), blauer Rahmen = Zonenraster. Norden ist oben.')
    L.append('')
    for g in sorted(groups, key=lambda g: g.nr):
        L.append('## Nr. %d' % g.nr)
        L.append('')
        L.append('- **Quelle in eingang:** ' + '; '.join('`%s`' % s for s in g.sources))
        L.append('- **Im Eingang seit:** %s' % g.state['seit'])
        st = g.state['status']
        if g.error:
            L.append('- **Status:** abgelehnt: %s. Rohtext sofort löschen (Formular und eingang), wenn kein fehlender Teil mehr kommt.' % g.error)
            L.append('')
            continue
        dup = duplicate_of(g, groups, state)
        if st != 'offen':
            L.append('- **Status:** %s' % st)
        elif dup:
            L.append('- **Status:** Duplikat von Nr. %d%s (gleicher Inhalt, andere Export-Kennung): zählt nicht doppelt, nicht annehmbar.'
                     % (dup[0], ', angenommen' if dup[1] else ''))
        else:
            L.append('- **Status:** offen, zur Sichtprüfung')
        a = g.analysis
        L.append('- **Stücke:** %s in %d Zonen, %s Ketten (im Mittel %s Stücke)'
                 % (fmt(len(g.records)), len(a['zones']), fmt(a['chains']), ('%.1f' % (len(g.records) / max(1, a['chains']))).replace('.', ',')))
        L.append('- **Randstücke (außerhalb des Zonenrasters, aussortiert):** %d' % len(a['edge']))
        if a['unknown']:
            L.append('- **Zonen mit Größe unbekannt:** %s (%s Stücke; ohne Raster nicht prüfbar, werden nicht übernommen)'
                     % (', '.join(str(z) for z in sorted({r[0] for r in a['unknown']})), fmt(len(a['unknown']))))
        usable = len(a['kept']) + len(a['unknown'])
        L.append('- **Mit Sturz:** %d %% (%s von %s); Aufwand 100/150/200/300: %s'
                 % (round(100 * a['falls'] / max(1, usable)), fmt(a['falls']), fmt(usable), ' / '.join(fmt(a['steps'][c]) for c in (100, 150, 200, 300))))
        if a['own'] is not None:
            L.append('- **Überlappung mit Svens Wegen:** %d %% (in einer der beiden Richtungen %d %%)' % a['own'])
        if a['net'] is not None:
            L.append('- **Überlappung mit dem Grundnetz:** %d %% (in einer der beiden Richtungen %d %%)' % a['net'])
        if a['other'][1]:
            L.append('- **Am meisten gemeinsam mit:** Nr. %d (%d %% der Stücke)' % (a['other'][1], a['other'][0]))
        if a['off'] is not None:
            L.append('- **Abseits bekannter Wege** (weiter als %d Felder von Svens Wegen und vom Grundnetz): %d %%' % (OFF_WAY, a['off']))
        L.append('')
        L.append('| Zone | Name | Raster | Stücke | Rand | längste gerade Linie | dichte Blöcke | Felder mit 6+ Richtungen | Bild |')
        L.append('|---|---|---|---:|---:|---|---:|---:|---|')
        flags = []
        for zone, z in a['zones'].items():
            size = z['size']
            grid = '%d × %d (%s)' % (z['grid'][0], z['grid'][1], size[3]) if z['grid'] else 'Größe unbekannt'
            run = '%d Felder' % z['run'] + (' (%d %% der Zone)' % round(100 * z['run'] / z['extent']) if z['extent'] else '')
            L.append('| %d | %s | %s | %s | %d | %s | %d | %d | `%s` |' % (zone, (size[2] if size else NAMES.get(zone, '')) or '–', grid,
                     fmt(z['pieces']), z['edge'], run, z['dense'], z['stars'], pics.get((g.nr, zone), '–')))
            if z['straight']:
                flags.append('Zone %d: gerade Linie über %d Felder%s' % (zone, z['run'], ' (%d %% der Zone)' % round(100 * z['run'] / z['extent']) if z['extent'] else ''))
            if z['dense']:
                flags.append('Zone %d: dicht – %d Blöcke von 100 × 100 yd mit %d+ Stücken (am meisten %d)' % (zone, z['dense'], DENSE_PIECES, z['densest']))
        L.append('')
        L.append('- **Auffällig:** ' + ('; '.join(flags) if flags else 'nichts nach den festen Schwellen') + '. Wasser und Gelände kennt das Werkzeug nicht: das zeigt nur das Bild.')
        L.append('')
    if gone:
        L.append('## Angenommen, Rohtext nicht mehr im Eingang')
        L.append('')
        for nr in gone:
            L.append('- Nr. %d: angenommen, Rohtext gelöscht' % nr)
        L.append('')
    L.append('## Befehle')
    L.append('')
    L.append('Annehmen: dieselbe Zeile wie für diesen Bericht, dazu `--accept <Nr>`. Ablehnen: `--reject <Nr>`. Danach nennt das Werkzeug, welchen Rohtext du löschen kannst; es selbst löscht nichts.')
    Path(path).write_text('\n'.join(L) + '\n', encoding='utf-8')


# ---------------------------------------------------------------- main
def main(argv=None, out=None):
    out = out or sys.stdout
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--eingang', required=True, type=Path)
    p.add_argument('--pruefung', required=True, type=Path)
    p.add_argument('--grundnetz', required=True, type=Path)
    p.add_argument('--sizes', action='append', default=[], type=Path)
    p.add_argument('--sizes-estimated', action='append', default=[], type=Path)
    p.add_argument('--own', type=Path)
    p.add_argument('--today', default=datetime.date.today().isoformat())
    g_ = p.add_mutually_exclusive_group()
    g_.add_argument('--accept', type=int)
    g_.add_argument('--reject', type=int)
    args = p.parse_args(argv)
    say = lambda s: print(s, file=out)
    today = datetime.date.fromisoformat(args.today).isoformat()
    args.pruefung.mkdir(parents=True, exist_ok=True)
    sizes = load_sizes(args.sizes, args.sizes_estimated)
    own = own_ways(args.own) if args.own else None
    net_doc = load_net(args.grundnetz)
    net = net_pieces(net_doc)
    groups = assemble(collect(args.eingang))
    state = number(load_state(args.pruefung), groups, today)

    if args.accept is not None or args.reject is not None:
        nr = args.accept if args.accept is not None else args.reject
        g = next((g for g in groups if g.nr == nr), None)
        if g is None:
            if nr in {a['nr'] for a in state['angenommen']}:
                say('Nr. %d ist schon angenommen; ihr Rohtext liegt nicht mehr im Eingang.' % nr)
            else:
                say('Nr. %d gibt es im Eingang nicht. Nichts geändert.' % nr)
            return 2
        where = '; '.join(g.sources)
        if g.state['status'] == 'angenommen':
            say('Nr. %d ist schon angenommen. Nichts geändert. Rohtext Nr. %d kann gelöscht werden (Formular und eingang): %s' % (nr, nr, where))
            return 2
        if args.reject is not None:
            g.state['status'] = 'abgelehnt'
            save_json(args.pruefung / 'stand.json', state)
            say('Nr. %d abgelehnt, nichts übernommen. Rohtext Nr. %d sofort löschen (Formular und eingang): %s' % (nr, nr, where))
            return 0
        if g.state['status'] == 'abgelehnt':
            say('Nr. %d ist abgelehnt. Nichts übernommen.' % nr)
            return 2
        if g.error:
            say('Nr. %d ist abgelehnt: %s. Nichts übernommen.' % (nr, g.error))
            return 2
        dup = duplicate_of(g, groups, state)
        if dup:
            say('Nr. %d ist ein Duplikat von Nr. %d (gleicher Inhalt): zählt nicht doppelt, nichts übernommen.%s'
                % (nr, dup[0], (' Rohtext Nr. %d kann gelöscht werden (Formular und eingang): %s' % (nr, where)) if dup[1] else ''))
            return 2
        kept, edge, unknown = split(g.records, sizes)
        for z, x, y, d, cost, fall in kept:
            zone = net_doc['zonen'].setdefault(str(z), {})
            k = str((y * GRID + x) * 9 + d)
            old = zone.get(k)
            # F3 §6.3: one ride without a fall makes it normal, the highest cost step stays
            zone[k] = [d, cost, fall, 1] if old is None else [d, max(old[1], cost), old[2] & fall, old[3] + 1]
        net_doc['zonen'] = {str(z): dict(sorted(net_doc['zonen'][str(z)].items(), key=lambda kv: int(kv[0])))
                            for z in sorted(map(int, net_doc['zonen']))}
        args.grundnetz.mkdir(parents=True, exist_ok=True)
        save_json(args.grundnetz / 'grundnetz.json', net_doc)
        g.state['status'] = 'angenommen'
        state['angenommen'].append({'nr': nr, 'inhalt': g.content})
        save_json(args.pruefung / 'stand.json', state)
        say('Nr. %d angenommen: %s Stücke in %d Zonen übernommen (nicht übernommen: %d Randstücke, %d aus Zonen ohne Größe).'
            % (nr, fmt(len(kept)), len({r[0] for r in kept}), len(edge), len(unknown)))
        say('Rohtext Nr. %d kann gelöscht werden (Formular und eingang): %s' % (nr, where))
        return 0

    pics = {}
    bilder = args.pruefung / (today + '_bilder')
    for g in groups:
        if g.records:
            g.analysis = analyse(g, groups, sizes, own, net)
            for zone in g.analysis['zones']:
                bilder.mkdir(parents=True, exist_ok=True)
                name = 'nr%d_zone%d.png' % (g.nr, zone)
                picture(bilder / name, g.nr, zone, g.analysis, g, sizes, own, net)
                pics[g.nr, zone] = '%s_bilder/%s' % (today, name)
    rp = args.pruefung / (today + '_pruefbericht.md')
    report(rp, pics, groups, state, sizes, own or {}, net, today, collect.skipped, own is not None)
    save_json(args.pruefung / 'stand.json', state)
    say('Prüfbericht: %s (%d Einsendungen, %d Bilder)' % (rp, len(groups), len(pics)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
