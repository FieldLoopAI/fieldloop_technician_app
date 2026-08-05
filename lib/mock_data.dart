import 'package:flutter/material.dart';

import 'models/mock_history_event.dart';
import 'models/mock_line_item.dart';
import 'models/mock_photo.dart';

// MOCK DATA
//
// Technicians and jobs now come from real Supabase queries (see
// providers/auth_provider.dart and providers/jobs_provider.dart). What's
// left here is sample content for the features that don't have a backend
// endpoint yet — photos, estimates/invoices line items, and job history
// events — keyed by the old mock job ids ('job-1', etc). Since real jobs
// use Supabase-generated ids, these lookups will come back empty for real
// jobs until those tables/endpoints exist.

DateTime _today(int hour, int minute) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

DateTime _daysAgo(int days, int hour, int minute) {
  final now = DateTime.now();
  final date = now.subtract(Duration(days: days));
  return DateTime(date.year, date.month, date.day, hour, minute);
}

// MOCK DATA - replace with Supabase query (photos table, filtered by job_id)
final Map<String, List<MockPhoto>> mockPhotosByJobId = {
  'job-1': [
    MockPhoto(
      id: 'photo-1',
      caption: 'Condenser unit — visible ice buildup',
      timestamp: _today(9, 42),
      color: const Color(0xFFEF9E4E),
    ),
    MockPhoto(
      id: 'photo-2',
      caption: 'Refrigerant line — frost damage close-up',
      timestamp: _today(9, 44),
      color: const Color(0xFF6B8CAE),
    ),
    MockPhoto(
      id: 'photo-3',
      caption: 'Thermostat reading 78°F',
      timestamp: _today(9, 47),
      color: const Color(0xFF63B583),
    ),
  ],
};

// MOCK DATA - replace with Supabase query (line_items table, filtered by job_id, type='estimate')
final Map<String, List<MockLineItem>> mockEstimateLineItemsByJobId = {
  'job-1': [
    MockLineItem(description: 'Diagnostic labor (1.5 hrs)', amount: 135.00),
    MockLineItem(description: 'Compressor capacitor — 45/5 MFD', amount: 62.00),
    MockLineItem(description: 'Refrigerant recharge (R-410A, 2 lbs)', amount: 190.00),
    MockLineItem(description: 'Labor — system repair (2 hrs)', amount: 210.00),
  ],
  'job-4': [
    MockLineItem(description: 'Furnace tune-up labor (1.5 hrs)', amount: 180.00),
    MockLineItem(description: 'Filter replacement', amount: 45.00),
    MockLineItem(description: 'Igniter cleaning & calibration', amount: 85.00),
  ],
  'job-5': [
    MockLineItem(description: 'Diagnostic + leak locate', amount: 90.00),
    MockLineItem(description: 'Supply line replacement (braided SS)', amount: 140.00),
    MockLineItem(description: 'Labor — leak repair (2 hrs)', amount: 250.00),
  ],
  'job-6': [
    MockLineItem(description: 'Outlet replacement (x2)', amount: 130.00),
    MockLineItem(description: 'Labor (1 hr)', amount: 90.00),
  ],
};

// MOCK DATA - replace with Supabase query (line_items table, filtered by job_id, type='change_order')
final Map<String, List<MockLineItem>> mockChangeOrdersByJobId = {
  'job-1': [
    MockLineItem(description: 'Change order: extra refrigerant top-off (1 lb)', amount: 75.00),
  ],
};

// MOCK DATA - replace with Supabase query (history_events table, filtered by job_id, ordered by timestamp)
final Map<String, List<MockHistoryEvent>> mockHistoryByJobId = {
  'job-1': [
    MockHistoryEvent(
      type: HistoryEventType.arrival,
      description: 'Arrived on site — geofence confirmed',
      timestamp: _today(9, 31),
    ),
    MockHistoryEvent(
      type: HistoryEventType.photo,
      description: 'Added 3 photos of condenser unit',
      timestamp: _today(9, 47),
    ),
    MockHistoryEvent(
      type: HistoryEventType.voiceNote,
      description: '"FieldLoop, prepare estimate for compressor replacement"',
      timestamp: _today(9, 52),
    ),
    MockHistoryEvent(
      type: HistoryEventType.estimate,
      description: 'Estimate #EST-1183 sent to customer — \$597.00',
      timestamp: _today(9, 58),
    ),
    MockHistoryEvent(
      type: HistoryEventType.changeOrder,
      description: 'Change order added: refrigerant top-off (+\$75.00)',
      timestamp: _today(10, 10),
    ),
  ],
  'job-4': [
    MockHistoryEvent(
      type: HistoryEventType.arrival,
      description: 'Arrived on site — geofence confirmed',
      timestamp: _daysAgo(3, 8, 2),
    ),
    MockHistoryEvent(
      type: HistoryEventType.estimate,
      description: 'Estimate #EST-1140 signed on site — \$310.00',
      timestamp: _daysAgo(3, 8, 20),
    ),
  ],
  'job-5': [
    MockHistoryEvent(
      type: HistoryEventType.arrival,
      description: 'Arrived on site — geofence confirmed',
      timestamp: _daysAgo(5, 13, 32),
    ),
    MockHistoryEvent(
      type: HistoryEventType.estimate,
      description: 'Estimate #EST-1098 signed on site — \$480.00',
      timestamp: _daysAgo(5, 13, 50),
    ),
    MockHistoryEvent(
      type: HistoryEventType.invoice,
      description: 'Invoice #INV-2091 sent — \$480.00 due',
      timestamp: _daysAgo(5, 14, 5),
    ),
  ],
  'job-6': [
    MockHistoryEvent(
      type: HistoryEventType.arrival,
      description: 'Arrived on site — geofence confirmed',
      timestamp: _daysAgo(9, 10, 17),
    ),
    MockHistoryEvent(
      type: HistoryEventType.estimate,
      description: 'Estimate #EST-1042 signed on site — \$220.00',
      timestamp: _daysAgo(9, 10, 30),
    ),
    MockHistoryEvent(
      type: HistoryEventType.invoice,
      description: 'Invoice #INV-2003 sent — \$220.00 due',
      timestamp: _daysAgo(9, 10, 45),
    ),
    MockHistoryEvent(
      type: HistoryEventType.payment,
      description: 'Payment received — \$220.00 via card',
      timestamp: _daysAgo(9, 15, 0),
    ),
  ],
};
