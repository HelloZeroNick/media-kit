/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:ffi';
import 'dart:io';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/execmem_restriction.dart';
import 'package:media_kit/src/player/native/core/initializer_isolate.dart';
import 'package:media_kit/src/player/native/core/initializer_native_callable.dart';

/// {@template initializer}
///
/// Initializer
/// -----------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class Initializer {
  /// Singleton instance.
  static Initializer? _instance;

  /// {@macro initializer}
  Initializer._(this.mpv);

  /// {@macro initializer}
  factory Initializer(generated.MPV mpv) {
    _instance ??= Initializer._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Whether the event loop must be moved off the calling isolate.
  ///
  /// On HarmonyOS the `mmap` probe of [isExecmemRestricted] is not a reliable
  /// signal: depending on the system build the anonymous `PROT_READ|PROT_EXEC`
  /// mapping may succeed even though `NativeCallable` callbacks are still
  /// delivered on the isolate that created them. When that happens
  /// [InitializerNativeCallable] runs `mpv_wait_event` on the UI isolate, which
  /// both stalls the whole app whenever mpv emits events (start-up & first
  /// frame are the busiest moments) and keeps a callback in flight across
  /// `mpv_terminate_destroy`, aborting the process inside libmpv's Talloc
  /// canary check. Always use the worker isolate on HarmonyOS.
  static final bool _useIsolate =
      Platform.operatingSystem == 'ohos' || isExecmemRestricted;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    if (_useIsolate) {
      return InitializerIsolate().create(callback, options: options);
    } else {
      return InitializerNativeCallable(mpv).create(callback, options: options);
    }
  }

  /// Disposes [Pointer<mpv_handle>].
  ///
  /// Awaits the wakeup/event machinery being fully torn down, so the caller can
  /// destroy [ctx] afterwards without racing a still-running `mpv_wait_event`.
  Future<void> dispose(Pointer<generated.mpv_handle> ctx) async {
    if (_useIsolate) {
      await InitializerIsolate().dispose(mpv, ctx);
    } else {
      await InitializerNativeCallable(mpv).dispose(ctx);
    }
  }
}
