# Troubleshooting

Back to the [README](../README.md).

**Always start with `spft check`.** It tests the host phone and the setup and says what to do for every problem.

1. [SP Flash Tool error codes](#sp-flash-tool-error-codes)
2. [The device is not detected](#the-device-is-not-detected)
3. [Problems with spft itself](#problems-with-spft-itself)
4. [Start again from zero](#start-again-from-zero)

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
| Black or empty Termux:X11 screen | An old or dead server is in the way (Android may have killed it and left its socket file behind). | `spft stop` (it also stops the Termux:X11 server and removes that socket file), swipe Termux:X11 away from Recents, run `spft`. |
| The picture is upside down | The phone's landscape is the other way. | `spft x11 reverse` |
| The tool window is too big or too small | | `spft x11 zoom=130` (smaller) or `zoom=170` (bigger). Above about 160 the tool is taller than the screen. |
| `SP Flash Tool is already running` | A copy is open in the background. | Switch to Termux:X11, or run `spft stop`. |
| `SP Flash Tool is not installed yet` | The tool download did not finish. | `spft tool` ([README](../README.md#if-the-download-fails)). |
| `checksum mismatch` | The site re-packed the zip, or the download was damaged. | Download it by hand ([README](../README.md#if-the-download-fails)). |
| The tool or Termux closes by itself | Android's background process killer (Android 12 and newer). | [README, Android 12 and newer](../README.md#android-12-and-newer) |
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
