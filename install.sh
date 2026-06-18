#!/usr/bin/bash
# needs to run as root and inherit these from the environment:
# all configuration is keyed off the hostname.
MYCALL=`hostname`
PASSCODE=`python tools/passcode.py $MYCALL`
# for a wide digi do WIDEn-N
WIDEALIASES="RELAY,WIDE,TRACE"
WIDETRACE="--trace TRACE --trace WIDE"
# for a fill-in digi only do WIDE1-1, not WIDEn-N
FILLALIASES="RELAY,TRACE,WIDE1-1,TRACE1-1"
FILLTRACE=""

case $MYCALL in
    n2ygk)
	BEACON='!4109.01N/07349.14W#PHG7300/fill in digipeater n2ygk@weca.org'
	ALIASES=$FILLALIASES
	TRACE=$FILLTRACE
	;;
    w2aee)
	BEACON='!4048.56N/07357.61W#PHG7430/W-R-T www.w2aee.columbia.edu'
	ALIASES=$WIDEALIASES
	TRACE=$WIDETRACE
	;;
    wb2zii)
	BEACON='!4104.83N/07348.44W#PHG7550/W-R-T www.weca.org'
	ALIASES=$WIDEALIASES
	TRACE=$WIDETRACE
	;;
    wb2zii-12)
	BEACON='!4054.  N/07349.  W#PHG7300/fill-in digipeater www.weca.org'
	ALIASES=$FILLALIASES
	TRACE=$FILLTRACE
	;;
    wb2zii-13)
	BEACON='!4119.  N/07333.  W#PHG7530/ fill-in digipeater www.weca.org'
	ALIASES=$FILLALIASES
	TRACE=$FILLTRACE
	;;
    wb2zii-14)
	BEACON='!4118.  N/07353.  W#PHG7300/fill-in digipeater www.weca.org'
	ALIASES=$FILLALIASES
	TRACE=$FILLTRACE
	;;
    wb2zii-15)
	BEACON='!4116.  N/07348.  W#PHG7300/fill-in digipeater www.weca.org'
	ALIASES=$FILLALIASES
	TRACE=$FILLTRACE
	;;
    *)
	BEACON='aprsdigi not configured de $MYCALL'
	ALIASES=$FILLALIASES
	TRACE=$FILLTRACE
	;;
esac

# TODO ALIASES vs. fill-in

RXGAIN=10 # Mic capture volume
TXGAIN=17 # Speaker playback volume

set -x
# TIGHTEN SECURITY
# firewall to only allow ssh
apt-get install -y ufw
ufw allow ssh
ufw enable

# block hosts making repeated failed attempts

apt-get install -y fail2ban
# fails to start because it can't find sshd log when backend = auto
sed -i.bak -e 's/^backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
# this message doesn't cause a ban with default INFO level logging:
# Connection closed by authenticating user foo 192.168.1.154 port 59027 [preauth]
echo "LogLevel VERBOSE" >/etc/ssh/sshd_config.d/ssh_verbose.conf

systemctl restart fail2ban

# we don't need to be multicasting who we are
apt-get remove -y avahi-daemon
apt autoremove -y

# fix up auth (add users, etc.)
if [ -f ./fix-auth.sh ]; then
    ./fix-auth.sh
fi

# enable automatic security updates
apt-get install -y unattended-upgrades
systemctl stop unattended-upgrades
cat >> /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::SyslogEnable "true";
EOF
systemctl enable unattended-upgrades
systemctl start unattended-upgrades
# run it once now:
unattended-upgrade

# require both ssh key and google authenticator for ssh login.
# disable ssh password login.
apt-get install -y libpam-google-authenticator

cat >/etc/ssh/sshd_config.d/google-authenticator.conf <<EOF
# require google-authenticator
ChallengeResponseAuthentication yes
AuthenticationMethods publickey,keyboard-interactive
PasswordAuthentication no
EOF

if ( ! grep -nq 'pam_google_authenticator.so' /etc/pam.d/sshd ); then
    sed -i.bak \
	-e 's/^@include common-auth/#@include common-auth\n# two-factor authentication via Google Authenticator\nauth   required   pam_google_authenticator.so/' \
	/etc/pam.d/sshd
fi

systemctl restart ssh

