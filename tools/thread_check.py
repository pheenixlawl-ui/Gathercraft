"""The independent checker of the thread (0.2.4 a7, S1.1, F3 §1, §7, F4 §C/§E).

It never reads Ways.lua: it makes ways, and it checks what tools/thread_cases.lua
says the addon's thread for them is - with its own geometry, in exact fractions.

  python -I tools/thread_check.py make <ways.txt> [count] [seed]
      count random ways (1000, seed 1) and the fixed cases (U, the way back to a
      square beside an earlier one, the diagonal passed back, the L, stairs, ...)
  luajit tools/thread_cases.lua <Gathercraft folder> <ways.txt> <threads.txt>
  python -I tools/thread_check.py check <ways.txt> <threads.txt>
      every thread against the rules; exit code 1 on any breach
  python -I tools/thread_check.py selftest
      the checker on threads made by hand: good ones pass, bad ones (a bend
      off the squares, a U cut short, a guessed edge pulled, ...) are caught

The rules (for a thread that is done):
  1. you -> the first square's middle and the last square's middle -> the node
     are the straight bits of the centre line;
  2. it passes every passage of the way in its order (a side two squares share,
     the corner of a diagonal step): the first point on it after the one before;
  3. between two passages it lies in the square between them (closed) - so
     never off the squares of the way;
  4. at one point at most two passages, and then two sides at right angles;
  5. the corner of every diagonal step, the middles of the first and the last
     square and both middles of a guessed edge (CON 3, GREV 4) are points of
     it, and a guessed edge is the straight stretch between its middles;
  6. not longer than the centre line;
  7. the events the addon wrote: one per passage, at the yards found here (s)
     and the middle of the edge between the two middles (r);
  8. the points drawn: the first and the last, and every point left out lies
     on the straight line between the points drawn around it.
A thread that is not done must say why: "count" (the counter), "short" (one
square); anything else is a breach.
"""
import random
import sys
from fractions import Fraction as F

TILE = 25
ON = F(1, 10 ** 6)        # yards: a point on a passage or a square's border (the thread's crossings are worked out in floats)
SAME = F(1, 100)          # yards: two passages at one point (F4.1 §C)
CON, GREV = 3, 4


# ---------------------------------------------------------------- ways
def centre(g):
    return (g + 0.5) * TILE


def write_way(f, wid, squares, kinds, player=None, node=None):
    cs = [(centre(gx), centre(gy)) for gx, gy in squares]
    pts = [player or cs[0]] + cs + [node or cs[-1]]
    f.write("way %s %d\n" % (wid, len(pts)))
    for i, (x, y) in enumerate(pts):
        k = -1 if i <= 1 or i == len(pts) - 1 else kinds[i - 2]
        f.write("%r %r %d\n" % (float(x), float(y), k))
    f.write("end\n")


DIRS = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]


