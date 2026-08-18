#!/bin/sh
# 04-ab-matrix.sh - guided A/B power measurement.
#
# Walks you through a fixed sequence of configurations, holding the board in
# each one long enough to read your meter, and records what you type into a
# CSV. The point is to find out which of ethernet / SSD / mic actually costs
# you anything, instead of guessing.
#
# You need a meter on the Mallow input (bench supply with current readout,
# USB-C PD meter, or an inline shunt). Readings are entered in mW.
#
# Usage:
#   ./04-ab-matrix.sh idle      measure the running/idle state
#   ./04-ab-matrix.sh suspend   measure suspend-to-RAM (default 45s per step)
#   ./04-ab-matrix.sh both
#
#   -t SECS   hold time per suspend step (default 45)
#   -m FILE   append to a specific CSV

. "$(dirname "$0")/pm-common.sh"

HOLD=45
CSV=""

MODE="${1:-both}"
shift 2>/dev/null || true
while getopts 't:m:' opt; do
	case "$opt" in
		t) HOLD=$OPTARG ;;
		m) CSV=$OPTARG ;;
	esac
done

need_root
[ -n "$CSV" ] || CSV="$PM_LOGDIR/ab-matrix-$(date '+%Y%m%d-%H%M%S').csv"
csv_append "$CSV" "phase,config,power_mW,note"

RTC=$(rtc_snvs)
ETH=$(first_eth || echo "")

# ------------------------------------------------------------- peripherals --

usb_devs() {
	for d in /sys/bus/usb/devices/*; do
		b=$(basename "$d")
		case "$b" in usb*|*:*) continue ;; esac
		[ -e "$d/product" ] || continue
		echo "$b"
	done
}

MIC=""
SSD=""

identify() {
	hdr "Identify peripherals"
	for b in $(usb_devs); do
		p=$(cat "/sys/bus/usb/devices/$b/product" 2>/dev/null)
		printf '  %-8s %s\n' "$b" "$p"
		case "$p" in
			*[Mm]ic*|*[Aa]udio*|*Headset*) MIC="$b" ;;
			*SSD*|*[Ss]torage*|*[Dd]isk*|*NVMe*) SSD="$b" ;;
		esac
	done
	[ -n "$MIC" ] && info "detected mic -> $MIC" || warn "mic not auto-detected"
	if ls /dev/nvme0n1 >/dev/null 2>&1; then
		SSD="nvme"
		info "detected NVMe SSD (PCIe)"
	elif [ -n "$SSD" ]; then
		info "detected USB SSD -> $SSD"
	else
		warn "SSD not auto-detected"
	fi

	printf '\n  Override mic bus id (blank to keep "%s"): ' "$MIC"; read -r x
	[ -n "$x" ] && MIC="$x"
	printf '  Override ssd bus id / "nvme" (blank to keep "%s"): ' "$SSD"; read -r x
	[ -n "$x" ] && SSD="$x"
}

usb_off() { [ -n "$1" ] && [ "$1" != nvme ] && echo "$1" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null; }
usb_on()  { [ -n "$1" ] && [ "$1" != nvme ] && echo "$1" > /sys/bus/usb/drivers/usb/bind   2>/dev/null; }

eth_off() { [ -n "$ETH" ] && ip link set "$ETH" down; }
eth_on()  { [ -n "$ETH" ] && ip link set "$ETH" up; }

# ------------------------------------------------------------------ prompts --

read_power() {
	_phase="$1"; _cfg="$2"
	printf '\n  >> %s / %s\n' "$_phase" "$_cfg"
	printf '     enter reading in mW (or blank to skip): '
	read -r mw
	printf '     note (optional): '
	read -r note
	[ -n "$mw" ] && csv_append "$CSV" "$_phase,$_cfg,$mw,$note"
}

# ---------------------------------------------------------------- idle runs --

idle_step() {
	_cfg="$1"
	info "settling 10s ..."
	sleep 10
	read_power idle "$_cfg"
}

run_idle() {
	hdr "Idle (running) measurements"
	info "Board stays up. Let it settle between steps."

	eth_on;  usb_on "$MIC";  sleep 3
	idle_step "all-on"

	usb_off "$MIC"; sleep 3
	idle_step "no-mic"

	eth_off; sleep 3
	idle_step "no-mic,no-eth"

	if [ -n "$ETH" ] && have ethtool; then
		eth_on; sleep 2
		ethtool -s "$ETH" speed 100 duplex full autoneg on 2>/dev/null
		sleep 8
		idle_step "eth-100M"
		ethtool -s "$ETH" speed 1000 duplex full autoneg on 2>/dev/null
	fi

	if [ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
		orig=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
		for g in powersave schedutil; do
			case " $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors) " in
				*" $g "*) ;;
				*) continue ;;
			esac
			for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
				echo "$g" > "$c" 2>/dev/null
			done
			sleep 5
			idle_step "gov-$g"
		done
		for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
			echo "$orig" > "$c" 2>/dev/null
		done
	fi

	eth_on; usb_on "$MIC"
}

# ------------------------------------------------------------- suspend runs --

suspend_step() {
	_cfg="$1"
	info "suspending for ${HOLD}s - take your reading while it is down"
	rtc_clear_alarm "$RTC"
	echo "+$HOLD" > "/sys/class/rtc/$RTC/wakealarm" || { warn "arm failed"; return 1; }
	sync
	t0=$(date +%s)
	echo mem > /sys/power/state 2>/dev/null || warn "suspend write failed"
	t1=$(date +%s)
	slept=$((t1 - t0))
	info "back after ${slept}s"
	[ "$slept" -lt $((HOLD / 2)) ] && warn "woke early - reading may be invalid"
	rtc_clear_alarm "$RTC"
	read_power suspend "$_cfg"
}

run_suspend() {
	hdr "Suspend-to-RAM measurements"
	set_mem_sleep deep

	eth_on; usb_on "$MIC"; sleep 3
	suspend_step "all-attached"

	eth_off; sleep 2
	suspend_step "eth-down"

	usb_off "$MIC"; sleep 2
	suspend_step "eth-down,mic-unbound"

	if [ "$SSD" != "nvme" ] && [ -n "$SSD" ]; then
		usb_off "$SSD"; sleep 2
		suspend_step "eth-down,mic+ssd-unbound"
		usb_on "$SSD"
	fi

	usb_on "$MIC"; eth_on

	info ""
	info "For a true floor, power down and unplug everything from the"
	info "Mallow, then re-run just the first step. That number minus the"
	info "~150 mW module figure is your carrier board overhead."
}

# ------------------------------------------------------------------- driver --

identify

case "$MODE" in
	idle)    run_idle ;;
	suspend) run_suspend ;;
	both)    run_idle; run_suspend ;;
	*)       die "unknown mode '$MODE' (idle|suspend|both)" ;;
esac

hdr "Results"
sed 's/^/  /' "$CSV"
info ""
info "Saved to $CSV"
