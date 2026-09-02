import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/job_photo.dart';
import '../models/mock_job.dart';
import '../models/mock_line_item.dart';
import '../providers/arrival_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/currently_viewed_job_provider.dart';
import '../providers/estimate_invoice_providers.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/job_complete_provider.dart';
import '../providers/job_dictations_provider.dart';
import '../providers/job_history_provider.dart';
import '../providers/job_photos_provider.dart';
import '../providers/job_runtime_provider.dart';
import '../providers/job_voice_commands.dart';
import '../providers/jobs_provider.dart';
import '../providers/permission_providers.dart';
import '../providers/safe_ref_disposal.dart';
import '../providers/visit_provider.dart';
import '../providers/visit_tracking_service.dart';
import '../providers/voice_command_registry_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../widgets/job_history_feed_timeline.dart';
import '../widgets/job_photo_thumbnail.dart';
import '../widgets/pending_upload_badge.dart';
import '../widgets/permission_card.dart';
import '../widgets/primary_button.dart';
import '../widgets/status_pill.dart';
import '../widgets/tap_scale.dart';
import '../widgets/voice_phase_indicator.dart';
import 'change_orders_screen.dart';
import 'estimate_screen.dart';
import 'invoice_review_screen.dart';
import 'invoice_screen.dart';
import 'job_history_screen.dart';
import 'photo_capture_screen.dart';
import 'photo_viewer_screen.dart';
import 'voice_assistant_screen.dart';
import 'voice_command_registrar_mixin.dart';

enum _DetailTab { estimate, changeOrders, invoice, history }

String _formatTime(DateTime dt) {
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final suffix = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $suffix';
}

String _formatElapsed(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = two(d.inHours);
  final minutes = two(d.inMinutes.remainder(60));
  final seconds = two(d.inSeconds.remainder(60));
  return '$hours:$minutes:$seconds';
}

double _sum(List<MockLineItem> items) =>
    items.fold<double>(0, (total, item) => total + item.amount);

class JobDetailScreen extends ConsumerStatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<JobDetailScreen> createState() => _JobDetailScreenState();
}

/// Geofence radius for automatic arrival detection: 150 feet, in meters.
const double _geofenceRadiusMeters = 45.0;

