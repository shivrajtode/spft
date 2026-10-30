#!/bin/bash
# Test of the documentation: every link inside the repository and every #anchor works (markdown links and the HTML
# links and pictures of the README), the pictures in assets/ are safe and complete, the commands that `spft help`
# lists are in the Guide, the sections that spft's own messages point to exist, the README stays short and keeps the
# credits, and the install line is the same everywhere. (Links to other websites are not fetched: no internet needed.)
# Needs: bash, python3.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "ABORT: python3 is needed for this test"; exit 1; }
python3 -I - "$REPO" <<'PY'
import os, re, sys

repo = sys.argv[1]
fails = 0

def ok(msg):
    print("ok: " + msg)

def bad(msg):
    global fails
    fails += 1
    print("FAIL: " + msg)

def read(rel):
    with open(os.path.join(repo, rel), encoding="utf-8") as f:
        return f.read()

def slug(heading):
    """GitHub's anchor for a heading."""
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)   # links keep their text
    h = h.replace("`", "").replace("*", "").strip().lower()
    h = re.sub(r"[^\w\- ]", "", h)                           # drop punctuation (letters, digits, _ and - stay)
    return h.replace(" ", "-")

def anchors(rel):
    found, seen = set(), {}
    in_code = False
    for line in read(rel).splitlines():
        if line.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        m = re.match(r"^(#{1,6})\s+(.*?)\s*#*$", line)
        if m:
            s = slug(m.group(2))
            n = seen.get(s, 0)
            seen[s] = n + 1
            found.add(s if n == 0 else "%s-%d" % (s, n))
    return found

docs = ["README.md"] + sorted("docs/" + f for f in os.listdir(os.path.join(repo, "docs")) if f.endswith(".md")) + ["assets/README.md"]
print("pages checked:", ", ".join(docs))
anchor_cache = {d: anchors(d) for d in docs}

link_re = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)\)")
html_re = re.compile(r"""<a\s[^>]*?href="([^"]+)\"""")        # the links of the README that are written in HTML
img_re = re.compile(r"""<img\s[^>]*?src="([^"]+)\"[^>]*>""")   # and its pictures
total = 0
broken = 0
external = set()
images_seen = []
for page in docs:
    text = read(page)
    # links inside code blocks are examples, not links
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    targets = link_re.findall(text) + html_re.findall(text)
    for src in img_re.findall(text):
        images_seen.append((page, src))
        targets.append(src)
    for target in targets:
        total += 1
        if re.match(r"https?://", target):
            external.add(target)
            if not target.startswith("https://"):
                bad("%s: a link that is not https: %s" % (page, target))
            continue
        path, _, frag = target.partition("#")
        base = os.path.dirname(page)
        dest = page if path == "" else os.path.normpath(os.path.join(base, path))
        if not os.path.exists(os.path.join(repo, dest)):
            bad("%s: the link target %s does not exist" % (page, target))
            broken += 1
            continue
        if frag:
            if dest not in anchor_cache:
                if dest.endswith(".md"):
                    anchor_cache[dest] = anchors(dest)
                else:
                    bad("%s: %s has an anchor but is not a markdown page" % (page, target))
                    broken += 1
                    continue
            if frag not in anchor_cache[dest]:
                bad("%s: no heading for the anchor in %s" % (page, target))
                broken += 1
if broken == 0:
    ok("all %d links inside the repository and their #anchors work (%d links to other websites are not fetched)" % (total - len(external), len(external)))

# the sections that spft's own messages send people to
spft = read("spft")
readme = read("README.md")
guide = read("docs/GUIDE.md")
both = readme + "\n" + guide        # the short start and the long guide: what the old, single README said
for title in ("Android 12 and newer", "If the download fails"):
    if title in spft and "docs/GUIDE.md" in spft and slug(title) in anchor_cache["docs/GUIDE.md"]:
        ok('spft points to the Guide section "%s" and it exists' % title)
    else:
        bad('the Guide section "%s" that spft mentions is missing (or spft no longer mentions it)' % title)
