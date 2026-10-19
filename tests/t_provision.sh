#!/bin/bash
# Test of lib/provision.sh: the setup that runs INSIDE Debian (libraries, box64, the self-test) and the progress it shows.
# apt-get, dpkg, box64, wget, gpg, git, cmake and make are stand-ins; the Debian folders are moved into a work folder.
# Needs: bash, awk, sed, grep, find, stat, head, sort. It does not need root and does not touch the machine.
# On purpose in the tests: ok/bad always return 0, patterns are literal text, printf builds escapes.
# shellcheck disable=SC2015,SC2016,SC2012,SC2002,SC2059
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
for c in awk sed grep find stat head sort install; do command -v $c >/dev/null || { echo "ABORT: $c is needed for this test"; exit 1; }; done
T=$(mktemp -d "${TMPDIR:-/tmp}/spft-prov.XXXXXX")
mkdir -p "$T/bin" "$T/root" "$T/tmp" "$T/etc/apt/sources.list.d" "$T/usr/share/keyrings" "$T/var/cache/apt/archives/partial" \
         "$T/pkgtree/bin" "$T/pkgtree/usr/share/initramfs-tools/conf-hooks.d"
LOG=$T/calls.log; : > "$LOG"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { if grep -q -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
hasnt() { if grep -q -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }
count() { grep -c -- "$1" "$LOG" || true; }

# --- stand-ins ------------------------------------------------------------------------------------
# apt-get: knows update / install (-s, -d, --print-uris, real) / download / clean. State: $TT/installed (one name per line).
#   FAKE_APT_UNKNOWN="a b"  names that give "E: Unable to locate package"
#   FAKE_APT_FAIL=update    `apt-get update` fails like it does without internet
#   FAKE_APT_SLOW=N         every update and every install takes N seconds (so that the "still working" line shows up)
#   FAKE_APT_SIZE=BYTES     size of every .deb (default 200000)
#   FAKE_APT_BOX64=fail     installing box64-android fails (the repository is down)
cat > "$T/bin/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$TLOG"
sub= sim=0 dl=0 uris=0 pk=()
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  a=${args[$i]}
  case $a in
    -o) i=$((i + 1)) ;;
    -s) sim=1 ;;
    -d) dl=1 ;;
    --print-uris) uris=1 ;;
    -*) ;;
    *) if [ -z "$sub" ]; then sub=$a; else pk+=("$a"); fi ;;
  esac
  i=$((i + 1))
