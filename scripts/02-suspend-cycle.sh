#!/bin/sh
# 02-suspend-cycle.sh - suspend-to-RAM test harness.
#
# Runs N suspend/resume cycles with a configurable set of peripheral
# teardowns, verifies the board actually slept for the requested time, and
# flags anything that blocked or failed the transition.
#
# Usage:
#   ./02-suspend-cycle.sh [options]
#
#   -d SECS   sleep duration per cycle          (default 60)
#   -n COUNT  number of cycles                  (default 1)
#   -m MODE   deep | s2idle                     (default deep)
#   -r RTC    rtcN to arm; default = SNVS RTC
#   -e        bring ethernet down before sleep, up after
#   -u BUSID  unbind this USB device before sleep, rebind after
#             (e.g. -u 1-1 ; find it with `lsusb -t`)
#   -U        unbind ALL non-root-hub USB devices
#   -w        unload the Wi-Fi module before sleep, reload after
#   -W        arm Wake-on-LAN (magic packet) as a second wake source
#   -N        detach NVMe / put USB storage to sleep first
#   -k        keep going after a failed cycle
#   -h        help
#
# Exit status is nonzero if any cycle failed verification.

. "$(dirname "$0")/pm-common.sh"

DUR=60
COUNT=1
MODE=deep
RTC=""
DO_ETH=0
USB_UNBIND=""
USB_ALL=0
DO_WIFI=0
DO_WOL=0
DO_STORAGE=0
KEEP=0

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while getopts 'd:n:m:r:eu:UwWNkh' opt; do
	case "$opt" in
		d) DUR=$OPTARG ;;
		n) COUNT=$OPTARG ;;
		m) MODE=$OPTARG ;;
		r) RTC=$OPTARG ;;
		e) DO_ETH=1 ;;
		u) USB_UNBIND="$USB_UNBIND $OPTARG" ;;
		U) USB_ALL=1 ;;
		w) DO_WIFI=1 ;;
		W) DO_WOL=1 ;;
		N) DO_STORAGE=1 ;;
		k) KEEP=1 ;;
		h|*) usage ;;
	esac
done

need_root
[ -n "$RTC" ] || RTC=$(rtc_snvs)
ETH=$(first_eth || echo "")

RESULTS="$PM_LOGDIR/suspend-$(date '+%Y%m%d-%H%M%S').csv"
csv_append "$RESULTS" "cycle,mode,requested_s,measured_s,drift_s,resume_ok,notes"

# --------------------------------------------------------------- teardown ---

UNBOUND=""
WIFI_MOD=""

