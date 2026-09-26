import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_history_entry.dart';
import '../models/mock_job.dart';
import '../providers/job_history_provider.dart';
import '../providers/job_photos_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/job_history_feed_timeline.dart';
import '../widgets/voice_phase_indicator.dart';
import 'photo_viewer_screen.dart';
import 'voice_command_registrar_mixin.dart';

/// Full-screen version of a job's activity timeline, reachable from the
/// "View Full Timeline" action in the job detail screen's History section.
/// Read-only — no screen-specific voice commands of its own — but still a
/// job-scoped screen for voice purposes: it registers the shared
/// `jobLifecycleVoiceCommands` set (arrived/job complete/site condition/
/// ask a question) via the same `VoiceCommandRegistrarMixin` pattern every
/// other job screen uses, so voice doesn't silently go dead while this
/// screen happens to be the active one. `buildVoiceCommands` returning that
/// list (rather than an empty one) is deliberate for the same reason —
/// dispatching against an empty/no registry is already handled gracefully
/// by `GlobalVoiceService._dispatchCommand` (it just speaks "Sorry, I
/// didn't catch that"), but leaving even the shared commands unavailable
/// here would be an inconsistent gap, not a deliberate choice.
class JobHistoryScreen extends ConsumerStatefulWidget {
  const JobHistoryScreen({super.key, required this.job});

  final MockJob job;

  @override
  ConsumerState<JobHistoryScreen> createState() => _JobHistoryScreenState();
}

class _JobHistoryScreenState extends ConsumerState<JobHistoryScreen>
    with SafeRefDisposal<JobHistoryScreen>, VoiceCommandRegistrarMixin<JobHistoryScreen> {
  @override
  List<VoiceCommand> buildVoiceCommands() => jobLifecycleVoiceCommands(ref, widget.job.id);

  /// Resolves a tapped photo entry against `jobPhotosProvider(jobId)` (the
  /// same signed-URL-bearing `/photos/for-job` data the photo strip/grid on
  /// Job Detail already uses — see `job_photos_provider.dart`) by matching
  /// `s3Key`, then opens it in the existing [PhotoViewerScreen] rather than
  /// duplicating any image-viewing logic here.
  void _openPhoto(JobHistoryEntry entry) {
    final photos = ref.read(jobPhotosProvider(widget.job.id)).valueOrNull ?? const [];
    final match = photos.where((p) => p.s3Key == entry.s3ObjectKey);
    if (match.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("This photo isn't available right now.")),
      );
      return;
    }
    Navigator.of(context).push(FadeSlidePageRoute(builder: (_) => PhotoViewerScreen(photo: match.first)));
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final historyAsync = ref.watch(jobHistoryFeedProvider(job.id));
    // Ensures the photo list this job's photo entries resolve against (see
    // _openPhoto) is loaded/cached ahead of any tap, same provider Job
    // Detail's photo strip watches.
    final photos = ref.watch(jobPhotosProvider(job.id)).valueOrNull ?? const [];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('${job.jobIdPublic} · History'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        actions: const [
          Padding(padding: EdgeInsets.only(right: 14), child: Center(child: VoicePhaseIndicator())),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = responsiveGutter(constraints.maxWidth, min: 20);
            return RefreshIndicator(
              onRefresh: () => ref.refresh(jobHistoryFeedProvider(job.id).future),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 32),
                child: historyAsync.when(
                  data: (entries) => JobHistoryFeedTimeline(entries: entries, onTapPhoto: _openPhoto, photos: photos),
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, _) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text(
                        "Couldn't load history — pull to try again.",
                        style: TextStyle(color: AppColors.neutralGrey, fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
