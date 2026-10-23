-- Build 185: card-fee surcharge (invoice-payment STRIPE_PASS_FEE=true).
-- Additive and idempotent: two nullable integer columns on invoices, written
-- only when a Checkout session is created with the surcharge on. Old rows
-- stay null, and the stripe-webhook then checks them exactly as before
-- (amount_total = amount_cents). No RLS, policy or trigger changes.
--
-- Apply BEFORE setting STRIPE_PASS_FEE=true on the invoice-payment Lambda.
--
--   processing_fee_cents  card processing fee charged to the customer
--   charge_total_cents    what the customer paid (amount_cents + processing_fee_cents);
--                         the webhook requires amount_total = this when set
alter table invoices add column if not exists processing_fee_cents integer;
alter table invoices add column if not exists charge_total_cents integer;

-- Rollback (turn STRIPE_PASS_FEE off first):
-- alter table invoices drop column if exists charge_total_cents;
-- alter table invoices drop column if exists processing_fee_cents;
