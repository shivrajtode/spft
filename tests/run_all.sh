#!/bin/bash
# Runs every test in this folder, with stand-ins for su, mount, chroot, curl, pkg ... so nothing real is touched.
# For a Linux PC or a sandbox - NOT for a phone (the tests refuse to run where /system/bin/mount exists).
# Needs: bash, python3, git, zip, unzip, tar, gzip, sha256sum, cksum, sed, grep, pgrep.
#
#   bash tests/run_all.sh            run them all (takes about a minute)
#   bash tests/run_all.sh --update   after a change you made on purpose: store the new expected output
#                                    of t_run.sh and t_host.sh (look at the diff in git before you commit it)
cd "$(dirname "$0")" || exit 1
update=0
[ "${1:-}" != --update ] || update=1
OUT=$(mktemp -d "${TMPDIR:-/tmp}/spft-all.XXXXXX")

# t_run.sh and t_host.sh print what happened and are compared with the saved output in expected/;
# folder names, process numbers and git hashes change from run to run, so they are replaced first
# shellcheck disable=SC2016  # the sed replacement "$T" is literal text
norm() {
  sed -E -e 's#[A-Za-z0-9_./-]*/spft-(run|host)\.[A-Za-z0-9]{6}#$T#g' \
         -e 's/[0-9a-f]{7}\.\.[0-9a-f]{7}/HASH..HASH/g' \
         -e 's/\(pid [0-9]+\)/(pid N)/g'
}

failed=0
for t in t_run t_host t_tool t_install t_publish t_docs; do
  printf '%-10s ' "$t"
  bash "./$t.sh" > "$OUT/$t.out" 2>&1
  rc=$?
  problems=
  if [ "$rc" != 0 ]; then problems="$problems exit-status-$rc"; fi
  if grep -q '^FAIL:' "$OUT/$t.out"; then problems="$problems FAIL-lines"; fi
  if grep -q '^NOTE\|^ABORT' "$OUT/$t.out"; then problems="$problems NOTE-or-ABORT-lines"; fi
  case $t in
    t_run | t_host)
      norm < "$OUT/$t.out" > "$OUT/$t.norm"
      if [ "$update" = 1 ]; then
        mkdir -p expected
        cp "$OUT/$t.norm" "expected/$t.out"
      elif [ ! -f "expected/$t.out" ]; then
        problems="$problems no-expected/$t.out(run: bash tests/run_all.sh --update)"
      elif ! diff -u "expected/$t.out" "$OUT/$t.norm" > "$OUT/$t.diff"; then
        problems="$problems output-differs-from-expected"
      fi ;;
  esac
  if [ -z "$problems" ]; then
    echo "ok   ($(grep -c '^ok:' "$OUT/$t.out") checks)"
  else
    echo "FAILED:$problems"
    failed=$((failed + 1))
    grep '^FAIL:' "$OUT/$t.out" | head -n 20
    if [ -s "$OUT/$t.diff" ]; then head -n 40 "$OUT/$t.diff"; fi
    echo "   (full output: $OUT/$t.out)"
  fi
done
echo
if [ "$failed" = 0 ]; then
  echo "all tests passed"
  rm -rf "$OUT"
else
  echo "$failed test file(s) failed"
  exit 1
fi
