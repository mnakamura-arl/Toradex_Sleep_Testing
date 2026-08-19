#!/bin/bash
# pm_run.sh - orchestrate DUT sleep tests against the INA228 monitor stack.
#
# Run this ON THE MONITOR STACK (the machine running this compose stack).
# The DUT's clock drifts or stops during suspend, so every phase boundary is
# stamped here, by the same clock that timestamps the ina228_data rows —
# per-phase power/energy then falls out of a single SQL join.
#
# Everything is logged under logs/<RUN_ID>/ :
#   orchestrator.log        every pm_run.sh action, timestamped
#   phase-<id>-<label>.log  full stdout+stderr of each remote command
#   errors.log              one entry per failed phase (exit code + log tail)
# 'collect' bundles those plus the DUT-side /var/log/pmtest, the DB tables,
# and the service logs into results-<RUN_ID>.tgz for transfer back.
#
# Phases are grouped by RUN_ID: $PM_RUN_ID if set, else today's date.
# See RUNBOOK.md for the full test sequence.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f compose.yaml ] || { echo "ERROR: run from the sleep_test root"; exit 1; }

RUN_ID="${PM_RUN_ID:-$(date '+%Y%m%d')}"
LOGDIR="logs/$RUN_ID"
mkdir -p "$LOGDIR"

usage() {
    cat <<'EOF'
usage: ./tools/pm_run.sh <command> [args]

  init                              create the pm_phases marker table (idempotent)
  push  user@dut                    copy scripts/ to the DUT ~/sleep_test/scripts
  run   user@dut LABEL 'REMOTE CMD' marker-wrapped ssh command, output logged
  baseline LABEL SECONDS            marker-wrapped hold, no DUT command
  report [RUN_ID]                   per-phase power/energy table
  watch [WINDOW_S]                  live rolling power readout (default 10 s)
  collect [user@dut] [RUN_ID]       bundle all logs + data -> results-<RUN_ID>.tgz

Phases group under $PM_RUN_ID (default: today's date). Example:
  export PM_RUN_ID=$(date +%Y%m%d-%H%M)
  ./tools/pm_run.sh run torizon@10.0.0.2 suspend-60 \
      'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60'
EOF
    exit 1
}

olog() {  # timestamped line to console and orchestrator.log
    printf '%s  %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" | tee -a "$LOGDIR/orchestrator.log"
}

err_note() {  # err_note PHASE_ID LABEL RC PHASE_LOG - record a failure
    {
        echo "=== $(date '+%Y-%m-%dT%H:%M:%S')  phase $1 ($2) exit=$3"
        [ -f "$4" ] && tail -n 20 "$4" | sed 's/^/    /'
    } >> "$LOGDIR/errors.log"
    olog "!! phase $1 ($2) FAILED exit=$3 - see $LOGDIR/errors.log"
}

psql_exec() {
    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 \
        -U "$(cat secrets/db_user.txt)" -d data "$@"
}

sql_quote() {  # escape single quotes for SQL literals
    printf "%s" "${1//\'/\'\'}"
}

phase_open() {  # phase_open LABEL COMMAND -> prints phase id
    psql_exec -q -tA -c "INSERT INTO pm_phases (run_id, label, command, started_at)
        VALUES ('$(sql_quote "$RUN_ID")', '$(sql_quote "$1")', '$(sql_quote "$2")', now())
        RETURNING id;"
}

phase_close() {  # phase_close ID EXIT_CODE
    psql_exec -q -c "UPDATE pm_phases SET ended_at = now(), exit_code = $2 WHERE id = $1;"
}

report_sql() {  # report_sql RUN_ID -> the per-phase results query
    cat <<EOF
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
        WHERE p.run_id = '$(sql_quote "$1")'
        GROUP BY p.id, p.label, p.started_at, p.ended_at, p.exit_code
        ORDER BY p.started_at
EOF
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
    );" | tee -a "$LOGDIR/orchestrator.log"
    olog "init: pm_phases ready"
    ;;

push)
    DEST="${1:?usage: pm_run.sh push user@dut-ip}"
    {
        ssh "$DEST" 'mkdir -p sleep_test/scripts'
        rsync -av --exclude '*Zone.Identifier*' scripts/ "$DEST:sleep_test/scripts/"
        ssh "$DEST" 'chmod +x sleep_test/scripts/*.sh'
    } 2>&1 | tee -a "$LOGDIR/orchestrator.log"
    olog "push: scripts pushed to $DEST:sleep_test/scripts"
    ;;

