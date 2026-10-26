-- Test for supabase/migrations/20261024_estimate_write_rules.sql.
-- Run in the Supabase SQL editor AFTER applying that migration. Everything
-- happens inside BEGIN ... ROLLBACK: nothing is saved, and because nothing
-- commits, no realtime event reaches the app.
--
-- HOW TO READ THE RESULT: each test prints PASS or FAIL (a NOTICE, and a
-- row in the results select near the end). The script then ENDS WITH A
-- DELIBERATE ERROR whose text is the full PASS/FAIL list, so the results
-- show even in an editor that only displays the last statement, and the
-- error also guarantees the rollback. "Estimate write rules test results"
-- in that error is the expected ending, not a problem.
--
-- STEP 1 (read only, run on its own first): find the two values to fill in.
--   Pick a row with payment_locked = false (the payment-lock trigger would
--   otherwise refuse every write on the job).
--
--   select t.auth_user_id, t.id as technician_id, j.id as job_id, j.status as job_status,
--          public.job_payment_locked(j.id) as payment_locked
--   from public.jobs j
--   join public.technicians t on t.id = j.lead_technician_id
--   where t.auth_user_id is not null
--   order by public.job_payment_locked(j.id)
--   limit 20;
--
--   get_my_technician_id() is NOT tracked in supabase/migrations (it only
--   appears in policies). To see its live definition:
--   select pg_get_functiondef('public.get_my_technician_id()'::regprocedure);
--
-- STEP 2: paste the two values into the FILL IN block below, run the file.

begin;

-- ============================ FILL IN ============================
create temp table _t_params on commit drop as
select
  '98195467-e35a-4a48-a9eb-3d172a775b12'::uuid as auth_user_id, -- <<< FILL IN technicians.auth_user_id
  '312cebd6-f18d-4f77-9507-d80f24649b9d'::uuid as job_id;       -- <<< FILL IN a job led by that technician, payment_locked = false
-- =================================================================

create temp table _t_results (at timestamptz default clock_timestamp(), test text, result text, detail text)
  on commit drop;
create temp table _t_rows (name text primary key, id uuid) on commit drop;
grant all on _t_params, _t_results, _t_rows to authenticated, service_role;

-- PASS/FAIL recorder.
create function pg_temp.t_record(p_test text, p_ok boolean, p_detail text) returns void
language plpgsql as $$
begin
  insert into _t_results (test, result, detail) values (p_test, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
  raise notice '%', format('%s  %s%s', case when p_ok then 'PASS' else 'FAIL' end, p_test,
    coalesce(' — ' || p_detail, ''));
end;
$$;

create function pg_temp.t_id(p_name text) returns uuid
language sql as $$ select id from _t_rows where name = p_name $$;

-- ---------------------------------------------------------------
-- Setup (postgres, exempt): check the inputs, create one fixture row per
-- test on the test job.
-- ---------------------------------------------------------------
do $$
declare
  p record;
  v_tech uuid;
  v_id uuid;
  r text[];
begin
  select * into p from _t_params;
  select id into v_tech from public.technicians where auth_user_id = p.auth_user_id;
  if v_tech is null then
    raise exception 'SETUP: no technician has that auth_user_id - fill in the FILL IN block';
  end if;
  if not exists (select 1 from public.jobs where id = p.job_id and lead_technician_id = v_tech) then
    raise exception 'SETUP: that job is not led by that technician';
  end if;
  if public.job_payment_locked(p.job_id) then
    raise exception 'SETUP: that job is payment-locked - pick one with payment_locked = false';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgname = 'enforce_estimate_write_rules' and tgrelid = 'public.job_estimates'::regclass
  ) then
    raise exception 'SETUP: apply supabase/migrations/20261024_estimate_write_rules.sql first';
  end if;

  foreach r slice 1 in array array[
    ['draft_amounts', 'draft'],
    ['draft_send', 'draft'],
    ['draft_approve', 'draft'],
    ['draft_tech', 'draft'],
    ['approved_amounts', 'approved'],
    ['approved_void_amounts', 'approved'],
    ['approved_void', 'approved'],
    ['approved_status', 'approved'],
    ['sent_edit', 'sent'],
    ['sent_service', 'sent'],
    ['approved_postgres', 'approved']
  ] loop
    insert into public.job_estimates (job_id, technician_id, source_dictation_id, line_items, total_amount, status)
    values (p.job_id, v_tech, null, '[{"description": "Rules test line", "amount": 100}]', 100, r[2])
    returning id into v_id;
    insert into _t_rows values (r[1], v_id);
  end loop;
end $$;

