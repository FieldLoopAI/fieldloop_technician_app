import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/pending_upload.dart';

/// Thin sqflite wrapper around the single `pending_uploads` table — the
/// on-device durable queue for photos captured with no connectivity (or
/// that failed to upload for a network reason). Opened lazily and cached so
/// there's exactly one open `Database` handle for the whole app; every
/// offline-queue read/write goes through here rather than any caller
/// touching sqflite directly.
class PendingUploadsDb {
  PendingUploadsDb._();

  static final PendingUploadsDb instance = PendingUploadsDb._();

  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dbPath = p.join(await getDatabasesPath(), 'fielloop_offline_queue.db');
    final db = await openDatabase(
      dbPath,
      version: 1,
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

  Future<void> delete(int id) async {
    final db = await _open();
    await db.delete('pending_uploads', where: 'id = ?', whereArgs: [id]);
  }
}
