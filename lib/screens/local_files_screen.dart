import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/app_state.dart';
import '../models/video_info.dart';
import '../services/download_service.dart';

class LocalFilesScreen extends ConsumerStatefulWidget {
  const LocalFilesScreen({super.key});

  @override
  ConsumerState<LocalFilesScreen> createState() => _LocalFilesScreenState();
}

class _LocalFilesScreenState extends ConsumerState<LocalFilesScreen> {
  final List<PlatformFile> _pickedFiles = [];

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        for (final f in result.files) {
          if (!_pickedFiles.any((e) => e.path == f.path)) {
            _pickedFiles.insert(0, f);
          }
        }
      });
    }
  }

  void _castFile(PlatformFile file) {
    if (file.path == null) return;
    // Use the proxy to serve the local file — the proxy can handle file:// URIs
    // through its stream forwarding, but for local files we create a direct path.
    final fileUrl = Uri.file(file.path!).toString();
    ref.read(selectedFormatProvider.notifier).state = StreamFormat(
      id: 'local',
      label: file.name,
      url: fileUrl,
      height: 0,
      hasAudio: true,
    );
    // Load as a direct video so the Cast tab picks it up
    ref.read(videoProvider.notifier).loadDirect(fileUrl, title: file.name);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final downloads = ref.watch(downloadServiceProvider).activeTasks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Pick video files',
            onPressed: _pickFiles,
          ),
        ],
      ),
      body: _pickedFiles.isEmpty && downloads.isEmpty
          ? _buildEmptyState(cs)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Active Downloads ──
                if (downloads.isNotEmpty) ...[
                  Text('Downloads',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  ...downloads.map((task) => _DownloadTile(task: task)),
                  const SizedBox(height: 16),
                ],

                // ── Picked Files ──
                if (_pickedFiles.isNotEmpty) ...[
                  Row(
                    children: [
                      Text('Local videos',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: cs.onSurfaceVariant)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _pickedFiles.clear()),
                        child: const Text('Clear', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ..._pickedFiles.map((f) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: cs.primaryContainer,
                            child: Icon(Icons.video_file, color: cs.primary),
                          ),
                          title: Text(f.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14)),
                          subtitle: Text(_formatSize(f.size),
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant)),
                          trailing: FilledButton.icon(
                            icon: const Icon(Icons.cast, size: 16),
                            label: const Text('Send'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () => _castFile(f),
                          ),
                        ),
                      )),
                ],
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.video_file),
        label: const Text('Pick Videos'),
        onPressed: _pickFiles,
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 72, color: cs.onSurfaceVariant.withAlpha(80)),
            const SizedBox(height: 16),
            Text('No local videos',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text(
              'Pick videos from your device and send them to your TV.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Download Tile ───────────────────────────────────────────────────────────

class _DownloadTile extends StatelessWidget {
  final DownloadTask task;
  const _DownloadTile({required this.task});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  task.status == DownloadStatus.completed
                      ? Icons.check_circle
                      : task.status == DownloadStatus.failed
                          ? Icons.error
                          : Icons.downloading,
                  color: task.status == DownloadStatus.completed
                      ? Colors.green
                      : task.status == DownloadStatus.failed
                          ? cs.error
                          : cs.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(task.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500)),
                ),
                if (task.status == DownloadStatus.downloading)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: task.cancel,
                    tooltip: 'Cancel',
                  ),
              ],
            ),
            if (task.status == DownloadStatus.downloading) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: task.progress),
              const SizedBox(height: 2),
              Text('${(task.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
            if (task.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(task.error!,
                    style: TextStyle(fontSize: 11, color: cs.error)),
              ),
          ],
        ),
      ),
    );
  }
}