done
ARCH=$TT/var/cache/apt/archives
size=${FAKE_APT_SIZE:-200000}
fname() { local p=$1 arch=arm64; case $p in *:amd64) arch=amd64 ;; esac; echo "${p%%:*}_1.0_$arch.deb"; }
todo() { local p; for p in "${pk[@]}"; do grep -qxF "$p" "$TT/installed" 2>/dev/null || echo "$p"; done; }
case $sub in
  update)
    if [ "${FAKE_APT_FAIL:-}" = update ]; then echo "E: Failed to fetch http://deb.example/dists/trixie/InRelease  Temporary failure resolving 'deb.example'" >&2; exit 100; fi
    echo "Get:1 http://deb.example/debian trixie InRelease [43.3 kB]"
    sleep "${FAKE_APT_SLOW:-0}"
    echo "Fetched 43.3 kB in 1s (60.1 kB/s)"
    echo "Reading package lists... Done" ;;
  clean) rm -f "$ARCH"/*.deb ;;
  download)
    for p in "${pk[@]}"; do : > "$(fname "$p" | sed 's/_1.0_/_1.37-1_/')"; echo "Get:1 http://deb.example/debian trixie/main amd64 ${p%%:*} amd64 1.37-1 [1,000 kB]"; done ;;
  install)
    if [ "$sim" = 1 ] || [ "$uris" = 1 ]; then
      badn=0
      for p in "${pk[@]}"; do case " ${FAKE_APT_UNKNOWN:-} " in *" $p "*) echo "E: Unable to locate package $p"; badn=1 ;; esac; done
      [ "$badn" = 0 ] || exit 100
      if [ "$sim" = 1 ]; then
        n=0; for p in $(todo); do echo "Inst $p (1.0 Debian:13/stable [arm64])"; n=$((n + 1)); done
        echo "0 upgraded, $n newly installed, 0 to remove and 0 not upgraded."
      else
        echo "Reading package lists... Done"
        for p in $(todo); do echo "'http://deb.example/pool/main/$(fname "$p")' $(fname "$p") $size SHA256:0000"; done
      fi
      exit 0
    fi
    if [ "${FAKE_APT_BOX64:-}" = fail ]; then case " ${pk[*]} " in *" box64-android "*) echo "E: Unable to locate package box64-android" >&2; exit 100 ;; esac; fi
    if [ "$dl" = 1 ]; then
      k=0
      for p in $(todo); do
        k=$((k + 1)); f=$(fname "$p")
        echo "Get:$k http://deb.example/debian trixie/main arm64 ${p%%:*} arm64 1.0 [$((size / 1000)) kB]"
        head -c $((size / 2)) /dev/zero > "$ARCH/partial/$f"; [ "$k" -gt 1 ] || sleep 1.5   # (the first file is slow: the progress line sees it half done)
        head -c "$size" /dev/zero > "$ARCH/partial/$f"; mv "$ARCH/partial/$f" "$ARCH/$f"
      done
      echo "Fetched $((k * size / 1000)) kB in 2s"; echo "Download complete and in download only mode"
      exit 0
    fi
    sleep "${FAKE_APT_SLOW:-0}"
    echo "(Reading database ... 5%"
    echo "(Reading database ... 12345 files and directories currently installed.)"
    for p in $(todo); do echo "Unpacking ${p} (1.0) ..."; done
    for p in $(todo); do
      echo "Setting up ${p} (1.0) ..."
      echo "$p" >> "$TT/installed"
      case $p in box64-android | box64*) : > "$TT/box64-installed" ;; esac
    done
    echo "Processing triggers for libc-bin (2.41-12) ..." ;;
  *) echo "apt-get stand-in: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
cat > "$T/bin/dpkg" <<'EOF'
#!/bin/bash
echo "dpkg $*" >> "$TLOG"
case $1 in
  -x) cp -a "$TT/pkgtree/." "$3/" ;;
esac
exit 0
EOF
# box64: not installed until apt-get "installs" it; runs a program only when the file is executable and big, like the real one.
#   FAKE_BOX64_BROKEN=1  it cannot run programs (an unsupported kernel or CPU, say)
cat > "$T/bin/box64" <<'EOF'
#!/bin/bash
echo "box64 $*" >> "$TLOG"
[ -e "$TT/box64-installed" ] || { echo "box64: command not found" >&2; exit 127; }
case $1 in --version) echo "Box64 arm64 v0.3.8 (test)"; exit 0 ;; esac
f=$1; shift
if [ ! -x "$f" ]; then printf '[\033[31mBOX64\033[0m] Error: %s is not an executable file.\n' "$f" >&2; exit 255; fi
if [ "${FAKE_BOX64_BROKEN:-}" = 1 ]; then echo "Illegal instruction" >&2; exit 132; fi
case $1 in uname) echo x86_64 ;; esac
EOF
printf '#!/bin/bash\nexit 2\n' > "$T/bin/getent"
for c in groupadd usermod; do printf '#!/bin/bash\necho "%s $*" >> "$TLOG"\n' "$c" > "$T/bin/$c"; done
printf '#!/bin/bash\necho "wget $*" >> "$TLOG"\necho "-----BEGIN PGP PUBLIC KEY BLOCK-----"\n' > "$T/bin/wget"
printf '#!/bin/bash\necho "gpg $*" >> "$TLOG"\ncat > /dev/null\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done\n' > "$T/bin/gpg"
# git / cmake / make: for the "build box64 from source" path
printf '#!/bin/bash\necho "git $*" >> "$TLOG"\nmkdir -p "${@: -1}"\n' > "$T/bin/git"
printf '#!/bin/bash\necho "cmake $*" >> "$TLOG"\n' > "$T/bin/cmake"
printf '#!/bin/bash\necho "make $*" >> "$TLOG"\n[ "${1:-}" != install ] || : > "$TT/box64-installed"\n' > "$T/bin/make"
# find: lists the files in REVERSE order. With the package below this puts the text file usr/share/.../busybox BEFORE the
# program bin/busybox, which is the worst case for a self-test that takes the first file called busybox.
cat > "$T/bin/find" <<'EOF'
#!/bin/bash
/usr/bin/find "$@" | sort -r
EOF
chmod +x "$T"/bin/*

# the package busybox-static as `dpkg -x` unpacks it: the program, and a config text file with the same name
head -c 300000 /dev/zero > "$T/pkgtree/bin/busybox"; chmod 755 "$T/pkgtree/bin/busybox"
printf '# initramfs-tools hook configuration\nBUSYBOX=auto\n' > "$T/pkgtree/usr/share/initramfs-tools/conf-hooks.d/busybox"; chmod 644 "$T/pkgtree/usr/share/initramfs-tools/conf-hooks.d/busybox"

# --- the script under test: the Debian folders moved into the work folder ------------------------------
make_script() { # make_script OUT [SOURCE]
  sed -e "s#/var/cache/apt/archives#$T/var/cache/apt/archives#g" \
      -e "s#/tmp/bbtest#$T/tmp/bbtest#g" \
      -e "s#/root/\\.spft-selftest-failed#$T/root/.spft-selftest-failed#g" \
      -e "s#/root/box64-src#$T/root/box64-src#g" \
      -e "s#/etc/apt/sources.list.d#$T/etc/apt/sources.list.d#g" \
      -e "s#/usr/share/keyrings#$T/usr/share/keyrings#g" "${2:-$REPO/lib/provision.sh}" > "$1"
}
make_script "$T/provision.sh"
# every Debian path that was meant to move has moved (a moved path has the work folder's name in front of it)
if grep -n -E '(^|[^A-Za-z0-9_./-])/(var/cache/apt|tmp/bbtest|root/\.spft-selftest|root/box64-src|etc/apt/sources\.list\.d|usr/share/keyrings)' "$T/provision.sh"; then echo "NOTE: unreplaced absolute paths above"; fi

fresh() { rm -rf "$T/installed" "$T/box64-installed" "$T/root/.spft-selftest-failed" "$T/root/box64-src" "$T/tmp/bbtest" \
                 "$T/var/cache/apt/archives/"*.deb "$T/var/cache/apt/archives/partial/"* "$T/etc/apt/sources.list.d/"*; : > "$LOG"; }
run() { # run [VAR=value ...]   the script, with the stand-ins in front and short waiting times
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/root" TT="$T" TLOG="$LOG" SPFT_BEAT=1 SPFT_POLL=1 "$@" bash "$T/provision.sh"
}
sed_t() { sed "s#$T#\$T#g"; }

echo "=== 1. a normal run, with apt slow enough for the progress display to show"
fresh
run FAKE_APT_SLOW=2 > "$T/out" 2>&1; rc=$?
sed_t < "$T/out" | grep -v '^   \[' | head -n 60; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
has "$T/out" '^>> \[1/4\] base packages' "step 1 of 4 is announced"
has "$T/out" '^>> \[2/4\] arm64 + x86_64 libraries' "step 2 of 4 is announced, with the name people look for"
has "$T/out" '^>> \[3/4\] box64' "step 3 of 4 is announced"
has "$T/out" '^>> \[4/4\] self-test' "step 4 of 4 is announced"
has "$T/out" 'NOT stuck when it is quiet' "the long step says it is not stuck when quiet"
has "$T/out" 'downloading [0-9]* files, [0-9.]* MB' "the download says how many files and how many MB"
has "$T/out" 'downloaded [0-9.]* of [0-9.]* MB ([0-9]*%) - [0-9]* of [0-9]* files' "a progress line shows MB, percent and files"
has "$T/out" 'downloaded [0-9.]* of [0-9.]* MB (100%)' "and it ends at 100%"
has "$T/out" 'download finished in' "the end of the download is said"
has "$T/out" '^   \[1/[0-9]*\] Unpacking ' "the unpacking is counted"
has "$T/out" '^   \[[0-9]*/[0-9]*\] Setting up ' "the setting up is counted"
hasnt "$T/out" 'Reading database' "dpkg's own noisy lines are left out"
has "$T/out" '^   \.\.\. .*: still working ([0-9]*m[0-9][0-9]s)$' "a quiet step prints timed '... still working (0m03s)' lines (the intro text alone does not count)"
has "$T/out" 'busybox, run through box64, says: machine = x86_64' "the self-test ran the real program and got x86_64"
[ ! -e "$T/root/.spft-selftest-failed" ] && ok "the self-test passed (no failure marker)" || bad "the failure marker exists"
has "$T/out" 'Debian is ready' "ends with the ready message"
has "$LOG" '^dpkg --add-architecture amd64' "the amd64 architecture was added"
n=$(grep -c -- 'install -s ' "$LOG" || true)
[ "$n" -le 6 ] && ok "apt was asked what to install $n times in all (the old code asked once per library: about 90 times)" || bad "$n dry runs of apt-get"
has "$LOG" 'apt-get .*Acquire::Retries=3' "apt is told to retry dropped downloads"
# the total: files and MB add up
tot=$(grep -c . "$T/installed")
[ "$tot" -gt 80 ] && ok "$tot packages were installed (arm64 and amd64 libraries, desktop, box64)" || bad "only $tot packages installed"

