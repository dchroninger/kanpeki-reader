"""Tiny ZIP fixtures for KanpekiCoreTests. Regenerate with ~/Manga/tools/venv/bin/python."""
import io, os, sys, zipfile
from PIL import Image
out = sys.argv[1]
def png(w, h, c):
    b = io.BytesIO(); Image.new("RGB", (w, h), c).save(b, "PNG"); return b.getvalue()
pages = [("cover.png", png(8, 12, (200, 30, 40))), ("1.png", png(8, 12, (0, 0, 0))),
         ("10.png", png(8, 12, (50, 50, 50))), ("2.png", png(16, 8, (90, 90, 90))),  # 2 is wide
         ("__MACOSX/._1.png", b"junk"), ("notes.txt", b"ignored")]
ci = """<?xml version="1.0"?>
<ComicInfo>
  <Series>テスト</Series>
  <Number>3b</Number>
  <Volume>3</Volume>
  <LanguageISO>ja</LanguageISO>
  <Manga>YesAndRightToLeft</Manga>
  <PageCount>4</PageCount>
  <Pages>
    <Page Image="0" Type="FrontCover" ImageWidth="8" ImageHeight="12"/>
    <Page Image="1"/>
    <Page Image="2" DoublePage="true" ImageWidth="16" ImageHeight="8"/>
    <Page Image="3"/>
  </Pages>
</ComicInfo>
"""
for name, method, z64 in [("stored.zip", zipfile.ZIP_STORED, False), ("deflate.zip", zipfile.ZIP_DEFLATED, False), ("zip64.zip", zipfile.ZIP_STORED, True)]:
    with zipfile.ZipFile(os.path.join(out, name), "w", method) as z:
        for n, d in pages:
            if z64:
                with z.open(n, "w", force_zip64=True) as f: f.write(d)
            else:
                z.writestr(n, d)
        z.writestr("ComicInfo.xml", ci)
print("ok")
