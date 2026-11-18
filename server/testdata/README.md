# OMR test corpus

Public-domain piano scores for testing sheet music recognition end to end: the iOS app's test on
the Mac, `eval/run_corpus.py` against a running server, and the engine comparison in the report.
`manifest.json` lists every piece with its truth files and the expected staff and measure counts.

Every piece has:

- `score.pdf`: the printed score (an engraving or a scan, unchanged except for cutting out pages).
- `photo-mild.jpg`, `photo-hard.jpg`: page 1 as a simulated phone photo, made by
  `eval/make_photos.py` (fixed seeds). Mild: slight tilt and soft light. Hard: strong perspective,
  page curl, a hand shadow, warm uneven light, blur, noise and JPEG artefacts.
- `truth.mid` / `truth-mvt*.mid` / `truth.musicxml`: what the notes should be, one MIDI track or
  MusicXML staff per hand (upper staff first).

`real-photos/` holds real phone photos of a real printed page; its reference is homr's own reading
and is not verified, so use it only for structure and agreement checks.

## Pieces

| id | Piece | Kind | Printed fingering | Pages | Source | License |
|---|---|---|---|---|---|---|
| `mutopia-bach-minuet-g` | Minuet in G, BWV Anh. 114 | LilyPond engraving (Bach-Gesellschaft text) | no | 1 | [Mutopia](https://www.mutopiaproject.org/ftp/BachJS/BWVAnh114/anna-magdalena-04/) | Public Domain |
| `mutopia-burgmuller-la-candeur` | Burgmüller, La Candeur, Op. 100 No. 1 | LilyPond engraving (Litolff edition) | yes | 1 | [Mutopia](https://www.mutopiaproject.org/ftp/BurgmullerJFF/O100/25EF-01/) | Public Domain |
| `mutopia-burgmuller-arabesque` | Burgmüller, L'Arabesque, Op. 100 No. 2 | LilyPond engraving (Litolff edition) | yes | 1 | [Mutopia](https://www.mutopiaproject.org/ftp/BurgmullerJFF/O100/25EF-02/) | Public Domain |
| `mutopia-clementi-op36-1` | Clementi, Sonatina Op. 36 No. 1, all three movements | LilyPond engraving (Schirmer 1893) | no | 3 | [Mutopia](https://www.mutopiaproject.org/ftp/ClementiM/O36/sonatina-1/) | Public Domain |
| `scan-burgmuller-arabesque-schirmer-1903` | Burgmüller, L'Arabesque, Op. 100 No. 2 | 400 ppi library scan, Schirmer's Library Vol. 500 (1903), p. 5 | yes | 1 | [Internet Archive `burgmullerop100t00unse`](https://archive.org/details/burgmullerop100t00unse) | Public Domain Mark 1.0 |
| `scan-clementi-op36-1-schirmer-1893` | Clementi, Sonatina Op. 36 No. 1, 1st movement | 400 ppi library scan, Schirmer *Sonatina Album* (1893), p. 33 | yes | 1 | [Internet Archive `sonatinaalbumfor51kohl`](https://archive.org/details/sonatinaalbumfor51kohl) | Public Domain Mark 1.0 |
| `musescore-beethoven-fur-elise-fingered` | Beethoven, Für Elise, bars 1-40 | MuseScore 4.7 render of a fingered MuseScore transcription | yes (205 marks, also in the truth) | 2 | [musetrainer/library `Fur_Elise_fingered.mxl`](https://github.com/musetrainer/library) | Public domain (per the repository) |
| `real-photos/goodbye-dear-old-canada-1915` | Marjorie W. Henry, Goodbye Dear Old Canada (voice and piano) | 1915 print: scan plus two real phone photos (01: plain, 07: curved, tilted, busy background) | no | 1 | [liebharc/sheet-music-photos](https://github.com/liebharc/sheet-music-photos) (scan: Internet Archive [`1915henry90258goodbye`](https://archive.org/details/1915henry90258goodbye), p. 3, Canadian sheet music collection) | Scan: Public Domain Mark; photos: CC0 1.0 |

Truth files:

- Mutopia pieces: the MIDI file Mutopia publishes with the engraving, generated from the same
  LilyPond source (repeats are not unfolded, so notes follow the printed order).
- Scans: the Mutopia MIDI of the same piece. Mutopia transcribed the Clementi from this very
  Schirmer edition; the Burgmüller transcription follows the Litolff edition, which has the same
  notes. Fingerings are not part of these truth files.
- Für Elise: the MusicXML the PDF was rendered from (bars 1-40, layout breaks removed), including
  every fingering, so fingering recognition can be measured exactly. Page 1 holds bars 1-30.

IMSLP was not used: its downloads now sit behind a human-verification check. The two scans come
from the Internet Archive copies of Schirmer editions that IMSLP also lists.

## Regenerating the photos

```sh
pip install -r eval/requirements.txt
python eval/make_photos.py testdata/pieces/*/score.pdf
```
