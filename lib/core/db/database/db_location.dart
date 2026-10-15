import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';
import 'package:colitu_vpn/colitu/storage/backup_exclusion.dart';

/// Where the database lives on iOS.
///
/// Up to 5.9.0 it was `Documents/db.sqlite`, which iCloud and computer
/// backups copy; the active connection profile (server credentials) is in
/// it. It now lives in `Library/Application Support/colitu-db/`, a directory
/// excluded from backups, and an old file is moved there once.
abstract final class AppDatabaseLocation {
  static const dirName = 'colitu-db';
  static const fileName = 'db.sqlite';

  /// SQLite's companions of a database file (write-ahead log, shared
  /// memory, rollback journal).
  static const companions = ['-wal', '-shm', '-journal'];

  static Future<String> resolve() async {
    final documents = await getApplicationDocumentsDirectory();
    final legacy = p.join(documents.path, fileName);
    try {
      final support = await getApplicationSupportDirectory();
      return await prepare(
        supportDir: support.path,
        documentsDir: documents.path,
        exclude: ColituBackupExclusion.exclude,
      );
    } catch (_) {
      // The new place cannot be prepared: open the database where it was
      // (the next start tries the move again) rather than not at all.
      return legacy;
    }
  }

  /// Creates the directory, moves an old database over and marks the
  /// directory as excluded from backups. Returns the database path: the new
  /// one, or the old one when the move failed this time.
  static Future<String> prepare({
    required String supportDir,
    required String documentsDir,
    required Future<Object?> Function(String path) exclude,
  }) async {
    final dir = Directory(p.join(supportDir, dirName));
    await dir.create(recursive: true);
    final target = p.join(dir.path, fileName);
    final path = await migrate(
      from: p.join(documentsDir, fileName),
      to: target,
    );
    await exclude(dir.path);
    return path;
  }

  /// Moves [from] with its companions to [to] when [to] does not exist yet
  /// and returns the path to open. The companions move first and the main
  /// file last, so a database never sits apart from its write-ahead log; if
  /// any step fails, what was moved goes back and [from] is used this time
  /// (the next start tries again). When [to] exists, or [from] is gone,
  /// leftovers at [from] (also a lone -wal/-shm) are stale and deleted: they
  /// must not stay in the backups.
  static Future<String> migrate({
    required String from,
    required String to,
  }) async {
    final hasOld = await File(from).exists();
    if (await File(to).exists() || !hasOld) {
      for (final suffix in ['', ...companions]) {
        await _delete(File('$from$suffix'));
      }
      return to;
    }
    final moved = <String>[];
    try {
      for (final suffix in [...companions, '']) {
        final source = File('$from$suffix');
        if (!await source.exists()) continue;
        await _move(source, '$to$suffix');
        moved.add(suffix);
      }
      return to;
    } catch (_) {
      for (final suffix in moved.reversed) {
        try {
          await _move(File('$to$suffix'), '$from$suffix');
        } catch (_) {
          // Left at the new place; the old main file is still opened.
        }
      }
      return from;
    }
  }

  /// [file] to [path]: a rename, or a copy and delete across volumes. The
  /// copy is removed again when deleting the original fails.
  static Future<void> _move(File file, String path) async {
    try {
      await file.rename(path);
      return;
    } on FileSystemException {
      // Another volume: copy below.
    }
    final copy = await file.copy(path);
    try {
      await file.delete();
    } on FileSystemException {
      await _delete(copy);
      rethrow;
    }
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Locked: the next start tries again.
    }
  }

  /// Deleted rows are overwritten instead of lingering in free pages.
  static void setup(CommonDatabase db) {
    db.execute('PRAGMA secure_delete = ON;');
  }
}
