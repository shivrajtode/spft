# How spft works

Back to the [README](../README.md). You do not need this page to use spft. It is for the curious, and for anyone who wants to change something.

## The idea

SP Flash Tool is a **Linux x86-64** program. A phone is **ARM**. So spft stacks four things:

```
Android (rooted)
 └─ Termux                     the terminal where you type `spft`
     └─ Debian (a chroot)      a normal Linux system in /data/local/spft-debian
         └─ box64              translates x86-64 programs so that an ARM CPU can run them
             └─ SP Flash Tool  MediaTek's program, shown on the Termux:X11 screen
```

- **Root** is needed for `chroot`, for the bind mounts, and for access to the USB serial device (`/dev/ttyACM*`) that the target shows up as.
- The **kernel** of the phone does the real work (USB, serial). It has to be 64-bit ARM (`CONFIG_ARM64=y`) because box64 is 64-bit. The Android userspace can be 32-bit.
- The **screen** is Termux:X11, an X server inside an Android app. It is much faster than VNC.

## Files in the repository

```
spft                the command (a bash script). `spft help` lists the commands.
install.sh          one-time installer: Termux packages, the `spft` command, then `spft install`
check.sh            the check WITHOUT installing: downloads the repository into a temporary folder, runs `spft check`, deletes it
lib/tools.conf      SP Flash Tool versions: name, sha256, download address
lib/provision.sh    runs INSIDE Debian, once: libraries, desktop, box64, self-test (with a progress display)
lib/run.sh          runs INSIDE Debian, every time: picks the display, starts openbox and the tool
lib/gui.sh          runs INSIDE Debian: the VNC desktop for `spft vnc`
lib/kernelfix.sh    which kernels SP Flash Tool v5 turns away by mistake, and what to show it instead
lib/kernelfix.so.b64  the tiny library that shows it that (base64 text); built from tools/kernelfix.s
tools/publish.sh    puts this project on your GitHub account
tools/kernelfix.s   source of that library (x86-64 assembly, no libc)
tools/build-kernelfix.sh  rebuilds lib/kernelfix.so.b64 from it
tests/              automatic tests: bash tests/run_all.sh
docs/               these pages
```

## Files that spft creates

