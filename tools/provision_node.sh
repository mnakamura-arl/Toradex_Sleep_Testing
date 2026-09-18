#!/bin/bash
# provision_node.sh - bring a Verdin/Mallow node to the known-good baseline.
#
# Every setting below was learned the hard way during the 2026-08/09 sleep-test
# campaign; the todo/ items say why each one matters. Applying them by hand
# across a fleet is how you get four subtly different boards, so they live here
# instead.
#
# Usage (run from the sleep_test repo root):
#   ./tools/provision_node.sh [options] user@host [user@host ...]
#
#   --from user@host   read the baseline from a reference node instead of the
#                      built-in defaults (e.g. the eval board, .212)
#   --clear            SOFT WIPE first: stop compose stacks, drop their volumes,
#                      remove stack dirs and /var/lib/pmtest. Does NOT touch the
#                      OS. Irreversible - collect anything you want first.
#   --with-hmp         keep/add the HMP overlay (Cortex-M7). Off by default.
#   --dry-run          print what would change, touch nothing
#   --no-reboot        apply but do not reboot (default reboots, since the
#                      device-tree changes only take effect on boot)
#
# What it sets:
#   fdt_board=mallow, fdtfile=imx8mp-verdin-wifi-mallow.dtb   (todo/006)
#   overlays: spidev + gnss-pps-gpio [+ hmp]; drops hdmi/dsi   (todo/006, PPS)
#   tdxargs="no_console_suspend loglevel=8"   (serial suspend logging)
#   modprobe blacklist: mwifiex*, hci_uart, btintel, flexcan, galcore (todo/008)
#
# Safe to re-run: every step is idempotent and backs up what it replaces.

set -uo pipefail
cd "$(dirname "$0")/.."

FROM=""; CLEAR=0; DRY=0; WITH_HMP=0; REBOOT=1
TARGETS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --from)      FROM="$2"; shift 2 ;;
        --clear)     CLEAR=1; shift ;;
        --with-hmp)  WITH_HMP=1; shift ;;
        --dry-run)   DRY=1; shift ;;
        --no-reboot) REBOOT=0; shift ;;
        -h|--help)   sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          echo "unknown option: $1" >&2; exit 1 ;;
        *)           TARGETS+=("$1"); shift ;;
    esac
done

