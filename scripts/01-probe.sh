#!/bin/sh
# 01-probe.sh - read-only inventory of everything that matters for power work.
# Changes nothing. Run this first and keep the output; every later result
# should be read against this baseline.

. "$(dirname "$0")/pm-common.sh"

OUT="$PM_LOGDIR/probe-$(date '+%Y%m%d-%H%M%S').txt"

{

hdr "Module / BSP"
if have tdx-info; then
	tdx-info 2>/dev/null | sed 's/^/  /'
else
	info "tdx-info not present"
	info "kernel : $(uname -r)"
	info "model  : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
fi

hdr "Sleep states"
info "/sys/power/state     : $(sleep_states)"
info "/sys/power/mem_sleep : $(mem_sleep_all)"
info "active mem_sleep     : $(mem_sleep_current)"
case " $(sleep_states) " in
	*" mem "*) info "OK - suspend-to-RAM available" ;;
	*) warn "'mem' not in /sys/power/state - deep suspend unavailable" ;;
esac

hdr "RTCs"
for r in /sys/class/rtc/rtc*; do
	[ -e "$r" ] || continue
	n=$(basename "$r")
	printf '  %-6s name=%-14s' "$n" "$(rtc_name "$n")"
	if [ -e "$r/wakealarm" ]; then
		printf 'wakealarm=yes armed=%s' "$(cat "$r/wakealarm" 2>/dev/null | sed 's/^$/none/')"
	else
		printf 'wakealarm=NO'
	fi
	printf '\n'
done
info ""
info "SNVS (SoC)      -> $(rtc_snvs)   [use this for suspend-to-RAM]"
info "on-module Epson -> $(rtc_onmod)  [candidate for wake-from-poweroff]"
info "hwclock         -> $(hwclock -r 2>/dev/null || echo 'n/a')"

hdr "Registered wakeup sources (enabled only)"
found=0
for d in /sys/class/*/*/power/wakeup /sys/bus/*/devices/*/power/wakeup; do
	[ -e "$d" ] || continue
	if [ "$(cat "$d" 2>/dev/null)" = "enabled" ]; then
		echo "  $(echo "$d" | sed 's#/power/wakeup##')"
		found=1
	fi
done
[ "$found" -eq 1 ] || info "(none reported)"

hdr "CTRL_SLEEP_MOCI# (SODIMM 256)"
if have gpioinfo; then
	if gpioinfo 2>/dev/null | grep -i 'sleep.moci' | sed 's/^/  /' | grep -q .; then
		info "found above - note it is a GPIO hog, so it is not directly settable"
	else
		warn "no line named *sleep_moci* - check your device tree"
	fi
else
	info "libgpiod (gpioinfo) not installed - cannot check"
fi
info "Scope this pin during suspend: it should go LOW. If it stays high,"
info "the Mallow peripheral rails never get gated."

hdr "CPU"
info "online : $(cat /sys/devices/system/cpu/online)"
if [ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
	info "governor  : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
	info "available : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)"
	info "freqs kHz : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)"
	info "current   : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) kHz"
else
	warn "no cpufreq - DVFS is not active"
fi

hdr "cpuidle states (residency tells you if deep idle is actually used)"
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
	[ -e "$s" ] || { info "(no cpuidle states exposed)"; break; }
	printf '  %-10s %-22s usage=%-10s time=%s us\n' \
		"$(basename "$s")" "$(cat "$s/name")" \
		"$(cat "$s/usage")" "$(cat "$s/time")"
done

hdr "devfreq (DDR / bus scaling)"
if [ -d /sys/class/devfreq ] && [ -n "$(ls -A /sys/class/devfreq 2>/dev/null)" ]; then
	for d in /sys/class/devfreq/*; do
		printf '  %-24s gov=%-12s cur=%s\n' \
			"$(basename "$d")" \
			"$(cat "$d/governor" 2>/dev/null)" \
			"$(cat "$d/cur_freq" 2>/dev/null)"
	done
else
	info "no devfreq devices"
fi

hdr "Network"
if e=$(first_eth); then
	info "interface : $e"
	info "state     : $(cat /sys/class/net/"$e"/operstate)"
	if have ethtool; then
		ethtool "$e" 2>/dev/null | grep -E 'Speed|Duplex|Wake-on|Supports Wake' | sed 's/^/  /'
	else
		warn "ethtool not installed - cannot check WoL support"
	fi
else
	info "no ethernet interface found"
fi
info ""
info "All net devices:"
ls /sys/class/net | sed 's/^/    /'

hdr "USB"
if have lsusb; then
	lsusb -t 2>/dev/null | sed 's/^/  /'
	info ""
	lsusb 2>/dev/null | sed 's/^/  /'
else
	info "lsusb not installed"
fi
info ""
info "Per-device runtime PM:"
for d in /sys/bus/usb/devices/*; do
	[ -e "$d/power/control" ] || continue
	printf '    %-10s control=%-6s status=%s  %s\n' \
		"$(basename "$d")" \
		"$(cat "$d/power/control")" \
		"$(cat "$d/power/runtime_status" 2>/dev/null)" \
		"$(cat "$d/product" 2>/dev/null)"
done

hdr "Sound cards (your USB mic should appear here)"
cat /proc/asound/cards 2>/dev/null | sed 's/^/  /' || info "(none)"

hdr "PCIe / NVMe"
if [ -e /sys/module/pcie_aspm/parameters/policy ]; then
	info "ASPM policy : $(cat /sys/module/pcie_aspm/parameters/policy)"
else
	info "ASPM policy knob not exposed"
fi
if have lspci; then
	lspci 2>/dev/null | sed 's/^/  /' || info "  (no PCI devices)"
else
	info "lspci not installed"
fi
if ls /dev/nvme* >/dev/null 2>&1; then
	info "NVMe present: $(ls /dev/nvme* | tr '\n' ' ')"
	if have nvme; then
		nvme get-feature -f 0x0c -H /dev/nvme0 2>/dev/null | sed 's/^/  /'
	else
		info "nvme-cli not installed - cannot read APST config"
	fi
	info "kernel cmdline nvme args: $(grep -o 'nvme_core[^ ]*' /proc/cmdline || echo none)"
else
	info "no NVMe device -> your SSD is USB-attached"
fi

hdr "Block devices"
lsblk -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT 2>/dev/null | sed 's/^/  /' || \
	cat /proc/partitions | sed 's/^/  /'

hdr "Wi-Fi module (must be unloaded before deep suspend)"
if lsmod 2>/dev/null | grep -qE 'mwifiex|nxpwifi|moal'; then
	lsmod | grep -E 'mwifiex|nxpwifi|moal' | sed 's/^/  /'
	warn "loaded - unload before suspending (see 02-suspend-cycle.sh -w)"
else
	info "not loaded - nothing to do"
fi

hdr "Thermal"
for z in /sys/class/thermal/thermal_zone*; do
	[ -e "$z/temp" ] || continue
	printf '  %-8s %-16s %s C\n' "$(basename "$z")" \
		"$(cat "$z/type" 2>/dev/null)" \
		"$(( $(cat "$z/temp") / 1000 ))"
done

hdr "Done"
info "Saved to $OUT"

} 2>&1 | tee "$OUT"
