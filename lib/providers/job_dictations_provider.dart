import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The `job_dictations.command_type` values this app writes — a closed enum
/// (not a free-form String) so every call site is forced to pick one of the
/// values the backend actually recognizes. `jobCompleteNote` exists in the
/// table but isn't produced by any voice command yet.
enum DictationCommandType { prepareEstimate, siteCondition, jobCompleteNote }

extension on DictationCommandType {
  String get dbValue {
    switch (this) {
      case DictationCommandType.prepareEstimate:
        return 'prepare_estimate';
      case DictationCommandType.siteCondition:
        return 'site_condition';
      case DictationCommandType.jobCompleteNote:
        return 'job_complete_note';
    }
  }
}

/// Writes a verbatim dictation [transcript] to `job_dictations`, straight
/// through the technician's own authenticated Supabase session — RLS scopes
/// rows to the technician's own jobs, so (per backend context) no Lambda is
/// needed here, unlike photo uploads which go through one for S3 access
/// (see `job_photos_provider.dart`'s `uploadPhotoBytes`).
///
/// [transcript] is stored exactly as captured — no correction or
/// reformatting — per the app's single-verbatim-capture rule (see
/// `GlobalVoiceService.captureDictation`). Returns the new row's `id` — for
/// a `prepare_estimate` dictation this is what the caller hands straight to
/// `/estimates/parse` (see `JobEstimateController.parseDictation` in
/// `job_estimate_provider.dart`) to turn this verbatim transcript into a
/// structured estimate. Throws on failure; callers decide what to tell the
/// technician.
Future<String> insertJobDictation({
  required String jobId,
  required String technicianId,
  required DictationCommandType commandType,
  required String transcript,
}) async {
  debugPrint(
    'DICTATION: inserting job_dictations (command_type=${commandType.dbValue}) for job $jobId...',
  );
  try {
    final row = await Supabase.instance.client
        .from('job_dictations')
        .insert({
          'job_id': jobId,
          'technician_id': technicianId,
          'command_type': commandType.dbValue,
          'transcript': transcript,
          'captured_at': DateTime.now().toUtc().toIso8601String(),
          'status': 'captured',
        })
        .select('id')
        .single();
    debugPrint('DICTATION: job_dictations insert succeeded for job $jobId (id=${row['id']})');
    return row['id'].toString();
  } catch (e, stackTrace) {
    debugPrint('DICTATION ERROR (insert): $e\n$stackTrace');
    rethrow;
  }
}

/// The verbatim transcript for a single `job_dictations` row, straight from
/// the technician's own RLS-scoped session (same read pattern as
/// `job_estimate_provider.dart`'s `jobEstimateProvider`) — powers the
/// Estimate screen's "original dictation" expandable section, so a
/// technician can cross-check the AI-parsed line items/total against
/// exactly what they said (small extraction errors are expected — see
/// `JobEstimateController.parseDictation`). `null` if the dictation row
/// can't be found or has no transcript.
final dictationTranscriptProvider = FutureProvider.family<String?, String>((ref, dictationId) async {
  debugPrint('DICTATION: fetching transcript for dictation $dictationId...');
  final row = await Supabase.instance.client
      .from('job_dictations')
      .select('transcript')
      .eq('id', dictationId)
      .maybeSingle();
  return row?['transcript'] as String?;
});
