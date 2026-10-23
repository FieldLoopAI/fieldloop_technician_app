-- Build 185: money freeze. Once a job's payment is pending or paid, its
-- estimate (line items, total, status/approval, void), change orders
-- (create, edit, approve/decline, void) and invoice adjustments can't be
-- inserted, updated or deleted. Photos, notes (job_dictations), field
-- events, time on site and job status are NOT covered.
--
-- The rule mirrors the app and backend exactly (lib/models/invoice_payment.dart
-- isInvoicePaymentFrozen / generate-invoice-pdf's freeze check): locked while
-- any invoice of the job has payment_status 'pending' or 'paid'. There is no
-- session-expiry column: an expired Checkout session unlocks when the
-- stripe-webhook (checkout.session.expired) resets the invoice to 'unpaid'.
-- invoices has no void column, so every invoice row counts.
--
-- Triggers (not RLS policies) because the Lambdas that write these tables
-- (create-change-order, approve-estimate, approve-change-order,
-- parse-estimate-dictation, send-estimate-sms) use the service role, which
-- bypasses RLS but not triggers. Nothing here touches invoices, stripe_events
-- or any read policy, so the stripe-webhook still marks invoices paid/unpaid.
--
-- Additive and idempotent. NOT applied by the app or CI — run by hand.

create or replace function public.job_payment_locked(p_job_id uuid)
returns boolean
language sql
stable
security definer -- invoices may be hidden from the caller by RLS
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.invoices i
    where i.job_id = p_job_id
      and i.payment_status in ('pending', 'paid')
  );
$$;

revoke all on function public.job_payment_locked(uuid) from public;
grant execute on function public.job_payment_locked(uuid) to authenticated, service_role;

create or replace function public.reject_write_when_payment_locked()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (tg_op in ('UPDATE', 'DELETE') and public.job_payment_locked(old.job_id))
     or (tg_op in ('INSERT', 'UPDATE') and public.job_payment_locked(new.job_id)) then
    raise exception 'Payment started - invoice is locked'
      using errcode = 'P0001',
            detail = format('%s on %s refused: the job''s payment is pending or paid', tg_op, tg_table_name);
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists payment_lock_job_estimates on public.job_estimates;
create trigger payment_lock_job_estimates
  before insert or update or delete on public.job_estimates
  for each row execute function public.reject_write_when_payment_locked();

drop trigger if exists payment_lock_change_orders on public.change_orders;
create trigger payment_lock_change_orders
  before insert or update or delete on public.change_orders
  for each row execute function public.reject_write_when_payment_locked();

drop trigger if exists payment_lock_invoice_adjustments on public.invoice_adjustments;
create trigger payment_lock_invoice_adjustments
  before insert or update or delete on public.invoice_adjustments
  for each row execute function public.reject_write_when_payment_locked();

-- Note: deleting a job whose payment is pending or paid now fails too (its
-- invoice_adjustments cascade-delete is refused by the trigger).

-- Verification (read-only, or rolled back):
-- 1) Which jobs are locked right now:
--    select distinct job_id, public.job_payment_locked(job_id) as locked
--    from public.invoices where payment_status in ('pending', 'paid');
-- 2) The three triggers are installed:
--    select tgname, tgrelid::regclass from pg_trigger
--    where tgname like 'payment_lock_%' and not tgisinternal order by 1;
-- 3) A no-op write on a locked job is refused (nothing is kept):
--    begin;
--    update public.change_orders set description = description
--    where job_id = '<a locked job uuid>';   -- expect: Payment started - invoice is locked
--    rollback;

-- Rollback:
-- drop trigger if exists payment_lock_invoice_adjustments on public.invoice_adjustments;
-- drop trigger if exists payment_lock_change_orders on public.change_orders;
-- drop trigger if exists payment_lock_job_estimates on public.job_estimates;
-- drop function if exists public.reject_write_when_payment_locked();
-- drop function if exists public.job_payment_locked(uuid);
