#!/bin/sh
# 05-runtime-tune.sh - apply / revert the runtime power knobs.
#
# Everything here is non-persistent and reversible. Snapshot first, apply,
# measure, revert. Nothing in this script touches the device tree - the DT
# changes (disabling GPU/VPU/NPU/ISP/DSI/CSI) have to be done at build time
# and are listed by `./05-runtime-tune.sh dt`.
#
# Usage:
#   ./05-runtime-tune.sh save      snapshot current settings
#   ./05-runtime-tune.sh apply     apply low-power settings
#   ./05-runtime-tune.sh revert    restore from snapshot
#   ./05-runtime-tune.sh show      print current settings
#   ./05-runtime-tune.sh dt        print the device tree checklist

. "$(dirname "$0")/pm-common.sh"

SNAP="$PM_STATEDIR/runtime-snapshot"
ETH=$(first_eth || echo "")

# ------------------------------------------------------------------- show ---

do_show() {
	hdr "Current runtime settings"
	info "governor    : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
	info "cpu online  : $(cat /sys/devices/system/cpu/online)"
	info "aspm policy : $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo n/a)"
	if [ -n "$ETH" ] && have ethtool; then
		info "eth speed   : $(ethtool "$ETH" 2>/dev/null | sed -n 's/.*Speed: //p')"
		info "eth wol     : $(ethtool "$ETH" 2>/dev/null | sed -n 's/\tWake-on: //p')"
	fi
	info "usb runtime pm:"
	for d in /sys/bus/usb/devices/*; do
		[ -e "$d/power/control" ] || continue
		printf '    %-8s %-6s %s\n' "$(basename "$d")" \
			"$(cat "$d/power/control")" \
			"$(cat "$d/product" 2>/dev/null)"
	done
	for d in /sys/class/devfreq/*; do
		[ -e "$d/governor" ] || continue
		info "devfreq $(basename "$d") : $(cat "$d/governor") @ $(cat "$d/cur_freq")"
	done
}

# ------------------------------------------------------------------- save ---

do_save() {
	need_root
	: > "$SNAP"
	{
		echo "gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
		echo "aspm=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
		if [ -n "$ETH" ] && have ethtool; then
			echo "eth=$ETH"
			echo "eth_speed=$(ethtool "$ETH" 2>/dev/null | sed -n 's/.*Speed: \([0-9]*\)Mb\/s/\1/p')"
			echo "eth_wol=$(ethtool "$ETH" 2>/dev/null | sed -n 's/\tWake-on: //p')"
		fi
		for d in /sys/bus/usb/devices/*; do
			[ -e "$d/power/control" ] || continue
			echo "usb_$(basename "$d" | tr '.-' '__')=$(cat "$d/power/control")"
		done
	} >> "$SNAP"
	info "snapshot written to $SNAP"
	sed 's/^/    /' "$SNAP"
}

# ------------------------------------------------------------------ apply ---

do_apply() {
	need_root
	[ -e "$SNAP" ] || { warn "no snapshot - running save first"; do_save; }

	hdr "Applying low-power settings"

	# CPU: schedutil scales better than ondemand on i.MX8MP; powersave pins
	# to the lowest OPP and is the right choice for a mostly-idle box.
	for g in schedutil powersave; do
		case " $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null) " in
			*" $g "*)
				for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
					echo "$g" > "$c" 2>/dev/null
				done
				info "cpufreq governor -> $g"
				break ;;
		esac
	done

	# PCIe ASPM. Matters a lot if the SSD is NVMe.
	if [ -w /sys/module/pcie_aspm/parameters/policy ]; then
		if echo powersupersave > /sys/module/pcie_aspm/parameters/policy 2>/dev/null; then
			info "ASPM -> powersupersave"
		else
			warn "ASPM write rejected (needs pcie_aspm.policy= on cmdline)"
		fi
	fi

	# USB autosuspend. USB audio class devices frequently ignore this;
	# check runtime_status afterwards to see whether it took.
	for d in /sys/bus/usb/devices/*; do
		[ -w "$d/power/control" ] || continue
		echo auto > "$d/power/control" 2>/dev/null
	done
	info "USB runtime PM -> auto on all devices"

	# SATA/SCSI link power management, if any.
	for h in /sys/class/scsi_host/host*/link_power_management_policy; do
		[ -w "$h" ] || continue
		echo min_power > "$h" 2>/dev/null && info "$(dirname "$h") -> min_power"
	done

	# Ethernet: drop to 100M. Saves 0.2-0.4 W and you almost certainly do
	# not need gigabit on a low-power node.
	if [ -n "$ETH" ] && have ethtool; then
		if ethtool -s "$ETH" speed 100 duplex full autoneg on 2>/dev/null; then
			info "$ETH -> 100 Mb/s"
		fi
		ethtool --set-eee "$ETH" eee on 2>/dev/null && info "$ETH -> EEE on"
	fi

	info ""
	info "Applied. Measure now, then './05-runtime-tune.sh revert'."
	info "Check that USB actually suspended:"
	info "  grep . /sys/bus/usb/devices/*/power/runtime_status"
}

