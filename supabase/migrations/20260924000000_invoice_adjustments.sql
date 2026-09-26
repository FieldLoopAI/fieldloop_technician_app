-- Manual invoice line items (a fee, a discount, ...) added on the Invoice
-- Review screen before generating. Kept separate from job_estimates and
-- change_orders so neither of those customer-approved records is ever
-- rewritten by an invoice-time adjustment. /invoices/preview and
-- /invoices/generate-pdf add these on top of estimate + approved change
-- orders.
--
-- amount is signed: positive = added fee/charge, negative = discount.
create table invoice_adjustments (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  technician_id uuid references technicians(id),
  description text not null check (length(trim(description)) > 0),
  amount numeric(10, 2) not null check (amount <> 0),
  created_at timestamptz not null default now()
);

create index invoice_adjustments_job_id_idx on invoice_adjustments (job_id);

alter table invoice_adjustments enable row level security;

-- Same ownership rule as the change_orders policies: the job's lead
-- technician only.
create policy "technician reads own invoice adjustments" on invoice_adjustments
  for select using (
    job_id in (select id from jobs where lead_technician_id = get_my_technician_id())
  );

create policy "technician adds own invoice adjustments" on invoice_adjustments
  for insert with check (
    job_id in (select id from jobs where lead_technician_id = get_my_technician_id())
  );

create policy "technician removes own invoice adjustments" on invoice_adjustments
  for delete using (
    job_id in (select id from jobs where lead_technician_id = get_my_technician_id())
  );

alter table invoices
  add column adjustments_total numeric(10, 2) not null default 0;
