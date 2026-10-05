import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/pending_visit_event.dart';

/// Thin sqflite wrapper around the single `pending_visit_events` table —
/// the on-device durable queue for `gps_arrive`/`gps_depart` `field_events`
/// writes that failed for a network reason after exhausting
/// `visit_provider.dart`'s retry attempts. A dedicated table/db file rather
/// than extending `PendingUploadsDb`'s `pending_uploads` table: that
/// table's schema (`local_file_path`, `caption`) is specific to photo
/// bytes on disk, whereas a visit event is just a handful of small fields
/// with nothing to store on the filesystem — mirrors that class's
/// structure/method shape exactly (open lazily and cache the one
/// `Database` handle; every read/write goes through here) rather than its
/// literal table.
class PendingVisitEventsDb {
  PendingVisitEventsDb._();

  static final PendingVisitEventsDb instance = PendingVisitEventsDb._();

  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dbPath = p.join(await getDatabasesPath(), 'fielloop_pending_visit_events.db');
    final db = await openDatabase(
      dbPath,
      // v2 adds `visit_seq` (duplicate-arrival protection — see
      // `visit_provider.dart`); rows queued under v1 keep it NULL.
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pending_visit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL,
            technician_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            source TEXT NOT NULL,
            event_ts TEXT NOT NULL,
            visit_seq INTEGER,
            created_at TEXT NOT NULL,
            status TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE pending_visit_events ADD COLUMN visit_seq INTEGER');
        }
      },
    );
    _db = db;
    return db;
  }

  Future<int> insert(PendingVisitEvent event) async {
    final db = await _open();
    return db.insert('pending_visit_events', event.toMap());
  }

  /// Rows still owed a retry — both fresh ('pending') and previously-failed
  /// ('failed') rows are retried on the next connectivity-restored sync;
  /// only a genuinely successful insert removes a row (see [delete]), so
  /// nothing queued here is ever silently dropped. Ordered by [eventTs]
  /// (oldest first) so a job's visits are re-sent in the order they
  /// actually happened, matching the timeline they'll appear in once
  /// written.
  Future<List<PendingVisitEvent>> queryRetryable() async {
    final db = await _open();
    final rows = await db.query(
      'pending_visit_events',
      where: 'status IN (?, ?)',
      whereArgs: [PendingVisitEventStatus.pending.name, PendingVisitEventStatus.failed.name],
      orderBy: 'event_ts ASC',
    );
    return rows.map(PendingVisitEvent.fromMap).toList();
  }

  Future<void> updateStatus(int id, PendingVisitEventStatus status) async {
    final db = await _open();
    await db.update('pending_visit_events', {'status': status.name}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(int id) async {
    final db = await _open();
    await db.delete('pending_visit_events', where: 'id = ?', whereArgs: [id]);
  }
}
