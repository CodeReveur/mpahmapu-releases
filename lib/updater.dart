import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'i18n.dart';
import 'models.dart';
import 'permissions.dart';
import 'theme.dart';

enum UpdatePhase {
  idle,
  checking,
  available,
  downloading,
  readyToInstall,
  installing,
  upToDate,
}

class UpdateStatus {
  final UpdatePhase phase;
  final String currentVersion;
  final String? latestVersion;
  final double progress;
  final String? apkPath;

  const UpdateStatus({
    this.phase = UpdatePhase.idle,
    this.currentVersion = '1.2.6',
    this.latestVersion,
    this.progress = 0,
    this.apkPath,
  });

  UpdateStatus copyWith({
    UpdatePhase? phase,
    String? currentVersion,
    String? latestVersion,
    double? progress,
    String? apkPath,
  }) =>
      UpdateStatus(
        phase: phase ?? this.phase,
        currentVersion: currentVersion ?? this.currentVersion,
        latestVersion: latestVersion ?? this.latestVersion,
        progress: progress ?? this.progress,
        apkPath: apkPath ?? this.apkPath,
      );
}

class _RemoteReleaseCandidate {
  final String version;
  final String downloadUrl;
  final String updatedAt;
  final int? sizeBytes;

  const _RemoteReleaseCandidate({
    required this.version,
    required this.downloadUrl,
    required this.updatedAt,
    this.sizeBytes,
  });
}

class _UpdaterLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppUpdater.checkAndAutoUpdate(silent: true);
    }
  }
}

/// Native bridge for background execution, boot auto-start, and OTA self-updates.
class AppUpdater {
  static const MethodChannel _channel = MethodChannel('rw.mpahmapu.motari/app');
  static const String fallbackVersion = '1.2.6';
  static const String _installedStampKey = 'motari.installed_apk_stamp';
  static const List<String> _githubReleaseApis = [
    'https://api.github.com/repos/CodeReveur/mpahmapu-releases/releases/latest',
    'https://api.github.com/repos/CodeReveur/mpahmapu-mobile/releases/latest',
  ];

  static final ValueNotifier<UpdateStatus> status =
      ValueNotifier<UpdateStatus>(const UpdateStatus());

  static Timer? _pollTimer;
  static bool _busy = false;
  static bool _initialized = false;
  static final _UpdaterLifecycleObserver _lifecycleObserver = _UpdaterLifecycleObserver();

  /// Callback invoked when the driver taps ACCEPT or DECLINE on the Lock-Screen
  /// Call Notification or the System Call Overlay over other apps.
  static void Function(String action, String rideId)? onOfferAction;

