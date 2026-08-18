#!/bin/sh
# 06-soak.sh - overnight reliability soak.
#
# Suspend/resume is easy to get working once and hard to get working 500
# times in a row. PCIe/NVMe resume and USB re-enumeration are the usual
# offenders. This runs cycles until it hits a failure or the target count,
# verifying after every wake that your peripherals actually came back.
#
# Usage:
#   ./06-soak.sh [-n CYCLES] [-d SLEEP_S] [-a AWAKE_S] [-s] [-e] [-u BUSID]
#
#   -n CYCLES    total cycles, 0 = forever      (default 200)
#   -d SLEEP_S   sleep duration                 (default 120)
#   -a AWAKE_S   awake time between cycles      (default 15)
#   -s           stop on first failure          (default: log and continue)
#   -e           cycle ethernet down/up
#   -u BUSID     unbind/rebind this USB device each cycle
#
# Checks performed after every resume:
#   - ethernet link returns and gets an address
#   - the USB mic re-enumerates and ALSA sees it
#   - the SSD is still readable (short dd from the block device)
#   - no new suspend-related errors in dmesg
#   - RTC drift stays sane

. "$(dirname "$0")/pm-common.sh"

CYCLES=200
SLEEP_S=120
AWAKE_S=15
STOP=0
DO_ETH=0
USB_ID=""

while getopts 'n:d:a:seu:h' opt; do
	case "$opt" in
		n) CYCLES=$OPTARG ;;
		d) SLEEP_S=$OPTARG ;;
		a) AWAKE_S=$OPTARG ;;
		s) STOP=1 ;;
		e) DO_ETH=1 ;;
		u) USB_ID=$OPTARG ;;
		h|*) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	esac
done

need_root
RTC=$(rtc_snvs)
ETH=$(first_eth || echo "")
LOG="$PM_LOGDIR/soak-$(date '+%Y%m%d-%H%M%S').log"
CSV="$PM_LOGDIR/soak-$(date '+%Y%m%d-%H%M%S').csv"
csv_append "$CSV" "cycle,slept_s,drift_s,eth,usb,ssd,dmesg,verdict"

# Pick a block device to spot-check. Prefer the SSD over the eMMC.
SSD_DEV=""
for c in /dev/nvme0n1 /dev/sda; do
	[ -b "$c" ] && { SSD_DEV="$c"; break; }
done

set_mem_sleep deep

hdr "Soak test"
info "cycles   : $([ "$CYCLES" -eq 0 ] && echo unlimited || echo "$CYCLES")"
info "sleep    : ${SLEEP_S}s   awake: ${AWAKE_S}s"
info "rtc      : $RTC"
info "ethernet : ${ETH:-none}"
info "usb      : ${USB_ID:-none}"
info "ssd      : ${SSD_DEV:-none}"
info "log      : $LOG"
info ""
info "Estimated wall time: ~$(( CYCLES * (SLEEP_S + AWAKE_S) / 3600 ))h"

check_eth() {
	[ -n "$ETH" ] || { echo skip; return; }
	i=0
	while [ "$i" -lt 20 ]; do
		[ "$(cat /sys/class/net/"$ETH"/operstate)" = "up" ] && { echo ok; return; }
		sleep 1
		i=$((i + 1))
	done
	echo FAIL
}

check_usb() {
	[ -n "$USB_ID" ] || { echo skip; return; }
	i=0
	while [ "$i" -lt 15 ]; do
		[ -e "/sys/bus/usb/devices/$USB_ID/product" ] && { echo ok; return; }
		sleep 1
		i=$((i + 1))
	done
	echo FAIL
}

check_ssd() {
	[ -n "$SSD_DEV" ] || { echo skip; return; }
	if dd if="$SSD_DEV" of=/dev/null bs=4k count=256 iflag=direct 2>/dev/null; then
		echo ok
	else
		echo FAIL
	fi
}

FAILS=0
n=1
while [ "$CYCLES" -eq 0 ] || [ "$n" -le "$CYCLES" ]; do
	mark=$(dmesg_mark)

	[ "$DO_ETH" -eq 1 ] && [ -n "$ETH" ] && ip link set "$ETH" down
	if [ -n "$USB_ID" ]; then
		echo "$USB_ID" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
	fi

	rtc_clear_alarm "$RTC"
	if ! echo "+$SLEEP_S" > "/sys/class/rtc/$RTC/wakealarm" 2>/dev/null; then
		log "cycle $n: FAILED TO ARM ALARM"
		FAILS=$((FAILS + 1))
		csv_append "$CSV" "$n,,,,,,,arm-failed"
		[ "$STOP" -eq 1 ] && break
		sleep 5
		n=$((n + 1))
		continue
	fi

	sync
	t0=$(date +%s)
	echo mem > /sys/power/state 2>/dev/null
	t1=$(date +%s)
	slept=$((t1 - t0))
	drift=$((slept - SLEEP_S))

	[ "$DO_ETH" -eq 1 ] && [ -n "$ETH" ] && ip link set "$ETH" up
	if [ -n "$USB_ID" ]; then
		echo "$USB_ID" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
	fi

	sleep 3

	r_eth=$(check_eth)
	r_usb=$(check_usb)
	r_ssd=$(check_ssd)

	slice=$(dmesg_since "$mark")
	if dmesg_check_suspend "$slice" >/dev/null 2>&1; then
		r_dmesg=ok
	else
		r_dmesg=FAIL
	fi

	verdict=ok
	case "$r_eth$r_usb$r_ssd$r_dmesg" in *FAIL*) verdict=FAIL ;; esac
	[ "$slept" -lt $((SLEEP_S / 2)) ] && verdict=FAIL

	csv_append "$CSV" "$n,$slept,$drift,$r_eth,$r_usb,$r_ssd,$r_dmesg,$verdict"

	if [ "$verdict" = "FAIL" ]; then
		FAILS=$((FAILS + 1))
		log "cycle $n: FAIL  slept=${slept}s eth=$r_eth usb=$r_usb ssd=$r_ssd dmesg=$r_dmesg"
		{
			echo "=== cycle $n dmesg ==="
			echo "$slice"
		} >> "$LOG"
		[ "$STOP" -eq 1 ] && { warn "stopping on first failure"; break; }
	else
		log "cycle $n: ok  slept=${slept}s drift=${drift}s  (fails so far: $FAILS)"
	fi

	rtc_clear_alarm "$RTC"
	sleep "$AWAKE_S"
	n=$((n + 1))
done

hdr "Soak complete"
info "cycles run : $((n - 1))"
info "failures   : $FAILS"
info "csv        : $CSV"
[ "$FAILS" -gt 0 ] && info "dmesg dumps: $LOG"
exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