class _JobDetailScreenState extends ConsumerState<JobDetailScreen>
    with SafeRefDisposal<JobDetailScreen>, VoiceCommandRegistrarMixin<JobDetailScreen> {
  _DetailTab _tab = _DetailTab.estimate;
  Timer? _ticker;
  StreamSubscription<Position>? _positionSub;

  // Captured in initState (see SafeRefDisposal) rather than read fresh in
  // dispose() — by the time dispose() runs this widget's Element is already
  // detached, so a fresh ref.read() there isn't safe.
  late final GlobalVoiceService _voiceService;

  // Same capture-early-for-safe-dispose-use reasoning as [_voiceService]
  // above. [VisitTrackingService] (`visit_tracking_service.dart`) is the
  // app-wide singleton that now owns the actual departure/re-arrival
  // position stream + debounce timer — this screen only calls its
  // enterJobScope/exitJobScope at the exact same trigger points it already
  // calls [_voiceService]'s, so tracking for this job survives the app
  // being minimized instead of living and dying with this State object.
  late final VisitTrackingService _visitTrackingService;

  // Same capture-early-for-safe-dispose-use reasoning as [_voiceService]
  // above — see [SafeRefDisposal.capture]'s doc comment.
  late final StateController<String?> _viewedJobIdController;

  // Belt-and-suspenders alongside `mounted`: set synchronously as the very
  // first thing dispose() does, so every guard below reads it consistently
  // even if something re-enters mid-teardown. `mounted` alone is the same
  // check Flutter itself uses for "has dispose() run", but the geofencing
  // chain below crosses several real async gaps (network calls, a geolocator
  // permission check, a native position-stream callback that can fire after
  // cancellation was requested but before it's taken effect) — cheap enough
  // to double up the check at each one rather than trust a single check
  // taken several lines/awaits earlier.
  bool _disposed = false;

  // Whether this job was still in an active status (scheduled/en_route/
  // on_site) as of when the screen loaded — used ONLY to decide whether to
  // start the wake-word mic at all (see initState below). This is
  // deliberately a one-time snapshot, not the general "is voice available
  // right now" check — see [_voiceEligible] for that (reactive, since a
  // job can transition to 'complete' mid-session — see `job_complete`'s
  // `ref.listen` in [build]).
  late final bool _initialVoiceEligible;

  /// Whether voice commands/mic are available RIGHT NOW — re-evaluated on
  /// every read, unlike [_initialVoiceEligible]. A job pulled up from
  /// History (complete/invoiced/paid/closed) is a read-only view: no
  /// wake-word mic, no voice commands (see [buildVoiceCommands] and the
  /// appBar's read-only badge) — and the same is now true the instant a
  /// job transitions to 'complete' mid-session via `job_complete`, not
  /// just when freshly opened from History.
  bool get _voiceEligible => activeJobStatuses.contains(ref.read(jobRuntimeProvider(widget.jobId)).status);

  @override
  void initState() {
    super.initState();
    _voiceService = capture((ref) => ref.read(globalVoiceServiceProvider.notifier));
    _visitTrackingService = capture((ref) => ref.read(visitTrackingServiceProvider));
    _viewedJobIdController = capture((ref) => ref.read(currentlyViewedJobIdProvider.notifier));
    final job = capture((ref) => ref.read(jobByIdProvider(widget.jobId)));
    _initialVoiceEligible = job != null && activeJobStatuses.contains(job.status);
    // Ticks the labor-clock display once a second while the card is visible.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      // Job Detail is the single entry point of "a job is open" — it stays
      // mounted (just covered) for as long as the technician is anywhere
      // inside this job (Photo Capture, Estimate, ...), so its own
      // initState/dispose is what brackets when the wake-word mic should
      // actually be listening — and, same bracket, when
      // `currentlyViewedJobIdProvider` should report this job as open (see
      // that provider's doc comment). Deferred to a post-frame callback for
      // the same reason VoiceCommandRegistrarMixin._registerCommands() is:
      // writing provider state synchronously from initState() is unsafe
      // while the widget tree is still building.
      _viewedJobIdController.state = widget.jobId;
      if (_initialVoiceEligible) {
        _voiceService.enterJobScope();
        // Same trigger point as the voice enterJobScope() call just above —
        // see [VisitTrackingService]'s doc comment for why departure/
        // re-arrival tracking now lives there instead of this State's own
        // fields.
        _visitTrackingService.enterJobScope(widget.jobId);
      } else {
        // HARDENING (completed-job read-only audit) — GlobalVoiceService's
        // `_jobScopeActive` is a single global flag, not scoped per screen
        // instance: `enterJobScope`/`exitJobScope` are only ever called
        // from a JobDetailScreen's own initState/dispose, never from
        // `VoiceCommandRegistrarMixin`'s didPushNext/didPop (those only
        // touch the command REGISTRY, not the recognizer itself — see that
        // mixin's doc comment). So if a technician somehow reaches this
        // screen while some OTHER job's scope is still active (e.g. a
        // previous JobDetailScreen instance that got covered rather than
        // popped/disposed), simply not calling enterJobScope() here is not
        // enough — that stale scope would keep the mic listening
        // regardless, with this screen offering zero commands for it to
        // match against but the recognizer still genuinely running.
        // Explicitly exiting scope here — not just skipping entry —
        // guarantees a finished job's screen actively turns voice off
        // rather than merely declining to turn it on, matching the
        // original "fully read-only, zero recognizer activity" design.
        debugPrint(
          'VOICE: job ${widget.jobId} is not active-status at load (finished job, read-only) — '
          'explicitly exiting voice scope defensively, not just skipping entry',
        );
        _voiceService.exitJobScope();
        _visitTrackingService.exitJobScope();
      }
      _maybeStartGeofencing();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _positionSub?.cancel();
    _voiceService.exitJobScope();
    _visitTrackingService.exitJobScope();
    // Only clear if we're still the job "in view" — guards against a rare
    // teardown-order edge case where a newer JobDetailScreen instance (a
    // different job) has already overwritten this since this one's own
    // postFrameCallback set it.
    if (_viewedJobIdController.state == widget.jobId) {
      Future(() {
        _viewedJobIdController.state = null;
      });
    }
    super.dispose();
  }

  /// `didPopNext` (from `VoiceCommandRegistrarMixin`'s `RouteAware`
  /// conformance, already subscribed for voice-command registration) also
  /// fires the moment this screen becomes visible again after whatever was
  /// covering it (Photo Capture, Estimate, ...) gets popped — the exact
  /// signal needed to know when to check whether this job's photo URLs
  /// (signed for 1 hour, see `/photos/for-job`) might have gone stale
  /// while the technician was elsewhere. `super.didPopNext()` still runs
  /// the mixin's own voice-command re-registration; this only adds the
  /// photo refresh alongside it.
  @override
  void didPopNext() {
    super.didPopNext();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      ref.read(jobPhotosProvider(widget.jobId).notifier).refreshIfStale();
    });
  }

  /// This screen never starts the recognizer, only the wake-word LOOP
  /// itself (see `enterJobScope`/`exitJobScope` above) — see `RootShell` /
  /// `GlobalVoiceService` for recognizer initialization. Independently of
  /// that, it only offers these commands while it's the
  /// active/visible screen (handled by `VoiceCommandRegistrarMixin`) AND
  /// the job is still in an active status — see [_voiceEligible]. A job
  /// pulled up from History registers nothing here.
  @override
  List<VoiceCommand> buildVoiceCommands() {
    if (!_voiceEligible) return const [];
    return [
      openCameraVoiceCommand(
        ref: ref,
        jobId: widget.jobId,
        navigate: () => Navigator.of(
          context,
        ).push(FadeSlidePageRoute(builder: (_) => PhotoCaptureScreen(jobId: widget.jobId))),
      ),
      prepareEstimateVoiceCommand(ref: ref, jobId: widget.jobId),
      changeOrderVoiceCommand(ref: ref, jobId: widget.jobId),
      generateInvoiceVoiceCommand(
        ref: ref,
        jobId: widget.jobId,
        navigate: (preview) => Navigator.of(context).push(
          FadeSlidePageRoute(builder: (_) => InvoiceReviewScreen(jobId: widget.jobId, preview: preview)),
        ),
      ),
      ...jobLifecycleVoiceCommands(ref, widget.jobId),
    ];
  }

  /// Kicks off automatic GPS arrival detection for this job, unless it's
  /// already been arrived at (manually or automatically) — checked against
  /// `field_events`, the same source of truth the "not arrived" card uses.
  Future<void> _maybeStartGeofencing() async {
    if (!mounted || _disposed) return;
    final job = ref.read(jobByIdProvider(widget.jobId));
    if (job == null) return;

    debugPrint('GEOFENCE: checking for an existing gps_arrive event for job ${job.id}...');
    final alreadyArrivedAt = await ref.read(arrivalEventProvider(job.id).future);
    // Real async gap above (a Supabase query) — re-check immediately before
    // the next thing that touches `ref`/this screen's state, not just at
    // the top of this method.
    if (!mounted || _disposed) return;
    if (alreadyArrivedAt != null) {
      debugPrint('GEOFENCE: job ${job.id} already arrived, skipping automatic detection');
      return;
    }

    await _startGeofencing(job);
  }

  Future<void> _startGeofencing(MockJob job) async {
    if (!mounted || _disposed || _positionSub != null) return;

    debugPrint('GEOFENCE: checking location permission for job ${job.id}...');
    final permission = await Geolocator.checkPermission();
    // Real async gap above (a platform channel round-trip) — re-check
    // before anything further, even though nothing between here and the
    // listen() call below touches `ref` directly.
    if (!mounted || _disposed) return;
    debugPrint('GEOFENCE: permission status is $permission for job ${job.id}');

    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      debugPrint(
        'GEOFENCE: location permission not granted for job ${job.id}, automatic arrival detection unavailable',
      );
      return;
    }
    if (permission == LocationPermission.whileInUse) {
      debugPrint(
        'GEOFENCE: only "while in use" permission granted for job ${job.id} — attempting foreground detection only',
      );
    }

    if (job.serviceLat == null || job.serviceLng == null) {
      debugPrint('GEOFENCE: job ${job.id} has no service_lat/service_lng on file, skipping automatic detection');
      return;
    }

    debugPrint('GEOFENCE: starting position stream for job ${job.id} (accuracy=high, distanceFilter=10m)...');
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen(
      (position) => _onPositionUpdate(job, position),
      onError: (Object e) => debugPrint('GEOFENCE ERROR (position stream) for job ${job.id}: $e'),
    );
  }

  Future<void> _stopGeofencing() async {
    final sub = _positionSub;
    if (sub == null) return;
    _positionSub = null;
    debugPrint('GEOFENCE: stopping position stream for job ${widget.jobId}');
    await sub.cancel();
  }

  /// Called from the position stream's own callback — a native platform
  /// event that can already be in flight when `dispose()` requests
  /// cancellation (`StreamSubscription.cancel()` doesn't retroactively stop
  /// an event that already started delivering), so every `ref` touch below
  /// is guarded fresh rather than trusting the single check at the top. The
  /// whole body is additionally wrapped in try/catch: `ref.read()` throws a
  /// clean, catchable `StateError` if this widget is ever truly gone by the
  /// time a guarded line runs (a native callback's timing relative to
  /// Flutter's own frame pipeline isn't something this code controls) —
  /// this is the backstop so that throws as a silent, logged no-op instead
  /// of an unhandled Future error.
  Future<void> _onPositionUpdate(MockJob job, Position position) async {
    if (!mounted || _disposed) return;
    try {
      debugPrint(
        'GEOFENCE: position update received '
        '(${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}) for job ${job.id}',
      );

      final distanceMeters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        job.serviceLat!,
        job.serviceLng!,
      );
      debugPrint('GEOFENCE: distance to job site is ${distanceMeters.toStringAsFixed(1)}m for job ${job.id}');

      if (distanceMeters > _geofenceRadiusMeters) return;

      debugPrint(
        'GEOFENCE: within ${_geofenceRadiusMeters.toStringAsFixed(0)}m geofence, triggering automatic arrival for job ${job.id}',
      );
      // Stop first so a second position update arriving while the arrival
      // write is in flight can't fire a duplicate trigger.
      await _stopGeofencing();
      if (!mounted || _disposed) return;

      final alreadyArrivedAt = await ref.read(arrivalEventProvider(job.id).future);
      if (!mounted || _disposed) return;
      if (alreadyArrivedAt != null) {
        debugPrint('GEOFENCE: job ${job.id} already has a gps_arrive event, skipping automatic trigger');
        return;
      }

      final technicianId = ref.read(authControllerProvider).value?.id;
      if (technicianId == null) {
        debugPrint('GEOFENCE ERROR: no signed-in technician id, cannot log automatic arrival for job ${job.id}');
        return;
      }

      if (!mounted || _disposed) return;
      await ref
          .read(arrivalActionProvider(job.id).notifier)
          .markArrived(technicianId: technicianId, source: 'automatic');
    } catch (e, stackTrace) {
      debugPrint('GEOFENCE ERROR (position update) for job ${job.id}: $e\n$stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(jobByIdProvider(widget.jobId));
    if (job == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: AppColors.surface, elevation: 0),
        body: const Center(child: Text('Job not found')),
      );
    }

    // Covers the manual "I've Arrived" tap, which logs arrival independently
    // of this screen's position stream — stop listening the moment any
    // arrival (manual or automatic) lands.
    ref.listen(arrivalEventProvider(widget.jobId), (previous, next) {
      if (next.valueOrNull != null) _stopGeofencing();
    });

    // The reactive half of [_voiceEligible]/`job_complete`: a job leaving
    // an active status mid-session (in practice, only `markComplete()`
    // synced by `JobCompleteActionController` after a real Supabase write
    // succeeds) must flip this screen into its read-only, voice-disabled
    // view immediately — not just the next time it's freshly opened from
    // History. Deferred to a post-frame callback since this listener can
    // fire mid-build (same "provider write during the build phase is
    // unsafe" hazard `VoiceCommandRegistrarMixin._registerCommands`'s doc
    // comment explains); `refreshVoiceCommands()` un/re-registers this
    // screen's commands (empty, once no longer eligible) and
    // `exitJobScope()` actually stops the mic — see both methods' doc
    // comments for why both are needed, not just one.
    ref.listen<JobRuntimeState>(jobRuntimeProvider(widget.jobId), (previous, next) {
      final wasActive = previous == null || activeJobStatuses.contains(previous.status);
      final isActiveNow = activeJobStatuses.contains(next.status);
      if (!wasActive || isActiveNow) return;
      debugPrint(
        'JOB DETAIL: job ${widget.jobId} left active status '
        '(${previous?.status} -> ${next.status}) — exiting voice scope live',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _disposed) return;
        refreshVoiceCommands();
        _voiceService.exitJobScope();
      });
    });

    // Voice commands are active on this screen too, not just the dedicated
    // Voice Assistant screen — the recognizer itself is a single global
    // service (see RootShell/GlobalVoiceService); this screen only offers
    // its own commands (see buildVoiceCommands) while it's active.
    final cameraMic = ref.watch(cameraMicProvider);

    final runtime = ref.watch(jobRuntimeProvider(widget.jobId));
    final photos = ref.watch(jobPhotosProvider(widget.jobId)).valueOrNull ?? const [];
    final estimateItems = ref.watch(estimateLineItemsProvider(widget.jobId));
    final changeOrders = ref.watch(changeOrdersProvider(widget.jobId));
    final estimateStatus = ref.watch(estimateStatusProvider(widget.jobId));
    final invoiceStatus = ref.watch(invoiceStatusProvider(widget.jobId));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(job.jobIdPublic),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        actions: [
          if (!_voiceEligible)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: Center(child: _ReadOnlyBadge()),
            )
          else if (cameraMic.micGranted)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(child: VoicePhaseIndicator()),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            final horizontalPadding = isTablet ? constraints.maxWidth * 0.14 : 16.0;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _JobHeaderCard(job: job, status: runtime.status),
                  const SizedBox(height: 16),
                  _ArrivalCard(jobId: widget.jobId, runtime: runtime),
                  if (runtime.status == JobStatus.onSite) ...[
                    const SizedBox(height: 12),
                    _VisitControlsCard(jobId: widget.jobId),
                  ],
                  if (_voiceEligible) ...[
                    const SizedBox(height: 16),
                    _VoiceSessionButton(jobId: widget.jobId),
                    const SizedBox(height: 10),
                    _AskQuestionButton(jobId: widget.jobId),
                  ],
                  const SizedBox(height: 24),
                  _PhotoStrip(jobId: widget.jobId, photos: photos, canAddPhotos: _voiceEligible),
                  const SizedBox(height: 28),
                  _TabSelector(selected: _tab, onChanged: (tab) => setState(() => _tab = tab)),
                  const SizedBox(height: 16),
                  _TabContent(
                    tab: _tab,
                    job: job,
                    estimateItems: estimateItems,
                    changeOrders: changeOrders,
                    estimateStatus: estimateStatus,
                    invoiceStatus: invoiceStatus,
                    voiceEligible: _voiceEligible,
                  ),
                  const SizedBox(height: 28),
                  _JobCompleteButton(jobId: widget.jobId, runtime: runtime),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _JobHeaderCard extends StatelessWidget {
  const _JobHeaderCard({required this.job, required this.status});

  final MockJob job;
  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.customerName,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.textDark),
                ),
              ),
              StatusPill(status: status.wireValue),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 16, color: AppColors.neutralGreyLight),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  job.serviceAddress,
                  style: const TextStyle(fontSize: 13.5, color: AppColors.neutralGrey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${job.tradeCategory} · ${job.description}',
            style: const TextStyle(fontSize: 13.5, color: AppColors.neutralGrey),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.05, end: 0, duration: 300.ms);
  }
}

