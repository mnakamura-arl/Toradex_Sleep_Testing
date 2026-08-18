#!/bin/sh
# 03-poweroff-wake.sh - does the on-module RX8130CE wake the board from OFF?
#
# This is the make-or-break test for your hours-scale mode. If it works you
# skip the ~150 mW suspend floor entirely; if it does not, you fall back to
# suspend-to-RAM.
#
# It works in two halves:
#   arm    - drops a marker file, arms the on-module RTC alarm, powers off
#   check  - run after the board comes back; reports whether the wake was
#            caused by the alarm or by you pressing something
#
# The 'check' half is also installable as a boot service so the result is
# recorded automatically even if the board wakes unattended:
#   ./03-poweroff-wake.sh install
#
# Usage:
#   ./03-poweroff-wake.sh arm [SECONDS]     (default 300)
#   ./03-poweroff-wake.sh check
#   ./03-poweroff-wake.sh install
#   ./03-poweroff-wake.sh status

. "$(dirname "$0")/pm-common.sh"

MARKER="$PM_STATEDIR/poweroff-wake.marker"
RESULTS="$PM_LOGDIR/poweroff-wake.csv"
RTC=$(rtc_onmod)

do_arm() {
	need_root
	secs="${1:-300}"

	hdr "Arming wake-from-poweroff"
	info "rtc      : $RTC ($(rtc_name "$RTC"))"
	info "delay    : ${secs}s"

	rtc_has_alarm "$RTC" || die "$RTC has no writable wakealarm"

	# Sanity: the on-module RTC must be keeping time independently, and the
	# carrier needs a backup cell for this to survive a real power cut.
	info "rtc time : $(hwclock -r -f "/dev/$RTC" 2>/dev/null || echo unknown)"

	printf 'armed_at=%s\ndelay=%s\nrtc=%s\nexpect_at=%s\n' \
		"$(date +%s)" "$secs" "$RTC" "$(( $(date +%s) + secs ))" > "$MARKER"
	sync

	rtc_clear_alarm "$RTC"
	echo "+$secs" > "/sys/class/rtc/$RTC/wakealarm" || die "failed to arm alarm"
	info "alarm set for epoch $(cat "/sys/class/rtc/$RTC/wakealarm")"

	cat <<-EOF

	  The board will now power off. Watch your meter: it should drop to
	  the low-microamp range, not ~150 mW.

	  If it comes back on its own in ~${secs}s, wake-from-off works and
	  that is your hours-scale mode. If it does not, the RX8130 alarm
	  output is not wired to the PMIC on-request path on Mallow 1.1, and
	  you should use suspend-to-RAM instead.

	  Do NOT touch the power button - that would invalidate the test.

	EOF
	printf '  Proceed? [y/N] '
	read -r ans
	case "$ans" in
		y|Y) ;;
		*) rtc_clear_alarm "$RTC"; rm -f "$MARKER"; die "aborted" ;;
	esac

	sync
	log "powering off"
	poweroff
}

do_check() {
	if [ ! -e "$MARKER" ]; then
		info "no pending test marker - nothing to check"
		return 0
	fi

	. "$MARKER"

	now=$(date +%s)
	actual=$((now - armed_at))
	drift=$((actual - delay))
	uptime_s=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)

	hdr "Wake-from-poweroff result"
	info "armed at    : $(date -d "@$armed_at" 2>/dev/null || echo "$armed_at")"
	info "expected in : ${delay}s"
	info "actual gap  : ${actual}s (drift ${drift}s)"
	info "uptime now  : ${uptime_s}s"

	# Tolerance is generous: boot time is on top of the alarm delay.
	if [ "$drift" -ge -5 ] && [ "$drift" -le 60 ]; then
		verdict=PASS
		info "PASS - the board powered itself back on close to the alarm time."
		info "Wake-from-poweroff is viable. Use this for hours-scale sleep."
	elif [ "$actual" -lt $((delay - 10)) ]; then
		verdict=MANUAL
		warn "Came back EARLY - almost certainly a manual power-on."
		warn "Inconclusive. Re-run and leave the board alone."
	else
		verdict=LATE
		warn "Came back LATE by ${drift}s."
		warn "If you powered it on yourself, this is inconclusive; the RTC"
		warn "alarm likely did not fire. Fall back to suspend-to-RAM."
	fi

	csv_append "$RESULTS" "$(date '+%Y-%m-%dT%H:%M:%S'),$delay,$actual,$drift,$verdict"
	rtc_clear_alarm "$RTC"
	rm -f "$MARKER"

	info ""
	info "History:"
	sed 's/^/    /' "$RESULTS"
}

do_install() {
	need_root
	have systemctl || die "systemd not available"
	self=$(readlink -f "$0")

	cat > /etc/systemd/system/pmtest-wakecheck.service <<-EOF
	[Unit]
	Description=Record result of RTC wake-from-poweroff test
	After=time-sync.target
	ConditionPathExists=$MARKER

	[Service]
	Type=oneshot
	ExecStart=$self check
	RemainAfterExit=no

	[Install]
	WantedBy=multi-user.target
	EOF

	systemctl daemon-reload
	systemctl enable pmtest-wakecheck.service
	info "installed - results will be appended to $RESULTS on each boot"
}

do_status() {
	if [ -e "$MARKER" ]; then
		info "test pending:"
		sed 's/^/    /' "$MARKER"
	else
		info "no test pending"
	fi
	info ""
	info "current alarm on $RTC: $(cat "/sys/class/rtc/$RTC/wakealarm" 2>/dev/null | sed 's/^$/none/')"
	[ -e "$RESULTS" ] && { info "history:"; sed 's/^/    /' "$RESULTS"; }
}

case "${1:-}" in
	arm)     do_arm "$2" ;;
	check)   do_check ;;
	install) do_install ;;
	status)  do_status ;;
	*)       sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
