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
#include <native_buffer/buffer_common.h>

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
// HDR10 static metadata (SMPTE ST.2086 + CTA-861.3) for BT.2020 primaries on a
// nominal 1000-nit mastering display.
//
// HarmonyOS needs BOTH the metadata TYPE *and* the STATIC metadata: without the
// static part the display has no mastering information to tone-map the PQ
// signal with, which is the documented reason HDR content looks washed out
// ("泛白").
// ---------------------------------------------------------------------------
static int32_t SetHdrStaticMetadata(OHNativeWindow* window, float maxLuminance) {
  OH_NativeBuffer_StaticMetadata sm = {};
  // BT.2020 primaries.
  sm.smpte2086.displayPrimaryRed.x = 0.708f;
  sm.smpte2086.displayPrimaryRed.y = 0.292f;
  sm.smpte2086.displayPrimaryGreen.x = 0.170f;
  sm.smpte2086.displayPrimaryGreen.y = 0.797f;
  sm.smpte2086.displayPrimaryBlue.x = 0.131f;
  sm.smpte2086.displayPrimaryBlue.y = 0.046f;
  // D65 white point.
  sm.smpte2086.whitePoint.x = 0.3127f;
  sm.smpte2086.whitePoint.y = 0.3290f;
  // Light levels in nits. The peak is passed in from Dart, derived from mpv's
  // video-params sig-peak (e.g. 49.26 * 203 ~= 10000 nits for PQ content).
  sm.smpte2086.maxLuminance = maxLuminance;
  sm.smpte2086.minLuminance = 0.001f;
  // CTA-861.3 light levels.
  sm.cta861.maxContentLightLevel = maxLuminance;
  sm.cta861.maxFrameAverageLightLevel = maxLuminance / 5.0f;
  return OH_NativeWindow_SetMetadataValue(
      window, OH_HDR_STATIC_METADATA,
      static_cast<int32_t>(sizeof(OH_NativeBuffer_StaticMetadata)),
      reinterpret_cast<uint8_t*>(&sm));
}

// ---------------------------------------------------------------------------
// setSurfaceHdr(surfaceId: string | number | bigint, hdr: boolean): boolean
//
// Tags (or un-tags) the OHNativeWindow backing the XComponent surface as HDR.
//
// A 10-bit buffer format alone is NOT enough: unless the surface is *also*
// given the matching colorspace + metadata TYPE + static metadata, the
// compositor keeps interpreting the buffer as SDR and libmpv's PQ / BT.2020
// output shows up washed out ("泛白"). The full set is:
//
//   format      -> RGBA_1010102 (HDR only; SDR is left to mpv's negotiation)
//   colorspace  -> OH_COLORSPACE_BT2020_PQ_FULL (HDR) / OH_COLORSPACE_SRGB_FULL (SDR)
//   metadata    -> OH_HDR_METADATA_TYPE = OH_VIDEO_HDR_HDR10 (HDR) / OH_VIDEO_NONE (SDR)
//   static meta -> OH_HDR_STATIC_METADATA (HDR only)
//
// All of these are available since API 12.
// ---------------------------------------------------------------------------
static napi_value SetSurfaceHdr(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  uint64_t surfaceId = 0;
  if (argc >= 1 && args[0] != nullptr) {
    ParseSurfaceId(env, args[0], &surfaceId);
  }

  bool hdr = false;
  if (argc >= 2 && args[1] != nullptr) {
    napi_get_value_bool(env, args[1], &hdr);
  }

  // Optional content/mastering peak luminance in nits (HDR only). Derived on
  // the Dart side from mpv's video-params sig-peak.
  double maxLuminance = 1000.0;
  if (argc >= 3 && args[2] != nullptr) {
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[2], &type);
    if (type == napi_number) {
      napi_get_value_double(env, args[2], &maxLuminance);
    }
  }
  if (!(maxLuminance > 0.0)) {
    maxLuminance = 1000.0;
  }
  if (maxLuminance < 100.0) {
    maxLuminance = 100.0;
  }
  if (maxLuminance > 10000.0) {
    maxLuminance = 10000.0;
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

  // The metadata TYPE alone is not enough: without the matching STATIC metadata
  // (SMPTE ST.2086 masters + CTA-861.3 light levels) the display has no
  // mastering information to tone-map with — the documented cause of HDR
  // looking washed out ("泛白").
  int32_t staticRet = 0;
  if (hdr) {
    staticRet = SetHdrStaticMetadata(window, static_cast<float>(maxLuminance));
  }

  OH_NativeWindow_DestroyNativeWindow(window);

  OH_LOG_INFO(LOG_APP,
              "setSurfaceHdr: id=%{public}lld hdr=%{public}d peak=%{public}d formatRet=%{public}d colorRet=%{public}d metadataRet=%{public}d staticRet=%{public}d",
              static_cast<long long>(surfaceId), hdr ? 1 : 0,
              static_cast<int32_t>(maxLuminance), formatRet, colorRet, metadataRet, staticRet);

  napi_get_boolean(
      env, formatRet == 0 && colorRet == 0 && metadataRet == 0 && staticRet == 0, &result);
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
