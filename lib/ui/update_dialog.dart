import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/updates.dart';
import 'theme.dart';

/// Offers [release]. "Update" downloads it and opens Android's installer;
/// "Not now" closes the dialog until the next check.
Future<void> showUpdateDialog(
  BuildContext context, {
  required UpdateService updates,
  required AppRelease release,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UpdateDialog(updates: updates, release: release),
);

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.updates, required this.release});
  final UpdateService updates;
  final AppRelease release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _downloading = false;
  // Share of the APK downloaded; null until the size is known.
  double? _progress;
  UpdateException? _error;

  Future<void> _update() async {
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });
    try {
      await widget.updates.install(
        widget.release,
        onProgress: (received, total) {
          if (mounted && total != null) {
            setState(() => _progress = (received / total).clamp(0.0, 1.0));
          }
        },
      );
      // The installer takes over from here.
      if (mounted) Navigator.pop(context);
    } on UpdateException catch (error) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _openReleasePage() async {
    final uri = Uri.parse(widget.release.pageUrl);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No browser; the dialog stays open.
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    final change = release.change;
    final error = _error;
    final progress = _progress;
    final caption = TextStyle(color: ink(.54), fontSize: 12, height: 1.5);
    return PopScope(
      canPop: !_downloading,
      child: AlertDialog(
        icon: const Icon(Icons.system_update_rounded, color: accent),
        title: const Text('An update is available.'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Version: ${release.label}'),
              const SizedBox(height: 12),
              Text(
                change.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              // The commit description, set apart like a changelog file.
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: ink(.05),
                  border: Border.all(color: ink(.12)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    change.description.isEmpty
                        ? 'No description provided. Might just be some fixes.'
                        : change.description,
                    style: caption.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ),
              if (_downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 6),
                Text(
                  progress == null
                      ? 'Downloading…'
                      : 'Downloading… ${(progress * 100).round()}%',
                  style: caption,
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error.message,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _downloading ? null : () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          if (error == null || error.retryable)
            FilledButton(
              onPressed: _downloading ? null : _update,
              child: Text(error == null ? 'Update' : 'Try again'),
            )
          // A release signed with another key cannot be trusted, so the
          // dialog does not send the user to download it by hand.
          else if (error.failure != UpdateFailure.signature)
            FilledButton(
              onPressed: _openReleasePage,
              child: const Text('Open release'),
            ),
        ],
      ),
    );
  }
}
