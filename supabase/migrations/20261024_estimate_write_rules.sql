-- Build 185: write rules for public.job_estimates, enforced in the database
-- for technician logins (the app's own Supabase session).
--
-- Why: RLS today only checks ownership on INSERT and on the UPDATE result
-- (with_check = "own job"), so a technician login could insert an
-- 'approved' estimate, set a draft straight to 'approved', or change an
-- approved estimate's amounts while voiding it. The UPDATE policy's USING
-- clause (own job AND (status = 'draft' OR (status = 'approved' AND
-- voided_at IS NULL))) stays as it is; this trigger adds the rules for what
-- the new row may look like.
--
-- Who is checked: only technician logins, i.e. coalesce(auth.role(), '') in
-- ('authenticated', 'anon'). Exempt:
--   - service_role: the Lambdas (parse-estimate-dictation inserts drafts,
--     send-estimate-sms sets 'sent', approve-estimate sets 'approved'/
--     'declined'). They keep working unchanged.
--   - auth.role() null: the SQL editor / postgres / migrations.
--
-- Rules for technician logins:
--   INSERT  status 'draft'; voided_at and void_reason null; technician_id
--           null or = get_my_technician_id().
--   UPDATE  job_id, technician_id, source_dictation_id, created_at never
--           change, and then by the row's OLD state:
--           draft (not voided)    -> status 'draft' or 'sent'; voided_at and
--                                    void_reason stay null; line_items and
--                                    total_amount may change.
--           approved, not voided  -> only voiding: voided_at set (non-null),
--                                    void_reason may change; status,
--                                    line_items, total_amount identical.
--           sent / declined / voided -> nothing may change.
--   Refusals: ERRCODE P0001, text starting "Estimate rules:".
--
-- What the app writes today, all allowed (lib/providers/job_estimate_provider.dart):
--   saveLineItems  {line_items, total_amount} on a draft
--   sendToCustomer {status: 'sent'} - normally on a row the Lambda already
--                  set to 'sent', which the UPDATE policy's USING clause
--                  filters out first (0 rows, no error, same as today);
--                  if the Lambda's own update failed it is draft -> sent
--   voidEstimate   {voided_at, void_reason} on an unvoided approved row
--   The app never inserts into job_estimates (creation goes through the
--   /estimates/parse Lambda).
--
-- Leaves payment_lock_job_estimates (20261023_payment_freeze.sql) untouched.
-- Both are BEFORE triggers; Postgres fires them in name order, so this one
-- runs first. Either can refuse.
--
-- Requires (both exist live, neither is tracked in supabase/migrations):
--   auth.role()                    Supabase built-in
--   public.get_my_technician_id()  used by every RLS policy in this repo
--
-- APPLY: run this file by hand in the Supabase SQL editor, after
--   20261023_payment_freeze.sql. Then run
--   supabase/tests/20261024_estimate_write_rules_test.sql (it rolls back).
-- ROLLBACK: run supabase/migrations/rollback_20261024_estimate_write_rules.sql
--   (drops this trigger and function only).
--
-- Idempotent. NOT applied by the app or CI.

create or replace function public.enforce_estimate_write_rules()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- Only technician logins are checked; service_role (Lambdas) and a null
  -- role (SQL editor / postgres) pass through.
  if coalesce(auth.role(), '') not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'draft' then
      raise exception 'Estimate rules: a new estimate must be a draft'
        using errcode = 'P0001';
    end if;
    if new.voided_at is not null or new.void_reason is not null then
      raise exception 'Estimate rules: a new estimate cannot be voided'
        using errcode = 'P0001';
    end if;
    if new.technician_id is not null
       and new.technician_id is distinct from public.get_my_technician_id() then
      raise exception 'Estimate rules: an estimate can only be created under your own technician'
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- UPDATE
  if new.job_id is distinct from old.job_id
     or new.technician_id is distinct from old.technician_id
     or new.source_dictation_id is distinct from old.source_dictation_id
     or new.created_at is distinct from old.created_at then
    raise exception 'Estimate rules: the job, technician, source dictation and created time cannot change'
      using errcode = 'P0001';
  end if;

  if old.status = 'draft' and old.voided_at is null then
    if new.status is null or new.status not in ('draft', 'sent') then
      raise exception 'Estimate rules: a draft can only stay a draft or be sent'
        using errcode = 'P0001';
    end if;
    if new.voided_at is not null or new.void_reason is not null then
      raise exception 'Estimate rules: a draft cannot be voided'
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  if old.status = 'approved' and old.voided_at is null then
    if new.voided_at is null then
      raise exception 'Estimate rules: an approved estimate can only be voided'
        using errcode = 'P0001';
    end if;
    -- to_jsonb() so the comparison works whether line_items is json or jsonb.
    if new.status is distinct from old.status
       or to_jsonb(new.line_items) is distinct from to_jsonb(old.line_items)
       or new.total_amount is distinct from old.total_amount then
      raise exception 'Estimate rules: an approved estimate cannot be changed, only voided'
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  raise exception 'Estimate rules: this change is not allowed (the estimate is %)',
    case when old.voided_at is not null then 'voided' else old.status end
    using errcode = 'P0001';
end;
$$;

drop trigger if exists enforce_estimate_write_rules on public.job_estimates;
create trigger enforce_estimate_write_rules
  before insert or update on public.job_estimates
  for each row execute function public.enforce_estimate_write_rules();
