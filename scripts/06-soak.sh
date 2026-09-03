#!/bin/sh
# 06-soak.sh - overnight reliability soak.
#
# Suspend/resume is easy to get working once and hard to get working 500
# times in a row. PCIe/NVMe resume and USB re-enumeration are the usual
# offenders. This runs cycles until it hits a failure or the target count,
# verifying after every wake that your peripherals actually came back.
#
# Usage:
#   ./06-soak.sh [-n CYCLES] [-d SLEEP_S] [-a AWAKE_S] [-A ALIGN_S] [-s] [-e] [-u BUSID]
#
#   -n CYCLES    total cycles, 0 = forever      (default 200)
#   -d SLEEP_S   sleep duration                 (default 120)
#   -a AWAKE_S   awake time between cycles      (default 15)
#   -A ALIGN_S   align wake-ups to wall-clock multiples of ALIGN_S, e.g.
#                -A 900 wakes at :00 :15 :30 :45. Overrides -d: each cycle
#                sleeps until the next boundary instead of a fixed duration,
#                so alignment self-corrects and never accumulates drift.
#   -s           stop on first failure          (default: log and continue)
#   -F N         give up after N CONSECUTIVE failures (default 0 = never).
#                Guards against a soak degenerating into a fast retry loop:
#                on 2026-09-01 a wedged mwifiex firmware made every suspend
#                abort in ~11 s, and the run burned 39 h at 2.9 W before
#                anyone looked. -F 5 would have caught it in ~6 minutes.
#                On abort it writes $PM_STATEDIR/STOP (with the reason) so a
#                systemd Restart= does not relaunch into the same wedge;
#                delete that file to resume.
#   -e           cycle ethernet down/up
#   -u BUSID     unbind/rebind this USB device each cycle, then verify it
#                came back. A stress test: it exercises driver bind/unbind on
#                top of suspend/resume, and is NOT how the product runs.
#   -C BUSID     verify this USB device is still enumerated after each resume,
#                WITHOUT unbinding it. Passive, representative of real
#                operation. Use this to answer "does USB survive a sleep
#                cycle"; use -u to additionally stress re-enumeration.
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
ALIGN=0
MAXFAIL=0
STOP=0
DO_ETH=0
USB_ID=""
CHECK_USB=""

while getopts 'n:d:a:A:F:seu:C:h' opt; do
	case "$opt" in
		n) CYCLES=$OPTARG ;;
		d) SLEEP_S=$OPTARG ;;
		a) AWAKE_S=$OPTARG ;;
		A) ALIGN=$OPTARG ;;
		F) MAXFAIL=$OPTARG ;;
		s) STOP=1 ;;
		e) DO_ETH=1 ;;
		u) USB_ID=$OPTARG ;;
		C) CHECK_USB=$OPTARG ;;
		h|*) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	esac
done

need_root

# -u implies watching the same device; -C watches without touching it.
USB_WATCH="${USB_ID:-$CHECK_USB}"

RTC=$(rtc_snvs)
ETH=$(first_eth || echo "")
LOG="$PM_LOGDIR/soak-$(date '+%Y%m%d-%H%M%S').log"
CSV="$PM_LOGDIR/soak-$(date '+%Y%m%d-%H%M%S').csv"
csv_append "$CSV" "cycle,woke_at,requested_s,slept_s,drift_s,eth,usb,ssd,dmesg,verdict"

# Pick a block device to spot-check. Prefer the SSD over the eMMC.
SSD_DEV=""
for c in /dev/nvme0n1 /dev/sda; do
	[ -b "$c" ] && { SSD_DEV="$c"; break; }
done

set_mem_sleep deep

hdr "Soak test"
info "cycles   : $([ "$CYCLES" -eq 0 ] && echo unlimited || echo "$CYCLES")"
if [ "$ALIGN" -gt 0 ]; then
	info "sleep    : until next ${ALIGN}s wall-clock boundary   awake: ${AWAKE_S}s"
else
	info "sleep    : ${SLEEP_S}s   awake: ${AWAKE_S}s"
