#!/bin/bash
# Test of check.sh, the check that needs no install: it downloads the repository into a temporary folder, runs
# `spft check` from there, and cleans up. Stand-ins for curl (it serves a tarball made from this repository), su, id, zcat, uname.
# Needs: bash, tar, gzip, sed, grep. It refuses to run where a real /system/bin/mount exists.
# On purpose in the tests: ok/bad always return 0, patterns are literal text, printf builds escapes.
# shellcheck disable=SC2015,SC2016,SC2012,SC2002,SC2059
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ -e /system/bin/mount ]; then echo "ABORT: /system/bin/mount exists here"; exit 1; fi
for c in tar gzip; do command -v $c >/dev/null || { echo "ABORT: $c is needed for this test"; exit 1; }; done
T=$(mktemp -d "${TMPDIR:-/tmp}/spft-chk.XXXXXX")
mkdir -p "$T/bin" "$T/pfx/bin" "$T/pfx/tmp" "$T/home" "$T/stage/spft-main" "$T/elsewhere" "$T/nopfx/bin"
ln -s "$(type -P bash)" "$T/pfx/bin/bash"
: > "$T/pfx/bin/pkg"; chmod +x "$T/pfx/bin/pkg"
CURL_LOG=$T/curl.log; : > "$CURL_LOG"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
hasnot() { if grep -qF -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }

# the repository as GitHub would serve it: one folder (spft-main) holding everything. spft itself is the real one,
# with only `is_root` made switchable, because this test runs as root in a sandbox.
tar -C "$REPO" --exclude=./tests --exclude=./.git -cf - . | tar -C "$T/stage/spft-main" -xf -
sed -e 's#^is_root() .*#is_root() { [ "${FAKE_ROOT:-0}" = 1 ]; }#' "$REPO/spft" > "$T/stage/spft-main/spft"
tar -czf "$T/served.tar.gz" -C "$T/stage" spft-main
DEFAULT_REPO=$(sed -n 's/^  local repo=\${SPFT_REPO:-\([^}]*\)}.*/\1/p' "$REPO/check.sh")

# --- stand-ins ------------------------------------------------------------------------------------
# id: the normal user (1000), or root when FAKE_ROOT=1
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -u ]; then if [ "${FAKE_ROOT:-0}" = 1 ]; then echo 0; else echo 1000; fi; exit 0; fi
exec /usr/bin/env PATH=/usr/bin:/bin id "$@"
EOF
# su: the root step. SU_MODE=refuse -> permission denied; SU_MODE=eat-stdin -> like a program that reads standard input
cat > "$T/bin/su" <<'EOF'
#!/bin/bash
[ "${SU_MODE:-}" != refuse ] || { echo "su: permission denied" >&2; exit 1; }
[ "${SU_MODE:-}" != eat-stdin ] || cat > /dev/null
[ "$1" = -c ] || exit 2
[ "$2" != "id -u" ] || { echo 0; exit 0; }
exec env FAKE_ROOT=1 sh -c "$2"
EOF
cat > "$T/bin/zcat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = /proc/config.gz ]; then echo "CONFIG_ARM64=y"; echo "# CONFIG_USB_ACM is not set"; exit 0; fi
exec /usr/bin/env PATH=/usr/bin:/bin zcat "$@"
EOF
cat > "$T/bin/uname" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -r ]; then echo "4.19.127-g8d3429bdb336"; exit 0; fi
exec /usr/bin/env PATH=/usr/bin:/bin uname "$@"
EOF
# curl: logs the call; CURL_MODE=fail -> HTTP 404 (exit 22), garbage -> a file that is no archive, nospft -> an archive without spft
cat > "$T/bin/curl" <<EOF
#!/bin/bash
out= url=
while [ \$# -gt 0 ]; do
  case \$1 in
    -o) out=\$2; shift 2 ;;
    --retry) shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
echo "curl url=\$url" >> "$CURL_LOG"
case \${CURL_MODE:-} in
  fail) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
  garbage) echo "this is not an archive" > "\$out" ;;
  nospft) mkdir -p "$T/other/x-main" && echo hello > "$T/other/x-main/README.md" && tar -czf "\$out" -C "$T/other" x-main ;;
  *) cp "$T/served.tar.gz" "\$out" ;;
