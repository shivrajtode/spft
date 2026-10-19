#!/bin/bash
# Test of the documentation: every link inside the repository and every #anchor works, the commands that
# `spft help` lists are in the README, the sections that spft's own messages point to exist, and the install
# line is the same everywhere. (Links to other websites are not fetched: this test needs no internet.)
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

docs = ["README.md"] + sorted("docs/" + f for f in os.listdir(os.path.join(repo, "docs")) if f.endswith(".md"))
print("pages checked:", ", ".join(docs))
anchor_cache = {d: anchors(d) for d in docs}

link_re = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)\)")
total = 0
broken = 0
external = set()
for page in docs:
    text = read(page)
    # links inside code blocks are examples, not links
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    for target in link_re.findall(text):
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
for title in ("Android 12 and newer", "If the download fails"):
    if title in spft and slug(title) in anchor_cache["README.md"]:
        ok('spft points to the README section "%s" and it exists' % title)
    else:
        bad('the README section "%s" that spft mentions is missing (or spft no longer mentions it)' % title)

# the tool's start script points to the troubleshooting page for the kernel-version message
if "docs/TROUBLESHOOTING.md" in read("lib/run.sh") and slug('The "Invalid linux kernel version" message') in anchor_cache["docs/TROUBLESHOOTING.md"]:
    ok("lib/run.sh points to docs/TROUBLESHOOTING.md and its section on the kernel-version message exists")
else:
    bad("the kernel-version section of docs/TROUBLESHOOTING.md is missing, or lib/run.sh no longer points to it")

# every command in `spft help` is in the README's command table
usage = re.search(r"usage\(\) \{\n  cat <<'EOF'\n(.*?)\nEOF", spft, flags=re.S).group(1)
cmds = []
for line in usage.splitlines():
    m = re.match(r"^  (spft(?: [a-z0-9]+)?)\b", line)
    if m:
        cmds.append(m.group(1))
missing = [c for c in cmds if "`" + c in readme]
if len(cmds) < 8:
    bad("found only %d commands in `spft help` - did the format change?" % len(cmds))
elif len(missing) != len(cmds):
    bad("commands in `spft help` that the README does not show: %s" % ", ".join(c for c in cmds if c not in missing))
else:
    ok("all %d commands of `spft help` are in the README (%s)" % (len(cmds), ", ".join(cmds)))

# the install line must be the same in README, publish.sh and the docs. As shipped it carries the placeholder
# YOUR-GITHUB-NAME/spft; in a copy that publish.sh has already filled in (a published repository) it carries the
# owner's real address instead. Either way: at least twice, always the same, and a plain owner/repository.
line_re = re.compile(r"pkg update -y && pkg install -y git && git clone https://github\.com/([^ ]+) ~/spft && bash ~/spft/install\.sh")
found = line_re.findall(readme)
if len(found) >= 2 and len(set(found)) == 1 and re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", found[0]):
    if found[0] == "YOUR-GITHUB-NAME/spft":
        ok("the install line appears %d times in the README, always with the YOUR-GITHUB-NAME/spft placeholder" % len(found))
    else:
        ok("the install line appears %d times in the README, always with %s (this copy has been published)" % (len(found), found[0]))
else:
    bad("the install line in the README is missing or inconsistent: %r" % (found,))
publish = read("tools/publish.sh")
if "pkg update -y && pkg install -y git && git clone https://github.com/$owner/$name ~/spft && bash ~/spft/install.sh" in publish:
    ok("tools/publish.sh prints the same install line")
else:
    bad("tools/publish.sh prints a different install line than the README")

# the check that needs no install (check.sh): its one-liner is in the README for the same repository as the install line,
# check.sh downloads that repository by default, and publish.sh prints the line as well
install_repo = found[0] if found else None
check_re = re.compile(r"bash <\(curl -fsSL https://raw\.githubusercontent\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/main/check\.sh\)")
cfound = [c for c in check_re.findall(readme) if c != "owner/name"]    # "owner/name" is the README's example for a fork
if cfound and set(cfound) == {install_repo}:
    ok("the check line (check.sh) is in the README %d time(s), for the same repository as the install line" % len(cfound))
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
if slug("Check a phone first (no install)") in anchor_cache["README.md"]:
    ok('the README section "Check a phone first (no install)" exists')
else:
    bad('the README section "Check a phone first (no install)" is missing')

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

print()
print("FAIL count: %d" % fails)
sys.exit(1 if fails else 0)
PY
