-- Rollback for 20261024_estimate_write_rules.sql: removes the job_estimates
-- write-rules trigger and its function only. RLS policies, the status CHECK
-- and payment_lock_job_estimates are untouched. Run by hand in the Supabase
-- SQL editor.

drop trigger if exists enforce_estimate_write_rules on public.job_estimates;
drop function if exists public.enforce_estimate_write_rules();
