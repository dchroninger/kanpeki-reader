#!/usr/bin/env python3
"""Extracted volume folders -> Phase-0-style CBZs (STORED, 0000.jpg…, ComicInfo.xml).

    python3 tools/build_series.py <choice.json> <series name> <out dir>

choice.json maps volume number -> folder of page images. Ordering: cover /
表紙 / _C first, '#' colour frontispieces, body, omake/巻末 last, natural
sort within each group (same ordering rules as phase0_comicinfo.py). Images under
12 KB are scanner junk and dropped.
"""
import io, json, os, re, sys, zipfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from phase0_comicinfo import build_xml
from PIL import Image

choice = json.load(open(sys.argv[1])); series = sys.argv[2]; out = sys.argv[3]
os.makedirs(out, exist_ok=True)
IMG = re.compile(r'\.(jpg|jpeg|png|webp)$', re.I)
FW = str.maketrans("0123456789", "０１２３４５６７８９")
def nat(f): return [int(p) if p.isdigit() else p for p in re.split(r'(\d+)', f)]
def rank(f):
    if re.search(r'(_C\d|cover|表紙)', f, re.I): return 0
    if '#' in f: return 1
    if re.search(r'(omake|zassi|おまけ|巻末)', f, re.I): return 3
    return 2
for v, folder in sorted(choice.items(), key=lambda kv: int(kv[0])):
    if not folder: print(f"v{v}: no pick, skipped"); continue
    files = [f for f in os.listdir(folder) if IMG.search(f) and os.path.getsize(os.path.join(folder, f)) >= 12000]
    files.sort(key=lambda f: (rank(f), nat(f)))
    names = [f"{i:04d}{os.path.splitext(f)[1].lower()}" for i, f in enumerate(files)]
    dims = {}
    for f, n in zip(files, names):
        im = Image.open(os.path.join(folder, f)); dims[n] = (im.size[0], im.size[1], os.path.getsize(os.path.join(folder, f)))
    number = str(int(v)); title = f"{series}{number.zfill(2).translate(FW)}"
    xml = build_xml(series, number, title, names, dims)
    dst = os.path.join(out, title + ".cbz")
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_STORED) as z:
        for f, n in zip(files, names):
            zi = zipfile.ZipInfo(n, date_time=time.localtime(os.path.getmtime(os.path.join(folder, f)))[:6]); zi.external_attr = 0o644 << 16
            z.writestr(zi, open(os.path.join(folder, f), "rb").read())
        ci = zipfile.ZipInfo("ComicInfo.xml", date_time=time.localtime()[:6]); ci.external_attr = 0o644 << 16
        z.writestr(ci, xml.encode("utf-8"))
    zc = zipfile.ZipFile(dst); assert zc.testzip() is None and len(zc.namelist()) == len(files) + 1
    wide = sum(1 for n in names if dims[n][0] > dims[n][1])
    print(f"{os.path.basename(dst)}: {len(files)} pages, {wide} wide, {os.path.getsize(dst)/2**20:.0f} MB  <- {os.path.basename(folder)}")
