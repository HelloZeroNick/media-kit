/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2025 & onwards, Bao Han <erbws@foxmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 *
 * PlatformView based video output for HarmonyOS.
 *
 * Instead of rendering into a Flutter texture (SurfaceTextureEntry), the video
 * is rendered by libmpv directly into an XComponent surface, which is embedded
 * into the Flutter scene as a platform view. When the HCPP switch
 * (enable_ohos_hybrid_composition) is on, this view is composed as an
 * independent ArkUI system layer and its pixels never flow through Flutter's
 * 8-bit texture pipeline — the prerequisite for true 10-bit HDR output.
 *
 * Surface lifecycle (mirrors mpv-arkts):
 *   onSurfaceCreated   -> surfaceId handed to libmpv via --wid (string, uint64
 *                         safe) and pushed to Dart so the controller re-binds
 *                         after surface recreation (fullscreen switches etc.)
 *   onSurfaceDestroyed -> pushed to Dart; wid is invalidated.
 *
 * NOTE: surfaceId is carried as a string end-to-end. It is a uint64 value and
 * does not always fit the 2^53 precision of a JS/ArkTS number.
 */

import MethodChannel, {
  MethodCallHandler,
  MethodResult
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import PlatformView, { Params } from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import StandardMethodCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/StandardMethodCodec';
import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import common from '@ohos.app.ability.common';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import mediaKitVideoNative from 'libmedia_kit_video_native.so';

const TAG = 'VideoOutputView';
export const VIDEO_VIEW_CHANNEL_PREFIX = 'com.alexmercerind/media_kit_video_view';

// ---------------------------------------------------------------------------
// Explicit types (ArkTS forbids untyped object literals).
// ---------------------------------------------------------------------------

/** Rect payload of [VideoOutputManager.Create]. */
export interface SurfaceRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** Payload of a resolved [VideoOutputManager.Create] (same shape as the texture path). */
export interface VideoOutputCreateResult {
  id: number;
  wid: string;
  rect: SurfaceRect;
}

/**
 * Interface implemented by the factory so a disposed view can drop the
 * factory's reference without introducing a circular import between the view
 * and the factory.
 */
export interface VideoOutputViewOwner {
  onViewDisposed(): void;
}

// ---------------------------------------------------------------------------
// XComponent controller: receives the surface lifecycle of the XComponent.
// ---------------------------------------------------------------------------
export class VideoSurfaceController extends XComponentController {
  private surfaceId: string | null = null;
  private listener: ((event: string, surfaceId: string | null) => void) | null = null;

  setListener(listener: (event: string, surfaceId: string | null) => void): void {
    this.listener = listener;
  }

  getSurfaceId(): string | null {
    return this.surfaceId;
  }

  // Unified surface-ready handling, callable from BOTH onSurfaceCreated (the
  // XComponentController callback) and the XComponent .onLoad() event, since
  // the former is not guaranteed to fire in every hosting scenario (e.g. when
  // the XComponent is hosted inside a PlatformView / BuilderNode).
  notifySurfaceReady(surfaceId: string): void {
    if (surfaceId == null || surfaceId.length === 0 || surfaceId === '0') {
      return;
    }
    if (this.surfaceId === surfaceId) {
      return; // dedupe (onSurfaceCreated + onLoad may both fire)
    }
    Log.i(TAG, `surface ready: ${surfaceId}`);
    this.surfaceId = surfaceId;

    // The surface buffer format / colorspace / HDR metadata are OWNED by mpv's
    // OHOS video output: mpv configures them for whatever output it negotiates
    // (10-bit HDR for HDR content, 8-bit for SDR). This mirrors the reference
    // mpv-arkts player, which only hands --wid to mpv and never touches the
    // surface. Setting the format behind mpv's back produced a mismatched,
    // washed-out ("泛白") image for BOTH HDR and SDR content.
    this.listener?.('created', surfaceId);
  }

  // Safety net for hosts where the surface lifecycle callbacks are not
  // delivered (observed with the XComponent hosted inside a PlatformView: the
  // RS surface node is created but neither onSurfaceCreated nor .onLoad fire).
  // getXComponentSurfaceId() returns the id as soon as the controller is bound
  // to a live XComponent surface, so we can poll for it.
  tryAcquireSurfaceId(): boolean {
    if (this.surfaceId != null) {
      return true;
    }
    try {
      const id: string = this.getXComponentSurfaceId();
      if (id != null && id.length > 0 && id !== '0') {
        Log.i(TAG, `poll acquired surfaceId=${id}`);
        this.notifySurfaceReady(id);
        return true;
      }
    } catch (e) {
      Log.e(TAG, `tryAcquireSurfaceId failed: ${e}`);
    }
    return false;
  }

  onSurfaceCreated(surfaceId: string): void {
    Log.i(TAG, `onSurfaceCreated: ${surfaceId}`);
    this.notifySurfaceReady(surfaceId);
  }

  onSurfaceDestroyed(_: string): void {
    Log.i(TAG, 'onSurfaceDestroyed');
    this.surfaceId = null;
    this.listener?.('destroyed', null);
  }
}

// ---------------------------------------------------------------------------
// ArkUI component hosting the XComponent.
// ---------------------------------------------------------------------------
@Component
struct VideoComponent {
  // NOTE: deliberately NOT @ObjectLink. flutter_ohos' Params is not decorated
  // with @Observed, so @ObjectLink fails at runtime with
  // "assigned value is not decorated by @Observed" and the linked value (and
  // thus the XComponent controller taken from it) cannot be trusted.
  // The platform view reference never changes, so a plain member is enough.
  platformView: VideoOutputView | null = null;

  aboutToAppear(): void {
    // Safety net: neither XComponentController.onSurfaceCreated nor
    // XComponent.onLoad is delivered when the XComponent is hosted inside a
    // PlatformView. Poll getXComponentSurfaceId() until the controller is bound
    // to a live surface (or give up after ~10s so we do not spin forever).
    let tries: number = 0;
    const timer: number = setInterval(() => {
      tries++;
      const ready: boolean = this.platformView?.surfaceController.tryAcquireSurfaceId() ?? false;
      if (ready || tries >= 40) {
        clearInterval(timer);
        if (!ready) {
          Log.e(TAG, 'surface id never became available (poll gave up)');
        }
      }
    }, 250);
  }

  build() {
    // The ArkUI root must carry an explicit 100% size: in a PlatformView the
    // builder content is mounted into a BuilderNode slot, and
    // LayoutPolicy.matchParent may not resolve a parent size there (leaving the
    // XComponent at 0x0 -> no surface is ever produced).
    Column() {
      XComponent({
        id: `media_kit_video_${this.platformView?.viewId ?? 0}`,
        type: XComponentType.SURFACE,
        controller: this.platformView?.surfaceController,
      })
        .width('100%')
        .height('100%')
        // Fallback: XComponentController.onSurfaceCreated does not always fire
        // when the XComponent is hosted inside a PlatformView; onLoad +
        // getXComponentSurfaceId() is the documented way to obtain the surface
        // id (see HarmonyOS XComponent HDR guidance).
        .onLoad(() => {
          try {
            const controller = this.platformView?.surfaceController;
            if (controller == null) {
              Log.e(TAG, 'onLoad: platformView/controller is null');
              return;
            }
            const id: string = controller.getXComponentSurfaceId();
            Log.i(TAG, `onLoad surfaceId=${id}`);
            controller.notifySurfaceReady(id);
          } catch (e) {
            Log.e(TAG, `onLoad failed: ${e}`);
          }
        })
    }
    .width('100%')
    .height('100%')
  }
}

// The builder only reads immutable construction parameters (viewId &
// surfaceController), so pass-by-value semantics of @Builder are fine here.
@Builder
function VideoViewBuilder(params: Params) {
  VideoComponent({ platformView: params.platformView as VideoOutputView })
}

// ---------------------------------------------------------------------------
// PlatformView implementation.
// ---------------------------------------------------------------------------
@Observed
export class VideoOutputView extends PlatformView implements MethodCallHandler {
  readonly viewId: number;
  readonly surfaceController: VideoSurfaceController = new VideoSurfaceController();
  methodChannel: MethodChannel;
  private owner: VideoOutputViewOwner | null = null;
  // Whether the CURRENT video content is HDR. Drives the surface colorspace /
  // HDR metadata tagging. Persisted so it can be re-applied whenever the
  // XComponent recreates its surface (fullscreen switches, rebuilds, ...).
  private hdrEnabled: boolean = false;
  // Content/mastering peak luminance (nits) reported in the HDR static
  // metadata. Supplied by Dart from mpv's video-params sig-peak.
  private hdrMaxLuminance: number = 1000.0;

  constructor(context: common.Context, viewId: number, args: ESObject, messenger: BinaryMessenger) {
    super();
    Log.i(TAG, `VideoOutputView constructed viewId=${viewId}`);
    this.viewId = viewId;
    this.methodChannel =
      new MethodChannel(messenger, `${VIDEO_VIEW_CHANNEL_PREFIX}${viewId}`, StandardMethodCodec.INSTANCE);
    this.methodChannel.setMethodCallHandler(this);
    this.surfaceController.setListener((event: string, surfaceId: string | null) => {
      if (event === 'created' && surfaceId != null) {
        // NOTE: the surface is intentionally left UNTOUCHED here. libmpv's OHOS
        // video output configures the NativeWindow itself — its own log says
        //   mpv/vo/gpu-next/ohos: NativeWindow output switched to BT.2020 PQ
        // so tagging it again from the outside (with a different range) fights
        // mpv and washes out the picture. See OhosVideoController.useSurfaceHdrTag.
        //
        // Push the surface id to Dart so the controller binds / re-binds --wid.
        // The initial push may race with Dart's channel handler installation;
        // Dart also queries GetSurfaceId after attaching, so no push is missed.
        this.methodChannel.invokeMethod('OnSurfaceCreated', surfaceId);
      } else if (event === 'destroyed') {
        this.methodChannel.invokeMethod('OnSurfaceDestroyed', null);
      }
    });
  }

  // Called from Dart when the current content's dynamic range changes. Tags the
  // surface as HDR (BT.2020 PQ + HDR10 metadata) or SDR accordingly, so the
  // compositor interprets mpv's output correctly instead of showing washed-out
  // ("泛白") HDR.
  setHdr(enabled: boolean, maxLuminance: number): void {
    Log.i(TAG, `setHdr: ${enabled}, peak=${maxLuminance}`);
    this.hdrEnabled = enabled;
    this.hdrMaxLuminance = maxLuminance > 0 ? maxLuminance : 1000.0;
    this.applyHdrSurface();
  }

  private applyHdrSurface(): void {
    const surfaceId: string | null = this.surfaceController.getSurfaceId();
    if (surfaceId == null || surfaceId.length === 0) {
      // Surface not created yet: it will be applied by the 'created' listener.
      return;
    }
    try {
      const ok: boolean =
        mediaKitVideoNative.setSurfaceHdr(surfaceId, this.hdrEnabled, this.hdrMaxLuminance);
      Log.i(TAG, `setSurfaceHdr(${surfaceId}, ${this.hdrEnabled}, ${this.hdrMaxLuminance}): ${ok}`);
    } catch (e) {
      Log.e(TAG, `setSurfaceHdr failed: ${e}`);
    }
  }

  // Called by the factory that created this view (for cleanup on dispose).
  setOwner(owner: VideoOutputViewOwner): void {
    this.owner = owner;
  }

  // Whether the XComponent surface has been created & is ready for mpv.
  isSurfaceReady(): boolean {
    return this.surfaceController.getSurfaceId() != null;
  }

  getView(): WrappedBuilder<[Params]> {
    Log.i(TAG, 'getView() called');
    return new WrappedBuilder(VideoViewBuilder);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'GetSurfaceId') {
      // Dart queries the current surface id right after installing its channel
      // handler, covering the case where OnSurfaceCreated fired before.
      result.success(this.surfaceController.getSurfaceId());
      return;
    }
    result.notImplemented();
  }

  dispose(): void {
    this.methodChannel.setMethodCallHandler(null);
    // Let the factory drop its reference so a disposed view is never reused.
    this.owner?.onViewDisposed();
    this.owner = null;
  }
}