[ ${#TARGETS[@]} -gt 0 ] || { echo "no targets given; -h for help" >&2; exit 1; }

SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
say()  { printf '  %s\n' "$*"; }
head_() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------- baseline ---

BL_FDT_BOARD="mallow"
BL_FDTFILE="imx8mp-verdin-wifi-mallow.dtb"
BL_TDXARGS="no_console_suspend loglevel=8"
BL_OVERLAYS="verdin-imx8mp_spidev_overlay.dtbo verdin-imx8mp_gnss-pps-gpio.dtbo"
BL_BLACKLIST="mwifiex_sdio mwifiex hci_uart btintel flexcan galcore"

if [ -n "$FROM" ]; then
    head_ "reading baseline from reference $FROM"
    ref=$($SSH "$FROM" '
        OVT=$(find /boot -name overlays.txt 2>/dev/null | head -1)
        echo "FDT_BOARD=$(sudo -n fw_printenv -n fdt_board 2>/dev/null)"
        echo "FDTFILE=$(sudo -n fw_printenv -n fdtfile 2>/dev/null)"
        echo "TDXARGS=$(sudo -n fw_printenv -n tdxargs 2>/dev/null)"
        echo "OVERLAYS=$(sed -n "s/^fdt_overlays=//p" "$OVT" 2>/dev/null)"
    ' 2>/dev/null)
    [ -n "$ref" ] || { echo "could not read reference $FROM" >&2; exit 1; }
    # Quote the values: the overlay list is multi-word, and an unquoted
    # eval turns "VAR=a b" into "run b with VAR=a", silently losing the value.
    eval "$(echo "$ref" | sed 's/^\([A-Z_]*\)=\(.*\)$/BL_REF_\1="\2"/')"
    [ -n "${BL_REF_FDT_BOARD:-}" ] && BL_FDT_BOARD="$BL_REF_FDT_BOARD"
    [ -n "${BL_REF_FDTFILE:-}"   ] && BL_FDTFILE="$BL_REF_FDTFILE"
    [ -n "${BL_REF_TDXARGS:-}"   ] && BL_TDXARGS="$BL_REF_TDXARGS"
    [ -n "${BL_REF_OVERLAYS:-}"  ] && BL_OVERLAYS="$BL_REF_OVERLAYS"
    say "fdt_board : $BL_FDT_BOARD"
    say "fdtfile   : $BL_FDTFILE"
    say "tdxargs   : $BL_TDXARGS"
    say "overlays  : $BL_OVERLAYS"
fi

if [ "$WITH_HMP" -eq 1 ] && ! echo "$BL_OVERLAYS" | grep -q hmp; then
    BL_OVERLAYS="$BL_OVERLAYS verdin-imx8mp_hmp_overlay.dtbo"
fi

# The PPS overlay is NOT in the stock Torizon image - it has to be shipped.
PPS_DTBO=""
for c in tools/verdin-imx8mp_gnss-pps-gpio.dtbo \
         backups/verdin-imx8mp_gnss-pps-gpio.dtbo; do
    [ -f "$c" ] && { PPS_DTBO="$c"; break; }
done

# ------------------------------------------------------------------ per-node --

provision() {
    local T="$1"
    head_ "$T"

    $SSH "$T" true 2>/dev/null || { say "UNREACHABLE - skipping"; return 1; }
    $SSH "$T" 'sudo -n true' 2>/dev/null || {
        say "NO PASSWORDLESS SUDO - skipping."
        say "fix with: ssh -t $T 'echo \"torizon ALL=(ALL) NOPASSWD: ALL\" | sudo tee /etc/sudoers.d/torizon-nopasswd && sudo chmod 440 /etc/sudoers.d/torizon-nopasswd'"
        return 1; }

    say "before: $($SSH "$T" 'tr -d "\0" < /proc/device-tree/model' 2>/dev/null)"

    if [ "$CLEAR" -eq 1 ]; then
        say "--- soft clear ---"
        if [ "$DRY" -eq 1 ]; then
            say "[dry-run] would stop stacks, prune volumes, remove stack dirs and /var/lib/pmtest"
        else
            $SSH "$T" '
                for d in ~/*compose* ~/sleep_test; do
                    [ -f "$d/compose.yaml" ] || continue
                    (cd "$d" && docker compose down -v --remove-orphans >/dev/null 2>&1)
                done
                docker container prune -f >/dev/null 2>&1
                docker volume prune -f  >/dev/null 2>&1
                sudo -n rm -rf /var/lib/pmtest
                rm -rf ~/lean-mic-compose ~/agg-compose ~/sleep_test ~/lilipad-audio-proc
            ' 2>/dev/null
            say "cleared stacks, volumes, stack dirs, /var/lib/pmtest"
        fi
    fi

    if [ -n "$PPS_DTBO" ]; then
        if [ "$DRY" -eq 1 ]; then
            say "[dry-run] would install $(basename "$PPS_DTBO")"
        else
            scp -q -o BatchMode=yes "$PPS_DTBO" "$T:/tmp/pps.dtbo" 2>/dev/null &&
            $SSH "$T" 'OVD=$(dirname $(find /boot -name overlays.txt|head -1))/overlays
                       sudo -n cp /tmp/pps.dtbo "$OVD/verdin-imx8mp_gnss-pps-gpio.dtbo" && rm -f /tmp/pps.dtbo' 2>/dev/null &&
            say "PPS overlay installed"
        fi
    else
        say "!! no gnss-pps-gpio.dtbo found locally - PPS will not work on this node"
        say "   grab one from a node that has it into tools/ and re-run"
    fi

    if [ "$DRY" -eq 1 ]; then
        say "[dry-run] fdt_board=$BL_FDT_BOARD fdtfile=$BL_FDTFILE tdxargs=$BL_TDXARGS"
        say "[dry-run] overlays: $BL_OVERLAYS"
        say "[dry-run] blacklist: $BL_BLACKLIST"
        return 0
    fi

    $SSH "$T" "
        OVT=\$(find /boot -name overlays.txt 2>/dev/null | head -1)
        sudo -n cp \"\$OVT\" \"\$OVT.bak-\$(date +%Y%m%d)\" 2>/dev/null
        echo 'fdt_overlays=$BL_OVERLAYS' | sudo -n tee \"\$OVT\" >/dev/null
        sudo -n fw_setenv fdt_board '$BL_FDT_BOARD'
        sudo -n fw_setenv fdtfile  '$BL_FDTFILE'
        sudo -n fw_setenv tdxargs  '$BL_TDXARGS'
        { echo '# generated by provision_node.sh'
          for m in $BL_BLACKLIST; do echo \"blacklist \$m\"; done
        } | sudo -n tee /etc/modprobe.d/zz-power-profile.conf >/dev/null
    " 2>/dev/null && say "device tree, kernel args and blacklist applied"

    if [ "$REBOOT" -eq 1 ]; then
        say "rebooting ..."
        $SSH "$T" 'sudo -n systemd-run --on-active=2 --unit=provision-reboot systemctl reboot' >/dev/null 2>&1
    else
        say "NOT rebooting (--no-reboot); changes take effect on next boot"
    fi
}

for t in "${TARGETS[@]}"; do provision "$t"; done

if [ "$REBOOT" -eq 1 ] && [ "$DRY" -eq 0 ]; then
    head_ "waiting for nodes to return"
    sleep 45
    for t in "${TARGETS[@]}"; do
        h="${t#*@}"
        for i in $(seq 1 20); do
            $SSH "$t" true 2>/dev/null && break
            sleep 5
        done
        printf '  %-28s %s\n' "$h" "$($SSH "$t" 'tr -d "\0" < /proc/device-tree/model' 2>/dev/null || echo UNREACHABLE)"
    done
fi
