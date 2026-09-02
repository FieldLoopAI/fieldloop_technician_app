import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/job_history_entry.dart';

/// The unified, chronological activity feed for a job — GPS arrivals,
/// photos, dictations, and estimate events — read straight from the
/// `job_history_feed` view through the technician's own authenticated
/// Supabase session (RLS-scoped, same direct-read pattern as
/// `job_dictations_provider.dart` and `job_estimate_provider.dart` — no
/// Lambda needed for a plain read). Ordered oldest-first so
/// [JobHistoryScreen]'s timeline reads top-to-bottom in the order things
/// actually happened.
final jobHistoryFeedProvider = FutureProvider.family<List<JobHistoryEntry>, String>((ref, jobId) async {
  debugPrint('HISTORY: fetching job_history_feed for job $jobId...');
  final rows = await Supabase.instance.client
      .from('job_history_feed')
      .select()
      .eq('job_id', jobId)
      .order('ts', ascending: true);
  debugPrint('HISTORY: job_history_feed returned ${rows.length} row(s) for job $jobId');
  return rows.map((row) => JobHistoryEntry.fromJson(row)).toList();
});