# ----------------------------------------------------------------- revert ---

do_revert() {
	need_root
	[ -e "$SNAP" ] || die "no snapshot at $SNAP"
	# shellcheck disable=SC1090
	. "$SNAP"

	hdr "Reverting"

	if [ -n "${gov:-}" ]; then
		for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
			echo "$gov" > "$c" 2>/dev/null
		done
		info "governor -> $gov"
	fi

	if [ -n "${aspm:-}" ] && [ -w /sys/module/pcie_aspm/parameters/policy ]; then
		echo "$aspm" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null
		info "aspm -> $aspm"
	fi

	if [ -n "${eth:-}" ] && have ethtool; then
		[ -n "${eth_speed:-}" ] && \
			ethtool -s "$eth" speed "$eth_speed" duplex full autoneg on 2>/dev/null && \
			info "$eth -> ${eth_speed} Mb/s"
		[ -n "${eth_wol:-}" ] && ethtool -s "$eth" wol "$eth_wol" 2>/dev/null
	fi

	for d in /sys/bus/usb/devices/*; do
		[ -w "$d/power/control" ] || continue
		v=$(eval echo "\$usb_$(basename "$d" | tr '.-' '__')")
		[ -n "$v" ] && echo "$v" > "$d/power/control" 2>/dev/null
	done
	info "usb runtime pm restored"
}

# --------------------------------------------------------------------- dt ---

do_dt() {
	cat <<-'EOF'

	Device tree checklist (build-time, not runtime)
	==============================================

	For a headless node with ethernet + USB mic + SSD, set status = "disabled"
	on these in your overlay. Each one stops a clock domain and, for the big
	blocks, an entire power domain from ever being brought up.

	  Graphics / display
	    &gpu_3d  &gpu_2d  &gpumix  &ml_vipsi
	    &lcdif1  &lcdif2  &lcdif3
	    &mipi_dsi  &lvds_bridge  &hdmi_pvi  &hdmi_tx  &irqsteer_hdmi

	  Video / imaging
	    &vpu_g1  &vpu_g2  &vpu_vc8000e  &vpumix
	    &isp_0  &isp_1  &isi_0  &isi_1
	    &mipi_csi_0  &mipi_csi_1  &cameradev

	  Machine learning
	    &npu   (the 2.3 TOPS NPU - big win if unused)

	  Unused interfaces
	    &fec        second ethernet controller, if you only use eqos
	    &pcie &pcie_phy   ONLY if your SSD is USB, not NVMe
	    &sai1 &sai2 &sai3 &sai5 &sai6 &sai7   any not used by your mic path
	    &flexcan1 &flexcan2
	    &spdif1 &spdif2
	    &easrc  &micfil

	Verify after boot with:
	    cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
	Any domain still showing "on" that you thought you disabled is a clue.

	EOF
}

case "${1:-show}" in
	save)   do_save ;;
	apply)  do_apply ;;
	revert) do_revert ;;
	show)   do_show ;;
	dt)     do_dt ;;
	*)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
