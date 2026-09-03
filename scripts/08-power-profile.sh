#!/bin/sh
# 08-power-profile.sh - put the board into a declared power state.
#
# Reads power-profile.conf and powers down everything the workload does not
# need, so a power measurement is reproducible and the config file is the
# record of what was measured.
#
# Usage:
#   sudo ./08-power-profile.sh status      show current state, change nothing
#   sudo ./08-power-profile.sh apply       apply runtime actions (reversible)
#   sudo ./08-power-profile.sh restore     undo runtime actions
#   sudo ./08-power-profile.sh boot-config write module blacklist (needs reboot)
#   sudo ./08-power-profile.sh boot-clear  remove the blacklist
#   sudo ./08-power-profile.sh install     boot-config PLUS a systemd unit that
#                                          re-applies the runtime actions every
#                                          boot - the "make it stick" option
#   sudo ./08-power-profile.sh uninstall   remove both
#
#   -c FILE   use a different profile (default: power-profile.conf beside this)
#   -n        dry run - print what would happen, do nothing
#   -r        reboot when done (only with boot-config / install)
#
# Two kinds of action, deliberately separated:
#
#   runtime  rfkill block, ip link down, USB unbind, module unload. Immediate
#            and reversible with `restore`.
#   boot     modprobe blacklist. Needs a reboot, but it is the ONLY safe way
#            to deal with drivers that leave firmware state behind once they
#            have initialised - mwifiex being the known example on this board
#            (see todo/006: rmmod after init was associated with hard resets,
#            never loading it is clean).
#
# SAFETY: the interface carrying the default route is never brought down, so
# this cannot strand a headless board.

. "$(dirname "$0")/pm-common.sh"

CONF="$(dirname "$0")/power-profile.conf"
DRY=0
REBOOT=0
BLACKLIST_FILE=/etc/modprobe.d/zz-power-profile.conf
UNIT_FILE=/etc/systemd/system/power-profile.service

while getopts 'c:nrh' opt; do
	case "$opt" in
		c) CONF=$OPTARG ;;
		n) DRY=1 ;;
		r) REBOOT=1 ;;
		h|*) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	esac
done
shift $((OPTIND - 1))

ACTION="${1:-status}"

[ -f "$CONF" ] || die "no profile at $CONF"
# shellcheck disable=SC1090
. "$CONF"

KEEP_NET="${KEEP_NET:-}"
KEEP_USB="${KEEP_USB:-}"
WIFI="${WIFI:-on}"
BLUETOOTH="${BLUETOOTH:-on}"
CAN="${CAN:-on}"
GPU="${GPU:-on}"

run() {
	if [ "$DRY" -eq 1 ]; then
		printf '  [dry-run] %s\n' "$*"
	else
		printf '  %s\n' "$*"
		# shellcheck disable=SC2294
		eval "$@" 2>/dev/null || printf '    (failed, continuing)\n'
	fi
}