echo; echo "=== 2. names that this Debian does not have are skipped (and said so), the rest is installed"
fresh
run FAKE_APT_UNKNOWN="libpng16-16:amd64 libsm6" > "$T/out" 2>&1; rc=$?
grep 'skipped' "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
has "$T/out" 'this Debian does not have libpng16-16:amd64 - skipped' "the first unknown name is reported"
has "$T/out" 'this Debian does not have libsm6 - skipped' "the second one too"
! grep -qxF libsm6 "$T/installed" && ! grep -qxF libpng16-16:amd64 "$T/installed" && ok "they were not installed" || bad "an unknown name was installed"
grep -qxF libx11-6 "$T/installed" && grep -qxF libx11-6:amd64 "$T/installed" && ok "the others were (libx11-6, arm64 and amd64)" || bad "known libraries are missing"
n=$(grep -c -- 'install -s ' "$LOG" || true)
[ "$n" -le 7 ] && ok "still only $n dry runs" || bad "$n dry runs"

echo; echo "=== 3. a base package that does not exist is NOT skipped: the setup stops with apt's message"
fresh
run FAKE_APT_UNKNOWN="openbox" > "$T/out" 2>&1; rc=$?
tail -n 6 "$T/out"; echo "exit=$rc"
[ "$rc" != 0 ] && ok "non-zero exit" || bad "a missing base package did not stop the setup"
has "$T/out" 'E: Unable to locate package openbox' "apt's message is shown"
has "$T/out" 'The setup stopped in step: base packages' "and the step where it stopped"
has "$T/out" 'spft install  again' "and what to do next"

