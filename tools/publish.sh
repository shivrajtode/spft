#!/usr/bin/env bash
# Put this project on YOUR GitHub account, so that anyone can install it with `git clone`.
# Run it once from this folder (it works in Termux and on a PC):
#
#     bash tools/publish.sh            # creates  github.com/<your name>/spft
#     bash tools/publish.sh my-repo    # or with another repository name
#
# It needs git and the GitHub command line tool. In Termux:  pkg install git gh
# If you are not logged in to GitHub yet it starts the login: a code is shown, you type it on
# https://github.com/login/device in your browser.
#
# It also writes your GitHub name into the README (the places that say YOUR-GITHUB-NAME).
#
# Running it again after an update is safe. If you edited a file on github.com after the last publish (a thank-you
# line in the README, say), your edit is kept: GitHub's newer changes are merged in before anything is pushed. Only
# when the very same lines changed on both sides does it stop; it then pushes nothing, changes nothing on GitHub, and says so.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
name=${1:-spft}
die() { echo "publish: $*" >&2; exit 1; }
say() { printf '\n>> %s\n' "$*"; }

command -v git >/dev/null 2>&1 || die "git is missing (Termux: pkg install git)"
command -v gh >/dev/null 2>&1 || die "gh, the GitHub command line tool, is missing (Termux: pkg install gh)"
{ [ -f "$HERE/spft" ] && [ -f "$HERE/install.sh" ]; } || die "this script has to stay inside the spft folder (tools/publish.sh)"
case $name in
  '' | *[!A-Za-z0-9._-]*) die "'$name' is not a usable repository name (letters, digits, . _ - only)" ;;
esac
cd "$HERE"

say "GitHub login"
if ! gh auth status >/dev/null 2>&1; then
  gh auth login --web --git-protocol https
fi
gh auth setup-git >/dev/null 2>&1 || true
owner=$(gh api user -q .login) || die "could not read your GitHub user name - run:  gh auth login"
[ -n "$owner" ] || die "could not read your GitHub user name - run:  gh auth login"
echo "logged in as $owner"

say "writing $owner/$name into the README and the guides"
# a copy that is written back over the original keeps the file's permissions
for f in $(grep -rIl --exclude-dir=.git --exclude-dir=tests --exclude=publish.sh 'YOUR-GITHUB-NAME' . 2>/dev/null || true); do
  tmp=$(mktemp)
  sed -e "s#YOUR-GITHUB-NAME/spft#$owner/$name#g" -e "s#YOUR-GITHUB-NAME#$owner#g" "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  echo "   $f"
done

say "git"
if [ ! -d .git ]; then
  git init -q
  git symbolic-ref HEAD refs/heads/main   # the branch is called main (works with old and new git)
fi
if ! git config user.name >/dev/null 2>&1; then git config user.name "$(gh api user -q '.name // .login' 2>/dev/null || echo "$owner")"; fi
if ! git config user.email >/dev/null 2>&1; then
  id=$(gh api user -q .id 2>/dev/null || true)
  git config user.email "${id:+$id+}$owner@users.noreply.github.com"
fi
git add -A
if git diff --cached --quiet; then
  echo "(nothing new to commit)"
else
  git commit -q -m "spft: SP Flash Tool on a rooted phone or tablet (Termux + Debian chroot + box64 + Termux:X11)"
fi
git rev-parse --verify -q HEAD >/dev/null || die "there is nothing to publish (no commit)"

say "GitHub: $owner/$name"
if gh repo view "$owner/$name" >/dev/null 2>&1; then
  echo "the repository exists already - pushing to it"
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$owner/$name.git"
  # GitHub can be AHEAD of this folder: you edited a file on github.com (or in the GitHub app) after the last publish.
  # A plain push is refused then ("fetch first"), so bring that work in first. A merge keeps both: what is on GitHub
  # and what is in this folder. (If the repository is still empty, the fetch finds nothing and is skipped.)
  if git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null && ! git merge-base --is-ancestor origin/main HEAD; then
    echo "GitHub has changes that are not in this folder yet (an edit you made on github.com?). They are kept:"
    git log --format='   %h %an: %s' HEAD..origin/main
    if ! git merge --no-edit -q -m "Merge the changes made on GitHub" origin/main; then
      git merge --abort 2>/dev/null || true
      die "GitHub has a change that could not be joined with this update by itself (see the lines above).
   Nothing was pushed and nothing on GitHub was changed: the join was cancelled and this folder is as it was.
   Open github.com/$owner/$name, press History on the file that changed, and send what you see to whoever made this update."
    fi
  fi
  git push -u origin main
else
  echo "creating the repository (public: others must be able to clone it)"
  gh repo create "$owner/$name" --public --source . --remote origin --push \
    --description "SP Flash Tool (MediaTek) on a rooted Android phone or tablet: Termux + Debian chroot + box64 + Termux:X11"
fi

cat <<DONE

>> Published: https://github.com/$owner/$name

Anyone with a rooted Android phone can now install it in Termux with this one line:

  pkg update -y && pkg install -y git && git clone https://github.com/$owner/$name ~/spft && bash ~/spft/install.sh

and start it afterwards by typing:  spft

To only CHECK a phone first (nothing is installed), they can paste this in Termux:

  bash <(curl -fsSL https://raw.githubusercontent.com/$owner/$name/main/check.sh)
DONE
