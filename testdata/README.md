# Test scores

Small public-domain piano scores for testing the iOS app's imports, lessons and microphone feedback
(`ios/tools/e2e/run_e2e.py` uses them). The recognition server keeps its own, larger corpus with
photos and truth files in `server/testdata/` (on the `omr-server` branch).

| File | Piece | Tests | Source | License |
|---|---|---|---|---|
| `musicxml/fur-elise-fingered.mxl` | Beethoven, Für Elise | Two hands, 219 printed finger numbers, accidentals | [musetrainer/library](https://github.com/musetrainer/library/blob/master/scores/Fur_Elise_fingered.mxl) | Public domain (per the repository) |
| `musicxml/bach-minuet-in-g.mxl` | Minuet in G, BWV Anh. 114 | Two hands, chords across hands | [musetrainer/library](https://github.com/musetrainer/library/blob/master/scores/Bach_Minuet_in_G_Major_BWV_Anh._114.mxl) | Public domain (per the repository) |
| `musicxml/bach-prelude-c-bwv846.mxl` | Bach, Prelude in C, BWV 846 | Two hands, broken chords | [musetrainer/library](https://github.com/musetrainer/library/blob/master/scores/Prelude_I_in_C_major_BWV_846_-_Well_Tempered_Clavier_First_Book.mxl) | Public domain (per the repository) |
| `musicxml/ode-to-joy-easy.mxl` | Beethoven, Ode to Joy (easy) | Right-hand melody, movable Sa | [musetrainer/library](https://github.com/musetrainer/library/blob/master/scores/Ode_to_Joy_Easy_variation.mxl) | Public domain (per the repository) |
| `midi/burgmuller-la-candeur.mid` | Burgmüller, La Candeur, Op. 100 No. 1 | MIDI hands by track | [Mutopia](https://www.mutopiaproject.org/ftp/BurgmullerJFF/O100/25EF-01/) | Public Domain |
| `midi/bach-minuet-in-g.mid` | Minuet in G, BWV Anh. 114 | MIDI hands by track | [Mutopia](https://www.mutopiaproject.org/ftp/BachJS/BWVAnh114/anna-magdalena-04/) | Public Domain |
| `midi/clementi-op36-1.mid` | Clementi, Sonatina Op. 36 No. 1, 1st mvt | MIDI, two hands | [Mutopia](https://www.mutopiaproject.org/ftp/ClementiM/O36/sonatina-1/) (`sonatina-1.mid` from `sonatina-1-mids.zip`) | Public Domain |
| `sheets/burgmuller-la-candeur.pdf` | Burgmüller, La Candeur | PDF → recognition server → lesson (printed fingering, which recognition doesn't read) | [Mutopia](https://www.mutopiaproject.org/ftp/BurgmullerJFF/O100/25EF-01/) (`25EF-01-let.pdf`) | Public Domain |
| `sheets/burgmuller-la-candeur-p1.png` | Burgmüller, La Candeur | Image → recognition server → lesson | Rendered from the PDF above at 150 dpi with `ios/tools/pdf_page_to_png.swift` | Public Domain |
| `sheets/bach-minuet-in-g.pdf` | Minuet in G, BWV Anh. 114 | PDF → recognition server | [Mutopia](https://www.mutopiaproject.org/ftp/BachJS/BWVAnh114/anna-magdalena-04/) (`anna-magdalena-04-let.pdf`) | Public Domain |

Mutopia licenses were checked in each piece's LilyPond header (`license`/`copyright = "Public Domain"`).
musetrainer/library describes itself as a "public domain MusicXML library"; the compositions are all
long out of copyright.
