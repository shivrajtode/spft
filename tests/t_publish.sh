#!/bin/bash
# Test of tools/publish.sh: creating the GitHub repository, writing the user's name into the docs, pushing.
# "GitHub" is a folder of bare repositories (git's url.insteadOf maps https://github.com/ to it) and `gh` is a stand-in.
# Needs: bash, git, sed, grep.
# On purpose in the tests: ok/bad always return 0, patterns are literal text, printf builds escapes.
# shellcheck disable=SC2015,SC2016,SC2012,SC2002,SC2059
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
for c in git sed grep; do command -v $c >/dev/null || { echo "ABORT: $c is needed for this test"; exit 1; }; done
T=$(mktemp -d "${TMPDIR:-/tmp}/spft-pub.XXXXXX")
mkdir -p "$T/bin" "$T/home" "$T/remotes" "$T/nogh"
LOG=$T/calls.log; : > "$LOG"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { if grep -q -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }

# git must not see the real user's settings: the only setting is the "GitHub" folder
printf '[url "%s/remotes/"]\n\tinsteadOf = https://github.com/\n' "$T" > "$T/home/.gitconfig"

# the GitHub command line tool: logged in only after `gh auth login`; creates bare repositories under $T/remotes
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$TLOG"
case "$1 $2" in
  "auth status") [ -e "$TT/logged-in" ] ;;
  "auth login") : > "$TT/logged-in" ;;
  "auth setup-git") ;;
  "api user")
    case "$*" in
      *".name // .login"*) echo "The Octocat" ;;
      *"-q .login"*) echo octocat ;;
      *"-q .id"*) echo 583231 ;;
    esac ;;
  "repo view") [ -d "$TT/remotes/$3.git" ] ;;
  "repo create")
    mkdir -p "$TT/remotes/$(dirname "$3")"
    git init -q --bare "$TT/remotes/$3.git"
    git --git-dir="$TT/remotes/$3.git" symbolic-ref HEAD refs/heads/main    # like GitHub: the default branch is main
    git remote add origin "https://github.com/$3.git"
    git push -q -u origin main ;;
  *) echo "gh stand-in: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"

run() { # run PROJECT-FOLDER [ARGS...]
  local d=$1; shift
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 TT="$T" TLOG="$LOG" bash "$d/tools/publish.sh" "$@"
}
newproj() { # newproj FOLDER   a fresh copy of the project, with a file that has the placeholders
  local owner0 f
  rm -rf "$1"; mkdir -p "$1"
  (cd "$REPO" && tar -cf - --exclude=.git .) | (cd "$1" && tar -xf -)
  # This test also runs inside a PUBLISHED copy, where the owner's name has replaced the placeholder. Put the placeholder
  # back, in the copy only, so that publish.sh has something to replace (the owner is read from check.sh).
  owner0=$(sed -n 's#^.*SPFT_REPO:-\([A-Za-z0-9._-]*\)/spft.*$#\1#p' "$1/check.sh" | head -n 1)
  if [ -n "$owner0" ] && [ "$owner0" != YOUR-GITHUB-NAME ]; then
    for f in $(grep -rIl --exclude-dir=.git --exclude-dir=tests --exclude=publish.sh "$owner0/spft" "$1" || true); do
      sed -i "s#$owner0/spft#YOUR-GITHUB-NAME/spft#g" "$f"
    done
  fi
  mkdir -p "$1/docs"
  printf 'git clone https://github.com/YOUR-GITHUB-NAME/spft ~/spft\nissues: https://github.com/YOUR-GITHUB-NAME/spft/issues\nby YOUR-GITHUB-NAME\n' > "$1/docs/placeholder-test.md"
  chmod 644 "$1/docs/placeholder-test.md"
}
sed_t() { sed "s#$T#\$T#g"; }
g() { env HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git "$@"; }   # git with the test's "GitHub", not the real user's settings