class _ArrivalCard extends ConsumerWidget {
  const _ArrivalCard({required this.jobId, required this.runtime});

  final String jobId;
  final JobRuntimeState runtime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (runtime.status) {
      case JobStatus.scheduled:
      case JobStatus.enRoute:
        return _NotArrivedCard(jobId: jobId);

      case JobStatus.onSite:
        final elapsed = DateTime.now().difference(runtime.arrivedAt!);
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: AppColors.headerGradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(color: AppColors.primaryGreen.withValues(alpha: 0.3), blurRadius: 18, offset: const Offset(0, 8)),
            ],
          ),
          child: Row(
            children: [
              Container(
                    width: 14,
                    height: 14,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  )
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .fadeIn(duration: 700.ms)
                  .then()
                  .fadeOut(duration: 700.ms),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'On Site',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Arrived at ${_formatTime(runtime.arrivedAt!)} · Labor clock running',
                      style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              Text(
                _formatElapsed(elapsed),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: 60.ms, duration: 300.ms);

      case JobStatus.complete:
      case JobStatus.invoiced:
      case JobStatus.paid:
      case JobStatus.closed:
        final total = runtime.completedAt != null && runtime.arrivedAt != null
            ? runtime.completedAt!.difference(runtime.arrivedAt!)
            : Duration.zero;
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.primaryGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: AppColors.primaryGreen, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Job complete',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
                    ),
                    Text(
                      'Time on site: ${_formatElapsed(total)}',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.neutralGrey),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: 60.ms, duration: 300.ms);
    }
  }
}

