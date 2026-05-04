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

add_library(libfault_uaf SHARED fault_uaf.cpp)
add_library(libfault_double_free SHARED fault_double_free.cpp)
add_library(libfault_stack SHARED fault_stack.cpp)
add_library(libfault_heap_overflow SHARED fault_heap_overflow.cpp)
add_library(libfault_mismatch SHARED fault_mismatch.cpp)

add_library(entry SHARED napi_init.cpp fault_injection.cpp video_player.cpp normal_operations.cpp)

target_link_libraries(libfault_uaf PUBLIC libhilog_ndk.z.so)
target_link_libraries(libfault_double_free PUBLIC libhilog_ndk.z.so)
target_link_libraries(libfault_stack PUBLIC libhilog_ndk.z.so)
target_link_libraries(libfault_heap_overflow PUBLIC libhilog_ndk.z.so)
target_link_libraries(libfault_mismatch PUBLIC libhilog_ndk.z.so)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libfault_uaf
    libfault_double_free
    libfault_stack
    libfault_heap_overflow
    libfault_mismatch
    ${FFMPEG_LIB_DIR}/libavformat.so
    ${FFMPEG_LIB_DIR}/libavcodec.so
    ${FFMPEG_LIB_DIR}/libavutil.so
    ${FFMPEG_LIB_DIR}/libswscale.so
    ${FFMPEG_LIB_DIR}/libswresample.so
)
