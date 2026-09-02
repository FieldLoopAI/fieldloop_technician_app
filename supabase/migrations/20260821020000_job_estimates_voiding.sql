-- Brings job_estimates up to the same "void an approved record" capability
-- as change_orders (see 20260821010000_change_orders_voiding.sql) — a
-- technician closes out an already-customer-approved estimate as a
-- historical record, with a required reason, rather than editing its
-- line_items/total_amount in place after the customer has already seen and
-- approved specific numbers.
--
-- NOT confirmed already applied — unlike the change_orders voiding columns,
-- no prior conversation context established these columns/policy already
-- exist live. Run this against the Supabase project before relying on
-- JobEstimateController.voidEstimate() actually persisting anything.

alter table job_estimates
  add column voided_at timestamptz,
  add column void_reason text;

-- IMPORTANT — this repo has no tracked migration that created
-- job_estimates' existing technician UPDATE policy (it predates every
-- migration file checked into supabase/migrations/), so its real name and
-- exact USING clause are unknown here. Before applying the policy change
-- below:
--   1. Run: select policyname, qual from pg_policies
--            where tablename = 'job_estimates' and cmd = 'update';
--   2. Replace SOURCE_POLICY_NAME below with whatever that query returns.
--   3. Confirm that policy is the ONLY permissive UPDATE policy on this
--      table for the technician role — if a second, broader permissive
--      policy also exists, Postgres OR-combines permissive RLS policies,
--      so this new restrictive-looking policy would NOT actually stop an
--      edit to a sent/approved/declined/voided row; the broader policy
--      would need dropping (or narrowing) too.
--
-- drop policy "SOURCE_POLICY_NAME" on job_estimates;
--
-- create policy "technician updates own draft or unvoided-approved estimates" on job_estimates
--   for update using (
--     job_id in (select id from jobs where lead_technician_id = get_my_technician_id())
--     and (status = 'draft' or (status = 'approved' and voided_at is null))
--   );