teardown() {
	if [ "$DO_WIFI" -eq 1 ]; then
		for m in mwifiex_sdio nxpwifi_sdio moal; do
			if lsmod | grep -q "^$m "; then
				info "unloading $m"
				modprobe -r "$m" && WIFI_MOD="$WIFI_MOD $m"
			fi
		done
	fi

	if [ "$DO_STORAGE" -eq 1 ]; then
		if ls /dev/nvme0n1 >/dev/null 2>&1; then
			info "flushing NVMe"
			sync
			have nvme && nvme flush /dev/nvme0n1 >/dev/null 2>&1
		fi
		sync
	fi

	if [ "$USB_ALL" -eq 1 ]; then
		for d in /sys/bus/usb/devices/*; do
			b=$(basename "$d")
			case "$b" in usb*|*:*) continue ;; esac
			USB_UNBIND="$USB_UNBIND $b"
		done
	fi

	for b in $USB_UNBIND; do
		if [ -e "/sys/bus/usb/devices/$b" ]; then
			info "unbinding USB $b ($(cat "/sys/bus/usb/devices/$b/product" 2>/dev/null))"
			echo "$b" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null && \
				UNBOUND="$UNBOUND $b"
		else
			warn "USB $b not present, skipping"
		fi
	done

	if [ "$DO_WOL" -eq 1 ] && [ -n "$ETH" ]; then
		if have ethtool && ethtool -s "$ETH" wol g 2>/dev/null; then
			info "WoL magic packet armed on $ETH"
		else
			warn "could not arm WoL on $ETH"
		fi
	fi

	if [ "$DO_ETH" -eq 1 ] && [ -n "$ETH" ]; then
		info "bringing $ETH down"
		ip link set "$ETH" down
	fi
}

restore() {
	if [ "$DO_ETH" -eq 1 ] && [ -n "$ETH" ]; then
		ip link set "$ETH" up
	fi
	for b in $UNBOUND; do
		echo "$b" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
	done
	UNBOUND=""
	for m in $WIFI_MOD; do
		modprobe "$m" 2>/dev/null || true
	done
	WIFI_MOD=""
}

trap 'restore' EXIT INT TERM

# ------------------------------------------------------------------ setup ---

hdr "Suspend cycle test"
info "mode        : $MODE"
info "duration    : ${DUR}s x $COUNT cycle(s)"
info "rtc         : $RTC ($(rtc_name "$RTC"))"
info "ethernet    : ${ETH:-none}$([ "$DO_ETH" -eq 1 ] && echo ' (down before sleep)')"
info "results     : $RESULTS"

rtc_has_alarm "$RTC" || die "$RTC has no writable wakealarm"

if [ "$MODE" = "s2idle" ]; then
	set_mem_sleep s2idle
else
	set_mem_sleep deep
fi
info "mem_sleep   : $(mem_sleep_current)"

FAILED=0
i=1
while [ "$i" -le "$COUNT" ]; do
	hdr "Cycle $i/$COUNT"

	teardown

	mark=$(dmesg_mark)
	rtc_arm_relative "$RTC" "$DUR"

	t0=$(date +%s)
	info "entering $MODE ..."
	sync

	if ! echo mem | sudo tee /sys/power/state 2>/tmp/pm_err; then
		rtc_clear_alarm "$RTC"
		warn "write to /sys/power/state failed: $(cat /tmp/pm_err)"
		csv_append "$RESULTS" "$i,$MODE,$DUR,,,no,write-failed"
		FAILED=1
		restore
		[ "$KEEP" -eq 1 ] || exit 1
		i=$((i + 1))
		continue
	fi

	t1=$(date +%s)
	measured=$((t1 - t0))
	drift=$((measured - DUR))

	info "resumed after ${measured}s (drift ${drift}s)"

	rtc_clear_alarm "$RTC"

	restore

	notes=""
	ok=yes

	# A cycle that returns almost instantly did not really suspend.
	if [ "$measured" -lt $((DUR / 2)) ]; then
		warn "woke far too early - something aborted the suspend"
		ok=no
		notes="early-wake"
		FAILED=1
	fi

	slice=$(dmesg_since "$mark")
	if ! dmesg_check_suspend "$slice"; then
		ok=no
		notes="${notes:+$notes;}dmesg-errors"
		FAILED=1
	fi

	if echo "$slice" | grep -q 'PM: suspend entry'; then
		info "kernel confirmed suspend entry"
	else
		warn "no 'PM: suspend entry' in dmesg"
		notes="${notes:+$notes;}no-entry-log"
	fi

	# Report which device took longest to suspend, if the kernel tells us.
	echo "$slice" | grep -oE 'PM: [^ ]+ suspend of devices complete after [0-9.]+ msecs' \
		| sed 's/^/  /'

	csv_append "$RESULTS" "$i,$MODE,$DUR,$measured,$drift,$ok,$notes"

	[ "$ok" = "yes" ] || [ "$KEEP" -eq 1 ] || exit 1
	i=$((i + 1))
done

hdr "Summary"
cat "$RESULTS" | sed 's/^/  /'
[ "$FAILED" -eq 0 ] && info "all cycles passed" || warn "one or more cycles failed"
exit "$FAILED"
