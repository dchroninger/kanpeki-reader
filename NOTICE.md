# Third-party components, data, and licenses

Kanpeki has **no third-party code dependencies**: the app and its three local Swift packages
(`KanpekiCore`, `KanpekiDictionary`, `KanpekiOCR`) use only Apple frameworks. What it *does* use
is data and a model. Those are built or converted locally, are gitignored, and are not distributed
in this repository (see `.gitignore` and `docs/OCR.md`).

This is a good-faith summary, **not legal advice**.

| Component | Used for | License / terms |
|---|---|---|
| [manga-ocr](https://github.com/kha-white/manga-ocr) (`kha-white/manga-ocr-base`) | text recognition, converted to Core ML by `tools/ml/convert_manga_ocr.py` | Apache-2.0 |
| [JMdict](https://www.edrdg.org/jmdict/j_jmdict.html) (EDRDG) | dictionary entries, built into a SQLite file by `tools/ml/build_jmdict.py` | CC BY-SA 4.0. Attribution required; the app shows it |
| Kanjium accent data | pitch-accent display | Listed upstream as CC BY-SA 4.0, but its provenance is mixed and includes data derived from commercial dictionaries. Attributed in-app and **not redistributed here** beyond the small test fixture below. Treat as personal / non-commercial use unless you have verified the upstream terms |

## Test fixture

`KanpekiDictionary/Tests/KanpekiDictionaryTests/Fixtures/jmdict-mini.sqlite` is a 58-word extract of the
JMdict and Kanjium data above, kept only so the dictionary tests can run without the full 50 MB database.
It carries the same attributions and terms as its sources.

## Your library

Kanpeki reads comic archives (CBZ) that *you* already own. It ships with no catalog and hosts no content.
The archives and page images in your iCloud Drive are yours; none are, or should ever be, committed here
(`*.cbz` is gitignored).