/// Manual fallback for the multi-visit departure/re-arrival system — only
/// rendered while `runtime.status == JobStatus.onSite` (see [build]),
/// i.e. only once the job has had its first arrival and isn't complete
/// yet. Watches [openVisitProvider] (the same source of truth the
/// automatic debounce state machine in `_JobDetailScreenState` uses) to
/// show exactly one of:
///  - "Leaving Site" — a visit is currently open; lets the technician log
///    a departure themselves instead of waiting on the 3-minute automatic
///    debounce, matching the same manual-fallback pattern as "I've
///    Arrived" (`_NotArrivedCard`).
///  - "Back on Site" — no visit is currently open (departed mid-job); lets
///    the technician log a fresh arrival themselves instead of waiting for
///    automatic re-entry detection.
/// Both log the exact same `field_events` rows the automatic path does
/// (see [VisitActionController]) — tapping either immediately flips this
/// card to the other, since [openVisitProvider] is invalidated on every
/// write.
class _VisitControlsCard extends ConsumerWidget {
  const _VisitControlsCard({required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final openVisit = ref.watch(openVisitProvider(jobId));
    final visitAction = ref.watch(visitActionProvider(jobId));
    final errorMessage = visitAction.hasError ? visitAction.error.toString() : null;

    // Loading (first read) or an error resolving current visit state:
    // nothing meaningful to offer yet rather than guessing which button to
    // show — the position-stream state machine doesn't depend on this UI
    // read at all, so automatic detection is unaffected either way.
    return openVisit.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (arrivedAt) {
        final isOpen = arrivedAt != null;

        Future<void> handleTap() async {
          final technicianId = ref.read(authControllerProvider).value?.id;
          if (technicianId == null) {
            debugPrint('DEPARTURE ERROR: no signed-in technician id, cannot log manual visit change for job $jobId');
            return;
          }
          final controller = ref.read(visitActionProvider(jobId).notifier);
          if (isOpen) {
            await controller.logDeparture(technicianId: technicianId);
          } else {
            await controller.logReArrival(technicianId: technicianId);
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: visitAction.isLoading ? null : () => handleTap(),
              icon: Icon(isOpen ? Icons.logout_rounded : Icons.touch_app_rounded, size: 18),
              label: Text(isOpen ? 'Leaving Site' : 'Back on Site'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryGreenDark,
                side: const BorderSide(color: AppColors.primaryGreen),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage,
                style: const TextStyle(color: AppColors.error, fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ],
          ],
        ).animate().fadeIn(delay: 60.ms, duration: 300.ms);
      },
    );
  }
}

/// The "not yet arrived" arrival card, aware of location permission status.
/// The manual "I've Arrived" button always works (per the geofencing
/// fallback requirement); it's shown as a small secondary link when
/// background location is granted (automatic detection is the primary
/// path), and promoted to a full, primary button whenever it isn't — i.e.
/// whenever automatic detection can't be relied on.
class _NotArrivedCard extends ConsumerWidget {
  const _NotArrivedCard({required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arrivalEvent = ref.watch(arrivalEventProvider(jobId));
    final alreadyArrivedAt = arrivalEvent.valueOrNull;

    // field_events is the source of truth for "has this job already been
    // arrived at" — checked independently of the (ephemeral) runtime status
    // so a stale/out-of-sync status never leaves the button showing for a
    // job that's already been arrived at.
    if (alreadyArrivedAt != null) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderGrey),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.primaryGreen, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Arrived — ${_formatTime(alreadyArrivedAt)}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDark,
                ),
              ),
            ),
          ],
        ),
      ).animate().fadeIn(delay: 60.ms, duration: 300.ms);
    }

    final arrivalAction = ref.watch(arrivalActionProvider(jobId));
    final arrivalErrorMessage = arrivalAction.hasError ? arrivalAction.error.toString() : null;

    Future<void> handleArrive() async {
      final technicianId = ref.read(authControllerProvider).value?.id;
      if (technicianId == null) {
        debugPrint('ARRIVAL ERROR: no signed-in technician id, cannot log arrival');
        return;
      }
      await ref.read(arrivalActionProvider(jobId).notifier).markArrived(technicianId: technicianId);
    }

    final location = ref.watch(locationProvider);
    final askShown = ref.watch(locationAskShownProvider);
    final nudgeDismissed = ref.watch(locationAlwaysNudgeDismissedProvider);

    final showAsk = location.checked && !location.foregroundGranted && !askShown;

    if (showAsk) {
      return PermissionCard(
        icons: const [Icons.location_on_rounded],
        title: 'Automatic Arrival Detection',
        message:
            'FieldLoop uses your location to automatically detect when you arrive '
            'at a job site, so labor time is tracked accurately without manual '
            'clock-ins.',
        actionLabel: 'Continue',
        actionIcon: Icons.arrow_forward_rounded,
        onAction: () async {
          await ref.read(locationProvider.notifier).requestForeground();
          // The permission request is async — this widget (and its `ref`)
          // can be gone by the time it resolves if the technician navigated
          // away mid-request.
          if (!context.mounted) return;
          ref.read(locationAskShownProvider.notifier).state = true;
        },
      );
    }

    final backgroundGranted = location.backgroundGranted;
    final foregroundOnly = location.foregroundGranted && !backgroundGranted;
    final notGranted = !location.foregroundGranted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderGrey),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.location_searching_rounded, color: AppColors.neutralGrey),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Not yet arrived',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                backgroundGranted
                    ? 'Geofence will detect arrival automatically.'
                    : "Automatic arrival detection unavailable — tap when you arrive.",
                style: const TextStyle(fontSize: 12.5, color: AppColors.neutralGreyLight),
              ),
              const SizedBox(height: 12),
              if (backgroundGranted)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: arrivalAction.isLoading ? null : () => handleArrive(),
                    icon: const Icon(Icons.touch_app_outlined, size: 16),
                    label: const Text("Not detected? Tap to confirm I've arrived"),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.neutralGrey,
                      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                )
              else
                PrimaryButton(
                  label: "I've Arrived",
                  icon: Icons.touch_app_rounded,
                  isLoading: arrivalAction.isLoading,
                  onPressed: () => handleArrive(),
                ),
              if (arrivalErrorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDECEC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFF8C9C9)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          arrivalErrorMessage,
                          style: const TextStyle(
                            color: AppColors.error,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (notGranted) ...[
          const SizedBox(height: 12),
          PermissionCard(
            compact: true,
            icons: const [Icons.location_on_rounded],
            title: 'Automatic detection unavailable',
            message: location.whenInUse.isPermanentlyDenied
                ? 'Location access is turned off. Enable it in Settings for automatic arrival detection.'
                : 'Location access was declined. Enable it for automatic arrival detection.',
            actionLabel: location.whenInUse.isPermanentlyDenied ? 'Open Settings' : 'Enable Location',
            onAction: location.whenInUse.isPermanentlyDenied
                ? openAppSettings
                : () => ref.read(locationProvider.notifier).requestForeground(),
          ),
        ] else if (foregroundOnly && !nudgeDismissed) ...[
          const SizedBox(height: 12),
          _BackgroundLocationNudge(),
        ],
      ],
    ).animate().fadeIn(delay: 60.ms, duration: 300.ms);
  }
}

