#!/bin/sh
# pm-common.sh - shared helpers for Verdin iMX8M Plus power tests.
# Source this from the other scripts; it is not meant to be run directly.
#
# POSIX sh so it works on both Torizon OS and the Yocto reference images.

# /var/log is volatile tmpfs on Torizon (lost on reboot/crash); /var/lib
# persists, so results survive even a failed-suspend hard reset.
PM_LOGDIR="${PM_LOGDIR:-/var/lib/pmtest/log}"
PM_STATEDIR="${PM_STATEDIR:-/var/lib/pmtest}"

mkdir -p "$PM_LOGDIR" "$PM_STATEDIR" 2>/dev/null || true

# ---------------------------------------------------------------- output ----

_ts() { date '+%Y-%m-%dT%H:%M:%S'; }

log()  { printf '%s  %s\n' "$(_ts)" "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*" >&2; }
die()  { printf '  ** %s\n' "$*" >&2; exit 1; }

hdr() {
	printf '\n===============================================================\n'
	printf ' %s\n' "$*"
	printf '===============================================================\n'
}

# ------------------------------------------------------------ preflight ----

need_root() {
	[ "$(id -u)" -eq 0 ] || die "must run as root"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ RTC ----

# rtc_name <rtcN>  -> driver-reported name, e.g. rtc-rx8130 / snvs_rtc
rtc_name() {
	cat "/sys/class/rtc/$1/name" 2>/dev/null || echo "?"
}

# rtc_by_name <substring> -> first rtcN whose name matches, else empty
rtc_by_name() {
	for r in /sys/class/rtc/rtc*; do
		[ -e "$r/name" ] || continue
		case "$(cat "$r/name")" in
			*"$1"*) basename "$r"; return 0 ;;
		esac
	done
	return 1
}

# On Verdin: rtc0 is the on-module Epson RX8130CE, rtc1 is the SoC SNVS RTC.
# Resolve by name rather than trusting the numbering, which can shift.
rtc_snvs()   { rtc_by_name snvs || echo rtc1; }
rtc_onmod()  { rtc_by_name rx8130 || rtc_by_name ds1307 || echo rtc0; }

rtc_has_alarm() {
	[ -w "/sys/class/rtc/$1/wakealarm" ]
}

# Clearing is mandatory before re-arming, otherwise you get EBUSY if the
# previous alarm never fired (e.g. you woke on GPIO or WoL instead).
rtc_clear_alarm() {
	echo 0 > "/sys/class/rtc/$1/wakealarm" 2>/dev/null || true
}

rtc_arm_relative() {
	_r="$1"; _secs="$2"
	rtc_clear_alarm "$_r"
	if ! echo "+$_secs" > "/sys/class/rtc/$_r/wakealarm" 2>/dev/null; then
		die "could not arm $_r wakealarm (busy? unsupported?)"
	fi
	_set=$(cat "/sys/class/rtc/$_r/wakealarm")
	[ -n "$_set" ] || die "$_r wakealarm read back empty - alarm not armed"
	info "armed $_r for +${_secs}s (epoch $_set)"
}

# ---------------------------------------------------------------- sleep ----

sleep_states()  { cat /sys/power/state 2>/dev/null; }
mem_sleep_all() { cat /sys/power/mem_sleep 2>/dev/null; }

mem_sleep_current() {
	# the active mode is the one in [brackets]
	mem_sleep_all | tr ' ' '\n' | sed -n 's/^\[\(.*\)\]$/\1/p'
}

set_mem_sleep() {
	case " $(mem_sleep_all) " in
		*" $1 "*|*"[$1]"*) ;;
		*) die "mem_sleep mode '$1' not supported (have: $(mem_sleep_all))" ;;
	esac
	echo "$1" > /sys/power/mem_sleep
}

# --------------------------------------------------------------- dmesg -----

dmesg_mark() {
	# Returns a cursor we can diff against later. Falls back gracefully if
	# the kernel does not expose timestamps the way we expect.
	dmesg 2>/dev/null | wc -l
}

dmesg_since() {
	_from="$1"
	dmesg 2>/dev/null | tail -n +"$((_from + 1))"
}

# Look for the usual suspend-abort culprits in a dmesg slice.
dmesg_check_suspend() {
	_slice="$1"
	# PM_DMESG_IGNORE: egrep pattern of kernel lines to tolerate, for devices
	# with known-benign PM errors (e.g. PM_DMESG_IGNORE='lt8912'). Ignored
	# lines still appear in the full log; they just don't fail the cycle.
	if [ -n "${PM_DMESG_IGNORE:-}" ]; then
		_slice=$(echo "$_slice" | grep -vE "$PM_DMESG_IGNORE")
	fi
	_bad=0
	for _pat in \
		'PM: Some devices failed to suspend' \
		'PM: suspend of devices aborted' \
		'PM: Device .* failed to suspend' \
		'dpm_run_callback.*returns -' \
		'wakeup pending' \
		'Freezing of tasks failed' \
		'PM: suspend aborted'
	do
		if echo "$_slice" | grep -qE "$_pat"; then
			warn "dmesg: matched '$_pat'"
			echo "$_slice" | grep -E "$_pat" | sed 's/^/       /'
			_bad=1
		fi
	done
	return $_bad
}

# ----------------------------------------------------------------- misc ----

first_eth() {
	for i in /sys/class/net/*; do
		_n=$(basename "$i")
		case "$_n" in lo|docker*|veth*|br-*|wlan*|can*|sit*|tun*|tap*) continue ;; esac
		[ -e "$i/device" ] || continue
		echo "$_n"; return 0
	done
	return 1
}

csv_append() {
	_file="$1"; shift
	[ -e "$_file" ] || : > "$_file"
	printf '%s\n' "$*" >> "$_file"
}