echo; echo "=== 4. no internet: the failing step is named and the message says that running it again carries on"
fresh
run FAKE_APT_FAIL=update > "$T/out" 2>&1; rc=$?
tail -n 5 "$T/out"; echo "exit=$rc"
[ "$rc" != 0 ] && ok "non-zero exit" || bad "no error exit without internet"
has "$T/out" 'Temporary failure resolving' "apt's own message is shown"
has "$T/out" 'The setup stopped in step: base packages' "the step is named"
has "$T/out" 'what was already downloaded is kept' "it says that downloads are kept"

echo; echo "=== 5. the self-test takes the busybox PROGRAM, not the text file of the same name (it did once: red BOX64 error)"
fresh
run > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/root/.spft-selftest-failed" ] && ok "passes although the text file is listed first" || bad "self-test failed with the text file listed first (rc=$rc)"
has "$LOG" 'box64 ./bin/busybox uname -m' "box64 was given ./bin/busybox"
hasnt "$LOG" 'conf-hooks.d/busybox' "and never the config file"
hasnt "$T/out" 'is not an executable file' "no red BOX64 error"

echo; echo "=== 6. box64 that cannot run programs: the failure is reported and marked, the setup itself still ends"
fresh
run FAKE_BOX64_BROKEN=1 > "$T/out" 2>&1; rc=$?
tail -n 6 "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0 (spft reads the marker)" || bad "exit status $rc"
[ -e "$T/root/.spft-selftest-failed" ] && ok "failure marker written" || bad "no failure marker"
has "$T/out" 'self-test failed' "says the self-test failed"
has "$T/out" 'box64 could not run' "says what failed"

echo; echo "=== 7. no internet for the test program: the self-test says so"
fresh
sed -e 's#apt-get download busybox-static:amd64#false#' "$T/provision.sh" > "$T/provision-nodl.sh"
env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/root" TT="$T" TLOG="$LOG" SPFT_BEAT=1 SPFT_POLL=1 bash "$T/provision-nodl.sh" > "$T/out" 2>&1; rc=$?
tail -n 4 "$T/out"; echo "exit=$rc"
has "$T/out" 'could not download the test program' "the failed download is explained"
[ -e "$T/root/.spft-selftest-failed" ] && ok "failure marker written" || bad "no failure marker"

echo; echo "=== 8. everything is installed already (a second run): nothing is downloaded"
fresh
run > /dev/null 2>&1
: > "$LOG"
run > "$T/out" 2>&1; rc=$?
grep -c 'everything is installed already' "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
has "$T/out" 'everything is installed already' "says so"
[ "$(count 'install -d')" = 0 ] && [ "$(count 'print-uris')" -le 4 ] && ok "no download was started" || bad "downloads on the second run"

echo; echo "=== 9. box64's repository is down: it is built from source instead"
fresh
run FAKE_APT_BOX64=fail > "$T/out" 2>&1; rc=$?
grep -E 'building box64|self-test|machine =' "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
has "$T/out" 'building box64 from source' "the build is announced"
has "$LOG" '^git clone --depth 1 https://github.com/ptitSeb/box64' "box64 was cloned"
has "$LOG" '^cmake .* -D ARM64=1' "cmake ran"
has "$LOG" '^make install' "make install ran"
has "$T/out" 'machine = x86_64' "and the self-test passed with the built box64"

echo; echo "=== 10. a download that is already half there (an interrupted run) counts as progress"
fresh
head -c 100000 /dev/zero > "$T/var/cache/apt/archives/partial/libx11-6_1.0_arm64.deb"
run > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "the run completes" || bad "exit status $rc"
has "$T/out" 'downloaded [0-9.]* of [0-9.]* MB (100%)' "and still ends at 100%"

echo; echo "FAIL count: $fails"
rm -rf "$T"; echo "cleaned up"
[ "$fails" = 0 ]
