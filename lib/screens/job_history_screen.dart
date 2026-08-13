import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mock_data.dart';
import '../models/mock_job.dart';
import '../providers/job_voice_commands.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/voice_command_registry_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/job_history_timeline.dart';
import 'voice_command_registrar_mixin.dart';

/// Full-screen version of a job's activity timeline, reachable from the
/// "View Full Timeline" action in the job detail screen's History section.
/// Read-only — no screen-specific voice commands of its own — but still a
/// job-scoped screen for voice purposes: it registers the shared
/// `jobLifecycleVoiceCommands` set (arrived/job complete/site condition/
/// troubleshoot) via the same `VoiceCommandRegistrarMixin` pattern every
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

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    // MOCK DATA - replace with Supabase query (history_events table, filtered by job_id)
    final events = mockHistoryByJobId[job.id] ?? const [];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('${job.jobIdPublic} · History'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            final horizontalPadding = isTablet ? constraints.maxWidth * 0.18 : 20.0;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 32),
              child: JobHistoryTimeline(events: events),
            );
          },
        ),
      ),
    );
  }
}
