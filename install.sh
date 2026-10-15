#!/usr/bin/bash
# Install/upgrade an APRS digipeater + receive-only igate on a Raspberry Pi
# running Raspberry Pi OS (Debian 13 "trixie" or 12 "bookworm"), using
# Dire Wolf with a DINAH (C-Media CM119B) USB soundcard/PTT interface.
#
# Must be run as root (sudo ./install.sh) from the top of this repo.
# All configuration is keyed off the hostname, which must be the callsign[-SSID].
#
# Safe to re-run. Running it on a Pi that has the old soundmodem/aprsdigi/aprx
# setup migrates it to Dire Wolf.

set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "run me as root: sudo $0" >&2
    exit 1
fi

MYCALL=$(hostname | tr '[:lower:]' '[:upper:]')
PASSCODE=$(python3 tools/passcode.py "$MYCALL")

# Digipeater behavior (Dire Wolf DIGIPEAT alias and wide patterns).
# Wide-area digi: RELAY/WIDE/TRACE aliases, WIDEn-N and TRACEn-N traced.
WIDE_ALIAS='^RELAY$|^WIDE$|^TRACE$'
WIDE_NN='^WIDE[1-7]-[1-7]$|^TRACE[1-7]-[1-7]$'
# Fill-in digi: only RELAY/TRACE/WIDE1-1/TRACE1-1, replaced by our call, no n-N.
FILL_ALIAS='^RELAY$|^TRACE$|^WIDE1-1$|^TRACE1-1$'
FILL_NN='^$'   # never matches a callsign: no n-N digipeating

case $MYCALL in
    N2YGK)
        BEACON='!4109.01N/07349.14W#PHG7300/fill in digipeater n2ygk@weca.org'
        ALIAS=$FILL_ALIAS; NN=$FILL_NN ;;
    W2AEE)
        BEACON='!4048.56N/07357.61W#PHG7430/W-R-T www.w2aee.columbia.edu'
        ALIAS=$WIDE_ALIAS; NN=$WIDE_NN ;;
    WB2ZII)
        BEACON='!4104.83N/07348.44W#PHG7550/W-R-T www.weca.org'
        ALIAS=$WIDE_ALIAS; NN=$WIDE_NN ;;
    WB2ZII-12)
        BEACON='!4054.  N/07349.  W#PHG7300/fill-in digipeater www.weca.org'
        ALIAS=$FILL_ALIAS; NN=$FILL_NN ;;
    WB2ZII-13)
        BEACON='!4119.  N/07333.  W#PHG7530/ fill-in digipeater www.weca.org'
        ALIAS=$FILL_ALIAS; NN=$FILL_NN ;;
    WB2ZII-14)
        BEACON='!4118.  N/07353.  W#PHG7300/fill-in digipeater www.weca.org'
        ALIAS=$FILL_ALIAS; NN=$FILL_NN ;;
    WB2ZII-15)
        BEACON='!4116.  N/07348.  W#PHG7300/fill-in digipeater www.weca.org'
        ALIAS=$FILL_ALIAS; NN=$FILL_NN ;;
    *)
        echo "WARNING: $MYCALL has no entry in install.sh; configuring as a fill-in digi with no beacon." >&2
        BEACON=''
        ALIAS=$FILL_ALIAS; NN=$FILL_NN ;;
esac

RXGAIN=10 # Mic capture volume
TXGAIN=17 # Speaker playback volume

set -x

################################################################
# TIGHTEN SECURITY
################################################################
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ufw fail2ban unattended-upgrades libpam-google-authenticator

# firewall to only allow ssh
ufw allow ssh
ufw --force enable

# block hosts making repeated failed attempts.
# Use a jail.d override rather than editing the packaged jail.conf
# (sshd logs only to the journal; there is no /var/log/auth.log).
cat >/etc/fail2ban/jail.d/zz-aprspi.conf <<EOF
[DEFAULT]
backend = systemd

[sshd]
enabled = true
backend = systemd
EOF
# this message doesn't cause a ban with default INFO level logging:
# Connection closed by authenticating user foo 192.168.1.154 port 59027 [preauth]
echo "LogLevel VERBOSE" >/etc/ssh/sshd_config.d/ssh_verbose.conf
systemctl restart fail2ban

# we don't need to be multicasting who we are
apt-get remove -y avahi-daemon || true
apt-get autoremove -y

# fix up auth (add users, etc.)
if [ -f ./fix-auth.sh ]; then
    ./fix-auth.sh
fi

# automatic security updates (drop-in file so re-running doesn't duplicate lines)
cat >/etc/apt/apt.conf.d/52aprspi-unattended-upgrades <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::SyslogEnable "true";
EOF
systemctl enable --now unattended-upgrades
unattended-upgrade || true

