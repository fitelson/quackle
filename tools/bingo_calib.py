#!/usr/bin/env python3
"""Calibrate the AI bingo-vocabulary quantile table (kBingoQuantile) from the real
CSW19 lexicon by walking the bundled Quackle V1 DAWG.

DAWG V1 format (see libquackle/lexiconparameters.cpp): 1 version byte, 16-byte hash,
3 bytes, 1 alphabet-count byte, then count entries each "<token> " (token + space),
then 7-byte node records. Node i -> byte offset headerEnd + i*7:
  p          = big-endian 3 bytes [0..2]   (first-child node index, 0 = none)
  letterByte = [3]: bit6=lastchild, bit7=!british, bits0-5 = 0-based letter index
  playability= big-endian 3 bytes [4..6];  terminal = (playability != 0)
Root child list starts at node index 1.
"""
import math, bisect, os, sys
from collections import Counter

BAG = {'A':9,'B':2,'C':2,'D':4,'E':12,'F':2,'G':3,'H':2,'I':9,'J':1,'K':1,'L':4,
       'M':2,'N':6,'O':8,'P':2,'Q':1,'R':6,'S':4,'T':6,'U':4,'V':2,'W':2,'X':1,'Y':2,'Z':1}
DAWG = os.path.join(os.path.dirname(__file__), '..', 'data', 'lexica', 'csw19.dawg')
data = open(DAWG,'rb').read()

# --- parse V1 header to find where node records begin ---
assert data[0] == 1, f"expected V1 dawg, got version {data[0]}"
pos = 1 + 16 + 3              # version + hash + 3 bytes
count = data[pos]; pos += 1  # alphabet entry count
for _ in range(count):
    while data[pos] != 0x20:  # token bytes
        pos += 1
    pos += 1                  # separator space
base = pos
assert (len(data) - base) % 7 == 0, f"node region {len(data)-base} not divisible by 7"
print(f"header end (node base) = {base}, nodes = {(len(data)-base)//7}")

def node(i):
    o = base + i*7
    p = (data[o]<<16)|(data[o+1]<<8)|data[o+2]
    lb = data[o+3]
    play = (data[o+4]<<16)|(data[o+5]<<8)|data[o+6]
    return p, (lb & 63), (lb & 64) != 0, play != 0   # p, letterIdx, lastchild, terminal

sys.setrecursionlimit(100000)
words7 = []
def walk(i, prefix):
    while True:
        p, li, last, term = node(i)
        w = prefix + chr(65 + li)
        if len(w) == 7:
            if term: words7.append(w)
        elif p:
            walk(p, w)
        if last: break
        i += 1
walk(1, "")

print(f"CSW19 7-letter words found = {len(words7)}")
assert "REGIONS" in words7, "sanity: REGIONS not found!"
for w in ["AALIIS","ZYMURGY","QI"*0 or "JUKEBOX"]:
    pass

def ln_draw(word):
    c = Counter(word); t = 0.0
    for L,k in c.items():
        n = BAG.get(L,0)
        if k > n: return None      # needs a blank to draw -> exclude
        t += math.log(math.comb(n,k))
    return t

vals = sorted(v for v in (ln_draw(w) for w in words7) if v is not None)
N = len(vals)
print(f"drawable (no-blank) 7-letter words = {N}")

grid = [i/20 for i in range(21)]
qs = [vals[min(N-1, max(0, int(round(p*(N-1)))))] for p in grid]
print("\nstatic const double kBingoQuantile[21] = {")
print("    " + ", ".join(f"{q:.4f}" for q in qs))
print("};")

def pct(w):
    v = ln_draw(w)
    if v is None: return None
    return bisect.bisect_left(vals, v)/N*100
print("\nreference percentiles (CSW19):")
for w in ["REGIONS","RETINAS","NOTAIRE","TOENAIL","PLAYERS","JACKETS","WIZARDS","QUICKLY","JUKEBOX"]:
    p = pct(w); print(f"  {w}: ln={ln_draw(w):.3f}  pct={p:.2f}%" if p is not None else f"  {w}: undrawable")
