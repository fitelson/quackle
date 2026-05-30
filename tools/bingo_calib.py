import math
bag = {'A':9,'B':2,'C':2,'D':4,'E':12,'F':2,'G':3,'H':2,'I':9,'J':1,'K':1,'L':4,
       'M':2,'N':6,'O':8,'P':2,'Q':1,'R':6,'S':4,'T':6,'U':4,'V':2,'W':2,'X':1,'Y':2,'Z':1}
def ln_draw(word):
    from collections import Counter
    c = Counter(word)
    total = 0.0
    for L,k in c.items():
        n = bag.get(L,0)
        if k > n:   # can't be drawn from natural tiles (needs a blank) -> exclude
            return None
        total += math.log(math.comb(n,k))
    return total
vals = []
with open('/usr/share/dict/words') as f:
    for line in f:
        w = line.strip()
        if len(w)==7 and w.isalpha() and w.islower():
            v = ln_draw(w.upper())
            if v is not None:
                vals.append(v)
vals.sort()
N = len(vals)
print(f"N drawable 7-letter words = {N}")
# Q(p) grid
grid = [i/20 for i in range(21)]  # 0.00..1.00 step 0.05
qs = []
for p in grid:
    idx = min(N-1, max(0, int(round(p*(N-1)))))
    qs.append(vals[idx])
print("Q grid (p: lnDrawCount):")
for p,q in zip(grid,qs):
    print(f"  p={p:.2f}  Q={q:.4f}")
# C array
print("\nstatic const double kBingoQuantile[21] = {")
print("    " + ", ".join(f"{q:.4f}" for q in qs))
print("};")
# REGIONS reference
reg = ln_draw("REGIONS")
import bisect
rank = bisect.bisect_left(vals, reg)
print(f"\nREGIONS lnDrawCount={reg:.4f}  -> empirical percentile = {rank/N*100:.2f}%  (top {100-rank/N*100:.2f}%)")
# a few more references
for w in ["RETINAS","NOTAIRE","TOENAIL","PLAYERS","JACKETS","QUICKLY","WIZARDS","JUKEBOX"]:
    v=ln_draw(w)
    if v is None: print(f"  {w}: undrawable"); continue
    r=bisect.bisect_left(vals,v); print(f"  {w}: ln={v:.3f} pct={r/N*100:.1f}%")