# require both ssh key and google authenticator for ssh login.
# disable ssh password login.
cat >/etc/ssh/sshd_config.d/google-authenticator.conf <<EOF
# require google-authenticator
KbdInteractiveAuthentication yes
AuthenticationMethods publickey,keyboard-interactive
PasswordAuthentication no
EOF

if ! grep -q 'pam_google_authenticator.so' /etc/pam.d/sshd; then
    sed -i.bak \
        -e 's/^@include common-auth/#@include common-auth\n# two-factor authentication via Google Authenticator\nauth   required   pam_google_authenticator.so/' \
        /etc/pam.d/sshd
fi
systemctl restart ssh

################################################################
# REMOVE THE OLD soundmodem/aprsdigi/aprx STACK (if present)
################################################################
for svc in aprsbeacon aprsdigi aprx dinah soundmodem; do
    systemctl disable --now "$svc" 2>/dev/null || true
done
rm -f /lib/systemd/system/dinah.service /lib/systemd/system/aprsdigi.service \
      /lib/systemd/system/aprsbeacon.service /usr/sbin/dinah \
      /lib/udev/rules.d/95-myusb.rules /etc/logrotate.d/aprsdigi
apt-get purge -y soundmodem aprsdigi aprx 2>/dev/null || true

################################################################
# DINAH USB AUDIO/PTT
################################################################
apt-get install -y direwolf alsa-utils

# Name the ALSA card "DINAH", make /dev/snd/DINAH and /dev/dinah-ptt symlinks,
# and let the audio group drive PTT. See the comments in the rules file.
install -m 0644 95-dinah.rules /etc/udev/rules.d/95-dinah.rules
udevadm control --reload
udevadm trigger --action=add --subsystem-match=sound --subsystem-match=hidraw
udevadm settle
if [ ! -e /dev/snd/DINAH ] || [ ! -e /dev/dinah-ptt ]; then
    read -r -p "Please pop out and replug the DINAH usb device then hit enter: " _
    udevadm settle
fi
if [ ! -e /dev/snd/DINAH ]; then
    echo "DINAH not found. Plug it in and re-run this script." >&2
    exit 1
fi

# set the alsamixer levels
amixer -c DINAH sset Mic $RXGAIN
amixer -c DINAH sset Speaker $TXGAIN
alsactl store

################################################################
# DIRE WOLF
################################################################
getent group direwolf >/dev/null || groupadd --system direwolf
id -u direwolf >/dev/null 2>&1 || \
    useradd --system --gid direwolf --home-dir /var/lib/direwolf \
            --no-create-home --shell /usr/sbin/nologin direwolf
usermod -a -G audio direwolf

if [ -n "$BEACON" ]; then
    BEACONS="# Position beacon on RF and to APRS-IS every 30 minutes.
CBEACON delay=1 every=30 via=WIDE2-2 info=\"$BEACON\"
CBEACON delay=2 every=30 sendto=IG info=\"$BEACON\""
else
    BEACONS="# No beacon: $MYCALL has no entry in install.sh"
fi

cat >/etc/direwolf.conf <<EOF
# Generated by aprspi/install.sh for $MYCALL -- edits will be overwritten.

ADEVICE plughw:DINAH,0
ACHANNELS 1
CHANNEL 0
MYCALL $MYCALL
MODEM 1200

# DINAH PTT is GPIO 3 of the CM119B, reached through its hidraw device.
PTT CM108 3 /dev/dinah-ptt

# Channel access, in units of 10 ms. TXDELAY/SLOTTIME/PERSIST match the old
# soundmodem.conf (150 ms, 100 ms, 40). TXTAIL is Dire Wolf's default 100 ms;
# soundmodem used 10 ms, which risks clipping the end of a packet.
TXDELAY 15
TXTAIL 10
SLOTTIME 10
PERSIST 40

# Digipeater. First pattern: aliases, replaced by our call.
# Second pattern: n-N paths, decremented and traced.
DIGIPEAT 0 0 $ALIAS $NN
# Drop duplicate packets heard within 30 seconds (the default).
DEDUPE 30

# Receive-only igate: RF -> APRS-IS. Nothing is transmitted from the internet.
IGSERVER noam.aprs2.net
IGLOGIN $MYCALL $PASSCODE

$BEACONS

# Daily packet logs (YYYY-MM-DD.log), cleaned up by tmpfiles after 90 days.
LOGDIR /var/log/direwolf

# Only the KISS port (localhost debugging with kissutil); no AGW port.
AGWPORT 0
KISSPORT 8001
EOF
chown root:direwolf /etc/direwolf.conf
chmod 0640 /etc/direwolf.conf   # contains the APRS-IS passcode

install -m 0644 tmpfiles.direwolf.conf /etc/tmpfiles.d/direwolf.conf
systemd-tmpfiles --create /etc/tmpfiles.d/direwolf.conf

install -m 0644 direwolf.service /etc/systemd/system/direwolf.service
systemctl daemon-reload
systemctl enable direwolf
systemctl restart direwolf
systemctl --no-pager status direwolf || true
