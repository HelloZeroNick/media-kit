/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2025 & onwards, Bao Han <erbws@foxmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
///
/// OHOS (HarmonyOS) implementation of the video surface widget.
///
/// Hosts the native ArkUI XComponent through the flutter_ohos PlatformView
/// mechanism. This file only compiles under the OpenHarmony Flutter SDK
/// (which provides the |OhosView| widget); other platforms use the stub.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Bridges surface lifecycle events pushed by the native XComponent
/// (OnSurfaceCreated / OnSurfaceDestroyed) to the controller.
///
/// The native side re-creates the surface on fullscreen switches and other
/// widget-tree rebuilds; the controller listens to this stream to re-bind
/// `--wid` when that happens.
class OhosVideoSurfaceEvents {
  static final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  static Stream<Map<String, dynamic>> get stream => _controller.stream;

  /// Installs the MethodCallHandler on the per-view channel. Called from
  /// |OhosView.onPlatformViewCreated|.
  static void attach(int viewId) {
    debugPrint('media_kit: [ohos] onPlatformViewCreated viewId=$viewId');
    final MethodChannel channel =
        MethodChannel('com.alexmercerind/media_kit_video_view$viewId');
    channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'OnSurfaceCreated') {
        _controller.add({
          'event': 'created',
          'surfaceId': call.arguments as String,
        });
      } else if (call.method == 'OnSurfaceDestroyed') {
        _controller.add({'event': 'destroyed'});
      }
    });

    // Query once: the XComponent surface may have been created before this
    // handler was installed (the native side renders the WrappedBuilder before
    // Flutter's onPlatformViewCreated fires), in which case the pushed event
    // would be lost.
    channel.invokeMethod<String>('GetSurfaceId').then((String? surfaceId) {
      if (surfaceId != null && surfaceId.isNotEmpty && surfaceId != '0') {
        _controller.add({'event': 'created', 'surfaceId': surfaceId});
      }
    }).catchError((Object error) {
      // Surface not created yet (null) or the channel is not ready: ignore.
    });
  }
}

/// Builds the |OhosView| hosting the native XComponent video output.
///
/// The viewType must match the registration in MediaKitVideoPlugin.ets
/// (VIDEO_VIEW_TYPE).
Widget buildOhosVideoSurface() {
  debugPrint('media_kit: [ohos] buildOhosVideoSurface()');
  return OhosView(
    viewType: 'com.alexmercerind/media_kit_video_view',
    creationParams: const <String, Object>{},
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: OhosVideoSurfaceEvents.attach,
  );
}
