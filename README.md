# An APRS digipeater running on a Raspberry Pi

<!-- toc -->

- [Hardware](#hardware)
  * [Cable pinout: VX-4500](#cable-pinout-vx-4500)
- [Software](#software)
  * [What changed from the soundmodem/aprsdigi/aprx version](#what-changed-from-the-soundmodemaprsdigiaprx-version)
- [Installation](#installation)
- [Upgrading an existing Pi](#upgrading-an-existing-pi)
- [Debugging](#debugging)
- [Appendix: How the DINAH is found](#appendix-how-the-dinah-is-found)

<!-- tocstop -->

## Hardware

* [Raspberry PI 3B+](https://www.raspberrypi.com/products/raspberry-pi-3-model-b-plus/)
* [Canakit DCAR-052A5 5V 2.5A micro-USB power supply](https://www.canakit.com/raspberry-pi-adapter-power-supply-2-5a.html)
* [MakerFocus Raspberry Pi Case X002338M49](https://www.amazon.com/MakerFocus-Raspberry-Aluminum-Heatsink-Driver/dp/B07PNB7JWP)
* [SanDisk Ultra microSDXC UHS-I card 64 GB](https://www.amazon.com/SanDisk-microSDXC-Standard-Packaging-SDSQUNC-064G-GN6MA/dp/B010Q588D4)
* [DINAH CM119 USB soundmodem/PTT interface](https://kits4hams.com/dinah)
* [Vertex Standard VX-4500](https://www.yaesu.com/indexVS.cfm?cmd=DisplayProducts&ProdCatID=74&encProdID=985145DD4C41E33B7A105CE862474ED9&DivisionID=65&isArchived=0)
  * with [DE-15 to mini-DIN6 cable](#cable-pinout-vx-4500) (3-row high density DB-15)
* or Kenwood DM-710
  * with DINAH supplied mini-DIN6 male to male cable

### Cable pinout: VX-4500

![VX-4500 cable](./VX-4500-cable.svg)

## Software

Everything runs in [Dire Wolf](https://github.com/wb2osz/direwolf), installed
from the standard Debian `direwolf` package. One process does all of it:

* 1200 bps AFSK modem on the DINAH, with PTT through the DINAH's CM119B GPIO pin
  (no patched drivers needed)
* APRS digipeater (wide-area or fill-in, per site)
* Receive-only APRS-IS igate
* Position beacon to RF and APRS-IS

Everything is configured based on callsign: [install.sh](./install.sh) generates
`/etc/direwolf.conf` from the Pi's hostname.

### What changed from the soundmodem/aprsdigi/aprx version

The earlier version of this repo used Thomas Sailer's `soundmodem` (rebuilt with a
DINAH PTT patch), `aprsdigi` for digipeating, `aprx` for the igate, and
`ax25-tools` `beacon`. `soundmodem` has been dropped from Debian testing and won't
be in Debian 14, so this version replaces the whole stack with Dire Wolf.

| Old | New |
|---|---|
| `soundmodem` + `fix-missing-hid-dinah-gpio.patch` + `build-soundmodem.sh` | Dire Wolf `PTT CM108` (supports the DINAH as-is) |
| `dinah` script rewriting `soundmodem.conf` with the card number on every start | udev names the ALSA card `DINAH`, so the config just says `plughw:DINAH,0` |
| PTT hard-coded to `/dev/hidraw0` | udev symlink `/dev/dinah-ptt` |
| `aprsdigi --kill_dupes --kill_loops --subst_mycall --trace ...` | `DIGIPEAT` + `DEDUPE` (same aliases and tracing) |
| `aprx` receive-only igate | `IGSERVER` / `IGLOGIN` |
| `aprsbeacon.service` + aprx beacon | Two `CBEACON` lines (RF and APRS-IS), same text |
| `dinah`, `aprsdigi`, `aprsbeacon`, `aprx` services | One `direwolf.service` |

Behavior differences to be aware of:

* **No X1J4 translation.** aprsdigi's `--x1j4_xlate` (for TheNet X1J4 nodes) has no
  Dire Wolf equivalent. These nodes are essentially extinct.
* **Beacon destination.** Beacons go out with Dire Wolf's software tocall
  (`APDW..`) instead of `APRS`, which is the current APRS convention.
* **TXTAIL** is 100 ms (Dire Wolf's default) instead of soundmodem's 10 ms.
* **APRS-IS server** is the North America rotation `noam.aprs2.net`.
* The `soundmodemconfig` scope is gone. See [Debugging](#debugging) for the
  Dire Wolf way to check audio levels.

## Installation
To configure and start the digipeater:
* Use Raspberry Pi Imager and select:
  * Raspberry Pi Device: No Filtering
  * OS: Raspberry Pi OS (other)/Raspberry Pi OS Lite (64-bit): Debian Trixie with no
    desktop environment. (Bookworm also works.)
  * Select the SD card to write to.
  * Edit options:
    * General
      * hostname: a simple callsign-SSID
      * username/password
      * initial bootstrap WiFi LAN
    * Services
      * Enable SSH w/public-key authentication only
* Boot up with the SD card just written and wait for one-time setup.
* Plug in the DINAH.
* ssh in just to make sure. If you can't get in via ssh, use the console and keyboard.
* Either tar up this directory and copy it to the Pi or use git to clone it:
```
$ ssh n2ygk@n2ygk.local
n2ygk@n2ygk:~ $ sudo apt-get update && sudo apt-get install -y git
n2ygk@n2ygk:~ $ mkdir src && cd src
n2ygk@n2ygk:~/src $ git clone https://github.com/swjpilot/aprspi.git
n2ygk@n2ygk:~/src $ cd aprspi
```

Copy the `fix-auth.sh` script which adds users:
```
aprspi$ scp fix-auth.sh n2ygk@n2ygk:src/aprspi/
```

Then pop back on the host and run the install script:
```
n2ygk@n2ygk:~/src/aprspi $ sudo ./install.sh
```

If the script can't find the DINAH after installing its udev rules it will ask you
to unplug and replug it, then hit enter.

If the hostname isn't one of the sites listed in `install.sh`, you get a fill-in
digi with no beacon and a warning. Add a `case` entry for the new site and re-run.

Don't logout yet!

After the installation script finishes, you will only be able to ssh in by having installed `~/.ssh/authorized_keys`.
Furthermore, you'll need to set up `google-authenticator` (answer 'y' to all the questions):
```
$ google-authenticator
```

Copy `~/.google_authenticator` and install in password store for later recovery.
```
scp n2ygk@n2ygk:.google_authenticator /tmp/t
pass edit comp/n2ygk/n2ygk
# copy in contents of /tmp/t
pass git push
```

## Upgrading an existing Pi

On a Pi running the old soundmodem/aprsdigi/aprx setup, pull this repo and re-run
`sudo ./install.sh`. It stops and removes the old services, packages, udev rule and
`dinah` script, then installs Dire Wolf. Your ssh, firewall and 2FA settings are
re-applied as before.

## Debugging

Note that the green LED at the USB end of the DINAH should be flashing when it is
working properly.

**Is it running?**
```
systemctl status direwolf
journalctl -u direwolf -f
```
Every decoded packet shows up in the journal, along with what was digipeated and
sent to APRS-IS. Daily packet logs are also kept in `/var/log/direwolf/`.

**Receive audio level.** Each received packet line starts with an audio level, like
`N2YGK audio level = 48(24/23)`. Aim for the first number to be around 50 (roughly
30 to 70 is fine). If it's way off, adjust the capture gain:
```
alsamixer -c DINAH     # F4 for capture controls
sudo alsactl store     # save it, and update RXGAIN in install.sh so a re-run keeps it
```

**Transmit audio and PTT.** Stop the service and have Dire Wolf key up with a
test tone so you can check deviation on a monitor receiver or service monitor:
```
sudo systemctl stop direwolf
sudo -u direwolf direwolf -c /etc/direwolf.conf -x a   # alternating mark/space tones; Ctrl-C to stop
sudo systemctl start direwolf
```
If the radio doesn't key, check that `/dev/dinah-ptt` exists and is in the `audio` group.

**Watch raw traffic** with Dire Wolf's KISS client (localhost only):
```
kissutil
```

## Appendix: How the DINAH is found

Depending on random boot order, the DINAH USB soundcard can show up as different ALSA
card numbers, and its HID interface (used for PTT) as different `/dev/hidrawN` devices.
[95-dinah.rules](./95-dinah.rules), installed to `/etc/udev/rules.d`, takes care of that:

* sets the ALSA card id to `DINAH`, so it's always `plughw:DINAH,0` / `amixer -c DINAH`
* creates `/dev/snd/DINAH` and tags it for systemd, so `direwolf.service` starts when
  the DINAH is plugged in and stops when it's removed
* creates `/dev/dinah-ptt` for the HID interface and makes it writable by the `audio` group

```
$ ls -l /dev/snd/DINAH /dev/dinah-ptt
lrwxrwxrwx 1 root root 6 Oct 15 12:22 /dev/dinah-ptt -> hidraw0
lrwxrwxrwx 1 root root 9 Oct 15 12:22 /dev/snd/DINAH -> controlC2
$ aplay -l | grep DINAH
card 2: DINAH [USB Audio Device], device 0: USB Audio [USB Audio]
```