echo "=== 1. first publish: not logged in yet"
newproj "$T/proj"
run "$T/proj" > "$T/out" 2>&1; rc=$?
sed_t < "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
has "$LOG" '^gh auth login' "asks GitHub to log in"
has "$LOG" '^gh repo create octocat/spft --public' "creates a public repository named after the user"
has "$T/out" 'git clone https://github.com/octocat/spft ~/spft && bash ~/spft/install.sh' "prints the one-line install command with the real name"
has "$T/out" 'bash <(curl -fsSL https://raw.githubusercontent.com/octocat/spft/main/check.sh)' "prints the check-only line with the real name"
[ -d "$T/remotes/octocat/spft.git" ] && ok "the repository exists on 'GitHub'" || bad "no repository was created"
rm -rf "$T/clone"
g clone -q https://github.com/octocat/spft "$T/clone" 2>/dev/null && ok "git clone of the published repository works" || bad "git clone failed"
g -C "$T/clone" branch --show-current | grep -q '^main$' && ok "the branch is main" || bad "branch is not main"
[ -x "$T/clone/install.sh" ] && [ -x "$T/clone/spft" ] && [ -x "$T/clone/check.sh" ] && ok "install.sh, spft and check.sh keep their executable bit" || bad "exec bits lost"
[ -f "$T/clone/lib/tools.conf" ] && [ -f "$T/clone/lib/run.sh" ] && [ -f "$T/clone/lib/provision.sh" ] && [ -f "$T/clone/lib/kernelfix.sh" ] && [ -f "$T/clone/lib/kernelfix.so.b64" ] && ok "lib/ is in the repository" || bad "lib files missing"
has "$T/clone/check.sh" 'SPFT_REPO:-octocat/spft' "check.sh downloads the published repository by default"
has "$T/clone/README.md" 'raw.githubusercontent.com/octocat/spft/main/check.sh' "the README shows the check line with the real name"
[ ! -e "$T/clone/.git/../spft-dl" ] && ok "nothing stray was committed" || bad "stray files"
g -C "$T/clone" log -1 --format='%an <%ae>' | tee "$T/author" ; has "$T/author" '^The Octocat <583231+octocat@users.noreply.github.com>$' "the commit is made in the user's name"
has "$T/clone/docs/placeholder-test.md" 'git clone https://github.com/octocat/spft ~/spft' "YOUR-GITHUB-NAME/spft became octocat/spft"
has "$T/clone/docs/placeholder-test.md" '^by octocat$' "a lone YOUR-GITHUB-NAME became octocat"
[ -d "$T/clone" ] || bad "there is no clone to look at"
if grep -rn --exclude-dir=.git --exclude-dir=tests --exclude=publish.sh 'YOUR-GITHUB-NAME' "$T/clone"; then bad "a placeholder is still in the repository (see above)"; else ok "no placeholder is left anywhere"; fi
[ "$(stat -c %a "$T/proj/docs/placeholder-test.md")" = 644 ] && ok "rewritten files keep their permissions" || bad "permissions changed"
(cd "$T/clone" && for f in install.sh check.sh spft tools/*.sh lib/*.sh tests/*.sh; do bash -n "$f" || echo "syntax error in $f"; done) 2>&1 | grep -q . && bad "a script in the clone has a syntax error" || ok "every script in the clone passes bash -n"
# the published copy has the user's name where the placeholder was: its own documentation test must still pass
# (it once failed there, because it only knew the placeholder)
if bash "$T/clone/tests/t_docs.sh" > "$T/docs.out" 2>&1; then ok "t_docs.sh passes in the published copy (name filled in)"; else bad "t_docs.sh fails in the published copy:"; grep '^FAIL' "$T/docs.out" | sed_t; fi

echo; echo "=== 2. run it again with nothing changed"
: > "$LOG"
run "$T/proj" > "$T/out" 2>&1; rc=$?
tail -n 8 "$T/out" | sed_t; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
has "$T/out" 'nothing new to commit' "no empty commit"
has "$T/out" 'exists already - pushing' "recognises the existing repository"
! grep -q '^gh repo create' "$LOG" && ok "does not try to create it again" || bad "tried to create the repository again"
! grep -q '^gh auth login' "$LOG" && ok "does not log in again" || bad "logged in again"

echo; echo "=== 3. a change is committed and pushed"
echo "one more line" >> "$T/proj/docs/placeholder-test.md"
run "$T/proj" > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
(g -C "$T/clone" pull -q 2>/dev/null; g -C "$T/clone" log --oneline | wc -l | tr -d ' ') | grep -q '^2$' && ok "the clone sees the second commit" || bad "second commit not pushed"

echo; echo "=== 4. another repository name"
newproj "$T/proj2"
run "$T/proj2" my-flasher > "$T/out" 2>&1; rc=$?
tail -n 6 "$T/out" | sed_t; echo "exit=$rc"
[ "$rc" = 0 ] && [ -d "$T/remotes/octocat/my-flasher.git" ] && ok "octocat/my-flasher was created" || bad "named repository missing"
has "$T/proj2/docs/placeholder-test.md" 'git clone https://github.com/octocat/my-flasher ~/spft' "the docs point to the new name"
has "$T/out" 'git clone https://github.com/octocat/my-flasher ~/spft && bash' "the one-liner uses the new name"

echo; echo "=== 5. refusals"
newproj "$T/proj3"
run "$T/proj3" 'bad name' 2>&1 | sed_t | sed -n '1p'
run "$T/proj3" 'bad name' 2>&1 | grep -q 'not a usable repository name' && ok "a name with a space is refused" || bad "bad name accepted"
env -i PATH="$T/nogh:/usr/bin:/bin" HOME="$T/home" bash "$T/proj3/tools/publish.sh" 2>&1 | sed -n '1p'
env -i PATH="$T/nogh:/usr/bin:/bin" HOME="$T/home" bash "$T/proj3/tools/publish.sh" 2>&1 | grep -q 'pkg install gh' && ok "no gh: tells how to get it" || bad "no hint for a missing gh"
mkdir -p "$T/loose/tools"; cp "$REPO/tools/publish.sh" "$T/loose/tools/"
run "$T/loose" 2>&1 | sed_t | sed -n '1p'
run "$T/loose" 2>&1 | grep -q 'has to stay inside the spft folder' && ok "a loose publish.sh is refused" || bad "loose publish.sh not refused"
[ ! -d "$T/proj3/.git" ] && ok "refusals did not touch the project" || bad "a refusal left a .git folder"

echo; echo "=== 6. GitHub is AHEAD of this folder (an edit made on github.com): the edit is kept and the push works"
# the edit on github.com: one line after the credit line of the README (made in a clone of 'GitHub', then pushed)
web() { # web CLONE 'sed script' MESSAGE
  g -C "$1" pull -q 2>/dev/null
  sed -i -e "$2" "$1/README.md"
  g -C "$1" -c user.name=web -c user.email=web@example.com commit -q -am "$3" && g -C "$1" push -q origin main
}
web "$T/clone" '/^Made by \*\*Shivraj\*\*:/a And special thanks to my friend, for the guide.' "Add acknowledgment for a friend in README" \
  && ok "(set-up) the edit was made on 'GitHub'" || bad "(set-up) the edit on 'GitHub' failed"
sed -i '1s/$/ (local edit)/' "$T/proj/README.md"      # a different place in the same file, made here
run "$T/proj" > "$T/out" 2>&1; rc=$?
sed_t < "$T/out" | sed -n '/GitHub: /,$p' | head -n 8; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0 (without the fix, git refuses the push: 'fetch first')" || bad "exit status $rc"
has "$T/out" 'GitHub has changes that are not in this folder yet' "it says that GitHub was ahead"
has "$T/out" 'Add acknowledgment for a friend in README' "and shows the change that it keeps"
g -C "$T/clone" pull -q 2>/dev/null
has "$T/clone/README.md" '^And special thanks to my friend, for the guide\.$' "the edit made on GitHub is still there"
has "$T/clone/README.md" '^# spft - SP Flash Tool on an Android phone (local edit)$' "and the change made here arrived on GitHub"
has "$T/proj/README.md" '^And special thanks to my friend, for the guide\.$' "the edit also reached this folder"
g -C "$T/clone" log --merges --format=%s | grep -q 'Merge the changes made on GitHub' && ok "one merge commit joins the two" || bad "no merge commit"

echo; echo "=== 7. the same line added on GitHub and in this folder (the update already carries the edit): it is there once, no conflict"
web "$T/clone" '/^Made by \*\*Shivraj\*\*:/a Thanks also to a second friend.' "Add a second friend" && ok "(set-up) the second edit was made on 'GitHub'" || bad "(set-up) failed"
sed -i '/^Made by \*\*Shivraj\*\*:/a Thanks also to a second friend.' "$T/proj/README.md"
run "$T/proj" > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || { bad "exit status $rc"; sed_t < "$T/out" | tail -n 8; }
g -C "$T/clone" pull -q 2>/dev/null
[ "$(grep -c '^Thanks also to a second friend\.$' "$T/clone/README.md")" = 1 ] && ok "the line is on GitHub exactly once" || bad "the line is missing or doubled"
[ "$(grep -c '^Thanks also to a second friend\.$' "$T/proj/README.md")" = 1 ] && ok "and in this folder exactly once" || bad "doubled here"

echo; echo "=== 8. GitHub has an edit on the SAME line as the update: nothing is pushed, nothing is lost, and the message says so"
newproj "$T/proj5"; run "$T/proj5" conflict-test > /dev/null 2>&1
g clone -q https://github.com/octocat/conflict-test "$T/clone5" 2>/dev/null
web "$T/clone5" '1s/.*/# a different title, made on github.com/' "Change the title" && ok "(set-up) the title was changed on 'GitHub'" || bad "(set-up) failed"
sed -i '1s/.*/# a different title, made in the update/' "$T/proj5/README.md"
before=$(g --git-dir="$T/remotes/octocat/conflict-test.git" rev-parse main)
run "$T/proj5" conflict-test > "$T/out" 2>&1; rc=$?
sed_t < "$T/out" | tail -n 6; echo "exit=$rc"
[ "$rc" = 1 ] && ok "exit 1" || bad "exit status $rc"
has "$T/out" 'could not be joined with this update by itself' "it explains what happened"
has "$T/out" 'Nothing was pushed and nothing on GitHub was changed' "and that nothing was lost"
[ "$(g --git-dir="$T/remotes/octocat/conflict-test.git" rev-parse main)" = "$before" ] && ok "GitHub is exactly as it was" || bad "GitHub changed"
[ -z "$(g -C "$T/proj5" status --porcelain)" ] && [ ! -e "$T/proj5/.git/MERGE_HEAD" ] && ok "this folder is clean again (no half-done merge)" || bad "a half-done merge is left"
has "$T/proj5/README.md" '^# a different title, made in the update$' "this folder keeps its own version"

echo; echo "=== 9. the repository on GitHub is still EMPTY (made there without files): it is simply filled"
git init -q --bare "$T/remotes/octocat/empty-test.git"; git --git-dir="$T/remotes/octocat/empty-test.git" symbolic-ref HEAD refs/heads/main
newproj "$T/proj6"
run "$T/proj6" empty-test > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || { bad "exit status $rc"; sed_t < "$T/out" | tail -n 6; }
g --git-dir="$T/remotes/octocat/empty-test.git" show main:install.sh > /dev/null 2>&1 && ok "the files arrived" || bad "nothing arrived on GitHub"

echo; echo "=== 10. GitHub has a README of its own that this folder never saw (unrelated history): refused with the same clear message"
git init -q --bare "$T/remotes/octocat/other-test.git"; git --git-dir="$T/remotes/octocat/other-test.git" symbolic-ref HEAD refs/heads/main
rm -rf "$T/seed"; mkdir "$T/seed"; g -C "$T/seed" init -q -b main; echo "# made on github.com" > "$T/seed/README.md"
g -C "$T/seed" add -A; g -C "$T/seed" -c user.name=web -c user.email=web@example.com commit -q -m "Initial commit"
g -C "$T/seed" push -q "$T/remotes/octocat/other-test.git" main
newproj "$T/proj7"
before=$(g --git-dir="$T/remotes/octocat/other-test.git" rev-parse main)
run "$T/proj7" other-test > "$T/out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit status $rc"
has "$T/out" 'could not be joined with this update by itself' "it explains what happened"
[ "$(g --git-dir="$T/remotes/octocat/other-test.git" rev-parse main)" = "$before" ] && ok "GitHub is exactly as it was" || bad "GitHub changed"

echo; echo "FAIL count: $fails"
rm -rf "$T"; echo "cleaned up"
[ "$fails" = 0 ]
