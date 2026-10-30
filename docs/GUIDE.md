# Guide

Back to the [README](../README.md). The README has the short start. This page has everything else, in order.

**Contents**

1. [What you need](#1-what-you-need)
2. [Install the apps](#2-install-the-apps)
3. [Install spft (one time)](#3-install-spft-one-time)
4. [Start SP Flash Tool](#4-start-sp-flash-tool)
5. [Where are my files? (internal storage)](#5-where-are-my-files-internal-storage)
6. [Flash firmware without errors](#6-flash-firmware-without-errors)
7. [If something goes wrong](#7-if-something-goes-wrong)

Also: [Check a phone first (no install)](#check-a-phone-first-no-install) &nbsp;·&nbsp; [If the download fails](#if-the-download-fails) &nbsp;·&nbsp; [Android 12 and newer](#android-12-and-newer) &nbsp;·&nbsp; [All commands](#all-commands) &nbsp;·&nbsp; [Update and uninstall](#update-and-uninstall) &nbsp;·&nbsp; [Good to know](#good-to-know)

## 1. What you need

**The host: the phone or tablet that runs spft**

| Need | Details |
|---|---|
| Root | Magisk, KernelSU, APatch or similar. The root app must allow Termux. With KernelSU or APatch there may be no pop-up: open the app, go to *Superuser* and switch **Termux** on before you install. |
| Android 8.0 or newer | Termux:X11 needs it. |
| A 64-bit **kernel** | The kernel, not Android itself. A phone with 32-bit Android can still have a 64-bit kernel (the Galaxy J7 Max does). `spft check` tells you. Without it the emulator (box64) cannot run. |
| Kernel 4.19.14 or newer | SP Flash Tool v5 asks for it ("Invalid linux kernel version"). A kernel in the range 4.19.100 to 4.19.139 is turned away by mistake, and spft fixes that for you. An older kernel may be turned away too: try first, and if the message comes, see the [details](TROUBLESHOOTING.md#the-invalid-linux-kernel-version-message). |
| USB host (OTG) | The phone must be able to act as a USB host. You need an **OTG adapter** and a **data** USB cable (a charge-only cable does not work). |
| The `cdc_acm` USB driver in the kernel | SP Flash Tool talks to the device through it. `spft check` tells you. |
| About 3 GB free | On the phone's internal storage. |
| Internet | For the install only. |

**The target: the device you want to flash**

- A MediaTek (MTK) chip. SP Flash Tool does not work with Qualcomm, Exynos or Unisoc devices.
- The **exact firmware for your model**, unzipped, with a `..._scatter.txt` file inside. See [section 6](#6-flash-firmware-without-errors).

## 2. Install the apps

Get the apps from the links below. Do **not** use the Google Play version of Termux (it is experimental and cannot be mixed with the others).

| App | What it is for | Download |
|---|---|---|
| **Termux** | The terminal where you type `spft`. Required. | [F-Droid](https://f-droid.org/packages/com.termux/) (press *Download APK*, you do not need the F-Droid app) or [GitHub releases](https://github.com/termux/termux-app/releases) |
| **Termux:X11** | The screen the tool is shown on. Required. | [GitHub nightly release](https://github.com/termux/termux-x11/releases/tag/nightly): download the file `termux-x11-universal-debug.apk` |
| **Termux:API** | Optional. spft works without it. It is only needed if you want other Termux tools that use Android features (notifications, `termux-usb`, ...). | [F-Droid](https://f-droid.org/packages/com.termux.api/) or [GitHub releases](https://github.com/termux/termux-api/releases) |
| **Root app** | You must already have root. | [Magisk](https://github.com/topjohnwu/Magisk/releases), [KernelSU](https://github.com/tiann/KernelSU) |

Rules that avoid problems:

- **Termux and Termux:API must come from the same place**, both from F-Droid or both from GitHub. They are signed with different keys. If you switch, uninstall all of them first.
- GitHub has many Termux files. Pick the one with `apt-android-7` in its name and your CPU type: `arm64-v8a` for most phones, `armeabi-v7a` for a 32-bit phone. The `universal` file works on both.
- Termux:X11 is installed **twice**: this is the app (above) and the package `termux-x11-nightly`. The installer ([section 3](#3-install-spft-one-time)) installs the package for you. You only install the app yourself.
- **It does not matter where your Termux:X11 app comes from.** spft only checks that the app is installed, not which build it is. If you already have it (from F-Droid, say), keep it. Only if the screen stays black or the app and the package do not work together, try the nightly APK from the table.
- Open each app once after installing it.

## 3. Install spft (one time)

1. Open **Termux**.
2. Paste the install line (it is the same line as in the [README](../README.md#step-2-install-spft-one-time)):

   ```
   pkg update -y && pkg install -y git && git clone https://github.com/shivrajtode/spft ~/spft && bash ~/spft/install.sh
   ```

3. Right at the start (you see `root: if your root app asks, press ALLOW for Termux`) your root app shows a window like *"Allow Termux superuser rights?"*. Press **Allow** quickly: such windows close by themselves after a few seconds. If you missed it, you get `root was refused`: run `bash ~/spft/install.sh` again. (KernelSU and APatch may show no window: open the app, go to *Superuser*, switch **Termux** on, and run it again.)
4. Wait. Keep Termux open and the phone charging. Four steps are shown:
   - `1/4` Termux packages (git, curl, wget, unzip, x11-repo, termux-x11-nightly, termux-api)
   - `2/4` checks that the Termux:X11 app is installed
   - `3/4` adds the `spft` command
   - `4/4` Debian, box64 and SP Flash Tool (this is the long one)

   **Step `4/4` is long, and it shows its progress.** It has four parts of its own, marked `[1/4]` to `[4/4]`: *base packages*, *arm64 + x86_64 libraries*, *box64* and a *self-test*. Part `[2/4]` is the longest (it has the most packages). Whatever takes time prints something (the numbers below are only an example, yours will differ):

   ```
   >> [2/4] arm64 + x86_64 libraries
      checking what has to be installed (up to a minute on a slow tablet; the bar moves while it works) ...
      [====================] 0m23s - done
      77 packages to install
      downloading 77 files, 38.2 MB, up to 4 at a time. A progress line follows every 5 seconds.
      downloaded 14.2 of 38.2 MB (37%) - 24 of 77 files - 1.9 MB/s, about 2 min left
      ...
      download finished in 0m41s
      installing 77 packages: unpacking, then setting them up. No more downloading; the phone is busy, it is not stuck.
      [12/77] Unpacking libxcb1:arm64 ...
      ... unpacking and setting up the packages: still working (1m20s)
   ```

   So the screen keeps moving:
   - while apt checks what is missing, a small **bar moves along one line** and counts the time (`[      =====         ] 0m12s`); when the check is done it fills up and says `done`. (If the output is not a terminal, a `... still working` line comes every 5 seconds instead.)
   - a counter for the downloads (MB, percent, files, the speed and the time left),
   - a counter `[12/77]` while packages are unpacked,
   - and a `... still working (1m20s)` line every 20 seconds when there is nothing else to say.

   **A quiet screen is not a hang.** If really nothing new appears for 10 minutes, press Ctrl+C and run `bash ~/spft/install.sh` again: it carries on, and what was already downloaded is kept. If it stops with an error it says in which step (`The setup stopped in step: ...`).

   **Built to be fast, and to survive a bad connection.** The files download **four at a time**. If your connection does not like that, type `SPFT_JOBS=1 bash ~/spft/install.sh` (one at a time), or try `SPFT_JOBS=8` for more. A download that was cut off, by the network or by you, **carries on where it stopped** the next time, also the Debian base system and the SP Flash Tool zip. A file that fails is tried again by itself, a few times, with one calm line each time. spft keeps the Mesa graphics drivers and LLVM out (about 100 MB that SP Flash Tool never uses). How fast it ends up depends on your internet.

   **Red or yellow warnings during the install are normal.** Lines with `Exec format error` (Debian tried to run a small x86_64 helper program before box64 was installed), or `systemctl: command not found` and `Restarting systemd-binfmt failed` (this Debian has no systemd, and spft does not need what box64 would register there) are harmless. spft prints a `Note:` under them that says so.
5. At the end you see `done. Type  spft  and press Enter: the menu opens, and Start SP Flash Tool is its first entry.`
6. Check everything with:

   ```
   spft check
   ```

   It prints the same kind of list as the [check without install](#check-a-phone-first-no-install), now with `debian : installed`, `box64 : installed` and `tool : /opt/SP_Flash_Tool_v5.2228_Linux/flash_tool`. The last block, **Result**, says in plain words whether spft can run on this device and what to keep in mind. A line that says `NOT` or `MISSING` is explained there or in [section 7](#7-if-something-goes-wrong). (The `storage` line is optional: it only matters if you want to use `termux-setup-storage`.)

Running `bash ~/spft/install.sh` again is always safe. It only does what is still missing, so it also **continues an install that stopped**. If the SP Flash Tool download fails, see [If the download fails](#if-the-download-fails).

## 4. Start SP Flash Tool

In Termux type:

```
spft
```

A **menu** opens, the same kind of menu as in FlashKit. **Start SP Flash Tool** is its first entry. Move with the arrow keys (Termux's extra-keys row has them) or type the number or letter of an entry, then press **Enter**. **Exit** closes the menu.

| Entry | What it does |
|---|---|
| **1 Start SP Flash Tool** | Opens the tool on Termux:X11, fitted to your screen (the same as `spft start`) |
| 2 Start with screen settings ... | A list of its own: *fit my screen by itself* (the default), *landscape, but the other way up*, *portrait*, *smaller (zoom 100)*, *bigger (zoom 150)*, *keep the extra keys bar*, *leave the Termux:X11 settings alone*, *put them back as before* |
| 3 Stop and clear the caches | `spft stop` |
| 4 Check this phone and setup | `spft check` |
| 5 Update spft | `spft update`, then the menu opens again with the new files |
| 6 Install/change SP Flash Tool | `spft tool` |
| 7 Repair setup (install again) | `spft install` |
| 8 Open a shell inside Debian | `spft enter`. Type `exit` to come back to the menu. |
| 9 Start on a VNC desktop | `spft vnc` |
| a Open menu at Termux start: off or ON | `spft autostart on` or `off` |
| b About | The version, who made it, where the source is |
| c Uninstall | `spft uninstall`. It asks you to type `yes` first. |

After an entry has run, the menu waits for you to press Enter and then comes back.

- **No menu, just start:** `spft start` starts the tool at once. A shortcut or a script (where there is no terminal to show a menu in) gets the same: there `spft` starts the tool without asking.
- **The menu every time Termux opens:** entry **a**, or `spft autostart on`. **Exit** then leaves you at the normal Termux prompt. `spft autostart off` switches it off again. It adds a few lines, marked `# >>> spft >>>` and `# <<< spft <<<`, to `~/.bashrc` (and `~/.zshrc`, if you have one), and `off` takes out exactly those lines.
- **No `dialog` program?** The menu uses `dialog`, a small Termux package. `install.sh` installs it, and the first time the menu opens without it, spft fetches it. Without internet you get a numbered list instead: type a number and press Enter. `SPFT_MENU=text spft` gives you that list on purpose.

When the tool starts, the Termux:X11 app opens, turns to landscape, goes fullscreen and zooms in as far as the whole tool window still fits on your screen (spft reads the screen size: about 105% on a 1280x800 tablet, 145% on a phone that is 1080 pixels wide), and the SP Flash Tool window appears. spft keeps the phone awake while the tool runs.

- Press the Android **Back** button to show or hide the on-screen keyboard (you need it to type a folder name).
- Tap = click, double tap = double click, two-finger tap = right click.
- The tool's messages appear in the Termux window. Leave that Termux session open. For other commands open a second session (swipe in from the left edge of Termux and tap *New session*).
- To leave the screen use Home or Recents as always. The tool keeps running.

Screen options (usually not needed; entry 2 of the menu has them too):

| Command | Effect |
|---|---|
| `spft start` | Start at once, with the screen settings that fit (no menu) |
| `spft x11 reverse` | Landscape the other way up (when the picture is upside down) |
| `spft x11 zoom=N` | Size in percent (30 to 300), for example `zoom=120`. Without it spft uses `zoom=auto`: the biggest zoom at which the whole tool window still fits. A bigger one cuts off the bottom of the window (the buttons and the status bar). |
| `spft x11 portrait` | Do not force landscape |
| `spft x11 plain` | Do not change the Termux:X11 settings at all |
| `spft x11 reset` | Put the Termux:X11 settings back as they were before spft |
| `spft vnc` | Use a VNC desktop instead of Termux:X11 (slower). Viewer app: `localhost:5901`, password `spft1234` |
| `spft stop` | **Force-stop everything of spft:** the tool and every other program in Debian, the Termux:X11 server and the Termux:X11 app. Then it unmounts Debian and **clears the caches** (Debian's `/tmp` and `~/.cache`, the Termux:X11 app's cache, the phone's memory cache) and says how much it freed. Your files, the tool itself and the downloads are not touched. **Never while it is flashing.** |

## 5. Where are my files? (internal storage)

SP Flash Tool runs inside a small Debian system, so it sees your phone's storage under a different name. **Your internal storage is `/sdcard` inside the tool.**

| Place | The "Download" folder of your internal storage |
|---|---|
| Phone's file manager | Internal storage / Download |
| **Inside SP Flash Tool** | **`/sdcard/Download`** |
| Termux (after `termux-setup-storage`) | `~/storage/downloads` |

The same rule works for every folder: `Internal storage/Firmware/MT6765` in the file manager is `/sdcard/Firmware/MT6765` in the tool.

**Choose a file in SP Flash Tool, step by step**

1. Click **Choose** (for example next to *Scatter-loading File*). A file window opens.
2. Click the **File name** box at the bottom. Press **Back** if the keyboard does not show.
3. Type the folder and press **Enter**, for example:

   ```
   /sdcard/Download/fw
   ```

4. The folder opens. Click your file, then **Open**.

> [!NOTE]
> **The file window starts in your internal storage.** In the list on the left it shows **sdcard**, which is your internal storage (and *Computer*, which is Debian's own root, that you do not need). Click **sdcard** to get back to the top of your storage at any time. (Older versions of spft showed a folder called *root* there, which confused people. If you prefer that, `SPFT_STORAGE=off spft` brings it back.)

**Tips that avoid "file not found"**

- Names are **case sensitive**: `/sdcard/Download` works, `/sdcard/download` does not.
- Only the **internal storage** is visible. A **memory card (SD card) is not**. Copy the firmware from the card to the internal storage with your file manager first.
- The tool cannot read a `.zip`. **Extract the firmware first**, with your file manager or in Termux:

  ```
  termux-setup-storage
  cd ~/storage/downloads
  unzip firmware.zip -d fw
  ```

- Use a short folder name **without spaces or special characters**, for example `fw`.
- Keep the scatter file **in the same folder as the `.img` / `.bin` files**. Do not move it alone: the tool finds the images next to it.
- To see what the tool sees, run this in Termux:

  ```
  spft enter ls -l /sdcard/Download
  ```

## 6. Flash firmware without errors

> [!CAUTION]
> Flashing the wrong firmware, or interrupting a flash, can **permanently damage a device**. Read the whole section once before you start.

Most flashing errors have one of five causes: wrong firmware, a bad cable or adapter, connecting at the wrong moment, a damaged download, or a dying battery. These steps avoid all five.

### Before you start

- [ ] **Right firmware.** The exact model (and region or variant) of the target, extracted, with a `..._scatter.txt` inside. The chip name in the scatter file (for example `MT6765`) must match the target. Never use a "similar" firmware.
- [ ] **Healthy firmware files.** Download them again if an extraction reported an error.
- [ ] **Know what gets erased.** A full firmware package also contains `userdata`, and writing it **replaces everything the owner stored on the target** (apps, photos, accounts). [Step 6](#flash) shows how to leave it out. After a factory reset, Android may ask for the **Google account that was on the target** (Factory Reset Protection): the owner has to know that password.
- [ ] **A back-up**, if the target still starts. The IMEI and the radio calibration (usually the partitions `nvram`, `nvdata`, `nvcfg`, `protect1` and `protect2`; some models also `persist` and `proinfo`) are **not** in a stock firmware and cannot be rebuilt from it. Save them with SP Flash Tool's **Readback** tab, or with [mtkclient](https://github.com/bkerler/mtkclient/blob/main/README-USAGE.md) (`r` reads partitions, `rl` dumps all of them). Put the files in `/sdcard/Backup` (your internal storage, which `spft uninstall` never touches) and copy them somewhere else too.
- [ ] **A good OTG adapter and a data cable**, connected directly (no USB hub).
- [ ] **Batteries.** The host phone at least 50%, and plug its charger in if your adapter allows it. The target: keep its battery inside (if it is removable) and as charged as you can. The flash must never be interrupted.
- [ ] **Android 12 or newer host?** Do [this](#android-12-and-newer) once first.
- [ ] `spft check` shows no problem.

### Flash

1. In Termux type `spft`. SP Flash Tool opens.
2. Open the **Download** tab.
3. Click **Choose** next to *Scatter-loading File* and select the `..._scatter.txt` ([how](#5-where-are-my-files-internal-storage)). The list of partitions fills in.
4. Leave *Download-Agent* as it is (`MTK_AllInOne_DA.bin`), unless your firmware comes with a special one for your model.
5. In the drop-down list choose **Download Only**. Hovatek calls it "the safest flash option":

   | Mode | What it does |
   |---|---|
   | **Download Only** | Writes only the ticked partitions. **Use this.** |
   | Firmware Upgrade | Only for the case that the firmware's partition layout is different from the device's (the tool then reports `PMT changed`, error 8038, and Download Only does not work). **All rows must be ticked.** It changes the partition layout, so expect to lose all data on the target. |
   | Format All + Download | Formats the whole flash first. **You lose the IMEI.** Avoid it, especially on secure-boot devices. |

6. Check the partition list:
   - Tick only what you want to write. A row with an **empty location** must stay **unticked**.
   - **`userdata` and `cache`:** writing `userdata` **replaces the target's data**. Untick both to keep the data. If the device then does not start, you need the factory reset of step 11.
   - **Preloader:** leave it **unticked** if the target shows any sign of life (screen, vibration, charging light, a reaction to the power button). Tick it only if the target is **completely dead** and flashing without it did not help. A wrong preloader can make a device impossible to connect.
   - Leave `nvram`, `nvdata`, `nvcfg`, `protect1` and `protect2` **unticked**. Your IMEI is not in the firmware.
7. Click **Download** (the arrow button). The tool now **waits** for the device. Nothing happens yet.
8. **Now connect the target**, switched **off**: target - USB cable - OTG adapter - host phone. Do not hold any button at first.
   - If the tool does not react within about 10 seconds: unplug, then plug in again **while holding Volume Down** (on some models Volume Up, or both). Which key works depends on the model.
9. A progress bar runs. **Do not touch anything** and do not unplug.
10. Wait for the **green circle with "Download OK"**. This is the only sign that it worked.
11. Unplug the target and switch it on. The first start can take 5 to 10 minutes.
    - If it stays on the logo, boot it to recovery (switched off, usually hold Volume Up + Power; the keys differ per model, so search for yours) and do a factory reset. **This erases all data**, and afterwards Android may ask for the Google account that was on the device.
12. Close the tool: `spft stop`.

### The seven golden rules

1. Always press **Download first**, connect the device **second**.
2. The target is **switched off** when you connect it.
3. **Download Only**, nothing else, unless you know why.
4. **Never** tick a row without a file. Leave `nvram` / `nvdata` / `nvcfg` / `protect1` / `protect2` alone. Flash `preloader` only if the target is completely dead (step 6).
5. Do not touch the cable or the screen of the host during the flash.
6. If it fails, **do not retry in a loop**. Read the error in [section 7](#7-if-something-goes-wrong) first.
7. A green "OK" means you are done. An error means the flash did not finish: fix the cause, then flash again.

## 7. If something goes wrong

**First run `spft check`.** It points to the problem and says what to do. Copy its output into an issue if you ask for help.

Common problems with spft itself:

| You see | What to do |
|---|---|
| `no su found` or `root was refused` | Root is needed. In your root app (Magisk, KernelSU, ...) allow Termux, then run the command again. |
| `not a 64-bit ARM kernel` | This phone cannot be the host (box64 needs a 64-bit kernel). Use another phone. |
| `cdc_acm : MISSING` | This phone's kernel was built without the USB serial driver, so SP Flash Tool cannot see the target. Use another host phone (or [mtkclient](https://github.com/bkerler/mtkclient), which does not need that driver). |
| `cdc_acm : NOT LOADED` | The driver is a kernel module that is not loaded. Try `su -c 'modprobe cdc_acm'`, then `spft check` again. If that does not work, use another host phone. |
| `only N MB are free` / `No space left on device` | Free some space (about 3 GB needed) and run `bash ~/spft/install.sh` again. |
| `pkg could not install ...` | Run `termux-change-repo`, pick another mirror, and run the install again. |
| `the Termux:X11 server did not start` | Install the **Termux:X11 app** (not only the package, [section 2](#2-install-the-apps)) and open it once. |
| `x11-app : NOT installed`, but the app is installed | An older spft could not see other apps on Android 11 and newer (Android hides them from Termux) and said so by mistake. Run `spft update`: spft now asks root, which sees every app. It does not matter whether the app is from F-Droid or from GitHub. |
| The install seems stuck at `arm64 + x86_64 libraries` | It is the longest part and it is working: look for the moving bar (`checking what has to be installed`), the counters and the `still working` lines ([section 3](#3-install-spft-one-time)). If nothing new appears for 10 minutes, press Ctrl+C and run `bash ~/spft/install.sh` again. |
| **Red or yellow** lines during the install: `Exec format error`, `systemctl: command not found`, `Restarting systemd-binfmt failed` | Harmless, and spft says so with a `Note:` under them. Debian tried to run a small x86_64 program before box64 was there, and it has no systemd. Neither is needed. Keep waiting. |
| Thousands of lines `W: Tried to start delayed item ... but failed` during the install | A bug in apt 3.0.3 (the apt of Debian 13), which spft before version 6 ran into whenever one download failed once. Run `spft update`, then `spft install`: spft 6 turns apt's own retrying off and retries by itself, with one calm line each time. (`spft version` shows your version.) |
| The install takes hours | Slow internet, and before version 6 also about 100 MB of graphics drivers (Mesa, LLVM) that SP Flash Tool never uses, downloaded one file at a time. Run `spft update`, then `spft install`: version 6 keeps them out, downloads four files at a time, and carries on where a download stopped. |
| The bottom of the tool window is cut off (no buttons, no status bar), or its lower rows cannot be reached | The screen is too small for the zoom. Run `spft update` (the zoom now fits itself to your screen), or try a smaller one, for example `spft x11 zoom=100`. `spft check` shows what spft chose (`screen` row). |
| The tool says `Invalid linux kervel version. Please upgrade linux kernel up to at least 4.19.14!` | The tool misspells *kernel*. On kernels 4.19.100 to 4.19.139 it says this by mistake, and spft handles it itself when it starts the tool (run `spft update` for the newest version). On a kernel older than 4.19.14 it may say this too: see [the details](TROUBLESHOOTING.md#the-invalid-linux-kernel-version-message). |
| A **red** `[BOX64] Error: ... is not an executable file` during the install | A bug in older versions of spft: its self-test picked a text file instead of the test program. Run `spft update` and `spft install`. |
| Lines like `Cannot dlopen` or `Error loading needed lib` when the tool starts | Normal: box64 mentions libraries it could not load and goes on. Only a red `[BOX64]` in front of `Error:` is a real problem. |
| Black screen in Termux:X11 | Run `spft stop` (it force-stops the tool, the Termux:X11 server and the Termux:X11 app, removes a socket file that an old server left behind, and clears the caches), then run `spft` again. |
| `SP Flash Tool is already running` | The tool is open in the background. Switch to Termux:X11, or run `spft stop`. |
| The file window shows a folder called *root* and not your storage | You have an older spft. Run `spft update`: the file windows now start in your internal storage (**sdcard**). |
| `box64 self-test FAILED` | Run `spft install` again. If it fails again, this phone cannot run the emulator. |
| The tool closes or Termux disappears by itself | See [Android 12 and newer](#android-12-and-newer). |
| The device is never detected | Try another OTG adapter and cable. Press **Download** first, then connect. While the target is connected, `spft enter 'ls /dev/ttyACM*'` should list a device (in preloader mode it is there for only a few seconds). |

SP Flash Tool error codes (`1013`, `2005`, `5054`, `4008`, `STATUS_BROM_CMD_SEND_DA_FAIL`, ...) with their meaning and fixes are in **[Fix a problem (TROUBLESHOOTING.md)](TROUBLESHOOTING.md)**.

> Devices with **secure boot** (they ask for an *Auth* file, or report errors like `S_AUTH` / `STATUS_BROM_CMD_SEND_DA_FAIL`) usually cannot be flashed with SP Flash Tool alone. [mtkclient](https://github.com/bkerler/mtkclient) can work around this on many of them.

## Check a phone first (no install)

Is this phone or tablet able to be the host? Find out **without installing anything**. This command downloads the few files it needs (a few hundred KB) into a temporary folder, runs the check, and deletes them again. You only need Termux and a root app that allows it. In Termux paste:

```
bash <(curl -fsSL https://raw.githubusercontent.com/shivrajtode/spft/main/check.sh)
```

(If it says `curl: command not found`, run `pkg install curl` first.) Your root app may ask: press **Allow** for Termux.

The check ends with a short **Result**: what stops spft on this device (a 32-bit kernel, too little space, ...) and what to keep in mind (for example: no `cdc_acm` driver, so the tool starts but cannot see a device). Example, from a tablet with Android 11:

```
== Termux ==
(your root app may ask now: press ALLOW for Termux)
root      : su found, and root works
x11-pkg   : installed
x11-app   : Termux:X11 app installed
storage   : run termux-setup-storage once if you want Termux to see your Download folder (optional)
== phone and Debian ==
kernel    : 64-bit ARM (CONFIG_ARM64=y) - OK, a 32-bit Android userspace doesn't matter
kernel-ver: 4.19.127-g8d3429bdb336 - SP Flash Tool v5 may refuse this kernel by mistake (it seems to compare versions as text). spft works around that by itself when it starts the tool
cdc_acm   : MISSING - this kernel was built without it (CONFIG_USB_ACM), so SP Flash Tool can't see a device from this phone (use mtkclient instead)
chroot    : /system/bin/chroot
android   : 11 (API 30), ABIs: arm64-v8a,armeabi-v7a,armeabi
free      : 27360 MB on /data (the install needs about 3000)
screen    : 1280x800 pixels - spft x11 picks zoom 105%, a Termux:X11 screen 761 pixels tall (the tool's window needs about 720)
debian    : not installed yet (spft install does that)
box64     : not installed yet (spft install does that)
tool      : not installed yet (spft install gets it, or: spft tool)

== Result ==
spft can be installed and started on this device.
Keep in mind:
 - this kernel has no cdc_acm driver (CONFIG_USB_ACM), so SP Flash Tool can't talk to a device from this phone. spft still installs and starts here, which is enough to try it out; to flash, use a phone whose kernel has the driver (or mtkclient)
```

That tablet can try out spft, but it cannot flash: it has no USB serial driver. A phone whose Result has no `Keep in mind` lines about `cdc_acm` is a good host. If the check says `spft can NOT run on this device`, the lines under it say why.

The same check is `spft check`, once spft is installed. If you got the files with `git clone`, `bash check.sh` in that folder does it too, without downloading anything. To check another copy of the project (a fork, a test branch): `SPFT_REPO=owner/name SPFT_BRANCH=main bash <(curl -fsSL https://raw.githubusercontent.com/owner/name/main/check.sh)`.

## If the download fails

`spft` downloads SP Flash Tool from [spflashtools.com](https://spflashtools.com/category/linux) (an unofficial site that hosts MediaTek's tool; as far as we know MediaTek has no public download page for it). It checks the file against a known checksum. If the site is down, has moved the file, or has re-packed it (`checksum mismatch`), do this by hand. It takes a minute:

1. In your phone's browser open **<https://spflashtools.com/category/linux>**.
2. Open **SP Flash Tool v5.2228 for Linux** ([direct page](https://spflashtools.com/linux/sp-flash-tool-v5-2228-for-linux/)) and press its **Download** link. You get `SP_Flash_Tool_v5.2228_Linux.zip` (about 75 MB). Take the **Linux** file, not the Windows one.
3. Leave it in your **Download** folder.
4. In Termux run:

   ```
   spft tool
   ```

   spft finds the zip, checks it, and installs it. It prints the file's checksum, and says whether it knows it.

Other ways to install a tool:

| Command | Effect |
|---|---|
| `spft tool` | The zip in your Download folder, or download the default version |
| `spft tool list` | Show the versions spft can download |
| `spft tool v5.2208` | Install another known version |
| `spft tool /sdcard/Download/file.zip` | Install a zip from any folder |
| `spft tool https://example.com/file.zip` | Download a zip from an address |

v5 is the tested one. v6 (`v6.2228`) is a newer generation of the tool and **experimental**: it is not tested with the emulator.

## Android 12 and newer

From Android 12 on, the system can kill background processes of Termux (you see `[Process completed (signal 9)]`, or the tool simply closes). A flash must never be killed, so switch this off **once**, before you flash. You need root (you have it).

Check your Android version in *Settings > About phone*, then run **one** of these in Termux:

| Android | Command |
|---|---|
| 12 | `su -c "/system/bin/device_config set_sync_disabled_for_tests persistent; /system/bin/device_config put activity_manager max_phantom_processes 2147483647"` |
| 12L, 13 and newer | `su -c "settings put global settings_enable_monitor_phantom_procs false"` |

On **Android 14 and newer** you can instead switch on *Settings > System > Developer options > **Disable child process restrictions***. This setting is lost when you turn Developer options off.

If the problem comes back after a restart, run the command again.

Good to know:

- On Android 12 the first half of the command (`set_sync_disabled_for_tests persistent`) stops Google Play services from putting the old value back a few minutes after the boot. It also stops *all* device settings from syncing from Google, so **undo it before a system update**: `su -c "/system/bin/device_config set_sync_disabled_for_tests none; /system/bin/device_config delete activity_manager max_phantom_processes"`.
- To undo the Android 12L and newer command: `su -c "settings delete global settings_enable_monitor_phantom_procs"`.

Also set *Settings > Apps > Termux > Battery* (and the same for Termux:X11) to **Unrestricted**. Source: [agnostic-apollo's Android docs](https://github.com/agnostic-apollo/Android-Docs/blob/master/en/docs/apps/processes/phantom-cached-and-empty-processes.md).

## All commands

| Command | What it does |
|---|---|
| `spft` | Open the menu. **Start SP Flash Tool** is its first entry. (Without a terminal, for example from a shortcut, it starts the tool at once.) |
| `spft start` | Start SP Flash Tool at once, without the menu (the same as `spft x11`) |
| `spft x11 [options]` | Start it on Termux:X11. Options: `reverse`, `portrait`, `zoom=N` (default: `auto`, fits your screen), `keys`, `plain`, `reset` |
| `spft vnc` | Start it on a VNC desktop instead |
| `spft stop` | Force-stop everything of spft (the tool, all programs in Debian, the Termux:X11 server and app), unmount, and clear the caches. Never while it flashes. |
| `spft tool [FILE\|URL\|NAME]` | Install or change SP Flash Tool. `spft tool list` shows the versions. |
| `spft check` | Test the phone and the setup, with a hint for every problem |
| `spft update` | Get the newest spft (`git pull`) and apply it |
| `spft install` | Set up Debian + box64 + SP Flash Tool (`install.sh` does this for you) |
| `spft autostart on\|off` | Open the menu every time Termux starts (off unless you switch it on). `spft autostart` shows which. |
| `spft version` | Show the version |
| `spft enter [command]` | A root shell inside Debian, or run one command there |
| `spft umount` | Stop everything and unmount. It says `WARNING` and exits with status 1 if something stays mounted. |
| `spft uninstall` | Delete the Debian system and the downloads. Asks first, and refuses while anything is still mounted. |
| `spft help` | Show this list |

Without installing spft you can still run the check: [Check a phone first](#check-a-phone-first-no-install).

## Update and uninstall

**Update:** `spft update` gets the newest version of spft and applies it.

**Uninstall:** in Termux type

```
spft uninstall
```

It asks you to type `yes`. Then it stops the tool, unmounts everything, **checks that nothing is still mounted**, and only then deletes the Debian system (`/data/local/spft-debian`) and the downloads in `~/spft-dl`. If you had switched the menu on for every start of Termux, that is switched off too. Your own files in the internal storage are never touched. To remove spft itself as well:

```
rm -rf ~/spft "$PREFIX/bin/spft"
```

If it says `NOT deleting`, something is still mounted inside the Debian folder. While that is so, the folder also holds your phone's `/dev` and your internal storage, and a recursive delete could wipe them. Restart the phone and run `spft uninstall` again.

> [!CAUTION]
> **Never delete `/data/local/spft-debian` by hand with `rm -rf`**, unless `spft umount` has just said `all unmounted`.

## Good to know

- **Tested** on a Samsung Galaxy J7 Max (Android 8, 32-bit Android on a 64-bit kernel) with SP Flash Tool v5.2228. The install, the commands and the download logic are also covered by automatic tests that use stand-in programs (`bash tests/run_all.sh`). Other devices should work if they meet the [requirements](#1-what-you-need). Please report what you find.
- SP Flash Tool belongs to MediaTek. It is **not part of this repository** and is downloaded when you install.
- Flashing the wrong firmware or interrupting a flash can **permanently damage a device**. You use this at your own risk.
- More details (folders, settings, how it works): [How it works](HOW-IT-WORKS.md).
- Problems and ideas: open an issue at <https://github.com/shivrajtode/spft/issues> and paste the output of `spft check`.
