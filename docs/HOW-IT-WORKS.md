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
lib/tools.conf      SP Flash Tool versions: name, sha256, download address
lib/provision.sh    runs INSIDE Debian, once: libraries, desktop, box64, self-test
lib/run.sh          runs INSIDE Debian, every time: picks the display, starts openbox and the tool
lib/gui.sh          runs INSIDE Debian: the VNC desktop for `spft vnc`
tools/publish.sh    puts this project on your GitHub account
tests/              automatic tests: bash tests/run_all.sh
docs/               these pages
```

## Files that spft creates

| Where | What |
|---|---|
| `$PREFIX/bin/spft` | The launcher: two lines that run `~/spft/spft` with bash (so it does not depend on file permissions or links). |
| `~/spft-dl/` | Downloads and working files: `rootfs.tar.gz` (Debian), `SP_Flash_Tool_<version>_Linux.zip`, `app/` (a copy of `spft` and `lib/` for the root step), `x11.log`, `x11-prefs.orig` (your Termux:X11 settings before spft changed them, for `spft x11 reset`). |
| `/data/local/spft-debian/` | The Debian system. Inside it: `/opt/SP_Flash_Tool_*` (the tool), `/opt/spft-current` (a link to the version that starts), `/usr/local/bin/spft-run` and `spft-gui`, `/root/spft-provision.sh`. |
| `/data/local/spft-debian/.spft-unpacked` | Proves the Debian unpack ran to the end. |
| `/data/local/spft-debian/.spft-provisioned` | Holds the checksum of `lib/provision.sh`. When `spft update` changes that file, the setup runs again once. |

## What happens when you type `spft`

1. **As the normal Termux user.** spft starts the Termux:X11 server (`termux-x11 :0`) if it is not running, opens the Termux:X11 app, and sets *landscape, fullscreen, zoom 150%* with `termux-x11-preference`. That tool can say "ok" for a value the app refused, and one refused key throws away a whole batch, so spft sets **one key per call** and reads every setting back to check. It keeps the phone's CPU awake (`termux-wake-lock`).
2. **As root** (`su -c`). The root step runs a **copy** of `spft` and `lib/` kept in `~/spft-dl/app`, because the repository may sit on shared storage that root cannot always read. It unsets `LD_LIBRARY_PATH` first: Termux's libraries must never reach Android's own tools (they would fail with `CANNOT LINK EXECUTABLE`).
3. **Mounts.** `/dev`, `/dev/pts`, a `tmpfs` for `/dev/shm`, `/proc`, `/sys`, the internal storage (`/data/media/0` to `/mnt/sdcard`, with a `/sdcard` link), and Termux:X11's socket folder.
4. **`chroot`** into Debian and run `spft-run` (a copy of `lib/run.sh`).
5. **`spft-run`** refuses to start a second copy of the tool, picks the display (Termux:X11 or VNC), starts the `openbox` window manager (one rule maximizes the tool's main window, written to `~/.config/openbox/rc.xml` inside Debian from Debian's default), sets the Qt and box64 variables, and runs `box64 ./flash_tool` from the tool's folder.

`spft stop` finds every process whose root folder is the Debian folder and ends it. Then it ends the Termux:X11 server (its process is called `termux-x11`, as the Termux:X11 README says) and removes the socket file that a server killed by Android leaves behind. With that file in the way, spft would think a server is running and the screen would stay black.

`spft umount` stops the Debian processes and then unmounts everything. If something stays mounted it prints a `WARNING` with the list and exits with status 1.

`spft uninstall` is built on that. The Debian folder holds the phone's `/dev` and its internal storage while they are mounted, and a recursive delete there would wipe both. So it deletes the folder only after `umount` succeeded **and** a second look at `/proc/mounts` shows nothing mounted inside it. It refuses folders that are too shallow or inside the system folders, and from `~/spft-dl` it removes only the files spft itself makes, never the folder as such.

## The install (`spft install`)

`install.sh` asks for root before it does anything else (`su -c 'id -u'`): the root app's window closes by itself after a few seconds, and nobody watches the screen 15 minutes into an install. Then `spft install` does these steps:

1. Check root, the 64-bit kernel and the free space.
2. `pkg install` the Termux packages, download the Debian **trixie arm64** root filesystem (the official Debian Docker image of `debuerreotype`), and unpack it as root.
3. Write DNS settings, make apt work without its sandbox user (Android does not give it network access), and run `lib/provision.sh` inside Debian: libraries (arm64 and amd64), `openbox`, a VNC server, **box64** (from the `box64-debs` apt repository, or built from source if that fails), and a **self-test** that runs a small x86-64 program through box64. If the self-test fails, the setup is **not** marked as done.
4. Download SP Flash Tool (`spft tool --if-missing`).

Every step can be repeated. Running `install.sh` again does only what is missing.

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

You rarely need these. Set them in front of the command, for example `SPFT_MIN_MB=1000 spft install`.

| Variable | Default | Meaning |
|---|---|---|
| `SPFT_ROOT` | `/data/local/spft-debian` | Where the Debian system lives |
| `SPFT_DL` | `~/spft-dl` | Where downloads and the root step's copy are kept |
| `SPFT_SUITE` | `trixie` | The Debian release |
| `SPFT_URL` | the official arm64 slim rootfs of `SPFT_SUITE` | Where `spft install` gets the Debian tarball |
| `SPFT_TOOL` | the first name in `lib/tools.conf` | The SP Flash Tool version `spft tool` installs |
| `SPFT_TOOL_SHA256` | none | The checksum to demand for `spft tool https://...` |
| `SPFT_MIN_MB` | `1500` | `spft install` refuses to start with less free space than this |
| `SPFT_DISPLAY` | `auto` | Inside Debian: `x11` or `vnc` |
| `SPFT_GEOMETRY` | `1280x720` | The VNC desktop size |
| `BOX64_LOG` | `1` | box64's own log level |

