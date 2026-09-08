# OCR and dictionary

Added 2026-09-07. Decisions were Dave's: manga-ocr over Live Text (accuracy
on manga), JMdict bundled, selection opens a sheet, text mode is a toggle.

## Pipeline

1. **Text mode** (文 in the reader chrome): paging is frozen, a drag draws a
   box (`RegionSelectView`), the box is mapped onto the page bitmap and
   cropped.
2. **manga-ocr** (`kha-white/manga-ocr-base`, Apache-2.0) on Core ML:
   `MangaOCREncoder` (ViT-base, 224×224 grayscale in, [1,197,768] out) and
   `MangaOCRDecoder` (2-layer BERT, `input_ids` [1,T] flexible to 128 +
   encoder states → logits). Greedy decoding loop and post-processing live
   in Swift (`KanpekiOCR`). ~0.2 s per crop on an M-series Mac, ~0.4 s on
   the simulator CPU. Compute units: CPU + Neural Engine (the simulator has
   no MPSGraph backend, and ANE is what we want on device anyway).
3. **JMdict** (EDRDG, CC BY-SA 4.0) as a 50 MB SQLite built by
   `tools/ml/build_jmdict.py`. `KanpekiDictionary` does Yomitan-style
   deinflection (rule table, depth 4) and a longest-prefix scan from the
   tapped character; candidates that needed deinflection must land on a
   verb/adjective; primary-form matches outrank secondary spellings.
4. **Sheet** (`DictionarySheet`): recognized text as tappable characters,
   entries with reading, common tag, part of speech, glosses; Copy and the
   system Translate panel. Non-modal detents so the page stays usable.

## Rebuilding the assets (not committed — ~215 MB)

    cd tools/ml && python3.11 -m venv .venv && .venv/bin/pip install torch transformers coremltools huggingface_hub numpy pillow
    # weights + vocab into tools/ml/cache (see convert_manga_ocr.py header), JMdict_e.gz alongside
    .venv/bin/python convert_manga_ocr.py cache ../../Kanpeki/Resources/Models      # prints PARITY OK
    python3.11 build_jmdict.py cache/JMdict_e.gz ../../Kanpeki/Resources/Dictionary/jmdict.sqlite

`KanpekiOCRTests` compiles the packages from `Kanpeki/Resources/Models` and
must reproduce the Python parity string; `KanpekiDictionaryTests` uses a
58-entry fixture built with `--only`.

## Sheet (2026-09-07 evening revision)

- Whole bubble segmented into words once (`JMDict.segment`): `NLTokenizer`
  boundaries, dictionary scan from each boundary so inflected verbs stay
  whole, particles from a fixed list. Chips: verbs/adjectives orange,
  nouns blue, particles muted, unknown plain.
- Tap a word → one card: headword, reading, **pitch accent** (Kanjium,
  drawn as high-mora line + downstep bar + particle ○, up to two
  variants), inflection chain, two senses, "More" for alternates.
  Furigana shows on the tapped word; a toolbar toggle (and a setting)
  shows it on every word.
- Translation blurred until tapped; "Always show translation" setting.
  No Copy buttons.

## Known gaps

- **No text detection.** manga-ocr recognizes a crop; finding bubbles needs
  a detector (comic-text-detector) and its own conversion. Until then the
  user draws the box.
- App is ~264 MB with both models and the dictionary bundled. On-demand
  resources or a first-run download would cut it if that matters.
- Ranking prefers the common reading; for counters (第2巻 → 巻 as かん) the
  first hit is まき. Needs POS-aware ranking with context (preceding digit).
- Segmenter particle list is fixed; a particle that is also the start of a
  word at a token boundary (は in はし) is disambiguated only by the
  tokenizer. Pitch rows exist for 124k word/reading pairs; verbs appear
  in dictionary form only, so an inflected form shows the base pitch.
- Crops come from the screen-resolution decode; a bubble on a 2-up iPad
  spread is smaller than the 224 px input likes. Decoding a higher-res
  crop straight from the archive would help.
- `-chromeHold YES` launch argument keeps the reader chrome visible for
  UI testing.
