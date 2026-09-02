-- Recorded for migration history — already applied directly against the
-- Supabase project before this file was added (see conversation context).
--
-- Adds the ability to void an already-approved change order: a technician
-- closes it out as a historical record (with a required reason) rather
-- than editing its description/amount in place, or after a customer has
-- already approved it. Voiding never changes `status` — a voided row is
-- still `status = 'approved'`, just excluded from any running total
-- (`voided_at IS NULL` is the filter for "still active").

alter table change_orders
  add column voided_at timestamptz,
  add column void_reason text;

-- Supersedes the pending-only UPDATE policy from
-- 20260821000000_change_orders_pending_only_update_policy.sql: a
-- technician may now also update a row while it's approved AND not yet
-- voided (to void it) — but never a pending-and-voided combination (not
-- reachable), never an already-voided row (voided_at IS NULL fails), and
-- never a declined row.
drop policy "technician updates own pending change orders" on change_orders;

create policy "technician updates own pending or unvoided change orders" on change_orders
  for update using (
    job_id in (select id from jobs where lead_technician_id = get_my_technician_id())
    and (status = 'pending' or (status = 'approved' and voided_at is null))
  );
