/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';
import 'package:media_kit_video/src/video/video_ohos_view_interface.dart';

/// {@template ohos_video_controller}
///
/// OhosVideoController
/// ----------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on Ohos.
///
/// {@endtemplate}
class OhosVideoController extends PlatformVideoController {
  /// Whether [OhosVideoController] is supported on the current platform or not.
  static bool get supported => Platform.operatingSystem == 'ohos';

  /// Whether to render through a native PlatformView (ArkUI XComponent)
  /// instead of a Flutter texture.
  ///
  /// PlatformView mode keeps the video pixels out of Flutter's compositor:
  /// combined with the HCPP switch (enable_ohos_hybrid_composition) the video
  /// surface is composed as an independent ArkUI system layer, which is
  /// required for true 10-bit HDR output.
  static bool usePlatformView = true;

  /// Pointer address to the global object reference of `OHNativeWindow`.
  final ValueNotifier<int?> wid = ValueNotifier<int?>(null);

  /// [Lock] used to synchronize [onLoadHooks], [onUnloadHooks] & [subscription].
  final lock = Lock();

  NativePlayer get platform => player.platform as NativePlayer;

  Future<void> setProperty(String key, String value) async {
    await platform.setProperty(key, value, waitForInitialization: false);
  }

  Future<void> setProperties(Map<String, String> properties) async {
    for (final entry in properties.entries) {
      await setProperty(entry.key, entry.value);
    }
  }

  /// [StreamSubscription] for listening to video [Rect].
  StreamSubscription<VideoParams>? videoParamsSubscription;

  /// [StreamSubscription] for surface recreation events pushed from the
  /// native XComponent (platform view mode only). Lets the controller re-bind
  /// `--wid` after the surface is recreated (fullscreen switches, ...).
  StreamSubscription<Map<String, dynamic>>? _surfaceEventsSubscription;

  /// The wid currently bound to mpv, used to ignore the redundant initial
  /// "OnSurfaceCreated" that always follows creation.
  int? _boundWid;

  /// Last dynamic-range state pushed to the native surface (platform view mode).
  bool _lastHdr = false;