# CONFIGURE APRSDIGI
# Have udev make a symlink for the DINAH soundcard as /dev/snd/DINAH
# N.B. only works for a single soundcard and because the vendor/product IDs are relatively unique.
cp 95-myusb.rules /lib/udev/rules.d
systemctl restart udev
# I'm unable to find a way to re-trigger udev add of the device without phsyically removing it.
read -p "Please pop out and replug the DINAH usb device then hit enter: " x

# set the alsamixer levels
amixer -c /dev/snd/DINAH sset Mic $RXGAIN
amixer -c /dev/snd/DINAH sset Speaker $TXGAIN
alsactl store

# Find out which ALSA sound card the DINAH shows up as. This changes based on order of boot/usb hotplug.
card=`readlink /dev/snd/DINAH | sed -e 's/^.*\(.\)$/\1/'`
if [ -z "$card" ]; then
    echo must plug in DINAH card before running this script.
    exit 1
fi

apt-get install -y libax25
apt-get install -y ax25-tools
apt-get install -y ax25-apps
# have to install my patched version.
# but first need to get the latest version (for stupid reasons)
apt-get install -y soundmodem
if [ ! -f ../soundmodem_*.deb ]; then
    # this script is running under sudo, so run the build as the actual user
    su ${USER} -c ./build-soundmodem.sh
fi
dpkg -i ../soundmodem_*.deb

apt-get install -y aprsdigi
apt-get install -y aprx
apt-get install -y emacs
apt-get install -y xinit
apt-get install -y xterm

cat >/etc/ax25/axports <<EOF
#portname	callsign	speed	paclen	window	description
sm0	$MYCALL	1200	255	2	144.39 MHz (1200 bps)
EOF

# N.B. during normal operation (reboot, etc.) /usr/bin/dinah edits this to fix the card number.
cat >/etc/ax25/soundmodem.conf <<EOF
<?xml version="1.0"?>
<modem>
  <configuration name="sm0">
    <chaccess txdelay="150" slottime="100" ppersist="40" fulldup="0" txtail="10"/>
    <audio type="alsa" device="plughw:${card},0" halfdup="0" capturechannelmode="Mono"/>
    <ptt file="/dev/hidraw0" hamlib_model="" hamlib_params="" gpio="2"/>
    <channel name="Channel 0">
      <mod mode="afsk" bps="1200" f0="1200" f1="2200" diffenc="1"/>
      <demod mode="afsk" bps="1200" f0="1200" f1="2200" diffdec="1"/>
      <pkt mode="MKISS" ifname="sm0" hwaddr="$MYCALL" ip="10.0.0.1" netmask="255.255.255.0" broadcast="10.0.0.255"/>
    </channel>
  </configuration>
</modem>
EOF

cat >/etc/ax25/aprsdigi.conf <<EOF
APRSDIGI_CFG="--kill_dupes --kill_loops --subst_mycall --x1j4_xlate --logfile /var/log/aprsdigi.log ${TRACE} --interface ax25:sm0:${ALIASES}"
BEACON_DEST='APRS via WIDE2-2'
BEACON_PORT=sm0
BEACON_TEXT='$BEACON'
EOF

cat >/etc/aprx.conf <<EOF
# stripped down aprx.conf

mycall  $MYCALL

<aprsis>
passcode $PASSCODE
server    rotate.aprs2.net
</aprsis>

<logging>
pidfile /var/run/aprx.pid
rflog /var/log/aprx/aprx-rf.log
aprxlog /var/log/aprx/aprx.log
</logging>

<interface>
   ax25-device   \$mycall
   #tx-ok        false  # transmitter enable defaults to false
   telem-to-is	 false
</interface>

<beacon>
beaconmode aprsis
beacon raw "$BEACON"
</beacon>
EOF

systemctl disable soundmodem
rm /lib/systemd/system/soundmodem.service
cp dinah.service aprsdigi.service aprsbeacon.service /lib/systemd/system/
cp dinah /usr/sbin/
systemctl daemon-reload
cp logrotate.aprsdigi /etc/logrotate.d

systemctl enable dinah
systemctl enable aprsdigi
systemctl enable aprsbeacon
systemctl enable aprx

# DINAH should start magically on hot plug
systemctl start dinah
systemctl start aprsdigi
systemctl start aprx
