/// Build 185 — the voice session's `/invoices/preview` prefetch, so "show me
/// the invoice" can open Invoice Review without waiting ~5 s on the Lambda.
/// One job at a time, valid for [kInvoicePreviewCacheTtl] from when the
/// request started, and handed out once (the screen keeps its own copy).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/invoice_preview.dart';

const Duration kInvoicePreviewCacheTtl = Duration(seconds: 45);

/// What [InvoicePreviewCache.take] hands out: the preview itself when the
/// prefetch already finished, otherwise the still-running request.
typedef CachedInvoicePreview = ({InvoicePreview? value, Future<InvoicePreview> pending});

class InvoicePreviewCache {
  InvoicePreviewCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  _Entry? _entry;

  /// Starts [fetch] for [jobId], replacing whatever was cached. Never throws:
  /// a failure only drops the entry, so the caller fetches on its own.
  void prefetch(String jobId, Future<InvoicePreview> Function({required String jobId}) fetch) {
    final Future<InvoicePreview> pending;
    try {
      pending = fetch(jobId: jobId);
    } catch (_) {
      debugPrint('INVOICE PREFETCH failed');
      return;
    }
    final entry = _Entry(jobId, _now(), pending);
    _entry = entry;
    debugPrint('INVOICE PREFETCH started');
    pending.then(
      (preview) {
        entry.value = preview;
        debugPrint('INVOICE PREFETCH ok');
      },
      onError: (Object _) {
        if (identical(_entry, entry)) _entry = null;
        debugPrint('INVOICE PREFETCH failed');
      },
    );
  }

  /// The cached preview for [jobId] — a finished one only while still
  /// within the TTL, a running one regardless — and clears it (single use).
  CachedInvoicePreview? take(String jobId) {
    final entry = _entry;
    if (entry == null || entry.jobId != jobId) return null;
    final value = entry.value;
    if (value != null && _now().difference(entry.startedAt) >= kInvoicePreviewCacheTtl) {
      _entry = null;
      return null;
    }
    _entry = null;
    return (value: value, pending: entry.pending);
  }

  void clear() => _entry = null;
}

class _Entry {
  _Entry(this.jobId, this.startedAt, this.pending);

  final String jobId;
  final DateTime startedAt;
  final Future<InvoicePreview> pending;
  InvoicePreview? value;
}

/// The one cache the voice session fills and `view_invoice` reads.
final InvoicePreviewCache invoicePreviewCache = InvoicePreviewCache();
