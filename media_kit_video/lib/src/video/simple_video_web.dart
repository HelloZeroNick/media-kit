/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:media_kit_video/src/video_controller/video_controller.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template simple_video}
///
/// SimpleVideo
/// -----------
///
/// A minimal, controls-less video surface for the web.
///
/// The web counterpart of `simple_video_texture.dart`: the video lives in an
/// `<video>` element registered by the platform controller, so it is rendered
/// through [HtmlElementView] instead of a Flutter texture. Everything else --
/// the absence of controls, and the [VideoController.rect] re-notification --
/// behaves exactly like the texture implementation.
///
/// {@endtemplate}
class SimpleVideo extends StatefulWidget {
  /// Fill color, painted while the first frame is not available yet.
  final Color fill;

  /// The [VideoController] whose video output should be displayed.
  final VideoController controller;

  /// Aspect ratio override, see [Video.aspectRatio].
  final double? aspectRatio;

  /// Texture sampling quality for the web implementation, where the element is
  /// composited by the browser: only [FilterQuality.low] and
  /// [FilterQuality.high] are meaningful translations of `image-rendering`.
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
  SimpleVideoState createState() => SimpleVideoState();
}

class SimpleVideoState extends State<SimpleVideo> {
  /// Width & height of the decoded video, as reported by the player.
  late int? _width = widget.controller.player.state.width;
  late int? _height = widget.controller.player.state.height;

  /// Whether a frame of a non-zero size can be shown.
  late bool _visible = (_width ?? 0) > 0 && (_height ?? 0) > 0;

  late final StreamSubscription<int?> _widthSubscription;
  late final StreamSubscription<int?> _heightSubscription;

  @override
  void initState() {
    super.initState();
    // ------------------------------------------------------------------
    // Do not show the video frame until width & height are available.
    // Since [ValueNotifier<Rect?>] inside [VideoController] only gets updated
    // by the render loop (i.e. it will not fire when video's width & height
    // are not available etc.), it's important to handle this separately here.
    _widthSubscription = widget.controller.player.stream.width.listen(
      (value) {
        _width = value;
        _syncVisibility();
      },
    );
    _heightSubscription = widget.controller.player.stream.height.listen(
      (value) {
        _height = value;
        _syncVisibility();
      },
    );
  }

  void _syncVisibility() {
    final visible = (_width ?? 0) > 0 && (_height ?? 0) > 0;
    if (_visible == visible) return;
    _visible = visible;
    // [VideoController.rect] is only written by the platform render loop, so
    // nudge it here to make the [ValueListenableBuilder] below re-evaluate.
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    widget.controller.rect.notifyListeners();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _widthSubscription.cancel();
    _heightSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctr = widget.controller;
    return ValueListenableBuilder<PlatformVideoController?>(
      valueListenable: ctr.notifier,
      builder: (context, notifier, _) {
        if (notifier == null) return const SizedBox();
        return ValueListenableBuilder<int?>(
          valueListenable: notifier.id,
          builder: (context, id, _) {
            return ValueListenableBuilder<Rect?>(
              valueListenable: notifier.rect,
              builder: (context, rect, _) {
                if (id != null && rect != null && _visible) {
                  return SizedBox(
                    width: widget.aspectRatio == null
                        ? rect.width
                        : rect.height * widget.aspectRatio!,
                    height: rect.height,
                    child: Stack(
                      children: [
                        const SizedBox(),
                        Positioned.fill(
                          child: HtmlElementView(
                            key: ValueKey(id),
                            viewType: 'com.alexmercerind.media_kit_video.$id',
                          ),
                        ),
                        // Keep the output hidden before the first frame
                        // renders, see [Video].
                        if (rect.width <= 1.0 && rect.height <= 1.0)
                          Positioned.fill(
                            child: ColoredBox(color: widget.fill),
                          ),
                      ],
                    ),
                  );
                }
                return const SizedBox();
              },
            );
          },
        );
      },
    );
  }
}
