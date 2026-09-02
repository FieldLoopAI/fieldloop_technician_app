-- Multi-visit departure/billable-hours feature (see visit_provider.dart,
-- job_complete_provider.dart's markComplete, job_detail_screen.dart's
-- visit-monitoring position stream).
--
-- billable_hours is computed client-side by
-- JobCompleteActionController.markComplete (summing every complete
-- gps_arrive-to-gps_depart pair in field_events, rounded to 2 decimals)
-- the moment a job's status is set to 'complete', and saved here. NULL
-- until a job reaches that point.
--
-- No new field_events rows or policy changes are needed for gps_depart:
-- it's inserted through the exact same field_events INSERT path
-- gps_arrive already uses (same table, same job_id/technician_id shape,
-- just a different event_type value), so whatever policy already allows
-- a technician to insert their own gps_arrive rows already allows this.

alter table jobs
  add column billable_hours numeric(10, 2);
