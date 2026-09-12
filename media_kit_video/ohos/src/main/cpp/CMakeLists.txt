cmake_minimum_required(VERSION 3.5.0)
project(media_kit_video_native)

add_library(media_kit_video_native SHARED media_kit_video_native.cpp)

find_library(libnapi-lib ace_napi.z)
find_library(libhilog-lib hilog_ndk.z)
find_library(libnative_window-lib native_window)
find_library(libnative_buffer-lib native_buffer)

target_link_libraries(media_kit_video_native PUBLIC
    ${libnapi-lib}
    ${libhilog-lib}
    ${libnative_window-lib}
    ${libnative_buffer-lib}
)