/// A dismissible, optional nudge to upgrade from "While Using" to "Always"
/// location access, so geofenced arrival keeps working if the technician
/// switches to another app. Declining leaves the app fully usable — this is
/// strictly an enhancement, never a requirement.
class _BackgroundLocationNudge extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.my_location_rounded, color: AppColors.primaryGreenDark, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enable background arrival detection?',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textDark),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Allow location "Always" so arrival is still detected if you switch to another app.',
                  style: TextStyle(fontSize: 12, color: AppColors.neutralGrey, height: 1.35),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => ref.read(locationProvider.notifier).requestBackground(),
                      child: const Text(
                        'Enable',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.primaryGreenDark),
                      ),
                    ),
                    const SizedBox(width: 20),
                    GestureDetector(
                      onTap: () => ref.read(locationAlwaysNudgeDismissedProvider.notifier).state = true,
                      child: const Text(
                        'Not now',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.neutralGrey),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 250.ms);
  }
}

/// Shown in place of [VoiceListeningIndicator] on a finished-status job
/// (see `_JobDetailScreenState._voiceEligible`) — makes it visually clear
/// voice is intentionally off here, not just silently broken.
class _ReadOnlyBadge extends StatelessWidget {
  const _ReadOnlyBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.neutralGreyLight.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline_rounded, size: 12, color: AppColors.neutralGrey),
          const SizedBox(width: 5),
          Text(
            'Completed — read only',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.neutralGrey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _VoiceSessionButton extends StatelessWidget {
  const _VoiceSessionButton({required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: () => Navigator.of(
        context,
      ).push(FadeSlidePageRoute(builder: (_) => VoiceAssistantScreen(jobId: jobId))),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          color: AppColors.textDark,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 16, offset: const Offset(0, 8)),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(color: AppColors.primaryGreen, shape: BoxShape.circle),
                  child: const Icon(Icons.mic_rounded, color: Colors.white, size: 18),
                )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .scale(begin: const Offset(1, 1), end: const Offset(1.15, 1.15), duration: 900.ms),
            const SizedBox(width: 12),
            const Text(
              'Start Voice Session',
              style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tap fallback for the "help"/"ask"/"question" voice trigger — runs the
/// exact same [handleAskQuestionCommand] the voice trigger does (greeting,
/// then listen, then the troubleshooting Lambda round-trip), same fallback
/// principle as every other voice feature in this app (see
/// `handleDictationCommand`'s "Dictate Estimate" tap button, above).
class _AskQuestionButton extends ConsumerWidget {
  const _AskQuestionButton({required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => handleAskQuestionCommand(ref: ref, jobId: jobId),
        icon: const Icon(Icons.help_outline_rounded, size: 18),
        label: const Text('Ask a Question'),
        style: _outlineButtonStyle,
      ),
    );
  }
}

class _PhotoStrip extends ConsumerWidget {
  const _PhotoStrip({required this.jobId, required this.photos, required this.canAddPhotos});

  final String jobId;
  final List<JobPhoto> photos;

  // Same status check as `_JobDetailScreenState._voiceEligible` (a
  // finished job — complete/invoiced/paid/closed — is read-only for ANY
  // new data, not just voice commands): existing photos still render
  // below in view-only mode either way, this only controls whether the
  // "Add Photos" tile — the entry point into PhotoCaptureScreen — appears
  // at all.
  final bool canAddPhotos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Photos (${photos.length})',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark),
            ),
            const Spacer(),
            PendingUploadBadge(jobId: jobId),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: canAddPhotos ? photos.length + 1 : photos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              if (index == photos.length) {
                return TapScale(
                  onTap: () => Navigator.of(
                    context,
                  ).push(FadeSlidePageRoute(builder: (_) => PhotoCaptureScreen(jobId: jobId))),
                  child: Container(
                    width: 84,
                    decoration: BoxDecoration(
                      color: AppColors.primaryGreen.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.3), style: BorderStyle.solid),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo_rounded, color: AppColors.primaryGreenDark, size: 22),
                        SizedBox(height: 6),
                        Text(
                          'Add Photos',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primaryGreenDark),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              }

              final photo = photos[index];
              return TapScale(
                onTap: () => Navigator.of(
                  context,
                ).push(FadeSlidePageRoute(builder: (_) => PhotoViewerScreen(photo: photo))),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 84,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        JobPhotoThumbnail(photo: photo),
                        if (photo.status == JobPhotoStatus.uploading)
                          Container(
                            color: Colors.black.withValues(alpha: 0.35),
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            ),
                          ),
                        if (photo.status == JobPhotoStatus.failed)
                          Container(
                            color: Colors.black.withValues(alpha: 0.45),
                            alignment: Alignment.center,
                            child: const Icon(Icons.error_outline_rounded, color: Colors.white, size: 20),
                          ),
                        if (photo.status == JobPhotoStatus.queuedOffline)
                          Container(
                            color: Colors.black.withValues(alpha: 0.35),
                            alignment: Alignment.center,
                            child: const Icon(Icons.cloud_upload_outlined, color: Colors.white, size: 18),
                          ),
                      ],
                    ),
                  ),
                ),
              ).animate(delay: (60 * index).ms).fadeIn(duration: 300.ms).scale(begin: const Offset(0.9, 0.9), end: const Offset(1, 1));
            },
          ),
        ),
      ],
    );
  }
}

