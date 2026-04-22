# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(hish)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

# FFmpeg 配置
set(FFMPEG_ROOT ${NATIVERENDER_ROOT_PATH}/third_party/ffmpeg)

if(${OHOS_ARCH} STREQUAL "arm64-v8a")
    set(FFMPEG_LIB_DIR ${FFMPEG_ROOT}/libs/arm64-v8a)
elseif(${OHOS_ARCH} STREQUAL "x86_64")
    set(FFMPEG_LIB_DIR ${FFMPEG_ROOT}/libs/x86_64)
else()
    set(FFMPEG_LIB_DIR ${FFMPEG_ROOT}/libs/arm64-v8a)
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include
                    ${FFMPEG_ROOT}/include)

link_directories(${FFMPEG_LIB_DIR})

add_library(entry SHARED napi_init.cpp fault_injection.cpp video_player.cpp)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_window.so
    ${FFMPEG_LIB_DIR}/libavformat.so
    ${FFMPEG_LIB_DIR}/libavcodec.so
    ${FFMPEG_LIB_DIR}/libavutil.so
    ${FFMPEG_LIB_DIR}/libswscale.so
    ${FFMPEG_LIB_DIR}/libswresample.so
)
