/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2025 & onwards, Bao Han <erbws@foxmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */

import MessageCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/MessageCodec';
import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import PlatformViewFactory from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformViewFactory';
import PlatformView from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import { MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import common from '@ohos.app.ability.common';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import {
  VideoOutputView,
  VideoOutputViewOwner,
  VideoOutputCreateResult
} from './VideoOutputView';

export class VideoOutputViewFactory extends PlatformViewFactory implements VideoOutputViewOwner {
  private messenger: BinaryMessenger;
  // Last created view. media_kit typically hosts a single video surface per
  // engine; VideoOutputManager.Create resolves against this instance.
  public currentView: VideoOutputView | null = null;

  constructor(messenger: BinaryMessenger, createArgsCodes: MessageCodec<Object>) {
    super(createArgsCodes);
    this.messenger = messenger;
  }

  public create(context: common.Context, viewId: number, args: Object): PlatformView {
    Log.i('VideoOutputViewFactory', `create viewId=${viewId}`);
    const view = new VideoOutputView(context, viewId, args, this.messenger);
    view.setOwner(this);
    this.currentView = view;
    return view;
  }

  // Entry point for VideoOutputManager.Create (platform_view mode).
  //
  // IMPORTANT: this ALWAYS replies immediately and never waits for the
  // XComponent surface. In Flutter, the VideoController's create() awaits this
  // reply before it publishes its notifier, and the |OhosView| is only built
  // once that notifier is published. Waiting here for the surface would
  // deadlock: no surface -> no reply -> no OhosView -> no surface.
  //
  // The surface id is therefore returned best-effort (may be '0'); once the
  // surface is created the view pushes it to Dart via the per-view channel
  // (OnSurfaceCreated) and Dart may also query GetSurfaceId.
  public handleCreate(result: MethodResult): void {
    const view = this.currentView;
    Log.i('VideoOutputViewFactory',
      `handleCreate currentView=${view == null ? 'null' : view.viewId}`);
    const surfaceId: string = view?.surfaceController.getSurfaceId() ?? '0';
    const payload: VideoOutputCreateResult = {
      id: 0,
      wid: surfaceId,
      rect: { left: 0, top: 0, width: 1, height: 1 }
    };
    result.success(payload);
  }

  // Called by VideoOutputManager.SetHdr: forwards the current content's dynamic
  // range (and content peak in nits) to the (single) hosted view so it can tag
  // the surface as HDR / SDR.
  public setHdr(enabled: boolean, maxLuminance: number): void {
    this.currentView?.setHdr(enabled, maxLuminance);
  }

  // Called by the view itself when disposed, so a disposed view is never
  // handed out to a later Create request (dangling reference).
  public onViewDisposed(): void {
    this.currentView = null;
  }

  public disposeView(): void {
    this.currentView?.dispose();
    this.currentView = null;
  }

  // Engine detach: release everything.
  public disposeAll(): void {
    this.disposeView();
  }
}
