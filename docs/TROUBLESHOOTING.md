# Troubleshooting

Back to the [README](../README.md).

**Always start with `spft check`.** It tests the host phone and the setup and says what to do for every problem.

1. [SP Flash Tool error codes](#sp-flash-tool-error-codes)
2. [The device is not detected](#the-device-is-not-detected)
3. [The "Invalid linux kernel version" message](#the-invalid-linux-kernel-version-message)
4. [Problems with spft itself](#problems-with-spft-itself)
5. [Start again from zero](#start-again-from-zero)

Not sure that a phone can be the host at all? [Check it without installing spft](../README.md#check-a-phone-first-no-install).

## SP Flash Tool error codes

The meanings and the first fixes come from the [Hovatek list of SP Flash Tool error codes](https://www.hovatek.com/forum/post-93019.html). That list is written for Windows. Here the Windows-only advice (VCOM drivers, compatibility mode, "run as administrator") is left out because it does not apply, and "port / cord / PC" became "OTG adapter / cable / host phone".

**Rules for every error**

- A flash that stopped with an error is **not finished**. Fix the cause, then flash again.
- Change **one thing at a time**, in this order: cable and OTG adapter, then the way you connect (the target **off**, press **Download first**), then the tool version, then the firmware.
- *Format* is the last resort. It can erase the IMEI and the radio calibration (`nvram`, `nvdata`), and on secured devices it makes the tool ask for an Auth file.

| Code | Name | What it usually means | What to try |
|---|---|---|---|
| `1013` | `S_COM_PORT_OPEN_FAIL` | The tool could not open the USB port to the device. | Another OTG adapter and cable. Press **Download** first and connect the target afterwards, switched off and with its battery inside. Run `spft check` and look at `cdc_acm`. Try another tool version (`spft tool list`). |
| `2005` | `S_BROM_CMD_STARTCMD_FAIL` | The device started up before the tool could talk to it. | Connect it completely switched off, and do not press the power button. If its battery is removable, take it out and put it back. Another cable or adapter. Try again. |
| `5054` | `S_DL_GET_DRAM_SETTINGS_FAIL` | The files do not match the device. | Use the firmware for your **exact model**. Tick only the rows whose files are in the firmware. |
| `0x13BE` | `S_DL_GET_DRAM_SETTING_FAIL` | Same as 5054. | Same as 5054. |
| `4032` / `0xFC0` | `S_FT_ENABLE_DRAM_FAIL` | Firmware or flash settings do not fit the device. | Firmware for the exact model, only rows with files ticked. Run `spft tool` again to unpack a fresh copy of the tool. Connect with the target off. Try holding **Volume Down** while you connect. Try the newest tool. |
| `4008` | `S_FT_DOWNLOAD_FAIL` | The flash failed, or the connection broke in the middle. | Keep the target off when connecting, with its battery inside. Another cable and adapter. A newer tool. |
| `2004` | `S_FT_DOWNLOAD_FAIL` | Same family as 4008. | Switch the target off, and if its battery is removable take it out and put it back, then reconnect. Another cable and adapter. |
| `6012` | `S_SECURITY_SF_CODE_COMMAND_FORBIDDEN` | The Download Agent does not fit the device. | Set *Download-Agent* to `MTK_AllInOne_DA.bin`. |
| `6124` | `S_SECURITY_INVALID_PROJECT` | Wrong firmware or flash settings. | The right Download Agent and firmware for your model. In the menu *Options > Option...* set *USB Speed* to *Full Speed* and untick *DA DL All With Checksum*. |
| `6047` | `S_SECURITY_SECURE_USB_DL_IMAGE_HASH_FAIL` | The image check failed. | The right Download Agent. Untick *DA DL All With Checksum*. Make sure the firmware files are not damaged or changed. |
| `0x411` | `S_CHKSUM_ERROR` | A checksum error while flashing. | Delete files with "checksum" in their name from the firmware folder. Untick *DA DL All With Checksum* (*Options > Option... > Download*). |
| `8038` | "PMT changed for the ROM" | The partition layout in the firmware is different from the one on the device. | Use the firmware for the exact model. If *Download Only* does not work, try *Firmware Upgrade* with all rows ticked. It changes the partition layout, so expect to lose all data on the device. |
| `0x7D4` | `S_BROM_DOWNLOAD_DA_FAIL` | The tool could not write to the device. | Change the *Download-Agent* setting. Another cable and adapter. The newest tool. A charged battery in the target. |
| `3149` | `S_DA_SDMMC_WRITE_FAILED` | Writing to the device's storage failed. | Do not tick rows with an empty file path. Another cable. Another firmware. If it keeps failing, the storage chip itself may be damaged. |
| `3140` | `S_DA_UPDATE_BOOLOADER_EXIST_MAGIC_NOT_MATCHED` | The bootloader in the firmware does not fit. | The newest tool and the exact firmware. |
| `4001` / `0xFA1` | `S_FT_DA_NO_RESPONSE` | The Download Agent got no answer. | Another cable and adapter. The target **off**, a charged battery inside, and **do not hold any button** when you connect. |

### `STATUS_BROM_CMD_SEND_DA_FAIL` (`0xC0060003`)

The tool could not send its *Download Agent* (DA) to the device. The Hovatek threads about this error do not name one cause and do not confirm one fix. Typical reasons, and what to try, in this order:

1. **A bad connection.** Another cable and OTG adapter. Press **Download** first, then connect the target switched off. Try with and without **Volume Down** held while connecting.
2. **A DA that does not fit the chip.** Use the default `MTK_AllInOne_DA.bin`. If your firmware package or the manufacturer's flash tool contains a DA for your chip, try that one.
3. **The tool version.** `spft tool list` shows the versions. Try another one, for example `spft tool v5.2208`.
4. **Secure boot (DAA / SLA).** Many newer MediaTek devices refuse a DA that is not signed. SP Flash Tool then needs an authentication file that only the manufacturer has. A workaround is [mtkclient](https://github.com/bkerler/mtkclient), which can bypass this protection on many chips.

If the tool asks for an **Auth file**, or shows `S_AUTH` or `S_SECURITY` errors, you have case 4.

## The device is not detected

The tool says nothing at all when you connect the target, or reports `1013`.

1. **Order:** press **Download** in the tool first, then connect the target, switched **off**.
2. **Cable and adapter:** use a cable that carries data (not a charge-only one) and an OTG adapter that works. Connect directly, without a USB hub. A phone charger cable with an adapter that does not fit tightly is the most common cause.
3. **Key:** if nothing happens within about 10 seconds, unplug and connect again **while holding Volume Down** (on some models Volume Up, or both).
4. **Host phone:** `spft check` must show `kernel ... 64-bit` and `cdc_acm ... present`. If `cdc_acm` says `NOT LOADED`, the driver is a kernel module: try `su -c 'modprobe cdc_acm'` and run `spft check` again. If it says `MISSING`, this host phone's kernel has no such driver and cannot see the target: use another host phone (or mtkclient).
5. **See what the host sees.** Connect the target, then run in Termux:

   ```
   spft enter 'ls -l /dev/ttyACM*'
   ```

   In *preloader* mode (USB id `0e8d:2000`) the device is only there for a few seconds after power-on. In *BROM* mode (`0e8d:0003`) it stays longer. If nothing ever appears, the host does not see the target at all: look at the cable, the adapter, the key, or whether the target is really dead (a device with a flat battery needs some minutes of charging first).
6. **Another host:** a different phone as the host settles whether the problem is the host or the target.

## The "Invalid linux kernel version" message

When SP Flash Tool v5 starts, it can open a window that says

> Invalid linux kervel version. Please upgrade linux kernel up to at least 4.19.14!

(the tool misspells *kernel*). In its messages it also prints `cur_kernel_version = 4.19.127`, so it did read your kernel correctly.

**What spft does.** Kernel 4.19.127 is *newer* than 4.19.14, so the message is wrong for it. The tool seems to compare the two versions **as text**, and as text `4.19.127` sorts before `4.19.14` (the character after `4.19.1` is `2`, and `2` is smaller than `4`). That would reject exactly the kernels **4.19.100 to 4.19.139**, which many phones and tablets run. This is an explanation that fits what the tool prints, **not something confirmed**: the tool is closed source.

For those kernels, and only for those, spft starts the tool with a tiny library (`lib/kernelfix.so.b64`, built from `tools/kernelfix.s`) that makes the system call `uname()` report kernel `4.19.140` to the tool. Nothing else changes: the other fields, and every other program, still see the real kernel. You see one line when the tool starts:

```
kernel 4.19.127: SP Flash Tool v5 refuses kernels like this one by mistake (it seems to compare versions as text), so it is shown 4.19.140.
```

`spft check` shows the same in its `kernel-ver` row.

**Your choice: `SPFT_FAKE_KERNEL`.** Put it in front of the command:

| Command | Effect |
|---|---|
| `spft` | The default (`auto`): the fix is used only for kernels 4.19.100 to 4.19.139 |
| `SPFT_FAKE_KERNEL=off spft` | Never change what the tool sees. Use it to find out whether the tool needs the fix on your kernel |
| `SPFT_FAKE_KERNEL=5.4.0 spft` | Always show this version (letters, digits and `. _ + -`, at most 64 characters) |

(Older versions of spft did not pass this setting on to the tool, so typing it did nothing. If you tried it before, run `spft update` and try again.)

**A kernel older than 4.19.14** (a line in `spft check` says so) may be refused by the tool, but it does not have to be: how the tool looks at the version is not known, so try `spft` first. `auto` leaves such a kernel alone. If the message comes, `SPFT_FAKE_KERNEL=5.4.0 spft` shows the tool another version. That is **at your own risk**: the tool asks for a newer kernel for a reason that is not known, and a flash that fails halfway can damage the target. [mtkclient](https://github.com/bkerler/mtkclient) has no such condition.

**If the message still comes** although spft said it shows 4.19.140: run `SPFT_FAKE_KERNEL=off spft` once and `SPFT_FAKE_KERNEL=5.4.0 spft` once, and tell what each did (together with the output of `spft check`). The fix has only been tested with stand-in programs on a PC and with a real program that loads the library; it has **not** been tried with the real tool under box64 on a phone.

**Why the library does not need Debian's libc.** It is a few dozen machine instructions that make the system call themselves, so it loads into any x86-64 program. box64 loads it first (`BOX64_LD_PRELOAD`), and `uname()` is then answered by it. You can rebuild it from the source with `bash tools/build-kernelfix.sh`.

## Problems with spft itself

| You see | Cause | What to do |
|---|---|---|
| `spft: command not found` | The install did not finish step 3. | Run `bash ~/spft/install.sh` again. |
| `no su found` | The phone is not rooted, or root is hidden from Termux. | Root the phone. In your root app give Termux root access. |
| `root was refused` | You pressed Deny, the root window closed before you pressed Allow, or there is no window (KernelSU, APatch). | Open the root app and allow Termux (KernelSU, APatch: switch Termux on in the *Superuser* list), then run the command again. |
| `this phone's kernel is not a 64-bit ARM kernel` | box64 cannot run on a 32-bit kernel. | Use a phone with a 64-bit kernel as the host. |
| `only N MB are free` | Not enough storage. | Free about 3 GB, run `bash ~/spft/install.sh` again. |
| `pkg could not install ...` | The Termux mirror is down or slow. | `termux-change-repo`, choose another mirror, run the install again. |
| `could not download Debian` | No internet, or GitHub is not reachable. | Check the connection and run `spft install` again. A broken download is deleted, so each try starts from the beginning. |
| `the arm64 Debian won't run on this phone: ...` | The kernel or ROM blocks chroot. | Run `spft check`. Another host phone may be needed. |
| `box64 self-test FAILED` | The emulator does not run on this phone. | Run `spft install` again. If it fails again, use another host phone. |
| `the Termux:X11 server did not start` | The Termux:X11 **app** is missing (the `termux-x11-nightly` package alone is not enough). | Install the app ([README, section 2](../README.md#2-install-the-apps)), open it once, run `spft` again. |
| `x11-app : NOT installed`, but the app is installed | An older spft asked Android for the list of apps as the normal Termux user. Since Android 11 a normal app is not shown the other apps, so Termux:X11 was missing from the list. | `spft update`. spft now asks root first, which sees every app (it reads `/data/system/packages.list`). The app can come from F-Droid or from GitHub: spft only looks that it is installed. |
| The install seems stuck at `arm64 + x86_64 libraries` | It is the longest part (about 90 packages), and older versions of spft printed nothing for minutes while apt worked. | Look at the screen: a bar that moves (`[      =====         ] 0m12s`, while apt checks what is missing), counters like `downloaded 14.2 of 38.2 MB (37%)` and `[12/77]`, or a `still working` line every 20 seconds, mean that it is busy. If **nothing** new appears for 10 minutes, press Ctrl+C and run `bash ~/spft/install.sh` again: it carries on and keeps the downloaded files. |
| **Red or yellow** lines during the install: `Exec format error`, `systemctl: command not found`, `Restarting systemd-binfmt failed` | `Exec format error`: while it sets up an x86_64 library Debian runs a small x86_64 helper program of that library, and that cannot work before box64 is there. The other two: this Debian has no systemd, so box64's package cannot register itself there. spft does not need any of it, because it starts the tool with `box64 ./flash_tool` itself. | **Nothing, keep waiting.** spft prints a `Note:` under these lines that says so. Only `The setup stopped in step: ...` is an error. |
| `The setup stopped in step: ...` | A command inside Debian failed. The step is named, and the lines above say why (often: no internet). | Fix that, then run `spft install` again. |
| A red `[BOX64] Error: ... is not an executable file` during the install | Older versions of spft chose the wrong file for the self-test: the package `busybox-static` also contains a *text* file called `busybox` (in `usr/share/initramfs-tools`), and box64 was asked to run it. box64 itself was fine. | `spft update`, then `spft install` (the setup is repeated once, and the self-test now takes the real program). |
| Lines like `Cannot dlopen` or `Error loading needed lib` when the tool starts | box64 mentions libraries it could not load by name, and goes on. This is the normal start. | Nothing. A real problem is a **red** `[BOX64]` in front of `Error:`. |
| `Invalid linux kervel version. Please upgrade linux kernel up to at least 4.19.14!` | The tool compares kernel versions badly. | [See above](#the-invalid-linux-kernel-version-message). |
| Black or empty Termux:X11 screen | An old or dead server is in the way (Android may have killed it and left its socket file behind). | `spft stop` (it force-stops the tool, the Termux:X11 server and the Termux:X11 app, removes that socket file, and clears the caches), run `spft`. |
| `spft stop` says `mounts : WARNING: still mounted` | Something still uses Debian: a shell from `spft enter` that is open in another Termux session, or a process that did not end. | Close the other Termux sessions, run `spft stop` again. If it stays, restart the phone. While something is mounted, `spft stop` leaves Debian's own folders alone (it clears only the Termux:X11 app's cache), and says so in the `cache` row. |
| `spft stop` says `could not force-stop the Termux:X11 app` | The `am` command was refused. | Swipe Termux:X11 away from Recents by hand. Everything else in `spft stop` has worked. |
| The picture is upside down | The phone's landscape is the other way. | `spft x11 reverse` |
| **The bottom of the tool window is cut off**: no buttons, no status bar, the lower rows cannot be reached | The zoom was too big for the screen. The tool's window is about 720 pixels tall and cannot be made smaller, and the Termux:X11 screen is only as tall as the short side of the phone divided by the zoom. The old fixed zoom of 150% gave a 1280x800 tablet a screen of only 533 pixels. | `spft update`: spft now reads the screen size and picks the biggest zoom at which the whole window fits (105 on a 1280x800 tablet). `spft check` shows it in the `screen` row. If it is still cut off, take a smaller one: `spft x11 zoom=100`, then `zoom=90`, until the whole window shows. |
| The tool window is too small (tiny writing) | Your screen is large, or the zoom is low on purpose. | `spft x11 zoom=130` or `zoom=170` (bigger). Above the zoom that the `screen` row of `spft check` names, the bottom of the window is cut off. |
| `SP Flash Tool is already running` | A copy is open in the background. | Switch to Termux:X11, or run `spft stop`. |
| `SP Flash Tool is not installed yet` | The tool download did not finish. | `spft tool` ([README](../README.md#if-the-download-fails)). |
| `checksum mismatch` | The site re-packed the zip, or the download was damaged. | Download it by hand ([README](../README.md#if-the-download-fails)). |
| The tool or Termux closes by itself | Android's background process killer (Android 12 and newer). | [README, Android 12 and newer](../README.md#android-12-and-newer) |
| The file window starts in a folder called *root* (with *Computer* above it) and not in *sdcard* | An older spft. Its file windows started in Debian's home folder, `/root`, one click away from the phone's storage. | `spft update`. Now the tool is started with your internal storage as its home folder, and the window starts there (`SPFT_STORAGE=off spft` brings the old behaviour back). Click **sdcard** in the list on the left to come back to the top of your storage. |
| The file window shows no files | Wrong folder name, or the files are on the SD card. | Names are case sensitive. Only internal storage is visible. [README, section 5](../README.md#5-where-are-my-files-internal-storage) |
| `spft update` says it was not made with git clone | The folder is a copy, not a clone. | Clone again ([README, section 3](../README.md#3-install-spft-one-time)). |

## Start again from zero

Only when nothing else helps. This removes Debian and everything in it, and spft's downloads (not your files in the internal storage), and then installs again.

```
spft uninstall
bash ~/spft/install.sh
```

`spft uninstall` asks you to type `yes`, stops everything, unmounts, **checks that nothing is still mounted**, and only then deletes. If it says `NOT deleting`, something is still mounted inside the Debian folder: restart the phone and run `spft uninstall` again.

**Do not delete `/data/local/spft-debian` by hand with `rm -rf`** unless `spft umount` has just said `all unmounted`. While the mounts are there, that folder also holds your phone's `/dev` and your internal storage, and a recursive delete could wipe them.