if "the README" not in re.sub(r"clone the repository again \(see the README\)", "", spft) and slug("Step 2. Install spft (one time)") in anchor_cache["README.md"]:
    ok("spft sends nobody to a README section that moved (only: clone again, see the README, where the install line is)")
else:
    bad("spft still mentions the README for something that is now in the Guide, or the README lost its install step")

# the tool's start script points to the troubleshooting page for the kernel-version message
if "docs/TROUBLESHOOTING.md" in read("lib/run.sh") and slug('The "Invalid linux kernel version" message') in anchor_cache["docs/TROUBLESHOOTING.md"]:
    ok("lib/run.sh points to docs/TROUBLESHOOTING.md and its section on the kernel-version message exists")
else:
    bad("the kernel-version section of docs/TROUBLESHOOTING.md is missing, or lib/run.sh no longer points to it")

# every command in `spft help` is in the Guide's command table, and the README's everyday commands are real ones
usage = re.search(r"usage\(\) \{\n  cat <<'EOF'\n(.*?)\nEOF", spft, flags=re.S).group(1)
cmds = []
for line in usage.splitlines():
    m = re.match(r"^  (spft(?: [a-z0-9]+)?)\b", line)
    if m:
        cmds.append(m.group(1))
missing = [c for c in cmds if "`" + c in guide]
if len(cmds) < 8:
    bad("found only %d commands in `spft help` - did the format change?" % len(cmds))
elif len(missing) != len(cmds):
    bad("commands in `spft help` that the Guide does not show: %s" % ", ".join(c for c in cmds if c not in missing))
else:
    ok("all %d commands of `spft help` are in the Guide (%s)" % (len(cmds), ", ".join(cmds)))
everyday = re.findall(r"^\| `(spft(?: [a-z0-9]+)?)` \|", re.search(r"^## Everyday commands\n(.*?)^## ", readme, flags=re.S | re.M).group(1), flags=re.M) if "## Everyday commands" in readme else []
if len(everyday) >= 5 and all(c in cmds or c == "spft help" for c in everyday):
    ok("the README's everyday commands (%s) are all real commands of `spft help`" % ", ".join(everyday))
else:
    bad("the README's table of everyday commands is missing, too short, or has a command that `spft help` does not list: %r" % (everyday,))

# the install line must be the same in README, publish.sh and the docs. As shipped it carries the placeholder
# YOUR-GITHUB-NAME/spft; in a copy that publish.sh has already filled in (a published repository) it carries the
# owner's real address instead. Either way: at least twice, always the same, and a plain owner/repository.
line_re = re.compile(r"pkg update -y && pkg install -y git && git clone https://github\.com/([^ ]+) ~/spft && bash ~/spft/install\.sh")
found = line_re.findall(both)
if len(found) >= 2 and len(set(found)) == 1 and re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", found[0]) and line_re.search(readme):
    if found[0] == "YOUR-GITHUB-NAME/spft":
        ok("the install line appears %d times (README and Guide), always with the YOUR-GITHUB-NAME/spft placeholder" % len(found))
    else:
        ok("the install line appears %d times (README and Guide), always with %s (this copy has been published)" % (len(found), found[0]))
else:
    bad("the install line in the README and the Guide is missing or inconsistent: %r" % (found,))
publish = read("tools/publish.sh")
if "pkg update -y && pkg install -y git && git clone https://github.com/$owner/$name ~/spft && bash ~/spft/install.sh" in publish:
    ok("tools/publish.sh prints the same install line")
else:
    bad("tools/publish.sh prints a different install line than the README")

# the check that needs no install (check.sh): its one-liner is in the README for the same repository as the install line,
# check.sh downloads that repository by default, and publish.sh prints the line as well
install_repo = found[0] if found else None
check_re = re.compile(r"bash <\(curl -fsSL https://raw\.githubusercontent\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/main/check\.sh\)")
cfound = [c for c in check_re.findall(both) if c != "owner/name"]    # "owner/name" is the Guide's example for a fork
if cfound and set(cfound) == {install_repo} and check_re.search(readme):
    ok("the check line (check.sh) is in the README and the Guide (%d times), for the same repository as the install line" % len(cfound))
