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
| `author-card.svg` | the card at the very end of the README, next to the live Telegram profile picture |
| `screenshots/*.jpg` | "See it running": four real screenshots of SP Flash Tool on an Android tablet. The first one shows the Android status bar and the notification panel (Termux and Termux:X11), so people can see that it really runs on Android |
| `social-preview.svg` and `social-preview.png` | the picture people see when they share the link to this repository |

The pictures move a little (they are animated SVG). They stand still when a phone or computer is set to "reduce motion".

## The Telegram picture is live

At the end of the README the profile picture on the left is not a file of this repository: it is `https://t.me/i/userpic/320/Shivraj_editx.jpg`, which Telegram serves for the public profile picture of that account, and GitHub fetches it for every reader. When the profile picture changes on Telegram, the README shows the new one by itself, within a short while (GitHub caches images). The card next to it, `author-card.svg`, is drawn by the script below. To use another account, change the name in the picture's address and link in `README.md`, and `handle` / `link` in `author_card()` in `tools/make-assets.py`.

## The screenshots

`screenshots/` holds real photos, so `tools/make-assets.py` does not draw them. They were taken on a tablet, scaled to 1280 pixels wide (the one with the status bar) and 640 pixels wide (the three small ones), and saved as JPEG without metadata, about 150 KB together. To change one, put a new picture under the same name, with the same size, so that the README keeps working. Keep them small: the front page loads them all.

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
