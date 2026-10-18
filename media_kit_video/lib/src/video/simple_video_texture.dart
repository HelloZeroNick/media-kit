/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:media_kit_video/src/video_controller/ohos_video_controller/ohos_video_controller.dart';
import 'package:media_kit_video/src/video/ohos_platform_video.dart';

/// {@template simple_video}
///
/// SimpleVideo
/// -----------
/// Bare video output, without any of the controls, subtitles, wakelock &
/// fullscreen handling that [Video] brings along.
///
/// It exists so that a consumer which renders its own chrome around the video
/// (a custom player UI, or a picture-in-picture overlay) can mount just the
/// surface. Size the widget yourself: on a platform view the geometry is taken
/// from the layer tree, so the [aspectRatio] only shapes the surrounding
/// [SizedBox] here.
///
/// **HarmonyOS**
/// * The output is a [Texture] by default, but a
///   [VideoControllerConfiguration.usePlatformView] controller renders into a
///   native XComponent instead and there is no texture ID to wait for. The
///   platform view is mounted here in that case, since a texture-only
///   implementation would show a black rectangle (or nothing at all) for HDR
///   output.
///
/// {@endtemplate}
class SimpleVideo extends StatefulWidget {
  /// Background color to fill the video background.
  final Color fill;

  /// The [VideoController] reference to control this [SimpleVideo] output.
  final VideoController controller;

  /// Preferred aspect ratio of the viewport.
  final double? aspectRatio;

  /// Filter quality of the [Texture] widget displaying the video output.
  final FilterQuality filterQuality;

  /// {@macro simple_video}
  const SimpleVideo({
    super.key,
    this.fill = Colors.black,
    required this.controller,
    this.aspectRatio,
    this.filterQuality = FilterQuality.low,
  });

  @override
  State<SimpleVideo> createState() => SimpleVideoState();
}

class SimpleVideoState extends State<SimpleVideo> {
  late double _devicePixelRatio;
  int? _width;
  int? _height;
  late bool _visible;
  final List<StreamSubscription<int?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _width = widget.controller.player.state.width;
    _height = widget.controller.player.state.height;
    _visible = (_width ?? 0) > 0 && (_height ?? 0) > 0;
    // --------------------------------------------------
    // Do not show the video frame until width & height are available.
    // Since [ValueNotifier<Rect?>] inside [VideoController] only gets updated by the render loop (i.e. it will not fire when video's width & height are not available etc.), it's important to handle this separately here.
    _subscriptions.addAll(
      [
        widget.controller.player.stream.width.listen(
          (value) {
            _width = value;
            _updateVisible();
          },
        ),
        widget.controller.player.stream.height.listen(
          (value) {
            _height = value;
            _updateVisible();
          },
        ),
      ],
    );
    // --------------------------------------------------
  }

  void _updateVisible() {
    final visible = (_width ?? 0) > 0 && (_height ?? 0) > 0;
    if (_visible != visible) {
      _visible = visible;
      // [VideoController.rect] is written by the platform render loop, which
      // may not have ticked yet when width & height first become known (a Live
      // Photo is only a couple of seconds long). Nudging it rebuilds anything
      // listening to [rect] -- an enclosing danmaku mask, for instance -- and
      // the [ListenableBuilder] below, so this widget re-evaluates [_visible]
      // and swaps its empty branch for the [Texture] one.
      //
      // setState is required on top of it: [VideoController.rect] is only
      // reported for controls-less surfaces here, and the live photo viewer
      // never touches it otherwise.
      // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
      widget.controller.rect.notifyListeners();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }

  @override
  Widget build(BuildContext context) {
    final ctr = widget.controller;
    return ListenableBuilder(
      // [VideoController.notifier] is in the list because the platform
      // controller is only created after the first frame, and that is when the
      // platform-view branch below can be taken for the first time.
      listenable: Listenable.merge([ctr.id, ctr.rect, ctr.notifier]),
      builder: (context, _) {
        final id = ctr.id.value;
        final rect = ctr.rect.value;
        // On HarmonyOS the video may live in a native XComponent instead of a
        // texture, in which case there is no texture ID to wait for: the
        // platform view creates the surface itself once it is mounted.
        //
        // The check has to go through [ctr.notifier] rather than [ctr.rect]:
        // its declared type is [PlatformVideoController?], a supertype of
        // [OhosVideoController], which is what allows the type promotion below.
        // [VideoController] itself is unrelated to it and would not promote.
        final notifier = ctr.notifier.value;
        if (notifier is OhosVideoController && notifier.usePlatformView) {
          // The engine places the view from the layer tree; [rect] only sizes
          // this [SizedBox]. Nothing is known about the video before mpv
          // reports video-params, so stay empty until then.
          if (rect == null) {
            return const SizedBox.shrink();
          }
          return SizedBox(
            width: widget.aspectRatio == null
                ? rect.width / _devicePixelRatio
                : rect.height / _devicePixelRatio * widget.aspectRatio!,
            height: rect.height / _devicePixelRatio,
            child: OhosPlatformVideo(controller: notifier),
          );
        }
        if (id != null && rect != null && _visible) {
          return SizedBox(
            width: widget.aspectRatio == null
                ? rect.width / _devicePixelRatio
                : rect.height / _devicePixelRatio * widget.aspectRatio!,
            height: rect.height / _devicePixelRatio,
            child: Stack(
              children: [
                Texture(textureId: id, filterQuality: widget.filterQuality),
                // Keep the |Texture| hidden before the first frame renders. In native implementation, if no default frame size is passed (through VideoController), a starting 1 pixel sized texture/surface is created to initialize the render context & check for H/W support.
                // This is then resized based on the video dimensions & accordingly texture ID, texture, EGLDisplay, EGLSurface etc. (depending upon platform) are also changed. Just don't show that 1 pixel texture to the UI.
                if (rect.width <= 1.0 && rect.height <= 1.0)
                  Positioned.fill(child: ColoredBox(color: widget.fill)),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}