else:
    bad("the check line in the README is missing, or names another repository than the install line: %r (install line: %r)" % (cfound, install_repo))
check_sh = read("check.sh")
m = re.search(r"local repo=\$\{SPFT_REPO:-([^}]+)\}", check_sh)
if m and m.group(1) == install_repo:
    ok("check.sh downloads %s by default, the same repository as the install line" % m.group(1))
else:
    bad("check.sh's default repository (%r) is not the install line's (%r)" % (m.group(1) if m else None, install_repo))
if "bash <(curl -fsSL https://raw.githubusercontent.com/$owner/$name/main/check.sh)" in publish:
    ok("tools/publish.sh prints the check line too")
else:
    bad("tools/publish.sh does not print the check line")
if slug("Check a phone first (no install)") in anchor_cache["README.md"] and slug("Check a phone first (no install)") in anchor_cache["docs/GUIDE.md"]:
    ok('the README and the Guide both have the section "Check a phone first (no install)"')
else:
    bad('the section "Check a phone first (no install)" is missing in the README or in the Guide')

# nothing unfinished, and the placeholder only where publish.sh replaces it
for page in docs:
    t = read(page)
    if re.search(r"\b(TODO|FIXME|XXX|TBD)\b", t):
        bad("%s: has a TODO / FIXME / TBD" % page)
for page in docs:
    for m in re.finditer(r"YOUR-GITHUB-NAME(?!/spft)", read(page)):
        ctx = read(page)[max(0, m.start() - 40):m.end() + 20].replace("\n", " ")
        bad("%s: a YOUR-GITHUB-NAME that is not followed by /spft (publish.sh would still replace it, but check): ...%s..." % (page, ctx))
ok("no TODO or FIXME left in the documentation")

# the apps the user asked to see with links
for name, needle in (("Termux", "f-droid.org/packages/com.termux/"), ("Termux GitHub", "github.com/termux/termux-app/releases"),
                     ("Termux:API", "f-droid.org/packages/com.termux.api/"), ("Termux:API GitHub", "github.com/termux/termux-api/releases"),
                     ("Termux:X11", "github.com/termux/termux-x11/releases/tag/nightly")):
    if needle in readme:
        ok("the README links %s" % name)
    else:
        bad("the README has no link for %s (%s)" % (name, needle))

# --- what the docs say about the zoom, the stop command, the file windows and the settings must match the code -------------
import subprocess