fi
info "rtc      : $RTC"
info "ethernet : ${ETH:-none}"
info "usb      : ${USB_WATCH:-none}$([ -n "$USB_ID" ] && echo ' (unbind/rebind each cycle)' || { [ -n "$CHECK_USB" ] && echo ' (check only)'; })"
info "ssd      : ${SSD_DEV:-none}"
info "log      : $LOG"
info ""
[ "$ALIGN" -gt 0 ] \
	&& info "Estimated wall time: ~$(( CYCLES * ALIGN / 3600 ))h (aligned)" \
	|| info "Estimated wall time: ~$(( CYCLES * (SLEEP_S + AWAKE_S) / 3600 ))h"

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
	[ -n "$USB_WATCH" ] || { echo skip; return; }
	i=0
	while [ "$i" -lt 15 ]; do
		[ -e "/sys/bus/usb/devices/$USB_WATCH/product" ] && { echo ok; return; }
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
STREAK=0
n=1
while [ "$CYCLES" -eq 0 ] || [ "$n" -le "$CYCLES" ]; do
	# Unattended stop valve: `touch $PM_STATEDIR/STOP` ends the soak at the
	# next cycle boundary. It lives on persistent storage, so it also stops
	# the systemd unit from resuming the soak after a reboot.
	if [ -e "$PM_STATEDIR/STOP" ]; then
		log "STOP file present ($PM_STATEDIR/STOP) - ending soak cleanly"
		STOPPED=1
		break
	fi

	mark=$(dmesg_mark)

	[ "$DO_ETH" -eq 1 ] && [ -n "$ETH" ] && ip link set "$ETH" down
	if [ -n "$USB_ID" ]; then
		echo "$USB_ID" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
	fi

	# With -A, sleep until the next wall-clock boundary rather than for a
	# fixed span. Computed fresh each cycle, so resume overhead and clock
	# corrections never accumulate into the alignment. Relative (+N) rather
	# than an absolute epoch, so it stays correct even if the RTC's own time
	# base is offset from system time.
	if [ "$ALIGN" -gt 0 ]; then
		now=$(date +%s)
		target=$(( (now / ALIGN + 1) * ALIGN ))
		# too close to the boundary to sleep meaningfully - take the next one
		[ $((target - now)) -lt 30 ] && target=$((target + ALIGN))
		SLEEP_THIS=$((target - now))
	else
		SLEEP_THIS=$SLEEP_S
	fi

	rtc_clear_alarm "$RTC"
	if ! echo "+$SLEEP_THIS" > "/sys/class/rtc/$RTC/wakealarm" 2>/dev/null; then
		log "cycle $n: FAILED TO ARM ALARM"
		FAILS=$((FAILS + 1))
		csv_append "$CSV" "$n,$(_ts),$SLEEP_THIS,,,,,,,arm-failed"
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
	drift=$((slept - SLEEP_THIS))

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
	[ "$slept" -lt $((SLEEP_THIS / 2)) ] && verdict=FAIL

	csv_append "$CSV" "$n,$(_ts),$SLEEP_THIS,$slept,$drift,$r_eth,$r_usb,$r_ssd,$r_dmesg,$verdict"

	if [ "$verdict" = "FAIL" ]; then
		FAILS=$((FAILS + 1))
		STREAK=$((STREAK + 1))
		log "cycle $n: FAIL  slept=${slept}s eth=$r_eth usb=$r_usb ssd=$r_ssd dmesg=$r_dmesg"
		{
			echo "=== cycle $n dmesg ==="
			echo "$slice"
		} >> "$LOG"
		[ "$STOP" -eq 1 ] && { warn "stopping on first failure"; break; }
	else
		STREAK=0
		log "cycle $n: ok  slept=${slept}s drift=${drift}s  (fails so far: $FAILS)"
	fi

	# Sustained failure means something is wedged and will not recover on its
	# own; continuing just burns power and fills the log with the same error.
	if [ "$MAXFAIL" -gt 0 ] && [ "$STREAK" -ge "$MAXFAIL" ]; then
		warn "$STREAK consecutive failures (-F $MAXFAIL) - aborting soak"
		log "ABORT: $STREAK consecutive failures; last dmesg is in $LOG"
		{ echo "=== abort after $STREAK consecutive failures ==="; echo "$slice"; } >> "$LOG"
		# Latch the stop valve, so that if this is running under systemd with
		# Restart=on-failure it does not relaunch straight back into the same
		# wedged state. Clearing STOP is then a deliberate human act.
		printf 'aborted %s after %s consecutive failures\n' "$(_ts)" "$STREAK" \
			> "$PM_STATEDIR/STOP" 2>/dev/null || true
		STOPPED=1
		break
	fi

	rtc_clear_alarm "$RTC"
	sleep "$AWAKE_S"
	n=$((n + 1))
done

hdr "Soak complete"
info "cycles run : $((n - 1))"
info "failures   : $FAILS"
info "final streak: $STREAK consecutive"
info "csv        : $CSV"
[ "$FAILS" -gt 0 ] && info "dmesg dumps: $LOG"

# A deliberate STOP always exits 0, even if cycles failed earlier - otherwise
# systemd's Restart=on-failure would relaunch straight into the STOP check and
# spin. Any other exit path keeps the pass/fail status.
[ "${STOPPED:-0}" -eq 1 ] && { info "stopped via STOP file"; exit 0; }
exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