# The interface we must never touch: whatever carries the default route.
protected_iface() {
	ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

# Belt and braces, and essential for the boot-time unit: at boot this can run
# before any default route exists, and protected_iface() would come back empty
# - at which point nothing would be protected. Any interface holding an IPv4
# address is therefore also protected, which keeps the management link up even
# with an empty route table.
has_ipv4() {
	ip -4 addr show dev "$1" 2>/dev/null | grep -q 'inet '
}

is_protected() {  # is_protected IFACE
	[ -n "$1" ] && [ "$1" = "$(protected_iface)" ] && return 0
	has_ipv4 "$1" && return 0
	return 1
}

# Interfaces we manage at all - skip loopback, docker, bridges, veth, tunnels.
managed_ifaces() {
	for i in /sys/class/net/*; do
		n=$(basename "$i")
		case "$n" in
			lo|docker*|veth*|br-*|sit*|tun*|tap*|virbr*) continue ;;
		esac
		echo "$n"
	done
}

in_list() {  # in_list NEEDLE "hay stack"
	for _w in $2; do [ "$_w" = "$1" ] && return 0; done
	return 1
}

# ------------------------------------------------------------------ status ---

do_status() {
	PROT=$(protected_iface)
	hdr "Power profile status"
	info "profile     : $CONF"
	info "protected   : ${PROT:-none} (default route - never touched)"
	info ""
	info "network:"
	for n in $(managed_ifaces); do
		st=$(cat "/sys/class/net/$n/operstate" 2>/dev/null)
		keep=no
		{ in_list "$n" "$KEEP_NET" || is_protected "$n"; } && keep=yes
		info "  $n  state=$st  keep=$keep"
	done
	info ""
	info "radios:"
	if have rfkill; then
		rfkill list 2>/dev/null | sed 's/^/    /'
	else
		info "    (no rfkill)"
	fi
	info ""
	info "usb (non-root-hub):"
	for d in /sys/bus/usb/devices/*; do
		b=$(basename "$d")
		case "$b" in usb*|*:*) continue ;; esac
		p=$(cat "$d/product" 2>/dev/null || echo "?")
		info "  $b  $p"
	done
	info ""
	info "modules of interest:"
	for m in mwifiex_sdio mwifiex cfg80211 hci_uart btintel flexcan can_dev galcore; do
		lsmod 2>/dev/null | grep -q "^$m " && info "  $m loaded"
	done
	info ""
	if [ -f "$BLACKLIST_FILE" ]; then
		info "boot blacklist ($BLACKLIST_FILE):"
		sed 's/^/    /' "$BLACKLIST_FILE"
		info "  NOTE: takes effect from the next reboot."
	else
		info "boot blacklist: none"
	fi
}

# ------------------------------------------------------------------- apply ---

do_apply() {
	need_root
	PROT=$(protected_iface)
	hdr "Applying power profile"
	info "profile   : $CONF"
	info "protected : ${PROT:-none}"
	[ "$DRY" -eq 1 ] && info "MODE      : dry run, nothing will change"
	info ""

	info "network:"
	for n in $(managed_ifaces); do
		if is_protected "$n"; then
			info "  $n kept (protected: default route, or holds an IPv4 address)"
			continue
		fi
		if in_list "$n" "$KEEP_NET"; then
			info "  $n kept (listed in KEEP_NET)"
			continue
		fi
		case "$n" in
			can*) [ "$CAN" = "off" ] || { info "  $n left alone (CAN=on)"; continue ;} ;;
		esac
		[ "$(cat "/sys/class/net/$n/operstate" 2>/dev/null)" = "down" ] && {
			info "  $n already down"; continue; }
		run "ip link set $n down"
	done

	info ""
	info "radios:"
	if [ "$WIFI" = "off" ]; then
		have rfkill && run "rfkill block wifi" || info "  (no rfkill; blacklist at boot instead)"
	else
		info "  wifi left enabled (WIFI=on)"
	fi
	if [ "$BLUETOOTH" = "off" ]; then
		have rfkill && run "rfkill block bluetooth" || info "  (no rfkill)"
	else
		info "  bluetooth left enabled (BLUETOOTH=on)"
	fi

	if [ "$CAN" = "off" ]; then
		info ""
		info "can:"
		lsmod 2>/dev/null | grep -q "^flexcan " && run "modprobe -r flexcan" \
			|| info "  flexcan not loaded"
	fi

	if [ "$GPU" = "off" ]; then
		info ""
		info "gpu:"
		lsmod 2>/dev/null | grep -q "^galcore " && run "modprobe -r galcore" \
			|| info "  galcore not loaded"
	fi

	if [ -n "$KEEP_USB" ]; then
		info ""
		info "usb:"
		for d in /sys/bus/usb/devices/*; do
			b=$(basename "$d")
			case "$b" in usb*|*:*) continue ;; esac
			if [ "$KEEP_USB" != "none" ] && in_list "$b" "$KEEP_USB"; then
				info "  $b kept ($(cat "$d/product" 2>/dev/null))"
				continue
			fi
			run "echo $b > /sys/bus/usb/drivers/usb/unbind"
		done
	fi

	info ""
	info "done. 'restore' undoes all of the above."
	[ -f "$BLACKLIST_FILE" ] || info "For mwifiex, also run 'boot-config' + reboot - see the header."
}

# ----------------------------------------------------------------- restore ---

do_restore() {
	need_root
	hdr "Restoring"
	have rfkill && run "rfkill unblock all"
	for d in /sys/bus/usb/devices/*; do
		b=$(basename "$d")
		case "$b" in usb*|*:*) continue ;; esac
	done
	# Rebind anything currently unbound, and reload what we removed.
	run "modprobe flexcan"
	run "modprobe galcore"
	for n in $(managed_ifaces); do
		run "ip link set $n up"
	done
	info ""
	info "NOTE: USB rebinding and module reloads are best-effort; a reboot is"
	info "the reliable way back to a clean default state."
}

# ------------------------------------------------------------- boot-config ---

do_boot_config() {
	need_root
	hdr "Writing boot-time module blacklist"
	TMP="$BLACKLIST_FILE.tmp"
	{
		echo "# generated by 08-power-profile.sh from $CONF"
		echo "# remove with: 08-power-profile.sh boot-clear"
		if [ "$WIFI" = "off" ]; then
			echo "blacklist mwifiex_sdio"
			echo "blacklist mwifiex"
		fi
		if [ "$BLUETOOTH" = "off" ]; then
			echo "blacklist hci_uart"
			echo "blacklist btintel"
		fi
		[ "$CAN" = "off" ] && echo "blacklist flexcan"
		[ "$GPU" = "off" ] && echo "blacklist galcore"
	} > "$TMP"

	if [ "$DRY" -eq 1 ]; then
		info "would write $BLACKLIST_FILE:"
		sed 's/^/    /' "$TMP"
		rm -f "$TMP"
		return
	fi
	mv "$TMP" "$BLACKLIST_FILE"
	sed 's/^/  /' "$BLACKLIST_FILE"
	info ""
	info "Written. REBOOT for this to take effect."
	info "This is the safe way to deal with mwifiex: never loading it cannot"
	info "leave firmware in the bad state that blocks every later suspend."
	[ "$ACTION" = "boot-config" ] && maybe_reboot
}

do_boot_clear() {
	need_root
	rm -f "$BLACKLIST_FILE" && info "removed $BLACKLIST_FILE - reboot to restore defaults"
}

# ---------------------------------------------------------------- install ---

maybe_reboot() {
	[ "$REBOOT" -eq 1 ] || return 0
	if [ "$DRY" -eq 1 ]; then info "would reboot now"; return 0; fi
	info ""
	info "rebooting in 5s (Ctrl-C to abort) ..."
	sleep 5
	reboot
}

do_install() {
	need_root
	SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	CONF_ABS="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"

	do_boot_config

	hdr "Installing boot-time apply unit"
	TMP="$UNIT_FILE.tmp"
	cat > "$TMP" <<EOF
[Unit]
Description=Apply declared power profile ($CONF_ABS)
# Needs the network up so the default-route check can identify the management
# link. The script also protects any interface holding an IPv4 address, so an
# early start cannot strand the board even if this ordering is not honoured.
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF -c $CONF_ABS apply

[Install]
WantedBy=multi-user.target
EOF
	if [ "$DRY" -eq 1 ]; then
		info "would write $UNIT_FILE:"
		sed 's/^/    /' "$TMP"
		rm -f "$TMP"
		maybe_reboot
		return
	fi
	mv "$TMP" "$UNIT_FILE"
	systemctl daemon-reload
	systemctl enable power-profile.service >/dev/null 2>&1 \
		&& info "enabled power-profile.service" \
		|| info "!! could not enable power-profile.service"
	info "runtime actions will now re-apply on every boot"
	info ""
	info "REBOOT needed for the module blacklist to take effect."
	maybe_reboot
}

do_uninstall() {
	need_root
	hdr "Uninstalling"
	systemctl disable --now power-profile.service >/dev/null 2>&1
	rm -f "$UNIT_FILE" && info "removed $UNIT_FILE"
	systemctl daemon-reload
	do_boot_clear
	info "reboot to restore default module loading"
}

case "$ACTION" in
	status)      do_status ;;
	apply)       do_apply ;;
	restore)     do_restore ;;
	boot-config) do_boot_config ;;
	boot-clear)  do_boot_clear ;;
	install)     do_install ;;
	uninstall)   do_uninstall ;;
	*)           die "unknown action '$ACTION' (status|apply|restore|boot-config|boot-clear|install|uninstall)" ;;
esac
