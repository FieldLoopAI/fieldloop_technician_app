import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The job id the technician is currently looking at anywhere within
/// `JobDetailScreen` — including screens pushed on top of it for the same
/// job (Estimate, Change Orders, Photo Capture, ...), since those stay
/// covering, not replacing, their `JobDetailScreen` instance. `null` when
/// they're not inside any job at all (Home/History/Profile).
///
/// Set/cleared by `JobDetailScreen`'s own initState/dispose — the exact same
/// bracket `GlobalVoiceService.enterJobScope`/`exitJobScope` already uses
/// for "a job is open" (see that class's doc comment in
/// `global_voice_service_provider.dart`), just exposed as plain state
/// instead of a scoped mic toggle.
///
/// [GlobalNotificationService] reads this to decide whether a realtime
/// approval/decline event needs a system notification at all: if the
/// technician is already looking at the exact job it's about, the existing
/// in-app banner + TTS (`jobStatusNotificationProvider`) already covers it,
/// and a system notification on top would be a redundant duplicate.
final currentlyViewedJobIdProvider = StateProvider<String?>((ref) => null);