-- ---------------------------------------------------------------
-- Technician login (authenticated): rules enforced.
-- ---------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', auth_user_id, 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', auth_user_id::text, true),
       set_config('request.jwt.claim.role', 'authenticated', true)
from _t_params;
set local role authenticated;

do $$
begin
  perform pg_temp.t_record('setup: technician login simulated (auth.role() = authenticated, get_my_technician_id() set)',
    coalesce(auth.role(), '') = 'authenticated' and public.get_my_technician_id() is not null,
    format('auth.role()=%s', coalesce(auth.role(), 'null')));
end $$;

-- 1. insert as draft OK
do $$
declare p record;
begin
  select * into p from _t_params;
  insert into public.job_estimates (job_id, technician_id, line_items, total_amount, status)
  values (p.job_id, public.get_my_technician_id(), '[{"description": "Tech draft", "amount": 50}]', 50, 'draft');
  perform pg_temp.t_record('technician: insert as draft is allowed', true, null);
exception when others then
  perform pg_temp.t_record('technician: insert as draft is allowed', false, sqlerrm);
end $$;

-- 2. insert as approved refused
do $$
declare p record;
begin
  select * into p from _t_params;
  insert into public.job_estimates (job_id, technician_id, line_items, total_amount, status)
  values (p.job_id, public.get_my_technician_id(), '[{"description": "Tech approved", "amount": 50}]', 50, 'approved');
  perform pg_temp.t_record('technician: insert as approved is refused', false, 'the insert was allowed');
