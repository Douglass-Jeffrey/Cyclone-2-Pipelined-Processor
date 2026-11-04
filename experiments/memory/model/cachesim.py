"""Trace-driven cache simulator matching dev/src/dcache.v and icache.v.

dcache: write-back, write-allocate (a store miss fetches the line first), one
miss per access, a write-back when the victim is valid and dirty; LRU when
associative.  write_validate=True models no-fetch-on-store-miss with per-word
valid bits: a word store that misses allocates the line without reading SRAM;
a load of a not-yet-valid word, or a sub-word store to one, fetches and merges.
icache: read-only, same indexing, LRU when associative.
"""


def dcache(trace, size=16384, line=16, ways=1, write_validate=False):
    sets = size // (line * ways)
    lb, sb = line.bit_length() - 1, sets.bit_length() - 1
    smask, wmask = sets - 1, (line >> 2) - 1
    full = (1 << (line >> 2)) - 1
    tags = [[] for _ in range(sets)]    # per set, LRU first: [tag, dirty, valid word mask]
    r = dict(acc=0, miss=0, ld_miss=0, st_miss=0, dirty_miss=0, wb=0,
             alloc=0, alloc_dirty=0, partial=0)
    for v in trace:
        addr, st, width = v & 0x3FFFF, (v >> 20) & 1, (v >> 21) & 3
        la = addr >> lb
        s, tag, word = la & smask, la >> sb, (addr >> 2) & wmask
        ways_l = tags[s]
        r["acc"] += 1
        hit = None
        for e in ways_l:
            if e[0] == tag:
                hit = e
                break
        if hit is not None:
            if ways > 1 and ways_l[-1] is not hit:
                ways_l.remove(hit); ways_l.append(hit)
            if write_validate and not (hit[2] >> word) & 1:
                if st and width == 2:
                    hit[2] |= 1 << word
                else:                       # fetch and merge; no victim
                    r["partial"] += 1
                    hit[2] = full
            if st:
                hit[1] = 1
            continue
        # miss: evict LRU if the set is full
        victim_dirty = 0
        if len(ways_l) == ways:
            vic = ways_l.pop(0)
            victim_dirty = vic[1]
        if victim_dirty:
            r["wb"] += 1
        if write_validate and st and width == 2:
            r["alloc"] += 1
            r["alloc_dirty"] += victim_dirty
            ways_l.append([tag, 1, 1 << word])
            continue
        r["miss"] += 1
        r["st_miss" if st else "ld_miss"] += 1
        r["dirty_miss"] += victim_dirty
        ways_l.append([tag, st, full])
    return r


def icache(fetch, size=8192, line=16, ways=1):
    sets = size // (line * ways)
    lb, sb = line.bit_length() - 1, sets.bit_length() - 1
    smask = sets - 1
    tags = [[] for _ in range(sets)]
    miss, last = 0, -1
    for pc in fetch:
        la = pc >> lb
        if la == last:                      # same line as the previous fetch: a hit, LRU unchanged
            continue
        last = la
        s, tag = la & smask, la >> sb
        ways_l = tags[s]
        if tag in ways_l:
            if ways > 1 and ways_l[-1] != tag:
                ways_l.remove(tag); ways_l.append(tag)
            continue
        miss += 1
        if len(ways_l) == ways:
            ways_l.pop(0)
        ways_l.append(tag)
    return miss
