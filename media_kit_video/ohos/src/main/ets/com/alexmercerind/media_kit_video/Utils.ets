/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2025 & onwards, Bao Han <erbws@foxmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */

import deviceInfo from '@ohos.deviceInfo';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

export class Utils {
  static isEmulator(): boolean {
    if (deviceInfo.productModel == "emulator") {
      return true;
    } else {
      return false;
    }
  }

  // 是否在进入全屏播放前窗口已处于最大化状态（仅自由窗口/PC 模式路径使用）
  private static wasMaximizedBeforeFullScreen: boolean = false;

  static enterFullScreen(context: common.UIAbilityContext): void {
    window.getLastWindow(context).then((lastWindow) => {
      // 不能仅凭 deviceType 判断：平板也可以启用 PC 模式（自由窗口模式）
      if (lastWindow.isInFreeWindowMode()) {
        // 记录进入全屏前窗口是否为最大化
        Utils.wasMaximizedBeforeFullScreen =
          lastWindow.getWindowStatus() == window.WindowStatusType.MAXIMIZE;
        lastWindow.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
        return;
      }
      lastWindow.enableLandscapeMultiWindow();
      lastWindow.setPreferredOrientation(window.Orientation.USER_ROTATION_LANDSCAPE);
      lastWindow.setWindowSystemBarEnable([]);
    })
  }

  static exitFullScreen(context: common.UIAbilityContext): void {
    window.getLastWindow(context).then((lastWindow) => {
      if (lastWindow.isInFreeWindowMode()) {
        if (!Utils.wasMaximizedBeforeFullScreen) {
          // 还原为自由悬浮窗口模式（WindowStatusType.FLOATING），并恢复之前的大小和位置
          lastWindow.recover();
        } else {
          // 从全屏恢复为最大化状态
          lastWindow.maximize(window.MaximizePresentation.EXIT_IMMERSIVE);
        }
        return;
      }
      lastWindow.disableLandscapeMultiWindow();
      if (deviceInfo.deviceType == 'phone') {
        lastWindow.setPreferredOrientation(window.Orientation.USER_ROTATION_PORTRAIT);
      }
      lastWindow.setWindowSystemBarEnable(['status']);
    })
  }
}

export interface Rect {
  left: number,
  top: number,
  width: number,
  height: number,
}

export interface SizeData {
  handle: number,
  id: number,
  wid: number,
  rect: Rect,
}