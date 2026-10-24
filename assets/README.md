# The pictures

These are the pictures of the front page ([README](../README.md)). spft does not need them to work.

| File | Where it is used |
|---|---|
| `banner.svg` | the top of the README |
| `badge-*.svg` | the five badges under the banner |
| `steps.svg` | "Start in 3 steps" |
| `terminal.svg` | "Check a phone first" |
| `stack.svg` | "How it works" |
| `icon-*.svg` | the small icons of the cards |
| `social-preview.svg` and `social-preview.png` | the picture people see when they share the link to this repository |

The pictures move a little (they are animated SVG). They stand still when a phone or computer is set to "reduce motion".

## Social preview: upload it once, by hand

GitHub does not take the share picture from the files of a repository. After you have published:

1. Open your repository on GitHub, then **Settings** and **General**.
2. Scroll to **Social preview**, press **Edit**, then **Upload an image**.
3. Choose `assets/social-preview.png` (1280 × 640 pixels).

## Change the pictures

Everything here is drawn by [`tools/make-assets.py`](../tools/make-assets.py), so there is no design file to keep. Change the script, then run it from the folder of the repository:

```
python3 tools/make-assets.py                  # writes all the .svg files into assets/
python3 tools/make-assets.py --png chromium   # also writes social-preview.png (needs a browser and Pillow)
python3 tools/make-assets.py --help           # all the options, for example a still picture of an animation
```

It needs `python3` and `fonttools` (`pip install fonttools`), and these fonts, which Debian has as `fonts-inter` and `fonts-dejavu-core`. The letters are turned into outlines, so the pictures need no web font and load nothing from other websites.

Fonts: [Inter](https://rsms.me/inter/) (SIL Open Font License 1.1) and [DejaVu Sans Mono](https://dejavu-fonts.github.io/) (free Bitstream Vera licence).
