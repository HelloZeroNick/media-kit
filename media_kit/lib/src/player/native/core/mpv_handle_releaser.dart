/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';

/// Releases an [mpv_handle] whose event loop is still attached, guaranteeing
/// the handle is never destroyed from inside an event callback.
///
/// [Initializer.dispose] only stops the event loop; the loop's callback may
/// still be in flight when it returns (the isolate implementation exits its
/// `mpv_wait_event` loop only after being woken up, the `NativeCallable` one
/// keeps waiting until the current callback returns). Destroying the handle
/// synchronously at that point is a use-after-free — the crash this class
/// guards against when a second player instance shares the event loop
/// machinery (e.g. dynamic-screenshot transcoding).
///
/// [destroy] is therefore always deferred by [destroyDelay], mirroring how
/// [NativePlayer.dispose] delays `mpv_terminate_destroy`, so the handle is
/// never torn down from inside an `MPV_EVENT_SHUTDOWN` callback.
///
/// [release] takes effect only once: transcode completion and user
/// cancellation may both arrive, and a repeated `mpv_terminate_destroy` is a
/// double free.
class MpvHandleReleaser {
  MpvHandleReleaser({
    required this.detachEvents,
    required this.quit,
    required this.destroy,
    this.schedule = Timer.new,
  });

  /// Matches the delay [NativePlayer.dispose] gives `mpv_terminate_destroy`.
  static const destroyDelay = Duration(seconds: 5);

  /// Stops the event callbacks ([Initializer.dispose]).
  final void Function() detachEvents;

  /// Makes a still-running core exit immediately so the deferred destroy does
  /// not keep burning CPU.
  final void Function() quit;

  /// `mpv_terminate_destroy`.
  final void Function() destroy;

  final Timer Function(Duration duration, void Function() callback) schedule;

  bool _released = false;

  /// [quitCore]: true when the core is still running (user cancellation);
  /// false after `MPV_EVENT_SHUTDOWN`, when the core is already exiting.
  void release({required bool quitCore}) {
    if (_released) return;
    _released = true;
    detachEvents();
    if (quitCore) quit();
    schedule(destroyDelay, destroy);
  }
}
