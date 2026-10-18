/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:ffi';
import 'dart:async';
import 'dart:isolate';
import 'dart:collection';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit/src/values.dart';

/// {@template initializer_isolate}
///
/// InitializerIsolate
/// ------------------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class InitializerIsolate {
  /// Singleton instance.
  static InitializerIsolate? _instance;

  /// {@macro initializer_isolate}
  InitializerIsolate._(this.libmpv);

  /// {@macro initializer_isolate}
  factory InitializerIsolate() {
    _instance ??= InitializerIsolate._(NativeLibrary.path);
    return _instance!;
  }

  /// Resolved libmpv dynamic library.
  final String libmpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    final completer = Completer();
    final receiver = ReceivePort();
    late SendPort port;
    late Pointer<generated.mpv_handle> handle;
    final isolate = await Isolate.spawn(
      _mainloop,
      receiver.sendPort,
    );
    // Completes once the worker isolate has left its `mpv_wait_event` loop and
    // is no longer touching the `mpv_handle`. [dispose] awaits it so the caller
    // can safely destroy the handle afterwards.
    final exited = Completer<void>();
    receiver.listen(
      (message) async {
        if (!completer.isCompleted && message is SendPort) {
          port = message;
          port.send(options);
          port.send(libmpv);
        } else if (!completer.isCompleted && message is int) {
          handle = Pointer.fromAddress(message);
          // Intialiation complete.
          completer.complete();
        }
        // Forward events to the supplied callback.
        else if (message != null) {
          Pointer<generated.mpv_event> event = Pointer.fromAddress(message);
          try {
            await callback(event);
          } catch (exception, stacktrace) {
            print(exception.toString());
            print(stacktrace.toString());
          }
          port.send(true);
        } else {
          // Worker has exited its event loop.
          if (!exited.isCompleted) {
            exited.complete();
          }
          receiver.close();
        }
      },
    );
    // Awaiting the retrieval of [Pointer<mpv_handle>].
    await completer.future;

    // Save the references.
    _ports[handle.address] = port;
    _isolates[handle.address] = isolate;
    _exited[handle.address] = exited;

    return handle;
  }

  /// Disposes [Pointer<mpv_handle>].
  ///
  /// Completes only after the worker isolate has left its `mpv_wait_event`
  /// loop, so callers may destroy the handle afterwards without racing a
  /// still-running `mpv_wait_event`.
  ///
  /// Without this handshake the worker may still be blocked inside
  /// `mpv_wait_event` (infinite timeout in release mode) when the handle is
  /// destroyed; its next call then touches freed memory and libmpv's Talloc
  /// canary check aborts the process:
  /// `Assertion failed: h->canary == CANARY (../ta/ta.c: ta_dbg_check_header)`.
  Future<void> dispose(
    generated.MPV mpv,
    Pointer<generated.mpv_handle> handle,
  ) async {
    final port = _ports.remove(handle.address);
    final isolate = _isolates.remove(handle.address);
    final exited = _exited.remove(handle.address);
    if (port == null || isolate == null) {
      return;
    }

    // Ask the worker to stop; it sets `disposed` and reports `null` once the
    // loop has actually been left.
    port.send(null);
    // Wake the (possibly infinite) `mpv_wait_event` so the loop can observe
    // `disposed` instead of waiting for the next real event.
    mpv.mpv_wakeup(handle);

    var exitedInTime = false;
    if (exited != null) {
      // Never let a wedged isolate block teardown forever.
      await exited.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      exitedInTime = exited.isCompleted;
    }

    // Only force-kill if the isolate did not confirm exit in time.
    if (!exitedInTime) {
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static void _mainloop(SendPort port) async {
    Completer completer = Completer();

    final receiver = ReceivePort();
    port.send(receiver.sendPort);

    late Map<String, String> options;
    late generated.MPV mpv;

    bool disposed = false;

    Pointer<generated.mpv_handle>? handle;

    receiver.listen(
      (message) {
        if (message is Map<String, String>) {
          options = message;
        } else if (message is String) {
          mpv = generated.MPV(DynamicLibrary.open(message));
          completer.complete();
        } else if (message is bool) {
          completer.complete();
        } else if (message == null) {
          if (handle != null) {
            disposed = true;
            completer.complete();
          }
        }
      },
    );

    await completer.future;

    handle ??= mpv.mpv_create();

    for (final entry in options.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_option_string(handle, name.cast(), value.cast());
      calloc.free(name);
      calloc.free(value);
    }

    mpv.mpv_initialize(handle);
    port.send(handle.address);

    while (!disposed) {
      completer = Completer();
      final event = mpv.mpv_wait_event(handle, kReleaseMode ? -1 : 0.1);
      if (disposed) {
        break;
      }
      if (event.ref.event_id != generated.mpv_event_id.MPV_EVENT_NONE) {
        port.send(event.address);
        await completer.future;
      } else {
        await Future.delayed(Duration.zero);
      }
    }

    port.send(null);
    receiver.close();
  }

  final _ports = HashMap<int, SendPort>();
  final _isolates = HashMap<int, Isolate>();
  /// Completes when the worker isolate has left its `mpv_wait_event` loop.
  final _exited = HashMap<int, Completer<void>>();
}