def random_way(rnd):
    m = rnd.choice([rnd.randint(2, 6), rnd.randint(5, 40), rnd.randint(30, 120), rnd.randint(100, 300)])
    edge = rnd.random() < 0.15
    if edge:  # along a border of the map
        gx, gy = rnd.choice([(0, rnd.randint(0, 1023)), (1023, rnd.randint(0, 1023)), (rnd.randint(0, 1023), 0), (rnd.randint(0, 1023), 1023)])
    else:
        gx, gy = rnd.randint(0, 1023), rnd.randint(0, 1023)
    simple = rnd.random() < 0.8
    squares, seen = [(gx, gy)], {(gx, gy)}
    d = rnd.randrange(8)
    keep = rnd.choice([0.3, 0.6, 0.85])
    while len(squares) < m:
        if rnd.random() < 0.07:  # a pattern: a U, a diagonal passed back, a diagonal and a side back over its corner
            pat = rnd.choice(["U", "UR", "back", "diagback"])
            x, y = squares[-1]
            if pat == "U":
                steps = [(1, 0), (0, 1), (-1, 0)]
            elif pat == "UR":
                steps = [(0, 1), (-1, 0), (0, -1)]
            elif pat == "back":
                steps = [(1, 1), (-1, 0)]
            else:
                steps = [(1, 1), (-1, -1)]
            path = []
            for sx, sy in steps:
                x, y = x + sx, y + sy
                path.append((x, y))
            if all(0 <= a <= 1023 and 0 <= b <= 1023 for a, b in path) and (not simple or not any(p in seen for p in path)) and len(set(path)) == len(path):
                for p in path:
                    squares.append(p)
                    seen.add(p)
                continue
        if rnd.random() > keep:
            d = (d + rnd.choice([-2, -1, 1, 2])) % 8
        ok = False
        for tries in range(8):
            dx, dy = DIRS[(d + tries * (1 if tries % 2 else -1) * ((tries + 1) // 2)) % 8] if tries else DIRS[d]
            x, y = squares[-1][0] + dx, squares[-1][1] + dy
            if 0 <= x <= 1023 and 0 <= y <= 1023 and (not simple or (x, y) not in seen) and (x, y) != squares[-1]:
                if len(squares) >= 2 and (x, y) == squares[-2] and rnd.random() < 0.8:
                    continue
                ok = True
                break
        if not ok:
            break
        squares.append((x, y))
        seen.add((x, y))
    kinds = [rnd.choices([1, 2, CON, GREV], [70, 15, 8, 7])[0] for _ in range(len(squares) - 1)]

    def offside(sq):
        cx, cy = centre(sq[0]), centre(sq[1])
        r = rnd.random()
        if r < 0.3:
            return None
        if r < 0.7:
            return (cx + rnd.uniform(-12.4, 12.4), cy + rnd.uniform(-12.4, 12.4))
        a, dist = rnd.uniform(0, 6.283), rnd.uniform(12.5, 30)
        import math
        return (cx + dist * math.cos(a), cy + dist * math.sin(a))
    return squares, kinds, offside(squares[0]), offside(squares[-1])


FIXED = {
    # name: squares, kinds
    "U": ([(-2, 0), (-1, 0), (0, 0), (1, 0), (1, 1), (0, 1), (-1, 1), (-2, 1)], None),
    "U-long": ([(x, 10) for x in range(0, 6)] + [(5, 11)] + [(x, 11) for x in range(4, -1, -1)], None),
    "self-touch": ([(0, 0), (1, 0), (2, 0), (3, 0), (3, 1), (3, 2), (2, 2), (1, 2), (1, 1)], None),
    "diagonal-back": ([(-1, 0), (0, 0), (1, 1), (1, 2), (0, 1), (-1, 1)], None),
    "diagonal-passed-back": ([(-1, 0), (0, 0), (1, 1), (0, 0), (-1, 0)], None),
    "diagonal-and-side-back": ([(-1, 0), (0, 0), (1, 1), (0, 1), (-1, 1)], None),
    "same-side-back": ([(-1, 0), (0, 0), (1, 0), (0, 0), (0, 1)], None),
    "L": ([(0, 0), (1, 0), (2, 0), (2, 1), (2, 2)], None),
    "L-back": ([(2, 2), (2, 1), (2, 0), (1, 0), (0, 0)], None),
    "stair80": (None, None),
    "two-diagonals": ([(0, 0), (1, 1), (2, 2), (3, 2)], None),
    "con-one": ([(0, 0), (1, 0), (2, 0), (3, 1), (4, 1), (5, 1)], [1, 1, CON, 1, 1]),
    "grev-one": ([(0, 0), (1, 0), (2, 1), (3, 1), (4, 2), (5, 2)], [1, 1, 1, GREV, 1]),
    "two-guessed": ([(0, 0), (1, 0), (2, 0), (3, 0), (4, 1), (5, 1)], [1, CON, GREV, 1, 1]),
    "map-west": ([(0, y) for y in range(100, 110)] + [(1, 110), (0, 111)], None),
    "map-east": ([(1023, y) for y in range(100, 110)] + [(1022, 110), (1023, 111)], None),
    "map-south": ([(x, 0) for x in range(100, 110)] + [(110, 1), (111, 0)], None),
    "map-north": ([(x, 1023) for x in range(100, 110)] + [(110, 1022), (111, 1023)], None),
    "on-a-side": ([(0, 0), (1, 0), (1, 1), (2, 1), (3, 1), (3, 0), (4, 0)], None),
}


def fixed_squares(name):
    sq, kinds = FIXED[name]
    if name == "stair80":
        sq, x, y = [(0, 0)], 0, 0
        for i in range(1, 81):
            x, y = (x + 1, y) if i % 2 == 1 else (x + 1, y + 1)
            sq.append((x, y))
    return sq, kinds or [1] * (len(sq) - 1)


def make(path, count=1000, seed=1):
    rnd = random.Random(seed)
    with open(path, "w") as f:
        for name in FIXED:
            sq, kinds = fixed_squares(name)
            write_way(f, "fixed-" + name, sq, kinds)
        # Codex' entry from the side and you and the node 30 yd off the squares
        write_way(f, "fixed-side-entry", [(1, 0), (2, 0), (3, 0), (4, 0), (5, 0)], [1] * 4, player=(12.5, 14.5))
        write_way(f, "fixed-off-30", [(0, 0), (1, 0), (2, 1), (3, 1)], [1] * 3, player=(12.5, 42.5), node=(87.5, 7.5))
        for i in range(count):
            sq, kinds, p, n = random_way(rnd)
            write_way(f, "r%d" % i, sq, kinds, p, n)


# ---------------------------------------------------------------- reading
def read_ways(path):
    ways, cur = {}, None
    for line in open(path):
        w = line.split()
        if not w:
            continue
        if w[0] == "way":
            cur = (w[1], [])
        elif w[0] == "end":
            ways[cur[0]] = cur[1]
        else:
            cur[1].append((float(w[0]), float(w[1]), int(w[2])))
    return ways


def read_threads(path):
    out, cur = {}, None
    for line in open(path):
        w = line.split()
        if w[0] == "way":
            cur = {"state": w[2], "reason": w[3], "used": int(w[4]), "limit": int(w[5]), "repairs": int(w[6]), "p": [], "e": [], "d": []}
            out[w[1]] = cur
        elif w[0] == "p":
            cur["p"].append((float(w[1]), float(w[2]), int(w[3]), int(w[4])))
        elif w[0] == "e":
            cur["e"].append((int(w[1]), int(w[2]), float(w[3]), float(w[4]), float(w[5]), float(w[6])))
        elif w[0] == "d":
            cur["d"] = [int(v) for v in w[1:]]
    return out


# ---------------------------------------------------------------- geometry (fractions)
def passages(cs):
    """per step i (middle i -> i+1): ('corner', P) or ('side', axis, value, lo, hi) in yards; None if not side by side"""
    out = []
    for (ax, ay), (bx, by) in zip(cs, cs[1:]):
        ga, gb = (int(ax // TILE), int(ay // TILE)), (int(bx // TILE), int(by // TILE))
        dx, dy = gb[0] - ga[0], gb[1] - ga[1]
        if max(abs(dx), abs(dy)) != 1:
            out.append(None)
        elif dx and dy:
            out.append(("corner", (F(max(ga[0], gb[0]) * TILE), F(max(ga[1], gb[1]) * TILE))))
        elif dx:
            out.append(("side", "x", F(max(ga[0], gb[0]) * TILE), F(ga[1] * TILE), F((ga[1] + 1) * TILE)))
        else:
            out.append(("side", "y", F(max(ga[1], gb[1]) * TILE), F(ga[0] * TILE), F((ga[0] + 1) * TILE)))
    return out


def dist(a, b):
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


class Line:
    def __init__(self, pts):
        self.p = [(F(x), F(y)) for x, y in pts]
        self.cum = [0.0]
        for a, b in zip(self.p, self.p[1:]):
            self.cum.append(self.cum[-1] + dist(a, b))

    def at(self, k, t):
        (ax, ay), (bx, by) = self.p[k], self.p[k + 1]
        return (ax + t * (bx - ax), ay + t * (by - ay))

    def arc(self, k, t):
        return self.cum[k] + float(t) * (self.cum[k + 1] - self.cum[k])


def seg_box(line, k, box, lo):
    """the t of segment k from lo to 1 inside the box (x0, x1, y0, y1), closed: (a, b), or None"""
    (ax, ay), (bx, by) = line.p[k], line.p[k + 1]
    x0, x1, y0, y1 = box
    a, b = lo, F(1)
    for p, d, b0, b1 in ((ax, bx - ax, x0, x1), (ay, by - ay, y0, y1)):
        if d == 0:
            if p < b0 or p > b1:
                return None
        else:
            t1, t2 = (b0 - p) / d, (b1 - p) / d
            if t1 > t2:
                t1, t2 = t2, t1
            a, b = max(a, t1), min(b, t2)
    return (a, b) if a <= b else None


def sq_box(sq):
    return (F(sq[0] * TILE) - ON, F((sq[0] + 1) * TILE) + ON, F(sq[1] * TILE) - ON, F((sq[1] + 1) * TILE) + ON)


def pas_box(ps, on=ON):
    if ps[0] == "corner":
        px, py = ps[1]
        return (px - on, px + on, py - on, py + on)
    _, axis, val, a0, a1 = ps
    if axis == "x":
        return (val - on, val + on, a0 - on, a1 + on)
    return (a0 - on, a1 + on, val - on, val + on)


def latest_in(line, sq, ps, k0, t0):
    """From (k0, t0) the line stays in the square sq until it first leaves it. The latest (k, t) of that
    stay on the passage ps, or None. (The latest, not the first: a line may touch a passage's end and go
    on inside the square, and pass the passage further on.)"""
    sb, pb, exact = sq_box(sq), pas_box(ps), pas_box(ps, F(0))
    best, k, lo = None, k0, t0
    while k < len(line.p) - 1:
        iv = seg_box(line, k, sb, lo)
        if not iv or iv[0] > lo:
            break  # (outside the square here: the stay is over)
        on = seg_box(line, k, pb, lo)
        if on:
            c, d = max(on[0], iv[0]), min(on[1], iv[1])
            if c <= d:
                # on the passage itself where the line meets it exactly (within ON only otherwise)
                ex = seg_box(line, k, exact, c)
                best = (k, min(ex[1], d)) if ex and ex[0] <= d else (k, d)
        if iv[1] < 1:
            break
        k, lo = k + 1, F(0)
    return best


def stays(line, sq, ka, ta, kb, tb):
    """the line from (ka, ta) to (kb, tb) inside the square (closed; the square is convex: its points suffice)"""
    sb = sq_box(sq)
    pts = [line.at(ka, ta), line.at(kb, tb)] + [line.p[j] for j in range(ka + 1, kb + 1)]
    return all(sb[0] <= x <= sb[1] and sb[2] <= y <= sb[3] for x, y in pts)


def check_one(wid, way, th):
    """the breaches of one thread, as text"""
    bad = []
    n = len(way)
    player, node = (F(way[0][0]), F(way[0][1])), (F(way[-1][0]), F(way[-1][1]))
    cs = [(x, y) for x, y, _ in way[1:-1]]
    kinds = [k for _, _, k in way[2:-1]]
    sqs = [(int(x // TILE), int(y // TILE)) for x, y in cs]
    pas = passages(cs)
    if th["state"] != "done":
        if th["reason"] == "count":
            return bad
        if th["reason"] == "short" and n < 4:
            return bad
        if th["reason"] == "step" and None in pas:
            return bad
        return ["not done: %s" % th["reason"]]
    pts = [(x, y) for x, y, _, _ in th["p"]]
    line = Line(pts)
    P = line.p
    C = [(F(x), F(y)) for x, y in cs]
    # 1. the straight bits
    if P[0] != player or P[-1] != node:
        bad.append("1: does not start at you or end at the node")
    if len(P) < 4 or P[1] != C[0] or P[-2] != C[-1]:
        bad.append("1: the first and last square's middles are not its second and last but one point")
        return bad
    last = len(P) - 2  # the exit middle
    # 2. the passages in their order, 3. inside the square between them: this checker's own crossings
    hits, k, t = [], 1, F(0)
    for i, ps in enumerate(pas):
        if ps is None:
            bad.append("2: step %d is not between squares side by side" % i)
            return bad
        h = latest_in(line, sqs[i], ps, k, t)
        if not h:
            bad.append("2/3: passage %d (%s) is not passed from inside square %d %s" % (i, ps[0], i, sqs[i]))
            return bad
        k, t = h
        hits.append((k, t, line.arc(k, t), line.at(k, t)))
    if (last, F(0)) < (k, t) or not stays(line, sqs[-1], k, t, last, F(0)):
        bad.append("3: the last square %s is left before its middle" % (sqs[-1],))
    marks = [(1, F(0), line.cum[1], P[1])] + hits + [(last, F(0), line.cum[last], P[last])]
    # 5. anchors; guessed edges
    verts = {}
    for idx, q in enumerate(P):
        verts.setdefault(q, []).append(line.cum[idx])

    def vertex_at(q, s):
        return any(abs(v - s) <= 1e-6 for v in verts.get(q, []))
    for i, ps in enumerate(pas):
        if ps[0] == "corner" and not vertex_at(ps[1], hits[i][2]):
            bad.append("5: the corner of diagonal step %d is no point of the thread" % i)
    for i, kd in enumerate(kinds):
        if kd in (CON, GREV):
            # middle i and i+1: points, the stretch between them straight and as long as the edge
            a_lo, a_hi = marks[i][2], marks[i + 1][2]          # square i's part
            b_lo, b_hi = marks[i + 1][2], marks[i + 2][2]      # square i+1's part
            ia = [idx for idx, q in enumerate(P) if q == C[i] and a_lo - 1e-6 <= line.cum[idx] <= a_hi + 1e-6]
            ib = [idx for idx, q in enumerate(P) if q == C[i + 1] and b_lo - 1e-6 <= line.cum[idx] <= b_hi + 1e-6]
            if not ia or not ib:
                bad.append("5: a guessed edge (step %d) without both its middles" % i)
                continue
            if abs((line.cum[ib[0]] - line.cum[ia[-1]]) - dist(C[i], C[i + 1])) > 1e-6:
                bad.append("5: the guessed edge (step %d) is not the straight stretch between its middles" % i)
    # 6. length
    centre_len = dist(player, C[0]) + sum(dist(a, b) for a, b in zip(C, C[1:])) + dist(C[-1], node)
    if line.cum[-1] > centre_len + 1e-6:
        bad.append("6: longer than the centre line (%.4f > %.4f)" % (line.cum[-1], centre_len))
    # 7. the addon's events: one per passage, a crossing as good as this checker's - on the passage, in
    # order, the line between two of them inside the square between - with r the middle of the edge
    raw = [0.0, dist(player, C[0])]
    for a, b in zip(C, C[1:]):
        raw.append(raw[-1] + dist(a, b))
    ev = {}
    for slot, kd, s, r, x, y in th["e"]:
        ev.setdefault(slot, []).append((kd, s, r, x, y))
    pos, prev_s, ok7, lua = (1, F(0)), line.cum[1], True, []
    for i, ps in enumerate(pas):
        slot = 2 * (i + 2) + 1
        got = ev.get(slot)
        if not got or len(got) != 1:
            bad.append("7: passage %d has %s events" % (i, len(got) if got else "no"))
            ok7 = False
            break
        kd, s, r, x, y = got[0]
        want_kind = 0 if ps[0] == "corner" else (1 if ps[1] == "x" else 2)
        if kd != want_kind or abs(r - (raw[i + 1] + raw[i + 2]) / 2) > 1e-9:
            bad.append("7: passage %d: event kind %d r %.9f, wanted %d %.9f" % (i, kd, r, want_kind, (raw[i + 1] + raw[i + 2]) / 2))
        if s < prev_s - 1e-9:
            bad.append("7: passage %d: its event comes before the one before" % i)
            ok7 = False
            break
        # where on the line it is: the first segment from the one before with the event's point and yards
        X, Y, found = F(x), F(y), None
        for kk in range(pos[0], len(P) - 1):
            (ax, ay), (bx, by) = P[kk], P[kk + 1]
            vx, vy = bx - ax, by - ay
            ll = vx * vx + vy * vy
            tt = F(0) if ll == 0 else min(F(1), max(F(0), ((X - ax) * vx + (Y - ay) * vy) / ll))
            if kk == pos[0] and tt < pos[1]:
                tt = pos[1]
            qx, qy = ax + tt * vx, ay + tt * vy
            if abs(qx - X) <= ON and abs(qy - Y) <= ON and abs(line.arc(kk, tt) - s) <= 1e-6:
                found = (kk, tt)
                break
        if not found:
            bad.append("7: passage %d: the event's point (%.6f, %.6f) is not on the line at %.6f yd" % (i, x, y, s))
            ok7 = False
            break
        pb = pas_box(ps)
        if not (pb[0] <= X <= pb[1] and pb[2] <= Y <= pb[3]):
            bad.append("7: passage %d: the event's point is not on the passage" % i)
        if not stays(line, sqs[i], pos[0], pos[1], found[0], found[1]):
            bad.append("7: passage %d: the line between the event before and this one leaves square %d" % (i, i))
        pos, prev_s = found, s
        lua.append(s)
    if ok7 and not stays(line, sqs[-1], pos[0], pos[1], last, F(0)):
        bad.append("7: the line after the last event leaves the last square")
    # 4. at one point (by the events, checked above to be crossings)
    i = 0
    while ok7 and i < len(lua):
        j = i
        while j + 1 < len(lua) and lua[j + 1] - lua[i] <= SAME:
            j += 1
        g = j - i + 1
        if g >= 3:
            bad.append("4: %d passages at one point (from %d)" % (g, i))
        elif g == 2:
            a, b = pas[i], pas[j]
            if a[0] == "corner" or b[0] == "corner":
                bad.append("4: a corner and another passage at one point (%d, %d)" % (i, j))
            elif a[1] == b[1]:
                bad.append("4: the same side twice at one point (%d, %d)" % (i, j))
        i = j + 1
    # 8. the points drawn
    d = th["d"]
    if not d or d[0] != 1 or d[-1] != len(P) or any(b <= a for a, b in zip(d, d[1:])):
        bad.append("8: the points drawn are not in order from the first to the last")
    else:
        for a, b in zip(d, d[1:]):
            A, B = P[a - 1], P[b - 1]
            for j in range(a + 1, b):
                Q = P[j - 1]
                cross = (B[0] - A[0]) * (Q[1] - A[1]) - (B[1] - A[1]) * (Q[0] - A[0])
                dot = (Q[0] - A[0]) * (B[0] - A[0]) + (Q[1] - A[1]) * (B[1] - A[1])
                ll = (B[0] - A[0]) ** 2 + (B[1] - A[1]) ** 2
                if not (Q == A or Q == B or (abs(cross) <= F(1, 10 ** 9) and 0 <= dot <= ll)):
                    bad.append("8: point %d is left out but does not lie between %d and %d" % (j, a, b))
                    break
    return bad


def check(ways_path, threads_path):
    ways, ths = read_ways(ways_path), read_threads(threads_path)
    stats = {"ways": 0, "done": 0, "repaired": 0}
    fails = {}
    breaches = 0
    used = []
    for wid, way in ways.items():
        th = ths.get(wid)
        stats["ways"] += 1
        if not th:
            print("BREACH %s: no thread written" % wid)
            breaches += 1
            continue
        if th["state"] == "done":
            stats["done"] += 1
            used.append(th["used"] / max(th["limit"], 1))
            if th["repairs"]:
                stats["repaired"] += 1
        else:
            fails[th["reason"]] = fails.get(th["reason"], 0) + 1
        for b in check_one(wid, way, th):
            print("BREACH %s: %s" % (wid, b))
            breaches += 1
    used.sort()
    print("%d ways: %d done (%d repaired), not done: %s; booked of the counter: median %.2f, most %.2f; %d breaches" % (
        stats["ways"], stats["done"], stats["repaired"], ", ".join("%s %d" % kv for kv in sorted(fails.items())) or "none",
        used[len(used) // 2] if used else 0, used[-1] if used else 0, breaches))
    return breaches


# ---------------------------------------------------------------- the checker checked
def selftest():
    def way(squares, kinds=None, player=None, node=None):
        cs = [(centre(gx), centre(gy)) for gx, gy in squares]
        pts = [player or cs[0]] + cs + [node or cs[-1]]
        kinds = kinds or [1] * (len(squares) - 1)
        return [(x, y, (-1 if i <= 1 or i == len(pts) - 1 else kinds[i - 2])) for i, (x, y) in enumerate(pts)]

    def thread(pts, way_, events=None):
        # events made here from this checker's own geometry: one per passage
        line = Line(pts)
        cs = [(x, y) for x, y, _ in way_[1:-1]]
        pas = passages(cs)
        raw = [0.0, dist(way_[0][:2], cs[0])]
        for a, b in zip(cs, cs[1:]):
            raw.append(raw[-1] + dist(a, b))
        sqs = [(int(x // TILE), int(y // TILE)) for x, y in cs]
        ev, k, t = [], 1, F(0)
        for i, ps in enumerate(pas):
            h = latest_in(line, sqs[i], ps, k, t)
            if not h:
                break
            k, t = h
            kd = 0 if ps[0] == "corner" else (1 if ps[1] == "x" else 2)
            x, y = line.at(k, t)
            ev.append((2 * (i + 2) + 1, kd, line.arc(k, t), (raw[i + 1] + raw[i + 2]) / 2, float(x), float(y)))
        return {"state": "done", "reason": "-", "used": 0, "limit": 1, "repairs": 0,
                "p": [(x, y, 0, 0) for x, y in pts], "e": ev, "d": list(range(1, len(pts) + 1))}
    L = way([(0, 0), (1, 0), (2, 0), (2, 1), (2, 2)])
    U = way([(-2, 0), (-1, 0), (0, 0), (1, 0), (1, 1), (0, 1), (-1, 1), (-2, 1)])
    D = way([(-1, 0), (0, 0), (1, 1), (0, 1), (-1, 1)])
    G = way([(0, 0), (1, 0), (2, 0), (3, 1), (4, 1), (5, 1)], [1, 1, CON, 1, 1])
    S = way([(0, 0), (1, 1), (2, 2), (3, 2)])
    cases = [
        ("the L pulled tight", L, [(12.5, 12.5), (12.5, 12.5), (50, 25), (62.5, 62.5), (62.5, 62.5)], True),
        ("the L as the centre line", L, [(12.5, 12.5), (12.5, 12.5), (37.5, 12.5), (62.5, 12.5), (62.5, 37.5), (62.5, 62.5), (62.5, 62.5)], True),
        ("a bend off the squares (offset bend)", L, [(12.5, 12.5), (12.5, 12.5), (40, 30), (62.5, 62.5), (62.5, 62.5)], False),
        ("the L cut across its corner square", L, [(12.5, 12.5), (12.5, 12.5), (62.5, 62.5), (62.5, 62.5)], False),
        ("the U cut short at its corner", U, [(-37.5, 12.5), (-37.5, 12.5), (25, 25), (-37.5, 37.5), (-37.5, 37.5)], False),
        ("the U with its anchors", U, [(-37.5, 12.5), (-37.5, 12.5), (37.5, 12.5), (37.5, 37.5), (-37.5, 37.5), (-37.5, 37.5)], True),
        ("a diagonal's corner and the side back at one point", D, [(-12.5, 12.5), (-12.5, 12.5), (25, 25), (-12.5, 37.5), (-12.5, 37.5)], False),
        ("the same with the square's middle", D, [(-12.5, 12.5), (-12.5, 12.5), (25, 25), (37.5, 37.5), (-12.5, 37.5), (-12.5, 37.5)], True),
        ("a guessed edge pulled", G, [(12.5, 12.5), (12.5, 12.5), (62.5, 12.5), (137.5, 37.5), (137.5, 37.5)], False),
        ("a guessed edge kept", G, [(12.5, 12.5), (12.5, 12.5), (62.5, 12.5), (75, 25), (87.5, 37.5), (137.5, 37.5), (137.5, 37.5)], True),
        ("a diagonal's corner missed", S, [(12.5, 12.5), (12.5, 12.5), (87.5, 62.5), (87.5, 62.5)], False),
        ("two diagonals through both corners", S, [(12.5, 12.5), (12.5, 12.5), (25, 25), (50, 50), (87.5, 62.5), (87.5, 62.5)], True),
    ]
    wrong = 0
    for name, w, pts, good in cases:
        b = check_one(name, w, thread(pts, w))
        if (not b) != good:
            wrong += 1
            print("SELFTEST WRONG: %s: %s" % (name, b or "accepted"))
        else:
            print("selftest ok: %s%s" % (name, "" if good else " (caught: %s)" % b[0]))
    # an event at the wrong yards, a point drawn wrongly left out
    th = thread([(12.5, 12.5), (12.5, 12.5), (50, 25), (62.5, 62.5), (62.5, 62.5)], L)
    th["e"][1] = (th["e"][1][0], th["e"][1][1], th["e"][1][2] + 0.5) + th["e"][1][3:]
    b = check_one("event", L, th)
    print(("selftest ok: an event at the wrong yards (caught: %s)" % b[0]) if b else "SELFTEST WRONG: an event at the wrong yards accepted")
    wrong += 0 if b else 1
    th = thread([(12.5, 12.5), (12.5, 12.5), (50, 25), (62.5, 62.5), (62.5, 62.5)], L)
    th["d"] = [1, 2, 4, 5]
    b = check_one("drawn", L, th)
    print(("selftest ok: a bend left out of the points drawn (caught: %s)" % b[0]) if b else "SELFTEST WRONG: a bend left out accepted")
    wrong += 0 if b else 1
    print("selftest: %d wrong" % wrong)
    return wrong


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "make":
        make(a[1], int(a[2]) if len(a) > 2 else 1000, int(a[3]) if len(a) > 3 else 1)
    elif a and a[0] == "check":
        sys.exit(1 if check(a[1], a[2]) else 0)
    elif a and a[0] == "selftest":
        sys.exit(1 if selftest() else 0)
    else:
        print(__doc__)
        sys.exit(2)
