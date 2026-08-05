import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mock_data.dart';
import '../models/mock_line_item.dart';

enum EstimateStatus { draft, sent, signed }

enum InvoiceStatus { notYetInvoiced, pending, paid }

/// MOCK DATA - replace with Supabase query (line_items table, type='estimate')
final estimateLineItemsProvider = Provider.family<List<MockLineItem>, String>((ref, jobId) {
  return mockEstimateLineItemsByJobId[jobId] ?? const [];
});

/// MOCK DATA - replace with Supabase query (line_items table, type='change_order')
final changeOrdersProvider = Provider.family<List<MockLineItem>, String>((ref, jobId) {
  return mockChangeOrdersByJobId[jobId] ?? const [];
});

/// In-session estimate status, seeded from mock data so already-completed
/// jobs show as signed. The estimate screen's "Send to Customer" action
/// moves this draft -> sent (-> signed once the mock signature lands).
final estimateStatusProvider = StateProvider.family<EstimateStatus, String>((ref, jobId) {
  // MOCK DATA - replace with Supabase query (jobs/estimates.status)
  if (jobId == 'job-1') return EstimateStatus.sent;
  if (const {'job-4', 'job-5', 'job-6'}.contains(jobId)) return EstimateStatus.signed;
  return EstimateStatus.draft;
});

/// In-session invoice status, seeded from mock data.
final invoiceStatusProvider = StateProvider.family<InvoiceStatus, String>((ref, jobId) {
  // MOCK DATA - replace with Supabase query (invoices.status)
  if (jobId == 'job-6') return InvoiceStatus.paid;
  if (jobId == 'job-5') return InvoiceStatus.pending;
  return InvoiceStatus.notYetInvoiced;
});
