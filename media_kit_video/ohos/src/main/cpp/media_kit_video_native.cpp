/*
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2025 & onwards, Bao Han <erbws@foxmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 *
 * HDR support helper for HarmonyOS (OpenHarmony).
 *
 * The Flutter texture registry allocates its video output surfaces with the
 * default 8-bit RGBA_8888 buffer format. libmpv, however, is able to output
 * 10-bit HDR (PQ / BT.2020). If the surface stays 8-bit, the 10-bit HDR data
 * gets clamped and the picture appears washed out ("泛白").
 *
 * This native module exposes setSurfaceFormat10Bit(surfaceId), which switches
 * the surface backing a given surface id to 10-bit RGBA_1010102 so that
 * libmpv's 10-bit HDR output survives into the buffer queue.
 */
#include <cstdint>
#include <string>

#include <napi/native_api.h>
#include <hilog/log.h>
#include <native_window/external_window.h>
#include <native_buffer/native_buffer.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "media_kit_video_native"

// ---------------------------------------------------------------------------
// setSurfaceFormat10Bit(surfaceId: string | number | bigint): boolean
//
// surfaceId is the XComponent / SurfaceTextureEntry surface id (a uint64
// value). Passing it as a string is the preferred & lossless form; number and
// bigint are accepted for convenience (number is lossy above 2^53).
// ---------------------------------------------------------------------------
static bool ParseSurfaceId(napi_env env, napi_value value, uint64_t* out) {
  napi_valuetype type = napi_undefined;
  napi_typeof(env, value, &type);
  if (type == napi_string) {
    char buf[64] = {0};
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, buf, sizeof(buf), &len) != napi_ok) {
      return false;
    }
    try {
      *out = std::stoull(buf);
      return true;
    } catch (...) {
      return false;
    }
  }
  if (type == napi_bigint) {
    bool lossless = false;
    return napi_get_value_bigint_uint64(env, value, out, &lossless) == napi_ok;
  }
  if (type == napi_number) {
    double v = 0.0;
    if (napi_get_value_double(env, value, &v) != napi_ok) {
      return false;
    }
    *out = static_cast<uint64_t>(v);
    return true;
  }
  return false;
}

static napi_value SetSurfaceFormat10Bit(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  uint64_t surfaceId = 0;
  if (argc >= 1 && args[0] != nullptr) {
    ParseSurfaceId(env, args[0], &surfaceId);
  }

  napi_value result = nullptr;
  napi_get_boolean(env, false, &result);

  if (surfaceId == 0) {
    OH_LOG_ERROR(LOG_APP, "setSurfaceFormat10Bit: invalid surfaceId");
    return result;
  }

  // API 12+: obtain a borrowed reference to the OHNativeWindow backing this
  // surface id. The buffer format is a property of the surface queue (not the
  // window instance), so it stays in effect after we release this reference.
  OHNativeWindow* window = nullptr;
  const int32_t createRet = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
  if (createRet != 0 || window == nullptr) {
    OH_LOG_ERROR(LOG_APP,
                 "setSurfaceFormat10Bit: cannot resolve surfaceId %{public}lld (ret=%{public}d)",
                 static_cast<long long>(surfaceId), createRet);
    return result;
  }

  // 10-bit RGBA. P010 / RGBA_1010102 are the HDR-capable formats added in
  // API 12; gpu-next outputs RGB so RGBA_1010102 is the right one here.
  //
  // The buffer format is set through OH_NativeWindow_NativeWindowHandleOpt with
  // the SET_FORMAT operation code (see NativeWindowOperation in
  // native_window/external_window.h).
  const int32_t format = NATIVEBUFFER_PIXEL_FMT_RGBA_1010102;
  const int32_t ret = OH_NativeWindow_NativeWindowHandleOpt(window, SET_FORMAT, format);

  OH_NativeWindow_DestroyNativeWindow(window);

  OH_LOG_INFO(LOG_APP, "setSurfaceFormat10Bit: surfaceId=%{public}lld ret=%{public}d",
              static_cast<long long>(surfaceId), ret);

  napi_get_boolean(env, ret == 0, &result);
  return result;
}

