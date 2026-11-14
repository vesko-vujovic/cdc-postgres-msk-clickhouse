-- How much WAL is each replication slot forcing PostgreSQL to keep?
SELECT
    slot_name,
    active,
    wal_status,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))         AS retained_wal,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS unconfirmed_changes,
    pg_size_pretty(safe_wal_size)                                               AS safe_wal_size
FROM pg_replication_slots;