| Where | What |
|---|---|
| `$PREFIX/bin/spft` | The launcher: two lines that run `~/spft/spft` with bash (so it does not depend on file permissions or links). |
| `~/spft-dl/` | Downloads and working files: `rootfs.tar.gz` (Debian), `SP_Flash_Tool_<version>_Linux.zip`, `app/` (a copy of `spft` and `lib/` for the root step), `x11.log`, `x11-prefs.orig` (your Termux:X11 settings before spft changed them, for `spft x11 reset`). |
| `/data/local/spft-debian/` | The Debian system. Inside it: `/opt/SP_Flash_Tool_*` (the tool), `/opt/spft-current` (a link to the version that starts), `/usr/local/bin/spft-run` and `spft-gui`, `/usr/local/lib/spft/` (the kernel-version fix), `/root/spft-provision.sh`. |
| `/tmp/spft-kernelfix.so`, `/tmp/spft-fake-kernel` (inside Debian) | Written by `spft-run` each time the tool starts on a kernel that needs the fix, and removed when it does not ([the fix](#the-kernel-version-fix)). |
| `/data/local/spft-debian/.spft-unpacked` | Proves the Debian unpack ran to the end. |
| `/data/local/spft-debian/.spft-provisioned` | Holds the checksum of `lib/provision.sh`. When `spft update` changes that file, the setup runs again once. |

## What happens when you type `spft`

1. **As the normal Termux user.** spft starts the Termux:X11 server (`termux-x11 :0`) if it is not running, opens the Termux:X11 app, and sets *landscape, fullscreen* and [the zoom that fits your screen](#the-zoom) with `termux-x11-preference`. That tool can say "ok" for a value the app refused, and one refused key throws away a whole batch, so spft sets **one key per call** and reads every setting back to check. It keeps the phone's CPU awake (`termux-wake-lock`).
2. **As root** (`su -c`). The root step runs a **copy** of `spft` and `lib/` kept in `~/spft-dl/app`, because the repository may sit on shared storage that root cannot always read. It unsets `LD_LIBRARY_PATH` first: Termux's libraries must never reach Android's own tools (they would fail with `CANNOT LINK EXECUTABLE`).
3. **Mounts.** `/dev`, `/dev/pts`, a `tmpfs` for `/dev/shm`, `/proc`, `/sys`, the internal storage (`/data/media/0` to `/mnt/sdcard`, with a `/sdcard` link), and Termux:X11's socket folder.
4. **`chroot`** into Debian and run `spft-run` (a copy of `lib/run.sh`).
5. **`spft-run`** refuses to start a second copy of the tool, picks the display (Termux:X11 or VNC), starts the `openbox` window manager (one rule maximizes the tool's main window, written to `~/.config/openbox/rc.xml` inside Debian from Debian's default), sets the Qt and box64 variables, [prepares the kernel-version fix](#the-kernel-version-fix) when the kernel needs it, [gives the tool the phone's storage as its home folder](#the-home-folder-of-the-file-windows), and runs `box64 ./flash_tool` from the tool's folder.

**Settings typed in front of the command** (`SPFT_STORAGE=off spft`, `SPFT_FAKE_KERNEL=off spft`, `SPFT_GEOMETRY=...`, `BOX64_LOG=...`) have to get from Termux into step 5, and on the way `su` is free to drop the environment and `enter` starts Debian's shell with `env -i`, which drops all of it. So spft hands the ones that are set down **inside the command line itself**, as `VAR='value'` words in front of `spft-run` (every word in single quotes, which any shell reads back unchanged, also with spaces, quotes or non-ASCII letters). Before v4 this was missing, and `SPFT_FAKE_KERNEL=off spft` did nothing. `bash tests/t_host.sh` (section V2) checks it with a `su` that drops the environment.

## `spft stop`: everything, and the caches

`spft stop` is for the moment when something hangs, the screen is black, or you simply want spft gone from the phone's memory. It is built to leave **nothing** of spft behind. The root step does this, in this order:

1. **Every process inside Debian.** It finds each process whose root folder is the Debian folder (the tool, box64, openbox, a VNC server, shells), sends `TERM`, waits 2 seconds, and sends `KILL` to whatever is still there.
2. **The Termux:X11 server.** Its process renames itself `termux-x11 <id> :0` (the Termux:X11 README says to use `pkill -f termux-x11`). It gets `TERM`, a second, then `KILL`. The socket and lock files that a server killed by Android leaves behind are removed too: with that socket in the way spft would think a server is running and the screen would stay black.
3. **The Termux:X11 app**, with `am force-stop com.termux.x11`.
4. **The mounts.** Everything `enter` mounted into Debian (`tmp/.X11-unix`, `mnt/sdcard`, `dev/shm`, `dev/pts`, `dev`, `proc`, `sys`), deepest first, twice if one was still busy.
5. **The caches:** Debian's `/tmp` and `/root/.cache`, and the Termux:X11 app's cache folders (`cache` and `code_cache` in its data folder, and its cache on the shared storage). It prints how many MB that freed.
6. **The phone's memory cache:** `sync`, then `echo 3 > /proc/sys/vm/drop_caches`, which gives back the RAM the kernel was using to remember files. (Some kernels do not allow it; spft says so and goes on.)

After that the Termux part removes a leftover socket if there still is one and releases the wake lock (the phone may sleep again). Each step prints one row, so you see what happened.

**What it never touches:** your files, the tool itself (everything under `/opt`, where it also writes its logs, as far as we know), Debian's `/root/.config` (the tool's settings, if it has any), Debian's installed packages, **apt's downloads** (`/var/cache/apt/archives`: an install that was interrupted carries on from them), and the Termux:X11 settings (`spft x11 reset` puts those back).

**How the cleaning is kept safe.** While Debian is running, the phone's real `/dev`, `/proc`, `/sys` and **internal storage** are mounted inside its folder, and a recursive delete that went into one of them would delete your phone's own files. So `clear_dir` (1) refuses any path that is not at least three levels deep, so never `/` or `/data`, (2) skips anything that is a mount point, and (3) spft cleans Debian's own folders **only after step 4 left nothing mounted**. If something is stuck (the row says `WARNING: still mounted`), only the Termux:X11 app's cache is cleared, and the row says that Debian's folders were left alone.

A force stop in the middle of an install can leave a package half installed. That is why the setup starts with `dpkg --configure -a` ("making sure no package is left half installed"), so the next `spft install` / `spft update` repairs it by itself.

`spft umount` stops the Debian processes and then unmounts everything, without the rest (no Termux:X11, no caches). If something stays mounted it prints a `WARNING` with the list and exits with status 1.

`spft uninstall` is built on that. The Debian folder holds the phone's `/dev` and its internal storage while they are mounted, and a recursive delete there would wipe both. So it deletes the folder only after `umount` succeeded **and** a second look at `/proc/mounts` shows nothing mounted inside it. It refuses folders that are too shallow or inside the system folders, and from `~/spft-dl` it removes only the files spft itself makes, never the folder as such.

## The zoom

SP Flash Tool's main window is **about 720 pixels tall and cannot be made smaller** (the window manager can make it bigger, not smaller). Termux:X11 shows a virtual screen, and in its `scaled` mode that screen is the phone's real screen divided by the zoom. In landscape its height is the **short side** of the phone divided by the zoom, so:

```
biggest zoom that still fits  =  short side of the screen * 100 / 740      (rounded down to a multiple of 5, between 30 and 300)
```

740 and not 720 leaves a little room for the window frame. With a bigger zoom the bottom of the tool window is cut off, and that is where its buttons and status bar are. (This is what happened on a 1280x800 tablet at the old fixed zoom of 150%: the screen was only 533 pixels tall.)

| Screen | Zoom | The Termux:X11 screen is |
|---|---|---|
| 1280x800 (a tablet) | 105 | 761 px tall |
| 720x1280 | 95 | 757 px tall |
| 1080x1920 or 1080x2400 | 145 | 744 px tall |
| 1200x1920 | 160 | 750 px tall |
| 1440x3200 | 190 | 757 px tall |

spft reads the screen size **as root** with `wm size`. That is the size Android uses now: an *Override size* (the "screen resolution" setting of some ROMs) wins over the *Physical size*. In portrait or `auto` orientation the zoom stays 100, because the tool is wider than a portrait screen. If `wm size` says nothing, spft falls back to 150 and tells you what to try (`spft x11 zoom=110`). `spft x11 zoom=N` overrides all of this, and `spft check` shows what spft would pick (the `screen` row). `bash tests/t_host.sh` (section Z) runs the real `auto_zoom` function over a table of screens.

## The home folder of the file windows

The tool's file windows are Qt's own (not the phone's). Their side bar lists *Computer* (Debian's `/`) and the **home folder** of the user, and spft used to run the tool as root, whose home is `/root`: the side bar showed a folder called *root*, and people got lost there, one click away from where their files are. Now `spft-run` starts **only the tool** with `HOME=/sdcard`, the phone's internal storage, and the side bar says *sdcard*.

- Only the tool sees the changed `HOME`. Its settings and caches would otherwise move to the storage, so `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `XDG_DATA_HOME` are pointed at the old home first (`/root/.config` and so on). The window manager is started before the change.
- `SPFT_STORAGE` chooses: `auto` (the default: `/sdcard`), `off` (leave home as it is, `/root`, where `sdcard` and `Download` are links), or a folder (`SPFT_STORAGE=/sdcard/Firmware spft`). A folder that does not exist is ignored with a message. Remember that [it has to be typed in front of the command](#what-happens-when-you-type-spft) and that spft passes it on.
- What is **not** verified here: the real Qt file window on a phone. The tests check the environment that the tool is started with (`HOME`, the XDG folders), not the window itself.

## The install (`spft install`)

`install.sh` asks for root before it does anything else (`su -c 'id -u'`): the root app's window closes by itself after a few seconds, and nobody watches the screen 15 minutes into an install. Then `spft install` does these steps:

1. Check root, the 64-bit kernel and the free space.
2. `pkg install` the Termux packages, download the Debian **trixie arm64** root filesystem (the official Debian Docker image of `debuerreotype`), and unpack it as root.
3. Write DNS settings, make apt work without its sandbox user (Android does not give it network access), and run `lib/provision.sh` inside Debian: libraries (arm64 and amd64), `openbox`, a VNC server, **box64** (from the `box64-debs` apt repository, or built from source if that fails), and a **self-test** that runs a small x86-64 program through box64. If the self-test fails, the setup is **not** marked as done.
4. Download SP Flash Tool (`spft tool --if-missing`).

Every step can be repeated. Running `install.sh` again does only what is missing.

### The progress display of `lib/provision.sh`

On a slow tablet `apt` can work for minutes without printing a line, and a screen that stays still looks like a hang (it was reported as one). So `provision.sh` never goes quiet:

- It asks apt **once** what a step will install (`apt-get install -s`, one dry run for the whole list; an earlier version made about 90 dry runs, one per package, silently), counts the files and megabytes from `apt-get install --print-uris`, and skips the names this Debian does not have (it says which).
- **That check shows a moving bar.** It is the one part that can take a minute without anything to count, and it used to be silent, so people took it for a hang. `bar()` draws one line over and over (`\r`): a block of 5 `=` that goes to and fro in a frame of 20, plus the time, `[      =====         ] 0m12s`. When the check is done the bar fills up: `[====================] 0m23s - done`. The line stays under 40 characters, because a phone held upright is about 45 wide and a line that wraps cannot be drawn over again. When the output is **not a terminal** (a log file, a pipe) there is nothing to draw over, and a `... still working` line comes every 5 seconds instead. The check itself (`apt_plan`) prints nothing while the bar runs; what it has to say (an apt error, the skipped names) waits in variables and is printed right after.
- It **downloads first** (`apt-get install -d`) and prints a progress line every 5 seconds from what has landed in `/var/cache/apt/archives` (finished files, and the size of the partial file): `downloaded 14.2 of 38.2 MB (37%) - 24 of 77 files`.
- It **installs** with a counter (`[12/77] Unpacking ...`, `[12/77] Setting up ...`); dpkg's long `(Reading database ...` lines are left out.
- When a command is busy without anything to print (reading package lists, unpacking), a `... still working (1m20s)` line comes every 20 seconds.
- **The little loops stop with the script.** They run in the background, and a background job of a script ignores Ctrl+C, so after every sleep each loop checks that the script is still there (`kill -0 $$`) and ends when it is not. Without that, a Ctrl+C left a bar or a counter printing on a screen where you were already typing the next command.
- **Harmless warnings get a note.** While the 64-bit x86 libraries are set up, Debian prints in red or yellow (a) `Exec format error`: the installation scripts of a foreign-architecture library run a small x86_64 program, and box64 is not there yet to run it; and (b) `systemctl: command not found` / `Restarting systemd-binfmt failed`: this Debian has no systemd, and box64's package wants to register itself with it (spft does not need that, it starts `box64 ./flash_tool` itself). Neither matters. Right after those lines (as soon as a normal line follows them) `apt_setup` prints one `Note:` that says so, **once per kind**, so the screen does not fill with notes.
- **A force stop is repaired.** The setup starts with `dpkg --configure -a` ("making sure no package is left half installed"), so an install that `spft stop` or a dead battery interrupted in the middle of a package carries on instead of stopping with a dpkg error.
- If anything fails, it says in which part (`The setup stopped in step: ...`), and that `spft install` carries on with what was downloaded.
- The self-test takes the real `busybox` program: it looks for an executable file of that name that is bigger than 100 KB. (The package also holds a *text* file called `busybox`; an older version tried to run that, and box64 answered with a red `[BOX64] Error: ... is not an executable file`.)

`SPFT_BEAT`, `SPFT_POLL` and `SPFT_FRAME` (below) change the intervals (the `still working` lines, the download counter, one picture of the bar); the tests set them small.

## The kernel-version fix

SP Flash Tool v5 stops at the start on some kernels with "Invalid linux kervel version. Please upgrade linux kernel up to at least 4.19.14!" Kernel 4.19.127 is newer than 4.19.14, so that is a mistake. The tool seems to compare the versions as text, and `4.19.127` sorts before `4.19.14`, so the kernels 4.19.100 to 4.19.139 are turned away. (That explanation fits what the tool prints; the tool is closed source, so it is **unconfirmed**.)

- `lib/kernelfix.sh` has two functions. `kernelfix_class RELEASE` says `fine`, `text` (turned away by mistake), `old` (older than 4.19.14: the tool may refuse it, and spft leaves it alone) or `unknown`. `kernelfix_show RELEASE MODE` says which version to show the tool, following `SPFT_FAKE_KERNEL` (`auto`, `off`, or a version).
- `lib/kernelfix.so.b64` is a shared library of 4744 bytes, written in assembly (`tools/kernelfix.s`) with no libc, no relocations and no symbol versions. It exports one function, `uname`. That makes the real system call, and then writes the first line of `/tmp/spft-fake-kernel` over the *release* field (at most 64 characters; an empty or missing file leaves the real release).
- `spft-run` decodes the library into `/tmp/spft-kernelfix.so`, writes the version into `/tmp/spft-fake-kernel`, and starts the tool with `BOX64_LD_PRELOAD=/tmp/spft-kernelfix.so`. box64 loads that x86-64 library before the others, so `uname()` inside the emulated program is answered by it. Without the need (or with `SPFT_FAKE_KERNEL=off`) nothing is written and nothing is preloaded, and a stale `/tmp/spft-fake-kernel` is removed.
- `spft check` uses the same `kernelfix_class` for its `kernel-ver` row.

`bash tests/t_kernelfix.sh` tests the tables, checks the library's structure, rebuilds it from the source and compares, and loads it into real programs with `LD_PRELOAD`. What it **cannot** test is the real tool under box64 on a phone.

## The check without an install (`check.sh`)

`check.sh` is for people who only want to know whether their phone can be a host. It downloads `https://github.com/<owner>/<name>/archive/refs/heads/<branch>.tar.gz` (a few hundred KB) into a temporary folder in Termux's `tmp`, runs that copy's `spft check` with `SPFT_DL` pointing into the same folder (so the root step's working copy lives there too), and deletes the folder, also when it fails or is interrupted. Nothing is written to `~/spft-dl`, no `spft` command is added. The default repository is the one that `tools/publish.sh` filled in; `SPFT_REPO=owner/name` and `SPFT_BRANCH=name` choose another one.

The whole script is one function that is called on its last line, so `curl ... | bash` works too: bash has read all of it before anything runs, and a program that reads standard input cannot swallow the rest of the script. Run as a file inside a copy of the repository (`bash check.sh`) it uses that copy and downloads nothing; run through curl it always downloads the newest files.

### How `spft check` finds the Termux:X11 app

Since Android 11 an app is only shown the apps it has declared interest in, so `pm list packages` run by the normal Termux user leaves out Termux:X11. An older spft used that list and wrongly said "NOT installed". Now `spft check` and `install.sh` ask root (`spft root-app-installed`), which sees everything: it reads `/data/system/packages.list` (one line per package, starting with its name), and if that file cannot be read it looks for the app's data folder in `/data/data` and `/data/user/0`. `pm` is asked as well, and **any source that says yes wins**. If root can read neither the list nor the folders, and `pm` does not show the app either, the answer is "could not tell", never "NOT installed". The app's origin (F-Droid, GitHub) is not looked at.

## Downloading SP Flash Tool (`spft tool`)

`lib/tools.conf` has one line per address: `NAME  SHA256  URL`.

```
v5.2228  18b11eed...df10  https://cdn.spflashtools.com/wp-content/uploads/SP_Flash_Tool_v5.2228_Linux.zip
v5.2228  18b11eed...df10  https://spflashtools.com/wp-content/uploads/SP_Flash_Tool_v5.2228_Linux.zip
```

- The first name in the file is the default. Lines with the same name are alternatives, tried from top to bottom.
- The download server wants a `Referer` header, so spft sends the file's own address as the referer.
- A zip is used only if its **SHA256** matches (a `-` instead of a checksum means "none known"). Then it must be a complete zip with a `flash_tool` (or `SPFlashToolV6`) inside that really is an **x86-64 ELF program** (bytes 18 and 19 of the file are `3e 00`). Anything else is thrown away.
- The root step unpacks it into `/opt/<name>` inside Debian and points `/opt/spft-current` at it. Older versions stay.
- `spft tool` first looks for a zip in your Download folder, then downloads.

**To add a version:** download the zip, run `sha256sum file.zip`, and add a line to `lib/tools.conf`. The checksums in the file are the ones the Arch Linux packages `spflashtool5-bin` and `spflashtool-bin` recorded for the same file names.

## Settings (environment variables)

You rarely need these. Set them in front of the command, for example `SPFT_MIN_MB=1000 spft install`. The four marked **(passed on)** are for the programs inside Debian, and spft hands them down inside the command line ([why](#what-happens-when-you-type-spft)). The ones that say *Inside Debian* and are not marked are not passed on: they are for the tests, and for whoever runs the Debian side by hand (`spft enter SPFT_POLL=2 /root/spft-provision.sh`).

| Variable | Default | Meaning |
|---|---|---|
| `SPFT_ROOT` | `/data/local/spft-debian` | Where the Debian system lives |
| `SPFT_DL` | `~/spft-dl` | Where downloads and the root step's copy are kept |
| `SPFT_SUITE` | `trixie` | The Debian release |
| `SPFT_URL` | the official arm64 slim rootfs of `SPFT_SUITE` | Where `spft install` gets the Debian tarball |
| `SPFT_TOOL` | the first name in `lib/tools.conf` | The SP Flash Tool version `spft tool` installs |
| `SPFT_TOOL_SHA256` | none | The checksum to demand for `spft tool https://...` |
| `SPFT_MIN_MB` | `1500` | `spft install` refuses to start with less free space than this |
| `SPFT_FAKE_KERNEL` | `auto` | **(passed on)** Which kernel version SP Flash Tool is shown: `auto` (a fix only for the kernels 4.19.100 to 4.19.139), `off`, or a version like `5.4.0` ([details](TROUBLESHOOTING.md#the-invalid-linux-kernel-version-message)) |
| `SPFT_STORAGE` | `auto` | **(passed on)** The home folder of the tool, so where its file windows start: `auto` (`/sdcard`, the internal storage), `off` (Debian's own `/root`), or a folder ([details](#the-home-folder-of-the-file-windows)) |
| `SPFT_BEAT` | `20` | Inside Debian, during the setup: seconds between the `still working` lines |
| `SPFT_POLL` | `5` | Inside Debian, during the setup: seconds between the download progress lines (and between the lines that stand in for the bar when the output is not a terminal) |
| `SPFT_FRAME` | `0.3` | Inside Debian, during the setup: seconds between two pictures of the moving bar |
| `SPFT_LIBDIR` | `/usr/local/lib/spft` | Inside Debian: where `spft-run` finds the kernel-version fix |
| `SPFT_REPO`, `SPFT_BRANCH` | the published repository, `main` | For `check.sh`: which repository and branch to download |
| `SPFT_DISPLAY` | `auto` | Inside Debian: `x11` or `vnc` (`spft x11` and `spft vnc` set it) |
| `SPFT_GEOMETRY` | `1280x720` | **(passed on)** The VNC desktop size |
| `BOX64_LOG` | `1` | **(passed on)** box64's own log level |

## Security

- spft runs SP Flash Tool, a **closed-source** program, as **root inside a chroot**. A chroot is **not a sandbox**: the tool can see the phone's devices and the whole internal storage. That is what flashing needs, but it is a reason to download the tool only from a place you trust and to keep the checksum check.
- The checksum in `lib/tools.conf` protects against a damaged or swapped download. It does not say that MediaTek made the file.
- spft never sends anything anywhere. It downloads the Debian image, the Debian and box64 packages, and SP Flash Tool.
- `spft enter` gives you a root shell in Debian. Be careful with what you delete under `/mnt/sdcard`: that is your real internal storage.

## Tests

`bash tests/run_all.sh` runs everything in a few minutes **on a Linux PC** (the tests refuse to run on a phone). They use stand-ins for `su`, `mount`, `chroot`, `curl`, `pkg`, `termux-x11` and the other phone-only commands, so nothing real is touched.

| Test | What it covers |
|---|---|
| `t_run.sh` | `lib/run.sh`: display choice, one copy of the tool, which version starts, the openbox rule, the kernel-version fix, the home folder of the tool (`SPFT_STORAGE` auto / off / a folder / a missing folder, and that the XDG folders keep the settings in `/root`) |
| `t_host.sh` | the `spft` command: start, settings typed in front of the command (through a `su` that drops the environment), the zoom for a table of screens, stop (the Debian processes, the Termux:X11 server and app, the mounts, the caches, a mount that will not go, the cleaning refusing shallow folders and walking around mount points), enter, check (the Termux:X11 app seen by root but not by `pm`, root refused, no su, the screen row, every kernel version case, the Result block with its blockers and limits), update, umount, uninstall (including: nothing is deleted while something is mounted), Termux:X11 settings, bad options |
| `t_tool.sh` | `spft tool`: downloads, mirrors, checksums, unpacking, damaged zips, wrong CPU type |
| `t_install.sh` | `install.sh` and `spft install`: fresh install, repeating it, the Termux:X11 app (installed, missing, "could not tell"), no root (asked for before anything is installed), 32-bit kernel, no space, no internet, a failed tool download, folders with spaces |
| `t_provision.sh` | `lib/provision.sh` with a stand-in `apt-get`: the progress display (the moving bar on a real terminal, driven through a pty, and the lines that stand in for it elsewhere; counters, percent, `still working` lines), the notes under the harmless warnings, background loops that end with the script, the `dpkg --configure -a` repair, unknown package names, no internet, the self-test choosing the real program and not the text file, a broken box64, building box64 from source, a half-downloaded file |
| `t_check.sh` | `check.sh`: the download, another repository or branch, bad names, a failed or damaged download, running from a copy of the repository, as root, outside Termux, root refused, piped into bash |
| `t_kernelfix.sh` | the kernel-version fix: which kernels are affected, what is shown, the library's structure, that it matches its source, and (on x86-64 Linux) the library loaded into real programs |
| `t_publish.sh` | `tools/publish.sh` against a stand-in GitHub: first publish, run again, another name, refusals, GitHub being ahead (an edit made on github.com is kept, also when the update carries the same line; a change to the same line stops it without pushing), an empty repository, and that the published copy (your name filled in) still passes `t_docs.sh` |
| `t_docs.sh` | the documentation: every link and `#anchor` inside the repository works, every command of `spft help` is in the README, the install line is the same everywhere (with the placeholder, or with your name after publishing) |

`t_run.sh` and `t_host.sh` print what happened, and the output is compared with the saved copy in `tests/expected/`. After a change you made on purpose, run `bash tests/run_all.sh --update` and look at the diff in git.

What the tests **cannot** check: the real download from spflashtools.com, real USB devices, and how box64 behaves on a given phone. Also not checked on a real phone: how the Qt file window reacts to the changed home folder, what the real `wm`, `am force-stop` and `drop_caches` do on your ROM, whether the output of a root step is a terminal (the bar draws itself only then), and the real height of the tool's window (the zoom aims at 740 pixels for a window of about 720).

## Publish your own copy

```
bash tools/publish.sh
```

Creates `github.com/<you>/spft` with the GitHub command line tool (`pkg install gh` in Termux), writes your name into the README, and pushes. It prints the one-line install command for your users.

Run it again after every update. If you edited a file on github.com in between (a thank-you line in the README, say), `publish.sh` first merges GitHub's newer changes into your folder, so your edit is kept and the push is not refused. Only when the very same lines changed on both sides does it stop: it pushes nothing, changes nothing on GitHub, and tells you.