def real_auto_zoom(size):
    """The zoom that the real auto_zoom function of the spft script gives for 'WIDTHxHEIGHT' (None when it refuses)."""
    mh = re.search(r"^X11_MIN_HEIGHT=(\d+)", spft, flags=re.M)
    fn = re.search(r"^auto_zoom\(\) \{\n.*?\n\}\n", spft, flags=re.S | re.M)
    if not (mh and fn):
        return None
    r = subprocess.run(["bash", "-c", "X11_MIN_HEIGHT=%s\n%s\nauto_zoom \"$1\"" % (mh.group(1), fn.group(0)), "bash", size],
                       capture_output=True, text=True)
    return int(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip().isdigit() else None

def tall(size, zoom):
    w, h = (int(x) for x in size.split("x"))
    return min(w, h) * 100 // zoom

how = read("docs/HOW-IT-WORKS.md")
trouble = read("docs/TROUBLESHOOTING.md")

# the table of screens in HOW-IT-WORKS: every row is what the real function says
sec = re.search(r"^## The zoom\n(.*?)^## ", how, flags=re.S | re.M)
rows = re.findall(r"^\| ([0-9x]+(?: or [0-9x]+)?)[^|]*\| (\d+) \| (\d+) px tall \|$", sec.group(1) if sec else "", flags=re.M)
wrong = []
for sizes, zoom, height in rows:
    for size in sizes.split(" or "):
        z = real_auto_zoom(size)
        if z != int(zoom) or tall(size, z or 1) != int(height):
            wrong.append("%s: the page says zoom %s / %s px, the code gives %s / %s px" % (size, zoom, height, z, tall(size, z) if z else "?"))
if len(rows) >= 4 and not wrong:
    ok("the screen table in docs/HOW-IT-WORKS.md (%d rows) is what auto_zoom gives" % len(rows))
else:
    bad("the screen table in docs/HOW-IT-WORKS.md does not match auto_zoom (%d rows found): %s" % (len(rows), "; ".join(wrong)))

# the README's sample `spft check` and its text use the same numbers
m = re.search(r"^screen\s+: (\d+x\d+) pixels - spft x11 picks zoom (\d+)%, a Termux:X11 screen (\d+) pixels tall", guide, flags=re.M)
if m and real_auto_zoom(m.group(1)) == int(m.group(2)) and tall(m.group(1), int(m.group(2))) == int(m.group(3)):
    ok("the Guide's sample check has the screen row, and its numbers are what auto_zoom gives (%s: zoom %s)" % (m.group(1), m.group(2)))
else:
    bad("the Guide's sample check has no screen row, or its numbers are not what auto_zoom gives: %r" % (m.groups() if m else None))
m = re.search(r"about (\d+)% on a (\d+x\d+) tablet, (\d+)% on a phone that is (\d+) pixels wide", guide)
if m and real_auto_zoom(m.group(2)) == int(m.group(1)) and real_auto_zoom("%sx%d" % (m.group(4), int(m.group(4)) * 16 // 9)) == int(m.group(3)):
    ok("the Guide's example zooms (%s%% and %s%%) are what auto_zoom gives" % (m.group(1), m.group(3)))
else:
    bad("the Guide's example zooms are not what auto_zoom gives: %r" % (m.groups() if m else None))
help_zoom =re.search(r"a (\d+x\d+)\s+tablet gets (\d+), a phone that is (\d+) pixels wide\s+gets (\d+)", re.sub(r"\s+", " ", usage))
if help_zoom and real_auto_zoom(help_zoom.group(1)) == int(help_zoom.group(2)) \
        and real_auto_zoom("%sx%d" % (help_zoom.group(3), int(help_zoom.group(3)) * 16 // 9)) == int(help_zoom.group(4)):
    ok("the examples in `spft help` (%s and %s) are what auto_zoom gives" % (help_zoom.group(2), help_zoom.group(4)))
else:
    bad("the zoom examples in `spft help` are not what auto_zoom gives: %r" % (help_zoom.groups() if help_zoom else None))

# the file windows: the Guide sends people to sdcard, no longer to a folder called root
if re.search(r"click \*\*root\*\*|in the list on the left click \*\*root\*\*", both, flags=re.I):
    bad("the README or the Guide still tells people to click root in the file window")
elif "Click **sdcard**" in guide and "SPFT_STORAGE=off" in guide and 'SPFT_STORAGE' in read("lib/run.sh"):
    ok("the Guide sends people to sdcard in the file window, and names SPFT_STORAGE=off, which lib/run.sh reads")
else:
    bad("the Guide does not explain the sdcard home folder of the file windows (or lib/run.sh no longer reads SPFT_STORAGE)")

# spft stop: what the help, the README and the code say it clears is the same list
stop_help = re.sub(r"\s+", " ", usage)
needs = ("force-stop everything", "Termux:X11 server", "clear the caches", "/tmp", "~/.cache", "cache", "memory cache")
code_dirs = re.search(r'^  local dirs="\$X11_DATA/cache \$X11_DATA/code_cache \$X11_MEDIA/cache"', spft, flags=re.M) and \
            '$R/tmp $R/root/.cache' in spft and "drop_caches" in spft and "am force-stop" in spft
readme_stop = re.search(r"^\| `spft stop` \| \*\*Force-stop everything of spft:\*\*(.*?)\|$", guide, flags=re.M)
miss = [n for n in needs if n not in stop_help] + [n for n in ("Debian's `/tmp`", "Termux:X11 server", "caches", "memory cache", "Never while it is flashing") if not readme_stop or n not in readme_stop.group(1)]
if code_dirs and not miss:
    ok("`spft stop` is described the same in `spft help` and the Guide, and the code clears those caches and force-stops the app")
else:
    bad("the description of `spft stop` (help, Guide) and the code do not agree: code=%s, missing=%s" % (bool(code_dirs), miss))
if "## `spft stop`: everything, and the caches" in how and "Termux:X11 app" in how and "drop_caches" in how:
    ok("docs/HOW-IT-WORKS.md has the section on `spft stop`")
else:
    bad("docs/HOW-IT-WORKS.md has no section on `spft stop` with its steps")

# the settings that spft hands down to Debian are the ones that docs/HOW-IT-WORKS.md marks "(passed on)"
dm = re.search(r'^DEBIAN_SETTINGS="([^"]*)"', spft, flags=re.M)
passed = sorted(re.findall(r"^\| `([A-Z0-9_]+)` \| [^|]*\| \*\*\(passed on\)\*\*", how, flags=re.M))
if dm and sorted(dm.group(1).split()) == passed:
    ok("the settings that spft passes on to Debian (%s) are exactly the ones marked (passed on) in docs/HOW-IT-WORKS.md" % ", ".join(passed))
else:
    bad("DEBIAN_SETTINGS in spft (%r) and the (passed on) rows in docs/HOW-IT-WORKS.md (%r) differ" % (dm.group(1) if dm else None, passed))

# every SPFT_ setting that the docs promise to work "in front of the command" is one that is passed on or read in Termux
for name in ("SPFT_FAKE_KERNEL", "SPFT_STORAGE"):
    if name in both + trouble and name in (dm.group(1) if dm else ""):
        ok("%s is in the docs, and spft passes it on" % name)
    else:
        bad("%s is in the docs but is not in DEBIAN_SETTINGS (typed in front of the command it would never arrive)" % name)

# the harmless install warnings: README and troubleshooting say so, and provision.sh really prints the note for each
prov = read("lib/provision.sh")
for text in ("Exec format error", "systemctl: command not found", "Restarting systemd-binfmt failed"):
    if text in guide and text in trouble and (text.split(":")[0] in prov):
        ok('"%s": the Guide and troubleshooting explain it as harmless, and provision.sh knows it' % text)
    else:
        bad('"%s": missing from the Guide, the troubleshooting page, or provision.sh' % text)

# --- the README is the front page: short, complete, and it keeps the credits ----------------------------------------------------------
n_lines = readme.count("\n") + 1
need_sections = ("What you need", "Start in 3 steps", "Check a phone first (no install)", "How it works", "Everyday commands", "Need help?", "Good to know")
miss_sec = [t for t in need_sections if slug(t) not in anchor_cache["README.md"]]
need_sections += ("See it running",)
miss_sec = [t for t in need_sections if slug(t) not in anchor_cache["README.md"]]
if n_lines <= 240 and not miss_sec:
    ok("the README is short (%d lines, at most 240) and has all its sections" % n_lines)
else:
    bad("the README has %d lines (at most 240: the long text belongs in docs/GUIDE.md) or lacks sections: %s" % (n_lines, miss_sec))
credits = ("https://t.me/Shivraj_editx", "https://github.com/shivrajtode", "https://t.me/mkr_infinity", "**Kaif**", "Hovatek forum",
           "[mtkclient]", "[box64]", "[Termux:X11]", "[Debian]", "[Termux]")
miss_credit = [c for c in credits if c not in readme]
if not miss_credit:
    ok("the README keeps the credits (Shivraj, Kaif, and the projects that are thanked)")
else:
    bad("the README lost these credits: %s" % miss_credit)
for step in ("Step 1. Get the apps", "Step 2. Install spft (one time)", "Step 3. Start it"):
    if slug(step) not in anchor_cache["README.md"]:
        bad("the README has no heading %r" % step)
risk = "permanently damage a device" in readme and "[!WARNING]" in readme
if risk:
    ok("the README shows the warning about flashing as a GitHub alert")
else:
    bad("the README lost its warning that flashing can permanently damage a device")

# --- the pictures in assets/ ---------------------------------------------------------------------------------------------------------------
import xml.etree.ElementTree as ET
assets_dir = os.path.join(repo, "assets")
svgs = sorted(f for f in os.listdir(assets_dir) if f.endswith(".svg"))
problems, total_bytes = [], 0
for f in svgs:
    raw = open(os.path.join(assets_dir, f), "rb").read()
    total_bytes += len(raw)
    txt = raw.decode("utf-8")
    try:
        root = ET.fromstring(txt)
    except ET.ParseError as e:
        problems.append("%s: not well-formed XML (%s)" % (f, e))
        continue
    if not root.tag.endswith("}svg") or not root.get("viewBox") or root.get("role") != "img":
        problems.append("%s: the root must be an svg with a viewBox and role=img" % f)
    if not any(el.tag.endswith("}title") and (el.text or "").strip() for el in root.iter()):
        problems.append("%s: has no <title>" % f)
    low = txt.lower()
    for word in ("<script", "<foreignobject", "<image", "javascript:", "@import", "url(http", 'href="http', "href='http", "<text", "<iframe", "your-github-name"):
        if word in low:
            problems.append("%s: contains %r (not allowed: GitHub shows pictures as plain images, and the letters are outlines)" % (f, word))
    if re.search(r"\son[a-z]+=", txt):
        problems.append("%s: has an event attribute" % f)
    if "@keyframes" in txt and "prefers-reduced-motion" not in txt:
        problems.append("%s: animates, but has no rule for people who asked for less motion" % f)
    ids = set(re.findall(r'\sid="([^"]+)"', txt))
    for ref in set(re.findall(r"url\(#([^)]+)\)", txt)):
        if ref not in ids:
            problems.append("%s: refers to #%s, which does not exist" % (f, ref))
    if len(raw) > 200000:
        problems.append("%s: %d bytes (more than 200 KB)" % (f, len(raw)))
if len(svgs) >= 10 and not problems and total_bytes < 600000:
    ok("the %d pictures in assets/ are well-formed, safe, titled, calm on request, and small (%d KB together)" % (len(svgs), total_bytes // 1024))
else:
    bad("problems with the pictures in assets/ (%d files, %d bytes): %s" % (len(svgs), total_bytes, "; ".join(problems) or "fewer than 10 pictures"))
unused = [f for f in svgs if f not in readme and f != "social-preview.svg"]
if not unused:
    ok("every picture in assets/ is used by the README (the social preview is for the repository's share card)")
else:
    bad("pictures in assets/ that the README does not show: %s" % unused)
alt_bad = []
for m in re.finditer(r"<img\s[^>]*>", readme):
    tag = m.group(0)
    src = re.search(r'src="([^"]+)"', tag)
    alt = re.search(r'alt="([^"]*)"', tag)
    if not src or alt is None:
        alt_bad.append(tag[:60])
    elif "/icon-" not in src.group(1) and len(alt.group(1)) < 8:
        alt_bad.append("%s has no real description" % src.group(1))
if not alt_bad:
    ok("every picture of the README has an alt text (the icons are decoration: an empty one is fine)")
else:
    bad("pictures without a proper alt text: %s" % alt_bad)
# --- the author block at the very end: the live Telegram picture and the card -------------------------------------------------------------
tg_live = '<a href="https://t.me/Shivraj_editx"><img src="https://t.me/i/userpic/320/Shivraj_editx.jpg"'
tg_card = '<a href="https://t.me/Shivraj_editx"><img src="assets/author-card.svg"'
if tg_live in readme and tg_card in readme:
    tail = readme[readme.index(tg_live):]
    card_svg = read("assets/author-card.svg")
    vb = re.search(r'viewBox="0 0 (\d+) (\d+)"', card_svg)
    dims = re.search(r'author-card\.svg"[^>]*width="(\d+)" height="(\d+)"', readme)
    live_dims = re.search(r'userpic/320/Shivraj_editx\.jpg" width="(\d+)" height="(\d+)"', readme)
    same_shape = bool(vb and dims) and int(vb.group(1)) * int(dims.group(2)) == int(vb.group(2)) * int(dims.group(1))
    if (readme.index(tg_live) > readme.index("## Good to know") and tail.count("<img ") == 2 and tg_live in tail
            and tail.index(tg_live) < tail.index(tg_card) and same_shape and live_dims and live_dims.group(2) == dims.group(2)):
        ok("the README ends with the live Telegram picture and the author card, side by side, both linking to https://t.me/Shivraj_editx")
    else:
        bad("the author block at the end of the README is not as expected: the live picture, then the card (same height, the card's shape kept), the last two pictures, after the section Good to know")
else:
    bad("the README has no live Telegram picture (https://t.me/i/userpic/320/Shivraj_editx.jpg) and author card, each inside a link to https://t.me/Shivraj_editx")
if re.search(r"\bhandle, link = \"@Shivraj_editx\", \"t\.me/Shivraj_editx\"", read("tools/make-assets.py")) and "Creator of spft" in read("tools/make-assets.py"):
    ok("tools/make-assets.py draws the card with the same Telegram name as the README")
else:
    bad("the Telegram name in tools/make-assets.py (the author card) differs from the README")

# --- the screenshots: real photos of the tool running on Android ----------------------------------------------------------------------------
def jpeg_size(rel):
    with open(os.path.join(repo, rel), "rb") as f:
        data = f.read()
    if data[:2] != b"\xff\xd8":
        return None, len(data), data
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            return (int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")), len(data), data
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
        else:
            i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    return None, len(data), data

shot_dir = os.path.join(repo, "assets", "screenshots")
shots_used = sorted(set(re.findall(r'src="(assets/screenshots/[^"]+)"', readme)))
shots_files = sorted("assets/screenshots/" + f for f in os.listdir(shot_dir)) if os.path.isdir(shot_dir) else []
problems, total_shot_bytes = [], 0
for rel in shots_used:
    if not os.path.exists(os.path.join(repo, rel)):
        problems.append("%s is missing" % rel)
        continue
    size, nbytes, data = jpeg_size(rel)
    total_shot_bytes += nbytes
    if size is None:
        problems.append("%s is not a JPEG" % rel)
        continue
    w, h = size
    if w < 600 or abs(w / h - 1.6) > 0.03:
        problems.append("%s is %dx%d (at least 600 wide, 16:10)" % (rel, w, h))
    if nbytes > 150000:
        problems.append("%s is %d KB (at most 150)" % (rel, nbytes // 1024))
    if b"Exif" in data[:4096]:
        problems.append("%s carries metadata (EXIF)" % rel)
hero = "assets/screenshots/running-on-android.jpg"
hero_size = jpeg_size(hero)[0] if os.path.exists(os.path.join(repo, hero)) else None
if len(shots_used) != 4:
    problems.append("the README should show 4 screenshots, it shows %d" % len(shots_used))
if hero not in shots_used or not hero_size or hero_size[0] < 1200:
    problems.append("the picture with the Android status bar (%s) is missing or too small (at least 1200 wide)" % hero)
if not re.search(r'running-on-android\.jpg"[^>]*alt="[^"]*status bar', readme):
    problems.append("the alt text of the status-bar picture does not say 'status bar'")
unused_shots = [f for f in shots_files if f not in shots_used]
if unused_shots:
    problems.append("not used by the README: %s" % ", ".join(unused_shots))
if total_shot_bytes > 300000:
    problems.append("together %d KB (at most 300)" % (total_shot_bytes // 1000))
if not problems:
    ok("the 4 screenshots (with the Android status bar) are in the README, real JPEGs of 16:10 without metadata, %d KB together" % (total_shot_bytes // 1000))
else:
    bad("problems with the screenshots: %s" % "; ".join(problems))

png = os.path.join(assets_dir, "social-preview.png")
if os.path.exists(png):
    head = open(png, "rb").read(32)
    size = os.path.getsize(png)
    w, h = (int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")) if head[:8] == b"\x89PNG\r\n\x1a\n" else (0, 0)
    if (w, h) == (1280, 640) and size < 1000000:
        ok("assets/social-preview.png is a 1280x640 PNG under 1 MB (upload it in Settings > Social preview)")
    else:
        bad("assets/social-preview.png must be a PNG of 1280x640 pixels under 1 MB: got %dx%d, %d bytes" % (w, h, size))
else:
    bad("assets/social-preview.png is missing")

print()
print("FAIL count: %d" % fails)
sys.exit(1 if fails else 0)
PY
