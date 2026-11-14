-- Insert :n dummy card transactions in one statement.
-- Usage: psql -v n=10000 -f seed.sql
INSERT INTO public.transactions (account_id, merchant, amount, currency, status, created_at, updated_at)
SELECT
    1 + floor(random() * 1000)::int,
    (ARRAY['Albert Heijn', 'Jumbo', 'Bol.com', 'NS', 'Shell', 'Spotify', 'Coolblue', 'IKEA'])[1 + floor(random() * 8)::int],
    round((1 + random() * 250)::numeric, 2),
    (ARRAY['EUR', 'EUR', 'EUR', 'USD', 'GBP'])[1 + floor(random() * 5)::int],
    'pending',
    ts,
    ts
FROM (
    SELECT now() - random() * interval '30 days' AS ts
    FROM generate_series(1, :n)
) s;

SELECT count(*) AS rows_in_postgres FROM public.transactions;
