/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:collection';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:synchronized/synchronized.dart';

/// {@template initializer_native_callable}
///
/// InitializerNativeCallable
/// -------------------------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class InitializerNativeCallable {
  /// Singleton instance.
  static InitializerNativeCallable? _instance;

  /// {@macro initializer}
  InitializerNativeCallable._(this.mpv);

  /// {@macro initializer}
  factory InitializerNativeCallable(generated.MPV mpv) {
    _instance ??= InitializerNativeCallable._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    final ctx = mpv.mpv_create();
    for (final entry in options.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_option_string(ctx, name.cast(), value.cast());
      calloc.free(name);
      calloc.free(value);
    }
    mpv.mpv_initialize(ctx);
    final nativeCallable = WakeUpNativeCallable.listener(_callback);
    final nativeFunction = nativeCallable.nativeFunction;
    _locks[ctx.address] = Lock();
    _eventCallbacks[ctx.address] = callback;
    _wakeUpNativeCallables[ctx.address] = nativeCallable;
    // Ignored once the handle is disposed: `_callback` checks it before
    // touching the handle again, so a drain loop which resumes after
    // `dispose` cannot call `mpv_wait_event` on freed memory.
    _disposed[ctx.address] = false;
    mpv.mpv_set_wakeup_callback(ctx, nativeFunction.cast(), ctx.cast());
    return ctx;
  }

  /// Disposes [Pointer<mpv_handle>].
  ///
  /// Resolves only after an in-flight drain loop has observed [_disposed] and
  /// stopped touching the handle, so the caller may destroy it right away.
  ///
  /// Without this handshake the loop in [_callback] may still be suspended in
  /// `await _eventCallbacks[...](event)` when the handle is destroyed; its next
  /// `mpv_wait_event` then reads freed memory and libmpv aborts through its
  /// Talloc canary check:
  /// `Assertion failed: h->canary == CANARY (../ta/ta.c: ta_dbg_check_header)`.
  Future<void> dispose(Pointer<generated.mpv_handle> ctx) async {
    final address = ctx.address;
    _disposed[address] = true;

    // Stop libmpv from queueing new wakeups on the closing callback.
    mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);

    final lock = _locks[address];
    _locks.remove(address);

    // Wait for the drain loop (running inside `lock.synchronized`) to finish.
    // `_callback` re-checks [_disposed] every iteration and bails out.
    if (lock != null) {
      await lock.synchronized(() async {}).timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }

    _eventCallbacks.remove(address);
    _disposed.remove(address);
    _wakeUpNativeCallables.remove(address)?.close();
  }

  void _callback(Pointer<generated.mpv_handle> ctx) {
    final lock = _locks[ctx.address];
    if (lock == null) return;
    lock.synchronized(() async {
      while (!(_disposed[ctx.address] ?? true)) {
        final event = mpv.mpv_wait_event(ctx, 0);
        if (event == nullptr) return;
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_NONE) return;
        await _eventCallbacks[ctx.address]?.call(event);
      }
    });
  }

  final _locks = HashMap<int, Lock>();
  final _eventCallbacks = EventCallbackMap();
  final _wakeUpNativeCallables = WakeUpNativeCallableMap();
  /// Set once [dispose] starts, so an in-flight drain loop stops early.
  final _disposed = HashMap<int, bool>();
}

typedef WakeUpCallback = Void Function(Pointer<generated.mpv_handle>);
typedef WakeUpNativeCallable = NativeCallable<WakeUpCallback>;
typedef WakeUpNativeCallableMap = HashMap<int, WakeUpNativeCallable>;

typedef EventCallback = Future<void> Function(Pointer<generated.mpv_event>);
typedef EventCallbackMap = HashMap<int, EventCallback>;