// ---------------------------------------------------------------------------
// setSurfaceHdr(surfaceId: string | number | bigint, hdr: boolean): boolean
//
// Tags (or un-tags) the OHNativeWindow backing the XComponent surface as HDR.
//
// A 10-bit buffer format alone is NOT enough: unless the surface is *also*
// given the matching colorspace + HDR metadata, the compositor keeps
// interpreting the buffer as SDR, so libmpv's PQ / BT.2020 output shows up
// washed out ("泛白"). These are the "three-piece set" required by the
// HarmonyOS HDR guidance:
//
//   format      -> (negotiated by mpv itself, left untouched here)
//   colorspace  -> OH_COLORSPACE_BT2020_PQ_FULL (HDR) / OH_COLORSPACE_SRGB_FULL (SDR)
//   metadata    -> OH_VIDEO_HDR_HDR10 (HDR) / OH_VIDEO_NONE (SDR)
//
// Both OH_NativeWindow_SetColorSpace and OH_NativeWindow_SetMetadataValue are
// available since API 12.
// ---------------------------------------------------------------------------
static napi_value SetSurfaceHdr(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  uint64_t surfaceId = 0;
  if (argc >= 1 && args[0] != nullptr) {
    ParseSurfaceId(env, args[0], &surfaceId);
  }

  bool hdr = false;
  if (argc >= 2 && args[1] != nullptr) {
    napi_get_value_bool(env, args[1], &hdr);
  }

  napi_value result = nullptr;
  napi_get_boolean(env, false, &result);

  if (surfaceId == 0) {
    OH_LOG_ERROR(LOG_APP, "setSurfaceHdr: invalid surfaceId");
    return result;
  }

  OHNativeWindow* window = nullptr;
  const int32_t createRet = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
  if (createRet != 0 || window == nullptr) {
    OH_LOG_ERROR(LOG_APP,
                 "setSurfaceHdr: cannot resolve surfaceId %{public}lld (ret=%{public}d)",
                 static_cast<long long>(surfaceId), createRet);
    return result;
  }

  // Order matters: the buffer must be HDR-capable (10-bit) BEFORE the
  // colorspace / HDR metadata are (meaningfully) applied. An 8-bit buffer is
  // never composited as HDR, even when tagged as BT.2020 PQ.
  //
  // The format is only forced for HDR; for SDR it is left to mpv's own
  // negotiation (forcing it there previously made SDR look wrong).
  int32_t formatRet = 0;
  if (hdr) {
    formatRet = OH_NativeWindow_NativeWindowHandleOpt(
        window, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102);
  }

  OH_NativeBuffer_MetadataType metadataType = hdr ? OH_VIDEO_HDR_HDR10 : OH_VIDEO_NONE;
  // RGB output from mpv is FULL range, so the HDR colorspace must be the *_FULL
  // variant too. Tagging full-range data as *_LIMIT makes the compositor apply
  // a wrong range expansion, which shows up as a washed-out ("泛白") picture.
  const int32_t colorRet =
      OH_NativeWindow_SetColorSpace(window, hdr ? OH_COLORSPACE_BT2020_PQ_FULL
                                                : OH_COLORSPACE_SRGB_FULL);
  const int32_t metadataRet = OH_NativeWindow_SetMetadataValue(
      window, OH_HDR_METADATA_TYPE,
      static_cast<int32_t>(sizeof(OH_NativeBuffer_MetadataType)),
      reinterpret_cast<uint8_t*>(&metadataType));

  OH_NativeWindow_DestroyNativeWindow(window);

  OH_LOG_INFO(LOG_APP,
              "setSurfaceHdr: id=%{public}lld hdr=%{public}d formatRet=%{public}d colorRet=%{public}d metadataRet=%{public}d",
              static_cast<long long>(surfaceId), hdr ? 1 : 0, formatRet, colorRet, metadataRet);

  napi_get_boolean(env, formatRet == 0 && colorRet == 0 && metadataRet == 0, &result);
  return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"setSurfaceFormat10Bit", nullptr, SetSurfaceFormat10Bit, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"setSurfaceHdr", nullptr, SetSurfaceHdr, nullptr, nullptr,
       nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module media_kit_video_native_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "media_kit_video_native",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMediaKitVideoNativeModule(void) {
  napi_module_register(&media_kit_video_native_module);
}
