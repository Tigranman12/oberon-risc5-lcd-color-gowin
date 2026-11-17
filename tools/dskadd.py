#!/usr/bin/env python3
# dskadd.py - OBERON_RISC5_LCD_gowin L4: add files to a Project Oberon 2013 disk image without
# project-norebo, so a new module can reach the SD card.
#   dskadd.py IMAGE OUT FILE...     OUT = IMAGE + the FILEs (a file of the same name is replaced)
# A FILE ending in .Mod / .Tool / .Text is a plain text: line ends become CR, as Oberon's texts (Texts.Open reads a
# file without the text tag as plain ASCII). Each file goes into free sectors after the last used one; files up to
# 64 sectors (64 KB - 352 bytes) only (no extension tables). Then the directory B-tree is built again from all names
# (byte order, as FileDir.Search): one page of up to 24 entries, or the root at DirRootAdr 29 with up to 25 leaves
# of 12..24 entries. Oberon itself rebuilds its free-sector map from the directory at every boot (FileDir.Init,
# Kernel.MarkSector), so the old pages and replaced files become free sectors there. Layout: odsk.py's header.
# Checked at the end: every old file reads back unchanged with odsk.py, every new one equal to its source.
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odsk import Disk, SS, HS, DIRMARK, HDRMARK  # noqa: E402

DIRROOT, PGSIZE, N, SECTAB = 29, 24, 12, 64
TEXT = (".mod", ".tool", ".text")


def used_sectors(d, files):
    used = set()

    def walk(a):
        used.add(a // 29)
        s = d.sec(a)
        m, p0 = struct.unpack_from("<iI", s, 4)
        if p0:
            walk(p0)
        for k in range(m):
            p = struct.unpack_from("<I", s, 64 + 40 * k + 36)[0]
            if p:
                walk(p)
    walk(DIRROOT)
    for _, adr in files:
        h = d.sec(adr)
        aleng = struct.unpack_from("<i", h, 36)[0]
        ext = struct.unpack_from("<12I", h, 48)
        secs = struct.unpack_from("<64I", h, 96)
        for i in range(min(aleng, SECTAB - 1) + 1):
            used.add(secs[i] // 29)
        if aleng >= SECTAB:
            for e in range((aleng - SECTAB) // 256 + 1):
                used.add(ext[e] // 29)
                x = d.sec(ext[e])
                for j in range(256):
                    a = struct.unpack_from("<I", x, 4 * j)[0]
                    if a:
                        used.add(a // 29)
    return used


def page(entries, p0=0, ps=None):
    b = bytearray(SS)
    struct.pack_into("<IiI", b, 0, DIRMARK, len(entries), p0)
    for k, (name, adr) in enumerate(entries):
        o = 64 + 40 * k
        b[o:o + 32] = name.encode("latin-1").ljust(32, b"\0")
        struct.pack_into("<II", b, o + 32, adr, ps[k] if ps else 0)
    return b


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: dskadd.py IMAGE OUT FILE...")
    src, out, new = sys.argv[1], sys.argv[2], sys.argv[3:]
    d = Disk(src)
    files = list(d.entries())
    old = {n: d.read(a) for n, a in files}
    img = bytearray(d.b)
    nxt = max(used_sectors(d, files)) + 1

    def put(s, data):                                   # sector number s (address s * 29)
        o = (s - 1) * SS
        if len(img) < o + SS:
            img.extend(bytes(o + SS - len(img)))
        img[o:o + SS] = data

    names = dict(files)
    added = {}
    for path in new:
        name = os.path.basename(path)
        assert 0 < len(name) < 32 and all(c.isalnum() or c == "." for c in name), f"bad Oberon file name {name}"
        data = open(path, "rb").read()
        if name.lower().endswith(TEXT):
            data = data.replace(b"\r\n", b"\r").replace(b"\n", b"\r")
        total = HS + len(data)
        aleng = (total - 1) // SS if total > HS else 0
        bleng = total - aleng * SS
        assert aleng < SECTAB, f"{name}: {len(data)} bytes, more than 64 sectors"
        secs = list(range(nxt, nxt + aleng + 1))
        nxt += aleng + 1
        body = bytes(HS) + data
        body += bytes((aleng + 1) * SS - len(body))
        hdr = bytearray(body[:SS])
        struct.pack_into("<I", hdr, 0, HDRMARK)
        hdr[4:36] = name.encode("latin-1").ljust(32, b"\0")
        struct.pack_into("<iii", hdr, 36, aleng, bleng, 0)
        struct.pack_into("<64I", hdr, 96, *([s * 29 for s in secs] + [0] * (SECTAB - len(secs))))
        put(secs[0], hdr)
        for i, s in enumerate(secs[1:], 1):
            put(s, body[i * SS:(i + 1) * SS])
        names[name] = secs[0] * 29
        added[name] = data
        print(f"dskadd: {name} {len(data)} bytes, sectors {secs[0]}..{secs[-1]}{' (replaced)' if name in old else ''}")

    ents = sorted(names.items(), key=lambda e: e[0].encode("latin-1"))
    n = len(ents)
    if n <= PGSIZE:
        put(1, page(ents))
    else:
        leaves = (n + 1 + PGSIZE) // (PGSIZE + 1)       # the fewest leaves: n - (leaves - 1) <= 24 * leaves
        assert leaves <= PGSIZE + 1, f"{n} files: more than two directory levels"
        k = n - (leaves - 1)
        sizes = [k // leaves + (1 if i < k % leaves else 0) for i in range(leaves)]
        assert min(sizes) >= N and max(sizes) <= PGSIZE
        root, ps, i = [], [], 0
        lp = list(range(nxt, nxt + leaves))
        nxt += leaves
        for j, sz in enumerate(sizes):
            put(lp[j], page(ents[i:i + sz]))
            i += sz
            if j < leaves - 1:
                root.append(ents[i]); ps.append(lp[j + 1] * 29)
                i += 1
        put(1, page(root, lp[0] * 29, ps))
    open(out, "wb").write(img)

    e = Disk(out)                                       # check
    got = {nm: e.read(a) for nm, a in e.entries()}
    want = dict(old); want.update(added)
    assert list(got) == sorted(got, key=lambda s: s.encode("latin-1")), "directory not in order"
    assert got == want, "files differ after the rebuild"
    print(f"dskadd: {out}: {len(got)} files ({len(added)} added), {len(img)} bytes, directory checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