class _TabSelector extends StatelessWidget {
  const _TabSelector({required this.selected, required this.onChanged});

  final _DetailTab selected;
  final ValueChanged<_DetailTab> onChanged;

  static const _labels = {
    _DetailTab.estimate: 'Estimate',
    _DetailTab.changeOrders: 'Change Orders',
    _DetailTab.invoice: 'Invoice',
    _DetailTab.history: 'Job History',
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _DetailTab.values.map((tab) {
          final isSelected = tab == selected;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(_labels[tab]!),
              selected: isSelected,
              onSelected: (_) => onChanged(tab),
              selectedColor: AppColors.primaryGreen,
              backgroundColor: AppColors.surface,
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : AppColors.neutralGrey,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
              side: BorderSide(color: isSelected ? AppColors.primaryGreen : AppColors.borderGrey),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TabContent extends ConsumerWidget {
  const _TabContent({
    required this.tab,
    required this.job,
    required this.estimateItems,
    required this.changeOrders,
    required this.estimateStatus,
    required this.invoiceStatus,
    required this.voiceEligible,
  });

  final _DetailTab tab;
  final MockJob job;
  final List<MockLineItem> estimateItems;
  final List<MockLineItem> changeOrders;
  final EstimateStatus estimateStatus;
  final InvoiceStatus invoiceStatus;

  // Mirrors `_JobDetailScreenState._voiceEligible` — gates the "Dictate
  // Estimate" tap fallback below, since it activates the mic
  // (`handleDictationCommand`) exactly like a voice command would, and a
  // finished-status job viewed from History is read-only.
  final bool voiceEligible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (tab) {
      case _DetailTab.estimate:
        return _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (estimateItems.isEmpty)
                const Text('No estimate yet', style: TextStyle(color: AppColors.neutralGrey))
              else ...[
                for (final item in estimateItems) _LineItemRow(item: item),
                const Divider(height: 24),
                _TotalRow(label: 'Estimate total', amount: _sum(estimateItems)),
              ],
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(FadeSlidePageRoute(builder: (_) => EstimateScreen(jobId: job.id))),
                style: _outlineButtonStyle,
                child: const Text('View Full Estimate'),
              ),
              if (voiceEligible) ...[
                const SizedBox(height: 10),
                // Tap fallback for the "prepare estimate" voice command —
                // runs the exact same handleDictationCommand the voice
                // handler does (see job_voice_commands.dart), same fallback
                // principle as every other voice feature in this app.
                // Wrapped in its own Consumer since _TabContent is a plain
                // StatelessWidget with no `ref` of its own.
                Consumer(
                  builder: (context, ref, _) => OutlinedButton.icon(
                    onPressed: () => handleDictationCommand(
                      ref: ref,
                      jobId: job.id,
                      commandType: DictationCommandType.prepareEstimate,
                      prompt: 'Go ahead, describe the work and price',
                      savedLabel: 'Estimate note saved.',
                    ),
                    icon: const Icon(Icons.mic_rounded, size: 18),
                    label: const Text('Dictate Estimate'),
                    style: _outlineButtonStyle,
                  ),
                ),
              ],
            ],
          ),
        );

      case _DetailTab.changeOrders:
        return _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (changeOrders.isEmpty)
                const Text('No change orders yet', style: TextStyle(color: AppColors.neutralGrey))
              else ...[
                for (final item in changeOrders) _LineItemRow(item: item),
                const Divider(height: 24),
                _TotalRow(label: 'Change orders total', amount: _sum(changeOrders)),
              ],
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(FadeSlidePageRoute(builder: (_) => ChangeOrdersScreen(jobId: job.id))),
                style: _outlineButtonStyle,
                child: const Text('View Change Orders'),
              ),
              if (voiceEligible) ...[
                const SizedBox(height: 10),
                // Tap fallback for the "change order" voice command — runs
                // the exact same handleChangeOrderCommand the voice trigger
                // does, same fallback principle as "Dictate Estimate" above.
                OutlinedButton.icon(
                  onPressed: () => handleChangeOrderCommand(ref: ref, jobId: job.id),
                  icon: const Icon(Icons.mic_rounded, size: 18),
                  label: const Text('Add Change Order'),
                  style: _outlineButtonStyle,
                ),
              ],
            ],
          ),
        );

      case _DetailTab.invoice:
        final total = _sum(estimateItems) + _sum(changeOrders);
        return _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    'Payment status',
                    style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textDark),
                  ),
                  const Spacer(),
                  _InvoiceStatusBadge(status: invoiceStatus),
                ],
              ),
              const SizedBox(height: 14),
              _TotalRow(label: 'Invoice total', amount: total),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(FadeSlidePageRoute(builder: (_) => InvoiceScreen(jobId: job.id))),
                style: _outlineButtonStyle,
                child: const Text('View Full Invoice'),
              ),
              if (voiceEligible) ...[
                const SizedBox(height: 10),
                // Tap fallback for the "FieldLoop, generate invoice" voice
                // command — runs the exact same handleGenerateInvoiceCommand
                // the voice trigger does (real /invoices/preview Lambda call,
                // spoken summary, then InvoiceReviewScreen), same fallback
                // principle as "Dictate Estimate"/"Add Change Order" above.
                // Distinct from "View Full Invoice" above, which is the
                // older mock payment-status flow (estimate_invoice_providers.dart).
                OutlinedButton.icon(
                  onPressed: () => handleGenerateInvoiceCommand(
                    ref: ref,
                    jobId: job.id,
                    navigate: (preview) => Navigator.of(context).push(
                      FadeSlidePageRoute(builder: (_) => InvoiceReviewScreen(jobId: job.id, preview: preview)),
                    ),
                  ),
                  icon: const Icon(Icons.mic_rounded, size: 18),
                  label: const Text('Generate Invoice'),
                  style: _outlineButtonStyle,
                ),
              ],
            ],
          ),
        );

      case _DetailTab.history:
        // Same `job_history_feed` provider the full JobHistoryScreen reads
        // (see job_history_provider.dart) — one shared cache, so this
        // preview and the full timeline are always showing the exact same
        // underlying rows, just sliced differently: newest-first and capped
        // to a handful here, oldest-first and complete there.
        final historyAsync = ref.watch(jobHistoryFeedProvider(job.id));
        return _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              historyAsync.when(
                data: (entries) {
                  final preview = entries.reversed.take(5).toList();
                  return JobHistoryFeedTimeline(entries: preview);
                },
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      "Couldn't load history.",
                      style: TextStyle(color: AppColors.neutralGrey, fontSize: 14),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(FadeSlidePageRoute(builder: (_) => JobHistoryScreen(job: job))),
                  icon: const Icon(Icons.open_in_full_rounded, size: 15),
                  label: const Text('View Full Timeline'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.primaryGreenDark),
                ),
              ),
            ],
          ),
        );
    }
  }
}