  /// Start periodic background update checks and sync native service state.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      WidgetsBinding.instance.addObserver(_lifecycleObserver);
    } catch (_) {}

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOfferAction') {
        final args = call.arguments as Map?;
        final action = args?['action']?.toString() ?? '';
        final rideId = args?['rideId']?.toString() ?? '';
        if (action.isNotEmpty && rideId.isNotEmpty) {
          onOfferAction?.call(action, rideId);
        }
      }
    });

    final current = await getCurrentVersion();
    status.value = status.value.copyWith(currentVersion: current);

    // Ensure background service is running so the app stays alive in background.
    await startBackgroundService(online: true);

    // If the app was auto-opened by BootReceiver, move it to background smoothly
    // after initial frame so the phone isn't hijacked while still running in background.
    final fromBoot = await wasLaunchedFromBoot();
    if (fromBoot) {
      Future<void>.delayed(const Duration(seconds: 3), () {
        moveToBackground();
      });
    }

    // Check for self-update immediately after launch (1s), then every 2 minutes.
    Future<void>.delayed(const Duration(seconds: 1), () {
      checkAndAutoUpdate(silent: true);
    });
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      checkAndAutoUpdate(silent: true);
    });
  }

  static Future<String> getCurrentVersion() async {
    try {
      final v = await _channel.invokeMethod<String>('getAppVersion');
      if (v != null && v.trim().isNotEmpty) return v.trim();
    } catch (_) {}
    return fallbackVersion;
  }

  static Future<bool> wasLaunchedFromBoot() async {
    try {
      final res = await _channel.invokeMethod<bool>('wasLaunchedFromBoot');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> startBackgroundService({
    bool online = true,
    String? title,
    String? body,
  }) async {
    try {
      await _channel.invokeMethod('startBackgroundService', {
        'online': online,
        'title': title ?? 'Ask Motari',
        'body': body ?? (online ? 'Running in background · Ready for rides' : 'Background sync active'),
      });
    } catch (_) {}
  }

  static Future<void> stopBackgroundService() async {
    try {
      await _channel.invokeMethod('stopBackgroundService');
    } catch (_) {}
  }

  static Future<void> moveToBackground() async {
    try {
      await _channel.invokeMethod('moveToBackground');
    } catch (_) {}
  }

  static Future<void> bringToFront() async {
    try {
      await _channel.invokeMethod('bringToFront');
    } catch (_) {}
  }

  /// Trigger the native Incoming Call Notification (with Lock-Screen Accept & Decline
  /// buttons) + Full-Screen Intent + System Call Overlay over other apps.
  static Future<void> showIncomingOfferCall(Offer offer) async {
    try {
      await _channel.invokeMethod('showIncomingOfferCall', {
        'rideId': offer.rideId,
        'passengerName': offer.passengerName,
        'kind': offer.kind,
        'pickupName': offer.pickupName ?? '',
        'destName': offer.destName ?? '',
        'fareRwf': offer.fareRwf ?? 0,
        'distanceM': offer.distanceToPickupM,
        'expiresSeconds': offer.expiresInSeconds,
      });
    } catch (_) {}
  }

  /// Dismiss the native Incoming Call Notification, ringing, and Call Overlay.
  static Future<void> dismissIncomingOfferCall() async {
    try {
      await _channel.invokeMethod('dismissIncomingOfferCall');
    } catch (_) {}
  }

  /// Consume any pending Accept / Decline action triggered while Flutter was warming up.
  static Future<Map<String, String>?> consumePendingOfferAction() async {
    try {
      final raw = await _channel.invokeMethod<Map>('consumePendingOfferAction');
      if (raw != null) {
        final action = raw['action']?.toString() ?? '';
        final rideId = raw['rideId']?.toString() ?? '';
        if (action.isNotEmpty && rideId.isNotEmpty) {
          return {'action': action, 'rideId': rideId};
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> canDrawOverlays() async {
    try {
      final ok = await _channel.invokeMethod<bool>('canDrawOverlays');
      return ok ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestOverlayPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (_) {}
  }

  /// Compare two semantic versions (e.g. "1.2.6" > "1.2.5", or "1.2.6+12" > "1.2.6+11").
  @visibleForTesting
  static bool isNewerVersion(String remote, String local) {
    final rRaw = remote.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final lRaw = local.trim().replaceFirst(RegExp(r'^[vV]'), '');
    if (rRaw.isEmpty || rRaw == lRaw) return false;

    final rSplit = rRaw.split('+');
    final lSplit = lRaw.split('+');
    final cleanRemote = rSplit.first;
    final cleanLocal = lSplit.first;

    final rParts = cleanRemote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final lParts = cleanLocal.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = rParts.length > lParts.length ? rParts.length : lParts.length;
    for (var i = 0; i < len; i++) {
      final r = i < rParts.length ? rParts[i] : 0;
      final l = i < lParts.length ? lParts[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }

    if (rSplit.length > 1 && lSplit.length > 1) {
      final rBuild = int.tryParse(rSplit[1]) ?? 0;
      final lBuild = int.tryParse(lSplit[1]) ?? 0;
      if (rBuild > lBuild) return true;
    }
    return false;
  }

  static Future<_RemoteReleaseCandidate?> _fetchGithubCandidate(String apiUrl) async {
    try {
      final res = await http.get(
        Uri.parse(apiUrl),
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'AskMotari-OTA-Updater',
        },
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (body['tag_name']?.toString() ?? '').trim();
      final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
      if (version.isEmpty) return null;

      String? downloadUrl;
      int? sizeBytes;
      final assets = body['assets'];
      if (assets is List) {
        for (final item in assets) {
          if (item is Map<String, dynamic>) {
            final name = (item['name']?.toString() ?? '').toLowerCase();
            if (name == 'motari.apk' || name.endsWith('.apk')) {
              downloadUrl = item['browser_download_url']?.toString();
              sizeBytes = (item['size'] as num?)?.toInt();
              if (name == 'motari.apk') break;
            }
          }
        }
      }
      if (downloadUrl == null || downloadUrl.isEmpty) return null;

      final publishedAt = body['published_at']?.toString() ?? '';
      return _RemoteReleaseCandidate(
        version: version,
        downloadUrl: downloadUrl,
        updatedAt: publishedAt,
        sizeBytes: sizeBytes,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<_RemoteReleaseCandidate?> _fetchBackendCandidate() async {
    try {
      final uri = Uri.parse('${Api.baseUrl}/api/app/info');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;

      final raw = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (raw['data'] is Map<String, dynamic>)
          ? raw['data'] as Map<String, dynamic>
          : raw;
      final available = data['android'] == true || data['available'] == true;
      if (!available) return null;

      final remoteVersion = (data['version']?.toString() ?? '').trim();
      if (remoteVersion.isEmpty) return null;
      final updatedAt = data['updatedAt']?.toString() ?? '';
      final rawUrl = data['url']?.toString() ?? '/api/app/android';
      final downloadUrl = rawUrl.startsWith('http')
          ? rawUrl
          : '${Api.baseUrl}${rawUrl.startsWith('/') ? '' : '/'}$rawUrl';
      return _RemoteReleaseCandidate(
        version: remoteVersion,
        downloadUrl: downloadUrl,
        updatedAt: updatedAt,
        sizeBytes: (data['sizeBytes'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<_RemoteReleaseCandidate?> _fetchGithubRawCandidate() async {
    try {
      final res = await http.get(
        Uri.parse('https://raw.githubusercontent.com/CodeReveur/mpahmapu-releases/main/motari-latest.version'),
        headers: const {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final lines = res.body.trim().split(RegExp(r'\r?\n'));
      final version = lines.first.trim().replaceFirst(RegExp(r'^[vV]'), '');
      if (version.isEmpty) return null;
      final updatedAt = lines.length > 1 ? lines[1].trim() : version;

      return _RemoteReleaseCandidate(
        version: version,
        downloadUrl: 'https://github.com/CodeReveur/mpahmapu-releases/releases/latest/download/Motari.apk',
        updatedAt: updatedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// Check GitHub Releases (instant, un-cached) and `/api/app/info` and automatically
  /// download + trigger install when a new production build is deployed.
  static Future<bool> checkAndAutoUpdate({bool silent = true}) async {
    if (_busy) return false;
    _busy = true;
    try {
      final current = await getCurrentVersion();
      if (!silent) {
        status.value = status.value.copyWith(
          phase: UpdatePhase.checking,
          currentVersion: current,
        );
      }

      // Query direct GitHub Release endpoints AND backend in parallel so newly
      // published releases are discovered immediately without waiting on cache TTL.
      final results = await Future.wait<_RemoteReleaseCandidate?>([
        for (final ghUrl in _githubReleaseApis) _fetchGithubCandidate(ghUrl),
        _fetchGithubRawCandidate(),
        _fetchBackendCandidate(),
      ]);

      _RemoteReleaseCandidate? best;
      for (final c in results) {
        if (c == null) continue;
        if (best == null) {
          best = c;
        } else if (isNewerVersion(c.version, best.version)) {
          best = c;
        } else if (c.version == best.version &&
            c.updatedAt.isNotEmpty &&
            c.updatedAt.compareTo(best.updatedAt) > 0) {
          best = c;
        }
      }

      if (best == null) {
        if (!silent) {
          status.value = status.value.copyWith(phase: UpdatePhase.upToDate);
        }
        return false;
      }

      final remoteVersion = best.version;
      final updatedAt = best.updatedAt;
      final downloadUrl = best.downloadUrl;
      final stamp = '$remoteVersion@$updatedAt@${best.sizeBytes ?? 0}';

      final prefs = await SharedPreferences.getInstance();
      final lastStamp = prefs.getString(_installedStampKey);

      final newerBySemver = remoteVersion.isNotEmpty && isNewerVersion(remoteVersion, current);
      final newerByStamp = remoteVersion == current &&
          updatedAt.isNotEmpty &&
          lastStamp != null &&
          lastStamp != stamp;

      if (!newerBySemver && !newerByStamp) {
        if (lastStamp == null && stamp.isNotEmpty) {
          await prefs.setString(_installedStampKey, stamp);
        }
        if (!silent) {
          status.value = status.value.copyWith(
            phase: UpdatePhase.upToDate,
            currentVersion: current,
            latestVersion: remoteVersion.isEmpty ? current : remoteVersion,
          );
        }
        return false;
      }

      status.value = status.value.copyWith(
        phase: UpdatePhase.downloading,
        currentVersion: current,
        latestVersion: remoteVersion.isEmpty ? current : remoteVersion,
        progress: 0.02,
      );

      final apkFile = await _downloadApk(
        downloadUrl,
        version: remoteVersion.isEmpty ? 'latest' : remoteVersion,
        expectedBytes: best.sizeBytes,
      );

      if (apkFile == null) {
        status.value = status.value.copyWith(phase: UpdatePhase.idle);
        return false;
      }

      await prefs.setString(_installedStampKey, stamp);

      status.value = status.value.copyWith(
        phase: UpdatePhase.readyToInstall,
        apkPath: apkFile.path,
        progress: 1.0,
      );

      await Permissions.showAlertNotification(
        id: 95,
        title: 'Ask Motari Update v$remoteVersion Ready',
        body: 'New update downloaded automatically. Tap to install v$remoteVersion now.',
      );

      await installDownloadedApk(apkFile.path);
      return true;
    } catch (_) {
      if (!silent) {
        status.value = status.value.copyWith(phase: UpdatePhase.idle);
      }
      return false;
    } finally {
      _busy = false;
    }
  }

  static Future<File?> _downloadApk(
    String url, {
    required String version,
    int? expectedBytes,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request).timeout(const Duration(minutes: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final total = response.contentLength ?? expectedBytes ?? 0;
      final safeVer = version.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final dir = await _apkDirectory();
      final outFile = File('${dir.path}/motari-$safeVer.apk');
      if (await outFile.exists()) {
        await outFile.delete();
      }

      final sink = outFile.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final pct = (received / total).clamp(0.02, 0.99);
          status.value = status.value.copyWith(
            phase: UpdatePhase.downloading,
            progress: pct,
          );
        }
      }
      await sink.flush();
      await sink.close();

      if (received < 1024 * 100) {
        // Reject truncated/invalid APK files (<100KB).
        await outFile.delete().catchError((_) => outFile);
        return null;
      }
      return outFile;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static Future<Directory> _apkDirectory() async {
    try {
      final customPath = await _channel.invokeMethod<String>('getUpdateDirectory');
      if (customPath != null && customPath.isNotEmpty) {
        final d = Directory(customPath);
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      }
    } catch (_) {}
    return Directory.systemTemp;
  }

  static Future<void> installDownloadedApk([String? path]) async {
    final targetPath = path ?? status.value.apkPath;
    if (targetPath == null || targetPath.isEmpty) return;

    status.value = status.value.copyWith(phase: UpdatePhase.installing);
    try {
      await _channel.invokeMethod('installApk', {'path': targetPath});
    } catch (_) {}
    // Keep readyToInstall state so the user can tap again if they dismissed the OS prompt.
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (status.value.phase == UpdatePhase.installing) {
        status.value = status.value.copyWith(phase: UpdatePhase.readyToInstall);
      }
    });
  }
}

/// Compact banner shown when an OTA self-update is downloading or ready to install.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: AppUpdater.status,
      builder: (context, s, _) {
        if (s.phase != UpdatePhase.downloading &&
            s.phase != UpdatePhase.readyToInstall &&
            s.phase != UpdatePhase.installing) {
          return const SizedBox.shrink();
        }

        final isReady = s.phase == UpdatePhase.readyToInstall;
        final isInstalling = s.phase == UpdatePhase.installing;
        final pct = (s.progress * 100).round();
        final label = isInstalling
            ? t('update.installing')
            : isReady
                ? t('update.ready', {'version': s.latestVersion ?? ''})
                : t('update.downloading', {'percent': pct});

        return GestureDetector(
          onTap: isReady ? () => AppUpdater.installDownloadedApk() : null,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF1A120B),
              border: Border.all(color: Brand.orange.withValues(alpha: 0.7)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isReady ? Icons.system_update : Icons.downloading,
                      size: 15,
                      color: Brand.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: Brand.text,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (isReady)
                      const Icon(Icons.arrow_forward_ios, size: 11, color: Brand.orange),
                  ],
                ),
                if (s.phase == UpdatePhase.downloading) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: s.progress,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF332211),
                      valueColor: const AlwaysStoppedAnimation<Color>(Brand.orange),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
