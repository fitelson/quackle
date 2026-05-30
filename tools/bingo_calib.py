#!/usr/bin/env python3
"""Calibrate the AI bingo-vocabulary quantile tables (kBingoQuantile[16][21]) from the
real CSW19 lexicon by walking the bundled Quackle V1 DAWG.

A bingo lays exactly 7 tiles but, played through existing board tiles, can form a word of
length 7..15. We score the FULL word's draw-count lnDrawCount = Σ ln C(bagCount[L],count_L)
and compare it to the distribution of CSW19 words OF THE SAME LENGTH, so the slider's "top
X%" is length-relative (an 8-letter bingo is judged against 8-letter words, not 7s).

DAWG V1: 1 version byte, 16-byte hash, 3 bytes, 1 alphabet-count byte, then count "<tok> "
entries, then 7-byte node records. Node i -> headerEnd + i*7: p=BE 3 bytes (first child),
letterByte[3] (bit6=lastchild, bits0-5 = 0-based letter), playability=BE 3 bytes
(terminal = playability!=0). Root child list starts at index 1.
"""
import math, bisect, os, sys
from collections import Counter

BAG = {'A':9,'B':2,'C':2,'D':4,'E':12,'F':2,'G':3,'H':2,'I':9,'J':1,'K':1,'L':4,
       'M':2,'N':6,'O':8,'P':2,'Q':1,'R':6,'S':4,'T':6,'U':4,'V':2,'W':2,'X':1,'Y':2,'Z':1}
MINLEN, MAXLEN = 7, 15
DAWG = os.path.join(os.path.dirname(__file__), '..', 'data', 'lexica', 'csw19.dawg')
data = open(DAWG,'rb').read()

assert data[0] == 1, f"expected V1 dawg, got version {data[0]}"
pos = 1 + 16 + 3
count = data[pos]; pos += 1
for _ in range(count):
    while data[pos] != 0x20: pos += 1
    pos += 1
base = pos
assert (len(data) - base) % 7 == 0
print(f"node base={base}, nodes={(len(data)-base)//7}")

def node(i):
    o = base + i*7
    p = (data[o]<<16)|(data[o+1]<<8)|data[o+2]
    lb = data[o+3]
    play = (data[o+4]<<16)|(data[o+5]<<8)|data[o+6]
    return p, (lb & 63), (lb & 64) != 0, play != 0

sys.setrecursionlimit(1000000)
bylen = {L: [] for L in range(MINLEN, MAXLEN+1)}
def walk(i, prefix):
    while True:
        p, li, last, term = node(i)
        w = prefix + chr(65 + li)
        L = len(w)
        if MINLEN <= L <= MAXLEN and term: bylen[L].append(w)
        if L < MAXLEN and p: walk(p, w)
        if last: break
        i += 1
walk(1, "")

def ln_draw(word):
    c = Counter(word); t = 0.0
    for L,k in c.items():
        n = BAG.get(L,0)
        if k > n: return None
        t += math.log(math.comb(n,k))
    return t

tables = {}      # length -> 21 quantiles
dists  = {}      # length -> sorted vals (for reference lookups)
for L in range(MINLEN, MAXLEN+1):
    vals = sorted(v for v in (ln_draw(w) for w in bylen[L]) if v is not None)
    dists[L] = vals
    N = len(vals)
    if N == 0:
        tables[L] = tables.get(MINLEN, [0.0]*21)  # fallback (shouldn't happen)
        print(f"len {L}: 0 drawable words (using fallback)"); continue
    qs = [vals[min(N-1, max(0, int(round(p/20*(N-1)))))] for p in range(21)]
    tables[L] = qs
    print(f"len {L}: words={len(bylen[L])} drawable={N}")

# Emit C 2D array; rows 0..6 duplicate row 7 (never used; bingos are >=7).
print("\nstatic const double kBingoQuantile[16][21] = {")
for L in range(0, 16):
    row = tables[min(max(L, MINLEN), MAXLEN)]
    nums = ", ".join(f"{q:7.4f}" for q in row)
    print(f"    {{ {nums} }},  // len {L if L>=MINLEN else str(L)+'->7'}")
print("};")

def refpct(w):
    L=len(w); v=ln_draw(w)
    if v is None or L not in dists: return None
    return bisect.bisect_left(dists[L], v)/len(dists[L])*100
print("\nreference percentiles (within own length):")
for w in ["REGIONS","RETINAS","NOTAIRE",          # 7
          "PANELING","NOTARIES","TZADDIQS","SQUEEZED",  # 8
          "ZETETICS","ENTOZOON"]:                  # 8 obscure-ish
    p=refpct(w); print(f"  {w} (len {len(w)}): ln={ln_draw(w) if ln_draw(w) is not None else float('nan'):.3f}  pct={p:.1f}%" if p is not None else f"  {w}: undrawable/not-in-lex")
