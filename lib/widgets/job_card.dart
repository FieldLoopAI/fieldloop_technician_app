import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mock_job.dart';
import '../providers/job_runtime_provider.dart';
import '../theme/app_theme.dart';
import 'status_pill.dart';

/// A modern job list card with a staggered fade/slide-in entrance driven by
/// [index], a leading trade icon, and a colored status pill that tracks the
/// job's live runtime status (not just its static mock status).
class JobCard extends ConsumerWidget {
  const JobCard({super.key, required this.job, required this.index, required this.onTap});

  final MockJob job;
  final int index;
  final VoidCallback onTap;

  IconData get _leadingIcon {
    final trade = job.tradeCategory.toLowerCase();
    if (trade.contains('plumb')) return Icons.plumbing_rounded;
    if (trade.contains('electr')) return Icons.electrical_services_rounded;
    if (trade.contains('hvac') || trade.contains('cool') || trade.contains('heat')) {
      return Icons.thermostat_rounded;
    }
    return Icons.build_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(jobRuntimeProvider(job.id)).status;
    final subtitle = [
      job.description,
      job.tradeCategory,
    ].where((s) => s.trim().isNotEmpty).join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_leadingIcon, color: AppColors.primaryGreen),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            job.jobIdPublic,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textDark,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        StatusPill(status: status.wireValue),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      job.customerName,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(fontSize: 13, color: AppColors.neutralGrey),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: AppColors.neutralGreyLight,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            job.serviceAddress,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.neutralGreyLight,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ).animate(delay: (60 * index).ms).fadeIn(duration: 380.ms, curve: Curves.easeOut).slideY(
      begin: 0.12,
      end: 0,
      duration: 380.ms,
      curve: Curves.easeOut,
    );
  }
}
