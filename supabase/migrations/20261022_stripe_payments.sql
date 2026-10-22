-- Build 185: Stripe test-mode payments (hosted Checkout, destination charge).
-- Additive and idempotent: safe to run more than once. Existing RLS policies
-- are NOT changed here.
--
-- invoices.payment_status is the payment lifecycle, separate from the
-- existing invoices.status ('draft'/'sent'), which is left alone:
--   unpaid  -> no Checkout session open (the default for every old row)
--   pending -> a Checkout session was created; the invoice is frozen
--   paid    -> the verified stripe-webhook confirmed the full amount
-- Only the stripe-webhook Lambda sets 'paid'. jobs.status is never written.
alter table invoices add column if not exists payment_status text not null default 'unpaid';
alter table invoices add column if not exists stripe_checkout_session_id text;
alter table invoices add column if not exists stripe_payment_intent_id text;
alter table invoices add column if not exists amount_cents integer;
alter table invoices add column if not exists application_fee_cents integer;
alter table invoices add column if not exists paid_at timestamptz;
alter table invoices add column if not exists payment_initiated_at timestamptz;
-- How many Checkout sessions were created for this invoice; the next
-- session's idempotency key is invoice_<id>_<checkout_attempts>.
alter table invoices add column if not exists checkout_attempts integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'invoices_payment_status_check'
  ) then
    alter table invoices
      add constraint invoices_payment_status_check
      check (payment_status in ('unpaid', 'pending', 'paid'));
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'invoices_stripe_checkout_session_id_key'
  ) then
    alter table invoices
      add constraint invoices_stripe_checkout_session_id_key
      unique (stripe_checkout_session_id);
  end if;
end $$;

-- The contractor's Stripe Connect account (acct_...), the destination of
-- the charge. Not a secret.
alter table contractor_financials add column if not exists stripe_account_id text;

-- Webhook dedupe: one row per processed Stripe event id. Only the
-- service-role key (the Lambdas) touches it, so RLS is on with no policies.
create table if not exists stripe_events (
  id text primary key,
  created_at timestamptz default now()
);

alter table stripe_events enable row level security;
