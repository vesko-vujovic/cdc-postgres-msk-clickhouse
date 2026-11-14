-- Simulate normal life on a transactions table: settle, refund, delete.
-- Usage: psql -v n=1000 -f churn.sql

BEGIN;

-- Most pending transactions get settled.
UPDATE public.transactions
SET status = 'settled', updated_at = now()
WHERE id IN (
    SELECT id FROM public.transactions
    WHERE status = 'pending'
    ORDER BY random()
    LIMIT :n
);

-- Some settled ones get refunded.
UPDATE public.transactions
SET status = 'refunded', amount = -amount, updated_at = now()
WHERE id IN (
    SELECT id FROM public.transactions
    WHERE status = 'settled'
    ORDER BY random()
    LIMIT GREATEST(:n / 10, 1)
);

-- A few get deleted (think: test transactions cleaned up).
DELETE FROM public.transactions
WHERE id IN (
    SELECT id FROM public.transactions
    ORDER BY random()
    LIMIT GREATEST(:n / 20, 1)
);

COMMIT;

SELECT status, count(*), sum(amount) FROM public.transactions GROUP BY status ORDER BY status;