## Security

- spft runs SP Flash Tool, a **closed-source** program, as **root inside a chroot**. A chroot is **not a sandbox**: the tool can see the phone's devices and the whole internal storage. That is what flashing needs, but it is a reason to download the tool only from a place you trust and to keep the checksum check.
- The checksum in `lib/tools.conf` protects against a damaged or swapped download. It does not say that MediaTek made the file.
- spft never sends anything anywhere. It downloads the Debian image, the Debian and box64 packages, and SP Flash Tool.
- `spft enter` gives you a root shell in Debian. Be careful with what you delete under `/mnt/sdcard`: that is your real internal storage.

## Tests

`bash tests/run_all.sh` runs everything in about a minute **on a Linux PC** (the tests refuse to run on a phone). They use stand-ins for `su`, `mount`, `chroot`, `curl`, `pkg`, `termux-x11` and the other phone-only commands, so nothing real is touched.

| Test | What it covers |
|---|---|
| `t_run.sh` | `lib/run.sh`: display choice, one copy of the tool, which version starts, the openbox rule |
| `t_host.sh` | the `spft` command: start, stop (also the Termux:X11 server and a stale socket), enter, check, update, umount, uninstall (including: nothing is deleted while something is mounted), Termux:X11 settings, bad options |
| `t_tool.sh` | `spft tool`: downloads, mirrors, checksums, unpacking, damaged zips, wrong CPU type |
| `t_install.sh` | `install.sh` and `spft install`: fresh install, repeating it, no root (asked for before anything is installed), 32-bit kernel, no space, no internet, a failed tool download, folders with spaces |
| `t_publish.sh` | `tools/publish.sh` against a stand-in GitHub, and that the published copy (your name filled in) still passes `t_docs.sh` |
| `t_docs.sh` | the documentation: every link and `#anchor` inside the repository works, every command of `spft help` is in the README, the install line is the same everywhere (with the placeholder, or with your name after publishing) |

`t_run.sh` and `t_host.sh` print what happened, and the output is compared with the saved copy in `tests/expected/`. After a change you made on purpose, run `bash tests/run_all.sh --update` and look at the diff in git.

What the tests **cannot** check: the real download from spflashtools.com, real USB devices, and how box64 behaves on a given phone.

## Publish your own copy

```
bash tools/publish.sh
```

Creates `github.com/<you>/spft` with the GitHub command line tool (`pkg install gh` in Termux), writes your name into the README, and pushes. It prints the one-line install command for your users.
