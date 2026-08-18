#!/bin/bash
# pm_run.sh - orchestrate DUT sleep tests against the INA228 monitor stack.
#
# Run this ON THE MONITOR STACK (the machine running this compose stack).
# The DUT's clock drifts or stops during suspend, so every phase boundary is
# stamped here, by the same clock that timestamps the ina228_data rows —
# per-phase power/energy then falls out of a single SQL join.
#
# Usage:
#   ./tools/pm_run.sh init
#       Create the pm_phases table (idempotent).
#
#   ./tools/pm_run.sh push torizon@<dut-ip>
#       Copy scripts/ to the DUT's ~/sleep_test/scripts (excludes Windows
#       Zone.Identifier droppings, sets exec bits).
#
#   ./tools/pm_run.sh run torizon@<dut-ip> LABEL 'REMOTE COMMAND'
#       Insert a start marker, run the command on the DUT over ssh, close the
#       marker with the exit code. Example:
#         ./tools/pm_run.sh run torizon@10.0.0.2 suspend-60s \
#             'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60'
#
#   ./tools/pm_run.sh baseline LABEL SECONDS
#       Marker-wrapped idle hold with no DUT command — e.g. measure the DUT
#       sitting at idle, or powered off, for SECONDS.
#
#   ./tools/pm_run.sh report [RUN_ID]
#       Per-phase results: duration, sample count, avg/min/max power from
#       samples, and true average from the INA228 energy accumulator.
#
#   ./tools/pm_run.sh watch [WINDOW_S]
#       Live readout (for 04-ab-matrix.sh prompts): rolling average power
#       over the last WINDOW_S seconds (default 10), refreshed every 2 s.
#
# Phases are grouped by RUN_ID: $PM_RUN_ID if set, else today's date.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f compose.yaml ] || { echo "ERROR: run from the sleep_test root"; exit 1; }

RUN_ID="${PM_RUN_ID:-$(date '+%Y%m%d')}"

psql_exec() {
    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 \
        -U "$(cat secrets/db_user.txt)" -d data "$@"
}

sql_quote() {  # escape single quotes for SQL literals
    printf "%s" "${1//\'/\'\'}"
}

phase_open() {  # phase_open LABEL COMMAND -> prints phase id
    psql_exec -tA -c "INSERT INTO pm_phases (run_id, label, command, started_at)
        VALUES ('$(sql_quote "$RUN_ID")', '$(sql_quote "$1")', '$(sql_quote "$2")', now())
        RETURNING id;"
}

phase_close() {  # phase_close ID EXIT_CODE
    psql_exec -q -c "UPDATE pm_phases SET ended_at = now(), exit_code = $2 WHERE id = $1;"
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in

init)
    psql_exec -c "CREATE TABLE IF NOT EXISTS pm_phases (
        id SERIAL PRIMARY KEY,
        run_id TEXT NOT NULL,
        label TEXT NOT NULL,
        command TEXT,
        started_at TIMESTAMPTZ NOT NULL,
        ended_at TIMESTAMPTZ,
        exit_code INT
    );"
    echo "pm_phases ready"
    ;;

push)
    DEST="${1:?usage: pm_run.sh push user@dut-ip}"
    ssh "$DEST" 'mkdir -p sleep_test/scripts'
    rsync -av --exclude '*Zone.Identifier*' scripts/ "$DEST:sleep_test/scripts/"
    ssh "$DEST" 'chmod +x sleep_test/scripts/*.sh'
    echo "scripts pushed to $DEST:sleep_test/scripts"
    ;;

run)
    DEST="${1:?usage: pm_run.sh run user@dut-ip LABEL 'REMOTE COMMAND'}"
    LABEL="${2:?missing LABEL}"
    REMOTE="${3:?missing remote command}"
    id=$(phase_open "$LABEL" "$REMOTE")
    echo "== [$RUN_ID/$id] $LABEL: $REMOTE"
    set +e
    ssh "$DEST" "$REMOTE"
    rc=$?
    set -e
    phase_close "$id" "$rc"
    echo "== [$RUN_ID/$id] $LABEL done (exit $rc)"
    [ "$rc" -eq 0 ] || echo "   NOTE: non-zero exit recorded; phase kept for the report"
    ;;

baseline)
    LABEL="${1:?usage: pm_run.sh baseline LABEL SECONDS}"
    SECS="${2:?missing SECONDS}"
    id=$(phase_open "$LABEL" "hold ${SECS}s")
    echo "== [$RUN_ID/$id] $LABEL: holding ${SECS}s"
    sleep "$SECS"
    phase_close "$id" 0
    echo "== [$RUN_ID/$id] $LABEL done"
    ;;

report)
    RID="${1:-$RUN_ID}"
    psql_exec -c "
        SELECT p.id,
               p.label,
               to_char(p.started_at, 'MM-DD HH24:MI:SS')                       AS start,
               round(extract(epoch FROM (COALESCE(p.ended_at, now()) - p.started_at))::numeric, 1)
                                                                               AS dur_s,
               p.exit_code                                                     AS rc,
               count(d.timestamp)                                              AS n,
               round(avg(d.power)::numeric  * 1000, 1)                         AS avg_mw,
               round(min(d.power)::numeric  * 1000, 1)                         AS min_mw,
               round(max(d.power)::numeric  * 1000, 1)                         AS max_mw,
               round(((array_agg(d.energy ORDER BY d.timestamp DESC))[1]
                    - (array_agg(d.energy ORDER BY d.timestamp ASC))[1])::numeric, 3)
                                                                               AS energy_j,
               round(((array_agg(d.energy ORDER BY d.timestamp DESC))[1]
                    - (array_agg(d.energy ORDER BY d.timestamp ASC))[1])::numeric
                    / NULLIF(extract(epoch FROM (COALESCE(p.ended_at, now()) - p.started_at)), 0)::numeric
                    * 1000, 1)                                                 AS true_avg_mw
        FROM pm_phases p
        LEFT JOIN ina228_data d
               ON d.timestamp BETWEEN p.started_at AND COALESCE(p.ended_at, now())
        WHERE p.run_id = '$(sql_quote "$RID")'
        GROUP BY p.id, p.label, p.started_at, p.ended_at, p.exit_code
        ORDER BY p.started_at;"
    echo "run_id: $RID   (true_avg_mw comes from the INA228 energy accumulator;"
    echo "a negative energy_j means the ina228 service restarted mid-phase)"
    ;;

watch)
    WIN="${1:-10}"
    echo "rolling ${WIN}s window, Ctrl-C to stop"
    while true; do
        psql_exec -tA -F' ' -c "
            SELECT 'avg_mW=' || round(avg(power)::numeric * 1000, 1),
                   'max_mW=' || round(max(power)::numeric * 1000, 1),
                   'V='      || round(avg(bus_voltage)::numeric, 3),
                   'mA='     || round(avg(current)::numeric * 1000, 1),
                   'n='      || count(*)
            FROM ina228_data
            WHERE timestamp > now() - make_interval(secs => $WIN);"
        sleep 2
    done
    ;;

*)
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
