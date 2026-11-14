-- ClickHouse side of the pipeline: Kafka engine -> materialized view -> ReplacingMergeTree.
-- __KAFKA_BOOTSTRAP__ and __KAFKA_TOPIC__ are replaced by cdc.sh before running.

CREATE DATABASE IF NOT EXISTS cdc;

-- 1. A Kafka "queue" table. It stores nothing. Reading from it consumes the topic.
--    Text columns for amount and timestamps, we parse them in the view.
CREATE TABLE IF NOT EXISTS cdc.transactions_kafka
(
    id              UInt64,
    account_id      UInt32,
    merchant        String,
    amount          String,
    currency        String,
    status          String,
    created_at      String,
    updated_at      String,
    __op            String,
    __lsn           UInt64,
    __source_ts_ms  UInt64,
    __deleted       String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list   = '__KAFKA_BOOTSTRAP__',
    kafka_topic_list    = '__KAFKA_TOPIC__',
    kafka_group_name    = 'clickhouse-cdc',
    kafka_format        = 'JSONEachRow',
    kafka_num_consumers = 1;

-- 2. The real table. ReplacingMergeTree keeps the row with the highest _version
--    per id, and drops it when _is_deleted = 1. The PostgreSQL LSN is a natural
--    version: it only ever goes up.
CREATE TABLE IF NOT EXISTS cdc.transactions
(
    id          UInt64,
    account_id  UInt32,
    merchant    LowCardinality(String),
    amount      Decimal(12, 2),
    currency    LowCardinality(String),
    status      LowCardinality(String),
    created_at  DateTime64(6, 'UTC'),
    updated_at  DateTime64(6, 'UTC'),
    _op         LowCardinality(String),
    _version    UInt64,
    _is_deleted UInt8,
    _source_ts  DateTime64(3, 'UTC'),
    _synced_at  DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY id;

-- 3. The glue: every batch read from Kafka gets transformed and inserted.
--    The OrZero functions matter for deletes: with REPLICA IDENTITY DEFAULT,
--    a delete event only carries the primary key, every other column is null.
CREATE MATERIALIZED VIEW IF NOT EXISTS cdc.transactions_mv TO cdc.transactions AS
SELECT
    id,
    account_id,
    merchant,
    toDecimal64OrZero(amount, 2)                    AS amount,
    currency,
    status,
    parseDateTime64BestEffortOrZero(created_at, 6)  AS created_at,
    parseDateTime64BestEffortOrZero(updated_at, 6)  AS updated_at,
    __op                                            AS _op,
    __lsn                                           AS _version,
    if(__deleted = 'true', 1, 0)                    AS _is_deleted,
    fromUnixTimestamp64Milli(toInt64(__source_ts_ms)) AS _source_ts
FROM cdc.transactions_kafka;
