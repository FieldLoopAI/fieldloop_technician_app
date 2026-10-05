-- Module D4: at most ONE "On Site" (gps_arrive) marker per visit.
--
-- The app now stamps every gps_arrive it writes with metadata.visit_seq —
-- 1 for a job's first visit, 2 after its first departure, and so on (see
-- visit_provider.dart's "Duplicate-arrival protection"). Two arrivals for
-- the same visit (geofence + manual "arrived" racing, a stale re-arrival,
-- or a second device) therefore carry the same (job_id, visit_seq) and the
-- second insert is rejected here with unique_violation (23505), which the
-- app treats as "already logged" rather than an error.
--
-- Partial index: rows written before this change have no visit_seq and are
-- left alone, so existing historical duplicates don't block creating it.
-- `->> ... is not null` works whether metadata is json or jsonb.

create unique index if not exists field_events_one_arrive_per_visit
  on public.field_events (job_id, (metadata ->> 'visit_seq'))
  where event_type = 'gps_arrive' and ( metadata ->> 'visit_seq') is not null;