final _outlineButtonStyle = OutlinedButton.styleFrom(
  foregroundColor: AppColors.primaryGreenDark,
  side: const BorderSide(color: AppColors.primaryGreen),
  padding: const EdgeInsets.symmetric(vertical: 14),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
);

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 6)),
        ],
      ),
      child: child,
    ).animate().fadeIn(duration: 250.ms);
  }
}

class _LineItemRow extends StatelessWidget {
  const _LineItemRow({required this.item});

  final MockLineItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.description,
              style: const TextStyle(fontSize: 13.5, color: AppColors.textDark),
            ),
          ),
          Text(
            '\$${item.amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textDark),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.label, required this.amount});

  final String label;
  final double amount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.textDark)),
        const Spacer(),
        Text(
          '\$${amount.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.primaryGreenDark),
        ),
      ],
    );
  }
}

class _InvoiceStatusBadge extends StatelessWidget {
  const _InvoiceStatusBadge({required this.status});

  final InvoiceStatus status;

  @override
  Widget build(BuildContext context) {
    late final Color fg;
    late final Color bg;
    late final String label;
    switch (status) {
      case InvoiceStatus.notYetInvoiced:
        fg = AppColors.neutralGrey;
        bg = const Color(0xFFF3F4F6);
        label = 'Not Yet Invoiced';
      case InvoiceStatus.pending:
        fg = AppColors.amber;
        bg = const Color(0xFFFEF3C7);
        label = 'Pending';
      case InvoiceStatus.paid:
        fg = AppColors.primaryGreenDark;
        bg = const Color(0xFFE3F5E9);
        label = 'Paid';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// Tap fallback for the `job_complete` voice command
/// (`job_voice_commands.dart`'s `_handleJobComplete`, the same logic this
/// mirrors) — the same evidence check, the same confirm-before-writing
/// rule, but as an in-card expansion instead of speaking/listening: tapping
/// "Mark Job Complete" checks for job_estimates/photo evidence, then
/// expands THIS SAME widget in place to show the matching warning/simple
/// prompt plus Confirm/Cancel — never a modal dialog. That pattern (inline
/// expansion, not `showDialog`/`AlertDialog`) is deliberate: a dialog here
/// previously raced this app's realtime subscriptions during the dialog's
/// own pop/teardown and crashed with a `'_dependents.isEmpty'` assertion
/// (see `ChangeOrdersScreen`'s void action, the first place this was fixed
/// and the pattern this copies).
class _JobCompleteButton extends ConsumerStatefulWidget {
  const _JobCompleteButton({required this.jobId, required this.runtime});

  final String jobId;
  final JobRuntimeState runtime;

  @override
  ConsumerState<_JobCompleteButton> createState() => _JobCompleteButtonState();
}

class _JobCompleteButtonState extends ConsumerState<_JobCompleteButton> {
  bool _expanded = false;
  bool _loadingEvidence = false;
  JobCompleteEvidence? _evidence;
  bool _confirming = false;
  String? _error;

  bool get _alreadyDone =>
      widget.runtime.status == JobStatus.complete ||
      widget.runtime.status == JobStatus.invoiced ||
      widget.runtime.status == JobStatus.paid ||
      widget.runtime.status == JobStatus.closed;

  /// Opens the confirmation expansion and kicks off the same evidence
  /// check the voice path does — no Supabase write yet, just the read that
  /// decides which prompt to show.
  Future<void> _startConfirming() async {
    setState(() {
      _expanded = true;
      _loadingEvidence = true;
      _error = null;
    });
    debugPrint('JOB COMPLETE: "Mark Job Complete" tapped for job ${widget.jobId}, checking evidence...');
    try {
      final evidence = await ref.read(jobCompleteActionProvider(widget.jobId).notifier).checkEvidence();
      if (!mounted) return;
      setState(() {
        _evidence = evidence;
        _loadingEvidence = false;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('JOB COMPLETE ERROR: evidence check failed for job ${widget.jobId}: $e');
      setState(() {
        _loadingEvidence = false;
        _error = 'Could not check this job — please try again.';
      });
    }
  }

  /// Collapses the expansion without writing anything — purely local
  /// widget state, nothing to await or race (same reasoning as
  /// `ChangeOrdersScreen._cancelVoiding`).
  void _cancel() {
    debugPrint('JOB COMPLETE: cancelled for job ${widget.jobId} — no write made');
    setState(() {
      _expanded = false;
      _evidence = null;
      _error = null;
    });
  }

  Future<void> _confirm() async {
    final evidence = _evidence;
    if (evidence == null) return;
    final technicianId = ref.read(authControllerProvider).value?.id;
    if (technicianId == null) {
      setState(() => _error = 'No active session — please sign in again.');
      return;
    }

    setState(() {
      _confirming = true;
      _error = null;
    });
    debugPrint('JOB COMPLETE: confirmed via tap for job ${widget.jobId}, writing completion...');
    try {
      await ref
          .read(jobCompleteActionProvider(widget.jobId).notifier)
          .markComplete(technicianId: technicianId, evidence: evidence);
      if (!mounted) return;
      debugPrint('JOB COMPLETE: job ${widget.jobId} marked complete via tap');
      setState(() {
        _confirming = false;
        _expanded = false;
        _evidence = null;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('JOB COMPLETE ERROR: completion write failed for job ${widget.jobId}: $e');
      setState(() {
        _confirming = false;
        _error = e is StateError ? e.message : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_alreadyDone) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.primaryGreen.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: const Text(
          'Job Complete ✓',
          style: TextStyle(color: AppColors.primaryGreenDark, fontWeight: FontWeight.w700, fontSize: 15),
        ),
      );
    }

    if (_expanded) return _buildConfirmExpansion();

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _startConfirming,
        icon: const Icon(Icons.check_circle_rounded),
        label: const Text('Mark Job Complete'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryGreen,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildConfirmExpansion() {
    final evidence = _evidence;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loadingEvidence)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else ...[
            Text(
              (evidence != null && !evidence.hasAny)
                  ? 'This job has no photos or estimate logged. Mark it complete anyway?'
                  : 'Mark this job complete?',
              style: const TextStyle(fontSize: 13.5, color: AppColors.textDark, fontWeight: FontWeight.w600),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _confirming ? null : _cancel, child: const Text('Cancel')),
                const SizedBox(width: 4),
                ElevatedButton(
                  onPressed: (evidence == null || _confirming) ? null : _confirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                  ),
                  child: _confirming
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Confirm'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
