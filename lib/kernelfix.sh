# The kernel-version problem of SP Flash Tool v5. This file is sourced (by `spft` on the phone, and by spft-run inside
# Debian); it only defines functions, and needs nothing but bash.
#
# SP Flash Tool v5 (5.2228 is the one spft installs) stops at the start with
#     "Invalid linux kervel version. Please upgrade linux kernel up to at least 4.19.14!"
# on some kernels that are new enough. Kernel 4.19.127, for example, is NEWER than 4.19.14, but as text "4.19.127"
# sorts BEFORE "4.19.14" (the character after "4.19.1" is "2", and "2" is less than "4"). The tool prints the version it
# read correctly ("cur_kernel_version = 4.19.127") and still refuses it, so it seems to compare the two as text.
# That hits the kernels 4.19.100 to 4.19.139, and Android phones and tablets often run 4.19.1xx.
#
# The fix is to show the tool a version that passes: lib/kernelfix.so.b64 is a tiny library that overrides uname()
# (box64's BOX64_LD_PRELOAD loads it), and it says what /tmp/spft-fake-kernel says. spft-run writes that file, and loads
# the library, only when it is needed.
#
# The text-comparison is an explanation that fits what the tool prints, but it is a guess (the tool is closed source).
# So there is an override:  SPFT_FAKE_KERNEL=auto (default) | off | a version such as 5.4.0

# kernelfix_class RELEASE   prints what the tool does with this kernel:
#   fine     it accepts it
#   text     the kernel is new enough (4.19.14 or newer) but the tool wrongly rejects it - spft fixes this by itself
#   old      the kernel is older than 4.19.14: the tool may reject it (then it is no mistake); spft leaves it alone
#   unknown  the version could not be read
kernelfix_class() {
  local v=${1%%[!0-9.]*} maj min pat
  IFS=. read -r maj min pat _ <<EOF
$v
EOF
  case $maj$min${pat:-0} in '' | *[!0-9]*) echo unknown; return 0 ;; esac
  if [ -z "$maj" ] || [ -z "$min" ]; then echo unknown; return 0; fi
  maj=$((10#$maj)); min=$((10#$min)); pat=$((10#${pat:-0}))
  if [ "$maj" -lt 4 ] || { [ "$maj" -eq 4 ] && { [ "$min" -lt 19 ] || { [ "$min" -eq 19 ] && [ "$pat" -lt 14 ]; }; }; }; then
    echo old
  elif [ "$maj" -eq 4 ] && [ "$min" -eq 19 ] && [ "$pat" -ge 100 ] && [ "$pat" -le 139 ]; then
    echo text
  else
    echo fine
  fi
}

# kernelfix_show RELEASE [MODE]   prints the release the tool should be shown, or nothing when it should see the real one.
# MODE is what SPFT_FAKE_KERNEL says: auto (the default), off, or the version to show. A bad MODE prints nothing and returns 1.
kernelfix_show() {
  local real=$1 mode=${2:-auto}
  case $mode in
    off | no | none | false | 0) return 0 ;;
    auto)
      if [ "$(kernelfix_class "$real")" = text ]; then echo 4.19.140; fi
      return 0 ;;
    *[!0-9A-Za-z._+-]*) return 1 ;;
    *)
      [ "${#mode}" -le 64 ] || return 1   # the field in uname()'s answer holds 64 characters
      printf '%s\n' "$mode" ;;
  esac
}
