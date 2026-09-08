#!/usr/bin/env python3
"""JMdict_e.gz -> compact SQLite for KanpekiDictionary.

    python3 tools/ml/build_jmdict.py tools/ml/cache/JMdict_e.gz Kanpeki/Resources/Dictionary/jmdict.sqlite
    python3 tools/ml/build_jmdict.py IN OUT --only 食べる,行く,...   # tiny fixture for tests

Schema (one row per JMdict <entry>, forms indexed for prefix/exact lookup):
  entries(id, seq, common)               common = any k_ele/r_ele carries a *_pri tag
  forms(entry_id, text, kind, common)    kind 'k' kanji form / 'r' reading;  UNIQUE-ish index on text
  senses(entry_id, ord, pos, misc, gloss) pos/misc: ';'-joined entity codes; gloss: ' | '-joined
  pitch(text, reading, accents)          Kanjium accents.txt (CC BY-SA 4.0), accents ','-joined ints
JMdict is © EDRDG, Kanjium © its authors; both CC BY-SA 4.0 — the app must show attribution.
Pass --accents PATH to include pitch data.
"""
import gzip, sqlite3, sys, os, re, time
import xml.etree.ElementTree as ET

src, out = sys.argv[1], sys.argv[2]
only = None
if "--only" in sys.argv:
    only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
if os.path.exists(out): os.remove(out)
db = sqlite3.connect(out)
db.executescript("""
PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
CREATE TABLE entries(id INTEGER PRIMARY KEY, seq INTEGER NOT NULL, common INTEGER NOT NULL);
CREATE TABLE forms(entry_id INTEGER NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL, common INTEGER NOT NULL);
CREATE TABLE senses(entry_id INTEGER NOT NULL, ord INTEGER NOT NULL, pos TEXT NOT NULL, misc TEXT NOT NULL, gloss TEXT NOT NULL);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE pitch(text TEXT NOT NULL, reading TEXT NOT NULL, accents TEXT NOT NULL);
""")
# Entity codes: ElementTree expands &n; to the long text. Map back to short codes for compactness.
raw = gzip.open(src, "rb").read()
entities = dict(re.findall(rb'<!ENTITY (\S+) "([^"]+)">', raw))
long2short = {v.decode(): k.decode() for k, v in entities.items()}
db.executemany("INSERT INTO meta VALUES(?,?)", [(f"ent:{k.decode()}", v.decode()) for k, v in entities.items()])
t0 = time.time(); n = 0; eid = 0
for _, el in ET.iterparse(gzip.open(src, "rb"), events=("end",)):
    if el.tag != "entry": continue
    kebs = [(k.findtext("keb"), bool(k.findall("ke_pri"))) for k in el.findall("k_ele")]
    rebs = [(r.findtext("reb"), bool(r.findall("re_pri"))) for r in el.findall("r_ele")]
    if only is not None and not ({t for t, _ in kebs} | {t for t, _ in rebs}) & only:
        el.clear(); continue
    eid += 1
    common = int(any(c for _, c in kebs) or any(c for _, c in rebs))
    db.execute("INSERT INTO entries VALUES(?,?,?)", (eid, int(el.findtext("ent_seq")), common))
    db.executemany("INSERT INTO forms VALUES(?,?,?,?)",
                   [(eid, t, "k", int(c)) for t, c in kebs] + [(eid, t, "r", int(c)) for t, c in rebs])
    for i, s in enumerate(el.findall("sense")):
        pos = ";".join(long2short.get(p.text, p.text) for p in s.findall("pos"))
        misc = ";".join(long2short.get(m.text, m.text) for m in s.findall("misc"))
        gloss = " | ".join(g.text for g in s.findall("gloss") if g.text)
        if gloss: db.execute("INSERT INTO senses VALUES(?,?,?,?,?)", (eid, i, pos, misc, gloss))
    n += 1
    if n % 20000 == 0: print(f"  {n} entries {time.time()-t0:.0f}s", flush=True)
    el.clear()
if "--accents" in sys.argv:
    acc = sys.argv[sys.argv.index("--accents") + 1]
    keep = None
    if only is not None:
        keep = {r[0] for r in db.execute("SELECT text FROM forms")}
    rows = []
    for line in open(acc, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3: continue
        text, reading, accs = parts
        if keep is not None and text not in keep and reading not in keep: continue
        nums = re.findall(r"\d+", accs)
        if nums: rows.append((text, reading, ",".join(dict.fromkeys(nums))))
    db.executemany("INSERT INTO pitch VALUES(?,?,?)", rows)
    db.execute("INSERT OR REPLACE INTO meta VALUES('pitch','Kanjium accents (CC BY-SA 4.0)')")
    print(f"  pitch rows: {len(rows)}")
db.executescript("""
CREATE INDEX pitch_text ON pitch(text, reading);
CREATE INDEX forms_text ON forms(text);
CREATE INDEX forms_entry ON forms(entry_id);
CREATE INDEX senses_entry ON senses(entry_id);
INSERT OR REPLACE INTO meta VALUES('source','JMdict_e (EDRDG), CC BY-SA 4.0');
""")
db.execute("INSERT OR REPLACE INTO meta VALUES('built',?)", (time.strftime("%Y-%m-%d"),))
db.execute("INSERT OR REPLACE INTO meta VALUES('entries',?)", (str(n),))
db.commit(); db.execute("VACUUM"); db.close()
print(f"done: {n} entries -> {out} ({os.path.getsize(out)/2**20:.1f} MB) in {time.time()-t0:.0f}s")
