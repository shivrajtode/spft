#!/data/data/com.termux/files/usr/bin/bash
# Check a phone or tablet WITHOUT installing spft.
#
# Nothing is installed: this downloads the repository into a temporary folder, runs `spft check` from there, and
# deletes the folder again. In Termux, paste:
#
#     bash <(curl -fsSL https://raw.githubusercontent.com/shivrajtode/spft/main/check.sh)
#
# (curl comes with Termux; if it is missing:  pkg install curl)
# It tells you whether this device can be the host: root, a 64-bit kernel, the kernel version, the USB driver, free space.
# From a copy of the repository you can also run  bash check.sh  or, once spft is installed,  spft check.
#
#   SPFT_REPO=owner/name   SPFT_BRANCH=main     read the files from another repository or branch (a fork, a test branch)
#
# The whole script is one function, so that it also works when it is piped (curl ... | bash): bash then reads all of
# it before anything runs, and nothing it starts can eat the rest of the script.

spft_check_tmp=''
spft_check_cleanup() { if [ -n "$spft_check_tmp" ]; then rm -rf "$spft_check_tmp"; spft_check_tmp=''; fi; }

spft_check_main() {
  set -eu
  local repo=${SPFT_REPO:-shivrajtode/spft} branch=${SPFT_BRANCH:-main}
  local prefix=${PREFIX:-/data/data/com.termux/files/usr}
  local here='' self src url rc=0

  say() { printf '\n>> %s\n' "$*"; }
  die() { echo "check: $*" >&2; exit 1; }

  [ "$(id -u)" != 0 ] || die "run this as the normal Termux user, not as root"
  [ -x "$prefix/bin/pkg" ] || die "this has to run inside Termux (get Termux from https://f-droid.org/packages/com.termux/)"
  case $repo in
    *[!A-Za-z0-9._/-]* | /* | */ | */*/* | ./* | ../* | */. | */..) die "SPFT_REPO must look like owner/name (for example shivrajtode/spft), not '$repo'" ;;
    */*) ;;
    *) die "SPFT_REPO must look like owner/name (for example shivrajtode/spft), not '$repo'" ;;
  esac
  case $branch in
    '' | *[!A-Za-z0-9._/-]*) die "SPFT_BRANCH may only hold letters, digits and . _ - /  (not '$branch')" ;;
  esac

  # Run as a file that sits next to a copy of the repository (bash check.sh)? Then use that copy and download nothing.
  # Run through curl (bash <(curl ...) or curl ... | bash) there is no such file: it always downloads the newest files.
  here=''
  self=${BASH_SOURCE[0]:-}
  if [ -n "$self" ] && [ -f "$self" ]; then here=$(cd "$(dirname "$self")" 2>/dev/null && pwd) || here=''; fi
  if [ -n "$here" ] && [ -f "$here/spft" ] && [ -d "$here/lib" ]; then
    src=$here
    say "checking with the copy of spft in $here (nothing is downloaded)"
  else
    command -v curl >/dev/null 2>&1 || die "curl is missing - run: pkg install curl"
    command -v tar >/dev/null 2>&1 || die "tar is missing - run: pkg install tar"
    spft_check_tmp=$(mktemp -d "${TMPDIR:-$prefix/tmp}/spft-check.XXXXXX") || die "could not make a temporary folder"
    trap spft_check_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    url=https://github.com/$repo/archive/refs/heads/$branch.tar.gz
    say "downloading $repo ($branch) into a temporary folder: a few hundred KB, nothing is installed"
    if ! curl -fsSL --retry 2 -o "$spft_check_tmp/repo.tar.gz" "$url"; then
      die "could not download $url
   Is the internet on? Does the repository exist, is it public, and does the branch '$branch' exist?
   (another address: SPFT_REPO=owner/name SPFT_BRANCH=main bash <(curl -fsSL .../check.sh))"
    fi
    mkdir -p "$spft_check_tmp/src"
    tar -xzf "$spft_check_tmp/repo.tar.gz" -C "$spft_check_tmp/src" --strip-components=1 ||
      die "the download is not a usable archive (a half-finished download?) - run this again"
    { [ -f "$spft_check_tmp/src/spft" ] && [ -d "$spft_check_tmp/src/lib" ]; } ||
      die "$repo does not look like the spft repository (no spft file and lib folder in it)"
    src=$spft_check_tmp/src
  fi

  say "spft check"
  # The root step runs a copy that spft keeps next to its downloads. With files from a temporary folder, that copy
  # lives in the temporary folder too, and is deleted with it.
  if [ -n "$spft_check_tmp" ]; then
    SPFT_DL=$spft_check_tmp/dl bash "$src/spft" check || rc=$?
  else
    bash "$src/spft" check || rc=$?
  fi

  echo
  if [ -n "$spft_check_tmp" ]; then
    spft_check_cleanup
    echo "That was only a check: nothing was installed on the phone, and the temporary files are deleted."
    echo "To install spft, paste this line:"
    echo
    echo "  pkg update -y && pkg install -y git && git clone https://github.com/$repo ~/spft && bash ~/spft/install.sh"
  else
    echo "That was only a check. To set spft up, run:  bash $src/install.sh"
  fi
  return "$rc"
}

spft_check_main "$@"