esac
EOF
chmod +x "$T/bin"/*
cp "$REPO/check.sh" "$T/elsewhere/check.sh"      # a copy that sits next to no spft: the way the one-liner runs it

# chk   run the check.sh copy in $T/elsewhere (or $SCRIPT) as the normal Termux user, in a clean environment
chk() {
  local extra=()
  [ -z "${SPFT_REPO:-}" ] || extra+=("SPFT_REPO=$SPFT_REPO")
  [ -z "${SPFT_BRANCH:-}" ] || extra+=("SPFT_BRANCH=$SPFT_BRANCH")
  env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" TMPDIR="$T/pfx/tmp" HOME="$T/home" TERM=xterm \
      CURL_MODE="${CURL_MODE:-}" SU_MODE="${SU_MODE:-}" FAKE_ROOT="${FAKE_ROOT:-0}" \
      ${extra[@]+"${extra[@]}"} bash "${SCRIPT:-$T/elsewhere/check.sh}"
}
curls() { grep -c '^curl ' "$CURL_LOG"; }
leftovers() { find "$T/pfx/tmp" -mindepth 1 -maxdepth 1 | grep -c . || true; }

echo "=== 1. the one-liner way: check.sh next to nothing, so it downloads the repository"
: > "$CURL_LOG"
chk > "$T/out1" 2>&1; rc=$?
sed "s#$T#\$T#g" "$T/out1"
echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit status 0" || bad "exit status $rc"
has "$CURL_LOG" "curl url=https://github.com/$DEFAULT_REPO/archive/refs/heads/main.tar.gz" "it downloaded the main branch of the default repository ($DEFAULT_REPO)"
[ "$(curls)" = 1 ] && ok "one download" || bad "$(curls) downloads"
has "$T/out1" "== Termux ==" "the Termux part of spft check is shown"
has "$T/out1" "== Result ==" "the Result block is shown"
has "$T/out1" "kernel-ver: 4.19.127-g8d3429bdb336" "the kernel version row is shown (the tablet's kernel)"
has "$T/out1" "nothing was installed on the phone" "it says that nothing was installed"
has "$T/out1" "git clone https://github.com/$DEFAULT_REPO ~/spft && bash ~/spft/install.sh" "it prints the install line for the same repository"
[ "$(leftovers)" = 0 ] && ok "the temporary folder is gone" || { bad "left in the temp folder:"; ls -A "$T/pfx/tmp"; }
[ ! -e "$T/home/spft-dl" ] && ok "nothing was written to spft-dl in the home folder" || bad "spft-dl was created in the home folder"
[ ! -e "$T/pfx/bin/spft" ] && ok "no spft command was added" || bad "a spft command was added"

echo; echo "=== 2. another repository and branch (SPFT_REPO, SPFT_BRANCH)"
: > "$CURL_LOG"
SPFT_REPO=someone/fork SPFT_BRANCH=test/one chk > "$T/out2" 2>&1; rc=$?
echo "exit=$rc"
has "$CURL_LOG" "curl url=https://github.com/someone/fork/archive/refs/heads/test/one.tar.gz" "the address uses the repository and the branch"
has "$T/out2" "git clone https://github.com/someone/fork ~/spft" "the install line names that repository"

echo; echo "=== 3. a repository name that is not owner/name is refused before anything is downloaded"
: > "$CURL_LOG"
for bad_repo in justaname a/b/c /a/b a/ 'a b/c' 'a/b;rm' ../x ./x a/.. a/. ; do
  SPFT_REPO=$bad_repo chk > "$T/out3" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q 'owner/name' "$T/out3"; then ok "refused: '$bad_repo'"; else bad "'$bad_repo' was not refused (exit $rc)"; sed -n '1,3p' "$T/out3"; fi
done
SPFT_BRANCH='x y' chk > "$T/out3" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -q 'SPFT_BRANCH' "$T/out3"; then ok "refused: a branch with a space"; else bad "a branch with a space was not refused"; fi
[ "$(curls)" = 0 ] && ok "no download for any of them" || bad "$(curls) downloads"

echo; echo "=== 4. the download fails (404, or no internet)"
: > "$CURL_LOG"
CURL_MODE=fail chk > "$T/out4" 2>&1; rc=$?
sed "s#$T#\$T#g" "$T/out4"
echo "exit=$rc"
[ "$rc" = 1 ] && ok "exit status 1" || bad "exit status $rc"
has "$T/out4" "could not download https://github.com/$DEFAULT_REPO/archive/refs/heads/main.tar.gz" "the message names the address"
has "$T/out4" "Is the internet on?" "the message says what to look at"
[ "$(leftovers)" = 0 ] && ok "the temporary folder is gone" || bad "something is left in the temp folder"

echo; echo "=== 5. the download is not an archive"
CURL_MODE=garbage chk > "$T/out5" 2>&1; rc=$?
echo "exit=$rc"; sed -n '1,6p' "$T/out5" | sed "s#$T#\$T#g"
[ "$rc" = 1 ] && has "$T/out5" "not a usable archive" "a clear message" || bad "exit status $rc"
[ "$(leftovers)" = 0 ] && ok "the temporary folder is gone" || bad "something is left in the temp folder"

echo; echo "=== 6. an archive that is not the spft repository"
CURL_MODE=nospft chk > "$T/out6" 2>&1; rc=$?
echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out6" "does not look like the spft repository" "a clear message" || bad "exit status $rc"
[ "$(leftovers)" = 0 ] && ok "the temporary folder is gone" || bad "something is left in the temp folder"

echo; echo "=== 7. from a copy of the repository: nothing is downloaded"
: > "$CURL_LOG"
SCRIPT="$T/stage/spft-main/check.sh" chk > "$T/out7" 2>&1; rc=$?
echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit status 0" || bad "exit status $rc"
[ "$(curls)" = 0 ] && ok "no download" || bad "$(curls) downloads"
has "$T/out7" "nothing is downloaded" "it says so"
has "$T/out7" "== Result ==" "the check ran"
has "$T/out7" "bash $T/stage/spft-main/install.sh" "it points to this copy's install.sh"
hasnot "$T/out7" "git clone" "no clone line (the copy is already there)"
[ -d "$T/home/spft-dl" ] && ok "(the root step kept its working copy in ~/spft-dl, as spft check always does)" || ok "no ~/spft-dl needed"
rm -rf "$T/home/spft-dl"

echo; echo "=== 8. refuses to run as root, and outside Termux"
FAKE_ROOT=1 chk > "$T/out8" 2>&1; rc=$?
[ "$rc" = 1 ] && has "$T/out8" "not as root" "root is refused" || bad "root: exit status $rc"
env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/nopfx" TMPDIR="$T/pfx/tmp" HOME="$T/home" bash "$T/elsewhere/check.sh" > "$T/out8" 2>&1; rc=$?
[ "$rc" = 1 ] && has "$T/out8" "has to run inside Termux" "outside Termux is refused" || bad "no Termux: exit status $rc"

echo; echo "=== 9. root refused: the check still ends cleanly, with the exit status of spft check"
SU_MODE=refuse chk > "$T/out9" 2>&1; rc=$?
sed "s#$T#\$T#g" "$T/out9" | sed -n '1,14p'
echo "exit=$rc"
[ "$rc" = 1 ] && ok "exit status 1" || bad "exit status $rc"
has "$T/out9" "root was REFUSED" "it says that root was refused"
has "$T/out9" "nothing was installed on the phone" "the closing lines are still printed"
[ "$(leftovers)" = 0 ] && ok "the temporary folder is gone" || bad "something is left in the temp folder"

echo; echo "=== 10. piped into bash (curl ... | bash), with a root step that reads standard input"
# when the script is piped, bash itself is the program (so not through chk, which names a script file)
pipe_run() { # pipe_run DIR   run `cat check.sh | bash` with DIR as the current folder
  ( cd "$1" && cat "$REPO/check.sh" | env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" TMPDIR="$T/pfx/tmp" HOME="$T/home" TERM=xterm \
      SU_MODE=eat-stdin bash )
}
: > "$CURL_LOG"
pipe_run "$T/elsewhere" > "$T/out10" 2>&1; rc=$?
echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit status 0" || bad "exit status $rc"
has "$T/out10" "== Result ==" "the check ran to the end"
has "$T/out10" "nothing was installed on the phone" "the closing lines were printed (nothing ate the rest of the script)"
[ "$(leftovers)" = 0 ] && ok "the temporary folder is gone" || bad "something is left in the temp folder"
echo "-- piped from inside a copy of the repository: it still takes the newest files from GitHub, not the old copy"
: > "$CURL_LOG"
pipe_run "$T/stage/spft-main" > "$T/out10b" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "exit status 0" || bad "exit status $rc"
[ "$(curls)" = 1 ] && ok "it downloaded" || bad "$(curls) downloads"
hasnot "$T/out10b" "nothing is downloaded" "it did not use the copy in the current folder"

echo; echo "=== 11. the same file runs as 'bash <(curl ...)' does it: from a file descriptor"
env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" TMPDIR="$T/pfx/tmp" HOME="$T/home" TERM=xterm \
  bash <(cat "$REPO/check.sh") > "$T/out11" 2>&1; rc=$?
echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit status 0" || bad "exit status $rc"
has "$T/out11" "downloading $DEFAULT_REPO" "it took the download way (no spft next to a file descriptor)"
has "$T/out11" "== Result ==" "the check ran"

echo
echo "FAIL count: $fails"
if grep -qF "$T" /proc/mounts; then echo "mounts under $T - not deleting"; else rm -rf "$T"; echo "cleaned up"; fi
[ "$fails" -eq 0 ]
