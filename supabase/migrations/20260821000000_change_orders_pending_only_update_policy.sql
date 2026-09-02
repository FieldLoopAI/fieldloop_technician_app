-- Once a change order has been approved or declined by the customer, a
-- technician must never be able to edit its description or amount in
-- place — the UI already enforces this (ChangeOrdersScreen only renders
-- editable fields for status = 'pending'), but the UI restriction alone is
-- not trustworthy: this policy makes the database itself reject any
-- update attempt on a non-pending change_orders row, regardless of what
-- code path (or bypassed UI) issued it.
--
-- Run this against the Supabase project's SQL editor (or via the Supabase
-- CLI once this repo is linked to a project) — there is no other tracked
-- migration history in this repo to chain it into.
drop policy "technician updates own change orders" on change_orders;

create policy "technician updates own pending change orders" on change_orders
  for update using (
    job_id in (select id from jobs where lead_technician_id = get_my_technician_id())
    and status = 'pending'
  );
