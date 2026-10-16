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
  rm -rf "$1"; mkdir -p "$1"
  (cd "$REPO" && tar -cf - --exclude=.git .) | (cd "$1" && tar -xf -)
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
[ -d "$T/remotes/octocat/spft.git" ] && ok "the repository exists on 'GitHub'" || bad "no repository was created"
rm -rf "$T/clone"
g clone -q https://github.com/octocat/spft "$T/clone" 2>/dev/null && ok "git clone of the published repository works" || bad "git clone failed"
g -C "$T/clone" branch --show-current | grep -q '^main$' && ok "the branch is main" || bad "branch is not main"
[ -x "$T/clone/install.sh" ] && [ -x "$T/clone/spft" ] && ok "install.sh and spft keep their executable bit" || bad "exec bits lost"
[ -f "$T/clone/lib/tools.conf" ] && [ -f "$T/clone/lib/run.sh" ] && [ -f "$T/clone/lib/provision.sh" ] && ok "lib/ is in the repository" || bad "lib files missing"
[ ! -e "$T/clone/.git/../spft-dl" ] && ok "nothing stray was committed" || bad "stray files"
g -C "$T/clone" log -1 --format='%an <%ae>' | tee "$T/author" ; has "$T/author" '^The Octocat <583231+octocat@users.noreply.github.com>$' "the commit is made in the user's name"
has "$T/clone/docs/placeholder-test.md" 'git clone https://github.com/octocat/spft ~/spft' "YOUR-GITHUB-NAME/spft became octocat/spft"
has "$T/clone/docs/placeholder-test.md" '^by octocat$' "a lone YOUR-GITHUB-NAME became octocat"
[ -d "$T/clone" ] || bad "there is no clone to look at"
if grep -rn --exclude-dir=.git --exclude-dir=tests --exclude=publish.sh 'YOUR-GITHUB-NAME' "$T/clone"; then bad "a placeholder is still in the repository (see above)"; else ok "no placeholder is left anywhere"; fi
[ "$(stat -c %a "$T/proj/docs/placeholder-test.md")" = 644 ] && ok "rewritten files keep their permissions" || bad "permissions changed"
(cd "$T/clone" && for f in install.sh spft tools/publish.sh lib/*.sh tests/*.sh; do bash -n "$f" || echo "syntax error in $f"; done) 2>&1 | grep -q . && bad "a script in the clone has a syntax error" || ok "every script in the clone passes bash -n"
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

echo; echo "FAIL count: $fails"
rm -rf "$T"; echo "cleaned up"
[ "$fails" = 0 ]
