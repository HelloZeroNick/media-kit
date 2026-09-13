/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2025 & onwards, Bao Han <erbws@foxmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */

import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  AbilityAware,
  AbilityPluginBinding
} from '@ohos/flutter_ohos';
import StandardMessageCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/StandardMessageCodec';
import { Utils } from './Utils';
import { VideoOutputManager } from './VideoOutputManager';
import { VideoOutputViewFactory } from './VideoOutputViewFactory';
import { common } from '@kit.AbilityKit';

// viewType registered with the platform view registry. Must match the Dart
// side |OhosView| in video_ohos_view.dart.
const VIDEO_VIEW_TYPE = 'com.alexmercerind/media_kit_video_view';

export default class MediaKitVideoPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private videoOutputManager: VideoOutputManager | null = null;
  // Static on purpose: Create/DisposeView resolve through it and it must
  // survive plugin instance recreation.
  private static videoOutputViewFactory: VideoOutputViewFactory | null = null;
  binding: FlutterPluginBinding | null = null;
  context: common.UIAbilityContext | null = null;

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.videoOutputManager = new VideoOutputManager(this.binding!.getTextureRegistry());
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.videoOutputManager?.disposeAll();
    this.videoOutputManager = null;
    this.context = null;
  }

  getUniqueClassName(): string {
    return "MediaKitVideoPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "com.alexmercerind/media_kit_video");
    this.channel.setMethodCallHandler(this);
    this.binding = binding;
    // Register the platform view factory for the XComponent based video
    // output (HDR path). The HCPP switch decides whether this view is
    // composed as an independent ArkUI system layer or via textures.
    //
    // IMPORTANT: keep the reference. VideoOutputManager.Create and
    // DisposeView resolve through |this.videoOutputViewFactory|; if it is not
    // stored, every Create fails with "not attached to an engine".
    const factory =
      new VideoOutputViewFactory(binding.getBinaryMessenger(), StandardMessageCodec.INSTANCE);
    MediaKitVideoPlugin.videoOutputViewFactory = factory;
    binding.getPlatformViewRegistry()?.registerViewFactory(VIDEO_VIEW_TYPE, factory);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
    }
    this.videoOutputManager?.disposeAll();
    this.videoOutputManager = null;
    // Release views before dropping the factory, so nothing hangs on the Dart
    // side after detach.
    MediaKitVideoPlugin.videoOutputViewFactory?.disposeAll();
    MediaKitVideoPlugin.videoOutputViewFactory = null;
    this.channel = null;
    this.binding = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case "VideoOutputManager.Create": {
        const handle = parseInt(call.argument("handle"));
        const modeArg: ESObject = call.argument("mode");
        const mode: string = modeArg == null ? "texture" : modeArg.toString();
        if (this.videoOutputManager == null) {
          result.error("unavailable", "VideoOutputManager is not attached to an ability.", null);
          break;
        }
        if (mode == "platform_view") {
          // XComponent / PlatformView (HDR) path: the surface is created by
          // the ArkUI XComponent, whose id is handed to libmpv via --wid.
          const factory = MediaKitVideoPlugin.videoOutputViewFactory;
          if (factory == null) {
            result.error("unavailable", "VideoOutputViewFactory is not attached to an engine.", null);
            break;
          }
          factory.handleCreate(result);
          break;
        }
        result.success(this.videoOutputManager.create(handle));
        break;
      }
      case "VideoOutputManager.DisposeView": {
        // PlatformView path cleanup (no texture to unregister).
        MediaKitVideoPlugin.videoOutputViewFactory?.disposeView();
        result.success(null);
        break;
      }
      case "VideoOutputManager.SetHdr": {
        // Dart detected (from mpv's video-params) whether the current content
        // is HDR. Tag the XComponent surface accordingly so the compositor
        // interprets mpv's PQ / BT.2020 output as HDR instead of SDR.
        const hdrArg: ESObject = call.argument("hdr");
        const hdr: boolean = hdrArg != null && hdrArg.toString() === "true";
        const peakArg: ESObject = call.argument("maxLuminance");
        const maxLuminance: number = peakArg == null ? 1000.0 : parseFloat(peakArg.toString());
        MediaKitVideoPlugin.videoOutputViewFactory?.setHdr(hdr, maxLuminance);
        result.success(null);
        break;
      }
      case "VideoOutputManager.SetSurfaceSize": {
        const handle = parseInt(call.argument("handle"));
        const width = parseInt(call.argument("width"));
        const height = parseInt(call.argument("height"));
        this.videoOutputManager?.setSurfaceSize(handle, width, height);
        result.success(null);
        break;
      }
      case "VideoOutputManager.Dispose": {
        const handle = parseInt(call.argument("handle"));
        this.videoOutputManager?.dispose(handle);
        result.success(null);
        break;
      }
      case "Utils.IsEmulator": {
        result.success(Utils.isEmulator());
        break;
      }
      case "Utils.EnterNativeFullscreen": {
        Utils.enterFullScreen(this.context!);
        result.success(null);
        break;
      }
      case "Utils.ExitNativeFullscreen": {
        Utils.exitFullScreen(this.context!);
        result.success(null);
        break;
      }
      default: {
        result.notImplemented();
        break;
      }
    }
  }
}
