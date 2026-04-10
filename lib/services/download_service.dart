import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Download video/audio files with progress tracking.
class DownloadService {
  final _dio = Dio();
  final _downloads = <String, DownloadTask>{};

  Map<String, DownloadTask> get downloads => Map.unmodifiable(_downloads);

  /// Get all active/recent download tasks as a list.
  List<DownloadTask> get activeTasks => _downloads.values.toList();

  /// Start downloading a URL. Returns the download task.
  Future<DownloadTask> download({
    required String url,
    required String filename,
    void Function(DownloadTask task)? onProgress,
  }) async {
    // Sanitize filename
    final safeName = filename
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    final dir = await _getDownloadDir();
    final filePath = '${dir.path}/$safeName';

    // Avoid overwriting — add counter if exists
    var finalPath = filePath;
    var counter = 1;
    while (await File(finalPath).exists()) {
      final ext = safeName.contains('.') ? '.${safeName.split('.').last}' : '';
      final base = safeName.contains('.')
          ? safeName.substring(0, safeName.lastIndexOf('.'))
          : safeName;
      finalPath = '${dir.path}/${base}_($counter)$ext';
      counter++;
    }

    final task = DownloadTask(
      url: url,
      filePath: finalPath,
      filename: safeName,
    );
    _downloads[url] = task;

    try {
      final cancelToken = CancelToken();
      task._cancelToken = cancelToken;
      task._status = DownloadStatus.downloading;
      onProgress?.call(task);

      await _dio.download(
        url,
        finalPath,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) Chrome/124.0 Mobile Safari/537.36',
          },
        ),
        onReceiveProgress: (received, total) {
          task._received = received;
          task._total = total;
          onProgress?.call(task);
        },
      );

      task._status = DownloadStatus.completed;
      onProgress?.call(task);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        task._status = DownloadStatus.cancelled;
        // Clean up partial file
        try { await File(finalPath).delete(); } catch (_) {}
      } else {
        task._status = DownloadStatus.failed;
        task._error = e.message ?? 'Download failed';
      }
      onProgress?.call(task);
    } catch (e) {
      task._status = DownloadStatus.failed;
      task._error = e.toString();
      onProgress?.call(task);
    }

    return task;
  }

  void cancel(String url) {
    _downloads[url]?._cancelToken?.cancel();
  }

  void removeCompleted() {
    _downloads.removeWhere((_, t) =>
        t.status == DownloadStatus.completed ||
        t.status == DownloadStatus.failed ||
        t.status == DownloadStatus.cancelled);
  }

  Future<Directory> _getDownloadDir() async {
    if (Platform.isAndroid) {
      // Try external storage first for user accessibility
      final dirs = await getExternalStorageDirectories(
        type: StorageDirectory.movies,
      );
      if (dirs != null && dirs.isNotEmpty) return dirs.first;
    }
    return await getApplicationDocumentsDirectory();
  }

  void dispose() {
    for (final task in _downloads.values) {
      task._cancelToken?.cancel();
    }
    _dio.close();
  }
}

enum DownloadStatus { pending, downloading, completed, failed, cancelled }

class DownloadTask {
  final String url;
  final String filePath;
  final String filename;
  DownloadStatus _status = DownloadStatus.pending;
  int _received = 0;
  int _total = -1;
  String? _error;
  CancelToken? _cancelToken;

  DownloadTask({
    required this.url,
    required this.filePath,
    required this.filename,
  });

  DownloadStatus get status => _status;
  int get received => _received;
  int get total => _total;
  String? get error => _error;
  double get progress => _total > 0 ? _received / _total : 0;

  void cancel() => _cancelToken?.cancel();

  String get progressText {
    if (_total <= 0) return _fmtSize(_received);
    return '${_fmtSize(_received)} / ${_fmtSize(_total)}';
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