  /// {@macro ohos_video_controller}
  OhosVideoController._(
    super.player,
    super.configuration,
  ) {
    videoParamsSubscription = player.stream.videoParams.listen(
      (event) => lock.synchronized(() async {
        // Report the current dynamic range to the native surface so it can tag
        // the XComponent surface as HDR (BT.2020 PQ + HDR10 metadata) or SDR.
        // Without the tag the compositor treats mpv's PQ output as SDR and the
        // picture looks washed out ("泛白"). HDR is detected from mpv's
        // video-params: PQ / HLG transfer, or a signal peak above SDR.
        if (usePlatformView) {
          final bool isHdr = event.gamma == 'pq' ||
              event.gamma == 'hlg' ||
              (event.sigPeak != null && event.sigPeak! > 1.0);
          debugPrint('media_kit: [ohos] video-params gamma=${event.gamma} '
              'primaries=${event.primaries} sigPeak=${event.sigPeak} '
              '-> hdr=$isHdr');
          if (isHdr != _lastHdr) {
            _lastHdr = isHdr;
            try {
              await _channel.invokeMethod(
                'VideoOutputManager.SetHdr',
                <String, dynamic>{'hdr': isHdr},
              );
            } catch (_) {
              // No platform view / channel not ready: best-effort.
            }
            // mpv negotiates its video output (bit depth, transfer, range)
            // against the surface's colorspace when `vo` starts — which happens
            // BEFORE this first video-params event, i.e. while the surface is
            // still tagged SDR. Restarting the video output here makes mpv
            // re-negotiate against the re-tagged (HDR) surface; otherwise it
            // keeps the SDR output it already picked and HDR never takes effect.
            final int? currentWid = wid.value;
            if (currentWid != null && currentWid != 0) {
              try {
                await setProperty('vo', 'null');
                await setProperty('vo', configuration.vo!);
              } catch (_) {
                // Best-effort: a failed restart must not break playback.
              }
            }
          }
        }

        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        final isZero = width == 0 || height == 0;
        final isSame = width == rect.value?.width.toInt() &&
            height == rect.value?.height.toInt();
        if (isZero || isSame) {
          return;
        }

        final handle = await player.handle;

        // In platform view mode the XComponent manages its own surface size
        // (mpv adapts to the native window), so no texture resize is needed.
        if (!usePlatformView) {
          await _channel.invokeMethod(
            'VideoOutputManager.SetSurfaceSize',
            {
              'handle': handle.toString(),
              'width': width.toString(),
              'height': height.toString(),
            },
          );
        }
        await setProperties({
          'ohos-surface-size': [width, height].join('x'),
        });

        rect.value = Rect.fromLTWH(
          0.0,
          0.0,
          width.toDouble(),
          height.toDouble(),
        );

        if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
          waitUntilFirstFrameRenderedCompleter.complete();
        }
      }),
    );
  }

  /// {@macro ohos_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    final bool isEmulator = await _channel.invokeMethod('Utils.IsEmulator');
    if (isEmulator) {
      throw UnsupportedError(
        '[VideoController] does not support emulator.'
        ' '
        'Please use actual device.',
      );
    }

    Future<String> getDefaultHwdec() async {
      bool hw = configuration.enableHardwareAcceleration;
      return hw ? 'auto' : 'no';
    }

    // Update [configuration] to have default values.
    configuration = configuration.copyWith(
      vo: configuration.vo ?? 'gpu-next',
      hwdec: configuration.hwdec ?? await getDefaultHwdec(),
    );

    // Retrieve the native handle of the [Player].
    final handle = await player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = OhosVideoController._(
      player,
      configuration,
    );

    // Register [_dispose] for execution upon [Player.dispose].
    player.platform?.release.add(controller._dispose);

    // Store the [VideoController] in the [_controllers].
    _controllers[handle] = controller;

    // Subscribe BEFORE Create: in platform view mode the |OhosView| (and thus
    // the XComponent surface) can be created at any time once the widget
    // builds — possibly before this create() call completes — so the listener
    // must be in place first.
    if (usePlatformView) {
      controller._surfaceEventsSubscription =
          OhosVideoSurfaceEvents.stream.listen(controller._onSurfaceEvent);
    }

    final Map<dynamic, dynamic>? data = await _channel.invokeMethod(
      'VideoOutputManager.Create',
      {
        'handle': handle.toString(),
        'mode': usePlatformView ? 'platform_view' : 'texture',
      },
    );

    if (data == null) {
      throw StateError('[OhosVideoController] failed to create video output.');
    }

    final id = (data['id'] as num).toInt();
    // wid is a uint64 surface id. In platform view mode the native side sends
    // it as a string (lossless); the texture path sends it as a number.
    final dynamic rawWid = data['wid'];
    final int wid = rawWid is num
        ? rawWid.toInt()
        : int.tryParse(rawWid.toString()) ?? 0;
    final rect = Rect.fromLTWH(
      (data['rect']['left'] as num).toDouble(),
      (data['rect']['top'] as num).toDouble(),
      (data['rect']['width'] as num).toDouble(),
      (data['rect']['height'] as num).toDouble(),
    );

    controller.id.value = id;
    controller.rect.value = rect;
    controller.wid.value = wid;

    await controller.lock.synchronized(() async {
      // MPV's HarmonyOS video output requires a valid surface ID before the
      // GPU video output is initialized.
      await controller.setProperty('vo', 'null');
      await controller.setProperties(
        {
          'ohos-surface-size': '${rect.width.toInt()}x${rect.height.toInt()}',
          'wid': wid.toString(),
          'hwdec': configuration.hwdec!,
          'vid': 'auto',
          'force-window': 'yes',
          'sub-use-margins': 'no',
          'sub-scale-with-window': 'no',
          'osd-font': 'HarmonyOS Sans SC',
          'vd-lavc-ohos-smart-fluency': 'yes',
          // Let mpv negotiate the output colorspace with the OHOS surface.
          // This mirrors the reference mpv-arkts player, which sets ONLY this
          // hint and leaves prim/trc/peak to mpv's own HDR surface negotiation.
          // Forcing --target-trc=pq / --target-prim=bt.2020 pushed a PQ signal
          // into a surface the compositor still treated as SDR, which made
          // every frame — HDR and SDR alike — look washed out ("泛白").
          'target-colorspace-hint': 'yes',
        },
      );
      // In platform view mode the surface may not exist yet: |wid == 0| is a
      // placeholder returned immediately by VideoOutputManager.Create (it must
      // not block, see VideoOutputViewFactory). Enabling vo without a valid
      // window would make mpv fail, so it is deferred until the surface-ready
      // event re-binds --wid in _onSurfaceEvent.
      if (!usePlatformView || wid != 0) {
        await controller.setProperty('vo', configuration.vo!);
      }
    });

    if (usePlatformView) {
      // Track the wid bound during creation; surface (re)creation events are
      // handled by the subscription installed above.
      controller._boundWid = wid;
    }

    // Return the [PlatformVideoController].
    return controller;
  }

  /// Handles surface recreation events from the native XComponent.
  ///
  /// On surface destroy the mpv window id becomes invalid; on surface create a
  /// new id must be re-bound. The initial "created" event that always follows
  /// creation is ignored via [_boundWid].
  Future<void> _onSurfaceEvent(Map<String, dynamic> event) async {
    await lock.synchronized(() async {
      final String type = event['event'] as String;
      if (type == 'destroyed') {
        await setProperty('vo', 'null');
        wid.value = null;
        _boundWid = null;
        return;
      }
      if (type == 'created') {
        final int newWid = int.tryParse(event['surfaceId'] as String) ?? 0;
        if (newWid == 0 || newWid == _boundWid) {
          return;
        }
        wid.value = newWid;
        await setProperty('vo', 'null');
        await setProperties({
          'wid': newWid.toString(),
          'vid': 'auto',
        });
        await setProperty('vo', configuration.vo!);
        _boundWid = newWid;
      }
    });
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({
    int? width,
    int? height,
  }) {
    throw UnsupportedError(
      '[OhosVideoController.setSize] is not available on Ohos',
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    await videoParamsSubscription?.cancel();
    await _surfaceEventsSubscription?.cancel();
    final handle = await player.handle;
    _controllers.remove(handle);
    if (usePlatformView) {
      await _channel.invokeMethod('VideoOutputManager.DisposeView', {});
    }
    await _channel.invokeMethod(
      'VideoOutputManager.Dispose',
      {
        'handle': handle.toString(),
      },
    );
    wid.dispose();
    super.dispose();
  }

  /// Currently created [OhosVideoController]s.
  static final _controllers = HashMap<int, OhosVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');
}
