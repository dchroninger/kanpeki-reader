# Sample volume

`hokusai-manga-sample.cbz` is an 11-page demo volume for screenshots and for trying the reader
without your own library.

- **Artwork:** *Hokusai Manga* (北斎漫画), Katsushika Hokusai, 1816. The Metropolitan Museum of
  Art, [object 57678](https://www.metmuseum.org/art/collection/search/57678), released under
  **CC0** through The Met's Open Access program.
- **Speech bubbles:** added for the demo (short, original Japanese lines) so the OCR and
  dictionary have something to read. The bubbles are part of this sample, not Hokusai's work.

To load it on a simulator (no iCloud), copy it into the app's Documents folder:

```bash
C=$(xcrun simctl get_app_container booted com.dchroninger.kanpeki data)
mkdir -p "$C/Documents/北斎漫画" && cp samples/hokusai-manga-sample.cbz "$C/Documents/北斎漫画/"
```
