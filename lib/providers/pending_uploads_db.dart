import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/pending_upload.dart';

/// Thin sqflite wrapper around the on-device durable queue — the
/// `pending_uploads` table (photos captured with no connectivity, or that
/// failed to upload for a network reason) and, since v2, the
/// `pending_photo_notes` table (a confirmed voice photo description whose
/// `field_events.transcript` write couldn't go out yet — see
/// `OfflineUploadQueueService.savePhotoNote`). Opened lazily and cached so
/// there's exactly one open `Database` handle for the whole app; every
/// offline-queue read/write goes through here rather than any caller
/// touching sqflite directly.
class PendingUploadsDb {
  PendingUploadsDb._();

  static final PendingUploadsDb instance = PendingUploadsDb._();

  Database? _db;

  static const String _createPendingPhotoNotes = '''
    CREATE TABLE pending_photo_notes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      job_id TEXT NOT NULL,
      field_event_id INTEGER NOT NULL,
      transcript TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dbPath = p.join(await getDatabasesPath(), 'fielloop_offline_queue.db');
    final db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pending_uploads (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL,
            local_file_path TEXT NOT NULL,
            caption TEXT,
            created_at TEXT NOT NULL,
            status TEXT NOT NULL
          )
        ''');
        await db.execute(_createPendingPhotoNotes);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await db.execute(_createPendingPhotoNotes);
      },
    );
    _db = db;
    return db;
  }

  Future<int> insert(PendingUpload upload) async {
    final db = await _open();
    return db.insert('pending_uploads', upload.toMap());
  }

  /// Rows still owed an upload attempt — both fresh ('pending') and
  /// previously-failed ('failed') rows are retried on the next
  /// connectivity-restored sync; only a genuinely completed upload removes
  /// a row (see [delete]), so nothing queued is ever silently dropped.
  Future<List<PendingUpload>> queryRetryable() async {
    final db = await _open();
    final rows = await db.query(
      'pending_uploads',
      where: 'status IN (?, ?)',
      whereArgs: [PendingUploadStatus.pending.name, PendingUploadStatus.failed.name],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingUpload.fromMap).toList();
  }

  Future<void> updateStatus(int id, PendingUploadStatus status) async {
    final db = await _open();
    await db.update('pending_uploads', {'status': status.name}, where: 'id = ?', whereArgs: [id]);
  }

  /// Attaches a voice photo description to a still-queued photo. Returns
  /// the number of rows updated — 0 means the row is already gone (the
  /// queue drained it in the meantime).
  Future<int> updateCaption(int id, String caption) async {
    final db = await _open();
    return db.update('pending_uploads', {'caption': caption}, where: 'id = ?', whereArgs: [id]);
  }

  /// The row's CURRENT caption — re-read after an upload rather than
  /// trusting the copy read before it, since a description can be attached
  /// while the upload is in flight.
  Future<String?> readCaption(int id) async {
    final db = await _open();
    final rows = await db.query('pending_uploads', columns: ['caption'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first['caption'] as String?;
  }

  Future<void> delete(int id) async {
    final db = await _open();
    await db.delete('pending_uploads', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> insertPhotoNote({required String jobId, required int fieldEventId, required String transcript}) async {
    final db = await _open();
    return db.insert('pending_photo_notes', {
      'job_id': jobId,
      'field_event_id': fieldEventId,
      'transcript': transcript,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<PendingPhotoNote>> queryPhotoNotes() async {
    final db = await _open();
    final rows = await db.query('pending_photo_notes', orderBy: 'created_at ASC');
    return rows
        .map(
          (r) => PendingPhotoNote(
            id: r['id'] as int,
            jobId: r['job_id'] as String,
            fieldEventId: r['field_event_id'] as int,
            transcript: r['transcript'] as String,
          ),
        )
        .toList();
  }

  Future<void> deletePhotoNote(int id) async {
    final db = await _open();
    await db.delete('pending_photo_notes', where: 'id = ?', whereArgs: [id]);
  }
}

/// A confirmed voice photo description still owed its
/// `field_events.transcript` write — see [PendingUploadsDb.insertPhotoNote].
class PendingPhotoNote {
  const PendingPhotoNote({
    required this.id,
    required this.jobId,
    required this.fieldEventId,
    required this.transcript,
  });

  final int id;
  final String jobId;
  final int fieldEventId;
  final String transcript;
}