exception when others then
  perform pg_temp.t_record('technician: insert as approved is refused', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- 2b. insert under another technician refused
do $$
declare p record;
begin
  select * into p from _t_params;
  insert into public.job_estimates (job_id, technician_id, line_items, total_amount, status)
  values (p.job_id, gen_random_uuid(), '[{"description": "Other tech", "amount": 50}]', 50, 'draft');
  perform pg_temp.t_record('technician: insert under another technician_id is refused', false, 'the insert was allowed');
exception when others then
  perform pg_temp.t_record('technician: insert under another technician_id is refused', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- 3. draft edit amounts OK
do $$
declare n int; v_total numeric;
begin
  update public.job_estimates
  set line_items = '[{"description": "Edited line", "amount": 250}]', total_amount = 250
  where id = pg_temp.t_id('draft_amounts');
  get diagnostics n = row_count;
  select total_amount into v_total from public.job_estimates where id = pg_temp.t_id('draft_amounts');
  perform pg_temp.t_record('technician: draft line items / total can be edited', n = 1 and v_total = 250,
    format('rows=%s total=%s', n, v_total));
exception when others then
  perform pg_temp.t_record('technician: draft line items / total can be edited', false, sqlerrm);
end $$;

-- 3b. draft: technician_id cannot change
do $$
declare n int;
begin
  update public.job_estimates set technician_id = gen_random_uuid() where id = pg_temp.t_id('draft_tech');
  get diagnostics n = row_count;
  perform pg_temp.t_record('technician: technician_id cannot change', false, format('allowed, rows=%s', n));
exception when others then
  perform pg_temp.t_record('technician: technician_id cannot change', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- 4. draft -> sent OK
do $$
declare n int; v_status text;
begin
  update public.job_estimates set status = 'sent' where id = pg_temp.t_id('draft_send');
  get diagnostics n = row_count;
  select status into v_status from public.job_estimates where id = pg_temp.t_id('draft_send');
  perform pg_temp.t_record('technician: draft -> sent is allowed', n = 1 and v_status = 'sent',
    format('rows=%s status=%s', n, v_status));
exception when others then
  perform pg_temp.t_record('technician: draft -> sent is allowed', false, sqlerrm);
end $$;

-- 5. draft -> approved refused
do $$
declare n int;
begin
  update public.job_estimates set status = 'approved' where id = pg_temp.t_id('draft_approve');
  get diagnostics n = row_count;
  perform pg_temp.t_record('technician: draft -> approved is refused', false, format('allowed, rows=%s', n));
exception when others then
  perform pg_temp.t_record('technician: draft -> approved is refused', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- 6. approved: amounts change refused (without voiding)
do $$
declare n int;
begin
  update public.job_estimates set total_amount = 999 where id = pg_temp.t_id('approved_amounts');
  get diagnostics n = row_count;
  perform pg_temp.t_record('technician: approved amount change is refused', false, format('allowed, rows=%s', n));
exception when others then
  perform pg_temp.t_record('technician: approved amount change is refused', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- 6b. approved: amounts change refused even while voiding
do $$
declare n int;
begin
  update public.job_estimates
  set voided_at = now(), void_reason = 'rules test', line_items = '[{"description": "Sneaky", "amount": 1}]', total_amount = 1
  where id = pg_temp.t_id('approved_void_amounts');
  get diagnostics n = row_count;
  perform pg_temp.t_record('technician: approved amounts cannot change while voiding', false, format('allowed, rows=%s', n));
exception when others then
  perform pg_temp.t_record('technician: approved amounts cannot change while voiding', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- 7. approved void OK (exactly what the app's voidEstimate sends)
do $$
declare n int; v_voided timestamptz;
begin
  update public.job_estimates set voided_at = now(), void_reason = 'rules test' where id = pg_temp.t_id('approved_void');
  get diagnostics n = row_count;
  select voided_at into v_voided from public.job_estimates where id = pg_temp.t_id('approved_void');
  perform pg_temp.t_record('technician: approved estimate can be voided', n = 1 and v_voided is not null,
    format('rows=%s', n));
exception when others then
  perform pg_temp.t_record('technician: approved estimate can be voided', false, sqlerrm);
end $$;

-- 8. approved status change refused
do $$
declare n int;
begin
  update public.job_estimates set status = 'declined' where id = pg_temp.t_id('approved_status');
  get diagnostics n = row_count;
  perform pg_temp.t_record('technician: approved status change is refused', false, format('allowed, rows=%s', n));
exception when others then
  perform pg_temp.t_record('technician: approved status change is refused', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- 9. sent edit refused. The UPDATE policy's USING clause hides a 'sent'
-- row from technician updates (0 rows); if that policy ever changes, the
-- trigger refuses instead. Either is a PASS.
do $$
declare n int; v_total numeric;
begin
  update public.job_estimates set total_amount = 999 where id = pg_temp.t_id('sent_edit');
  get diagnostics n = row_count;
  select total_amount into v_total from public.job_estimates where id = pg_temp.t_id('sent_edit');
  perform pg_temp.t_record('technician: sent estimate cannot be edited', n = 0 and v_total = 100,
    format('rows=%s (filtered by the RLS UPDATE policy) total=%s', n, v_total));
exception when others then
  perform pg_temp.t_record('technician: sent estimate cannot be edited', sqlerrm like 'Estimate rules:%', sqlerrm);
end $$;

-- ---------------------------------------------------------------
-- service_role (the Lambdas): exempt.
-- ---------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true),
       set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claim.role', 'service_role', true);
set local role service_role;

-- 10. service role can set sent -> approved (what approve-estimate does)
do $$
declare n int; v_status text;
begin
  update public.job_estimates set status = 'approved' where id = pg_temp.t_id('sent_service') and status = 'sent';
  get diagnostics n = row_count;
  select status into v_status from public.job_estimates where id = pg_temp.t_id('sent_service');
  perform pg_temp.t_record('service_role: sent -> approved is allowed', n = 1 and v_status = 'approved',
    format('auth.role()=%s rows=%s status=%s', coalesce(auth.role(), 'null'), n, v_status));
exception when others then
  perform pg_temp.t_record('service_role: sent -> approved is allowed', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------
-- postgres / SQL editor (no JWT role): exempt.
-- ---------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '{}', true),
       set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claim.role', '', true);

-- 11. postgres role unaffected: may change anything on an approved row
do $$
declare n int; v_total numeric;
begin
  update public.job_estimates set total_amount = 12345, status = 'declined' where id = pg_temp.t_id('approved_postgres');
  get diagnostics n = row_count;
  select total_amount into v_total from public.job_estimates where id = pg_temp.t_id('approved_postgres');
  perform pg_temp.t_record('postgres: unaffected by the rules', n = 1 and v_total = 12345,
    format('current_user=%s auth.role()=%s rows=%s', current_user, coalesce(nullif(auth.role(), ''), 'null'), n));
exception when others then
  perform pg_temp.t_record('postgres: unaffected by the rules', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------
-- Results, then the deliberate error that shows them and rolls back.
-- ---------------------------------------------------------------
select result, test, detail from _t_results order by at;

do $$
declare
  v_list text;
  v_pass int;
  v_fail int;
begin
  select count(*) filter (where result = 'PASS'), count(*) filter (where result = 'FAIL'),
         string_agg(format('%s  %s%s', result, test, coalesce(' — ' || detail, '')), E'\n' order by at)
  into v_pass, v_fail, v_list
  from _t_results;
  raise exception E'Estimate write rules test results (everything rolled back): % PASS, % FAIL\n%',
    v_pass, v_fail, v_list;
end $$;

rollback;
