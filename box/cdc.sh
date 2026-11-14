#!/usr/bin/env bash
# Demo helper that lives on the ClickHouse box at /opt/cdc/cdc.sh (also on PATH as `cdc`).
# Run it through `make <target>` from your laptop, or directly inside an SSM session.
set -euo pipefail

CDC_HOME=/opt/cdc
SQL="$CDC_HOME/sql"

set -a
# shellcheck disable=SC1091
source "$CDC_HOME/env"
set +a

psql_q() { psql -X -v ON_ERROR_STOP=1 "$@"; }
ch() { clickhouse-client "$@"; }

wait_ready() {
  until [ -f "$CDC_HOME/.ready" ]; do echo "waiting for bootstrap to finish..."; sleep 5; done
  until pg_isready -q; do echo "waiting for PostgreSQL..."; sleep 5; done
  until ch -q "SELECT 1" >/dev/null 2>&1; do echo "waiting for ClickHouse..."; sleep 5; done
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  init)
    wait_ready
    echo "== PostgreSQL: table, heartbeat, debezium user, publication"
    psql_q -v dbz_password="$DBZ_PASSWORD" -f "$SQL/postgres_init.sql"
    echo "== ClickHouse: Kafka engine, ReplacingMergeTree, materialized view"
    sed -e "s|__KAFKA_BOOTSTRAP__|$KAFKA_BOOTSTRAP|g" -e "s|__KAFKA_TOPIC__|$KAFKA_TOPIC|g" \
      "$SQL/clickhouse_init.sql" | ch --multiquery
    echo "== seeding 10000 transactions (these arrive through the initial snapshot)"
    psql_q -v n=10000 -f "$SQL/seed.sql"
    ;;

  seed)   # cdc seed [rows]
    psql_q -v n="${1:-10000}" -f "$SQL/seed.sql"
    ;;

  churn)  # cdc churn [rows]  -> updates, refunds and deletes
    psql_q -v n="${1:-1000}" -f "$SQL/churn.sql"
    ;;

  compare)
    echo "== PostgreSQL"
    psql_q -c "SELECT count(*) AS rows, sum(amount) AS total FROM public.transactions;"
    echo "== ClickHouse (FINAL = deduplicated view, deletes removed)"
    ch -q "SELECT count() AS rows, sum(amount) AS total FROM cdc.transactions FINAL FORMAT PrettyCompact"
    echo "== ClickHouse raw versions stored (before merges clean them up)"
    ch -q "SELECT _op, count() FROM cdc.transactions GROUP BY _op ORDER BY _op FORMAT PrettyCompact"
    ;;

  latency)
    ch -q "SELECT count() AS rows,
                  quantile(0.5)(dateDiff('millisecond', _source_ts, _synced_at)) AS p50_ms,
                  quantile(0.99)(dateDiff('millisecond', _source_ts, _synced_at)) AS p99_ms
           FROM cdc.transactions
           WHERE _synced_at > now() - INTERVAL 5 MINUTE AND _op != 'r'
           FORMAT PrettyCompact"
    ;;

  slot)
    psql_q -f "$SQL/slot_lag.sql"
    ;;

  flood)  # cdc flood [rows]  -> big write burst, then show what the slot is holding
    rows="${1:-1000000}"
    echo "== writing $rows rows, then updating all of them"
    psql_q -v n="$rows" -f "$SQL/seed.sql"
    psql_q -c "UPDATE public.transactions SET updated_at = now();"
    psql_q -f "$SQL/slot_lag.sql"
    ;;

  drop-slot)  # last resort when a dead slot is about to fill the disk
    psql_q -c "SELECT pg_drop_replication_slot('debezium_slot');"
    ;;

  top-merchants)
    ch -q "SELECT merchant, count() AS tx, sum(amount) AS total
           FROM cdc.transactions FINAL
           WHERE status = 'settled'
           GROUP BY merchant ORDER BY total DESC FORMAT PrettyCompact"
    ;;

  *)
    cat <<'EOF'
usage: cdc <command>
  init                 create table, user, publication, ClickHouse objects, seed 10k rows
  seed [n]             insert n transactions (default 10000)
  churn [n]            settle n, refund n/10, delete n/20
  compare              row count and total in PostgreSQL vs ClickHouse
  latency              end-to-end lag for rows synced in the last 5 minutes
  slot                 WAL retained by each replication slot
  flood [n]            big write burst, then slot status (default 1,000,000)
  drop-slot            drop debezium_slot (frees WAL, loses CDC position)
  top-merchants        example analytical query in ClickHouse
EOF
    ;;
esac
