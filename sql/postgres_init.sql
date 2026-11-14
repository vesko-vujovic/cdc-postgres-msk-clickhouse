-- Run as the RDS master user: psql -v dbz_password=... -f postgres_init.sql

-- 1. The source table: plain card transactions.
CREATE TABLE IF NOT EXISTS public.transactions (
    id          BIGSERIAL PRIMARY KEY,
    account_id  INT            NOT NULL,
    merchant    TEXT           NOT NULL,
    amount      NUMERIC(12, 2) NOT NULL,
    currency    CHAR(3)        NOT NULL DEFAULT 'EUR',
    status      TEXT           NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ    NOT NULL DEFAULT now()
);

-- 2. Heartbeat table. Debezium updates it every few seconds so the slot
--    keeps advancing even when nobody touches public.transactions.
CREATE TABLE IF NOT EXISTS public.debezium_heartbeat (
    id INT PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL
);
INSERT INTO public.debezium_heartbeat (id, ts) VALUES (1, now())
ON CONFLICT (id) DO NOTHING;

-- 3. A dedicated, least-privilege user for Debezium.
SELECT format('CREATE ROLE debezium WITH LOGIN PASSWORD %L', :'dbz_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'debezium')
\gexec

GRANT rds_replication TO debezium;          -- RDS role that allows replication slots
GRANT USAGE ON SCHEMA public TO debezium;
GRANT SELECT ON public.transactions TO debezium;   -- needed for the initial snapshot
GRANT SELECT, UPDATE ON public.debezium_heartbeat TO debezium;

-- 4. The publication: which tables go into the logical stream.
--    We create it here so Debezium does not need table ownership.
SELECT 'CREATE PUBLICATION dbz_publication FOR TABLE public.transactions, public.debezium_heartbeat'
WHERE NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'dbz_publication')
\gexec

-- Sanity check
SELECT name, setting FROM pg_settings WHERE name IN ('wal_level', 'max_replication_slots', 'max_slot_wal_keep_size');