run)
    DEST="${1:?usage: pm_run.sh run user@dut-ip LABEL 'REMOTE COMMAND'}"
    LABEL="${2:?missing LABEL}"
    REMOTE="${3:?missing remote command}"
    id=$(phase_open "$LABEL" "$REMOTE")
    PLOG="$LOGDIR/phase-$id-$LABEL.log"
    olog "run [$RUN_ID/$id] $LABEL: $REMOTE"
    set +e
    ssh "$DEST" "$REMOTE" 2>&1 | tee "$PLOG"
    rc=${PIPESTATUS[0]}
    set -e
    phase_close "$id" "$rc"
    if [ "$rc" -eq 0 ]; then
        olog "run [$RUN_ID/$id] $LABEL done (exit 0), log: $PLOG"
    else
        err_note "$id" "$LABEL" "$rc" "$PLOG"
    fi
    ;;

baseline)
    LABEL="${1:?usage: pm_run.sh baseline LABEL SECONDS}"
    SECS="${2:?missing SECONDS}"
    id=$(phase_open "$LABEL" "hold ${SECS}s")
    olog "baseline [$RUN_ID/$id] $LABEL: holding ${SECS}s"
    sleep "$SECS"
    phase_close "$id" 0
    olog "baseline [$RUN_ID/$id] $LABEL done"
    ;;

report)
    RID="${1:-$RUN_ID}"
    psql_exec -c "$(report_sql "$RID");"
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

collect)
    DEST=""
    RID="$RUN_ID"
    for a in "$@"; do
        case "$a" in *@*) DEST="$a" ;; *) RID="$a" ;; esac
    done
    CDIR="logs/$RID"
    mkdir -p "$CDIR"
    olog "collect: gathering results for run $RID"

    # 1. Database: per-phase report, raw markers, raw samples for the run window
    psql_exec -c "COPY ($(report_sql "$RID")) TO STDOUT WITH CSV HEADER" \
        > "$CDIR/report.csv" \
        || olog "!! collect: report export failed (is the stack up?)"
    psql_exec -c "COPY (SELECT * FROM pm_phases WHERE run_id = '$(sql_quote "$RID")'
        ORDER BY started_at) TO STDOUT WITH CSV HEADER" \
        > "$CDIR/pm_phases.csv" || true
    psql_exec -c "COPY (SELECT d.* FROM ina228_data d WHERE d.timestamp BETWEEN
          (SELECT min(started_at) - interval '60 seconds' FROM pm_phases
             WHERE run_id = '$(sql_quote "$RID")')
          AND
          (SELECT max(COALESCE(ended_at, now())) + interval '60 seconds' FROM pm_phases
             WHERE run_id = '$(sql_quote "$RID")')
        ORDER BY d.timestamp) TO STDOUT WITH CSV HEADER" \
        > "$CDIR/ina228_samples.csv" || true

    # 2. Monitor-side service logs (crashes, I2C errors, DB write failures)
    docker compose logs --no-color --timestamps ina228 > "$CDIR/ina228-service.log" 2>&1 || true
    docker compose logs --no-color --timestamps postgres | tail -n 200 \
        > "$CDIR/postgres-service.log" 2>&1 || true

    # 3. DUT-side logs: /var/log/pmtest (CSVs, soak logs) and /var/lib/pmtest
    #    (poweroff-wake results recorded at next boot). Owned by root, so tar
    #    runs under sudo -n; falls back to plain tar for permissive images.
    if [ -n "$DEST" ]; then
        if ssh "$DEST" 'sudo -n tar -C /var -cz log/pmtest lib/pmtest 2>/dev/null || tar -C /var -cz log/pmtest lib/pmtest 2>/dev/null' \
                > "$CDIR/dut-pmtest.tgz" 2>>"$LOGDIR/orchestrator.log" \
                && [ -s "$CDIR/dut-pmtest.tgz" ]; then
            olog "collect: DUT logs fetched"
        else
            rm -f "$CDIR/dut-pmtest.tgz"
            olog "!! collect: could not fetch DUT /var/log/pmtest (check ssh + passwordless sudo)"
        fi
    else
        olog "collect: no user@dut given - skipping DUT-side logs"
    fi

    # 4. Bundle
    OUT="results-$RID.tgz"
    tar -C logs -czf "$OUT" "$RID"
    olog "collect: wrote $OUT"
    echo ""
    echo "Transfer back with:"
    echo "  scp $(whoami)@<monitor-ip>:$(pwd)/$OUT ."
    ;;

*)
    usage
    ;;
esac
