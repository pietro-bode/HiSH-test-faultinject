# FFmpeg for HarmonyOS 预编译库

## 目录结构

```
third_party/ffmpeg/
├── include/              # FFmpeg 头文件
│   ├── libavcodec/
│   ├── libavformat/
│   ├── libavutil/
│   ├── libswscale/
│   └── libswresample/
└── libs/
    ├── arm64-v8a/        # arm64 预编译 so
    │   ├── libavcodec.so
    │   ├── libavformat.so
    │   ├── libavutil.so
    │   ├── libswscale.so
    │   └── libswresample.so
    └── x86_64/           # x86_64 预编译 so (模拟器)
        └── ...
```

## 编译信息

- **源码版本**: FFmpeg 6.1.1
- **SDK**: HarmonyOS NDK 6.0.0.47 (linux)
- **编译时间**: 2026-04-21
- **支持架构**: arm64-v8a, x86_64
- **编译选项**: 仅保留解码器和解封装器（无编码、无网络、无硬件加速）

## 如需重新编译

```bash
# 使用已保存的编译脚本
bash /tmp/build_ffmpeg_ohos_v4.sh

# 产物会自动安装到 /tmp/ffmpeg-ohos-output/<arch>/
# 然后执行以下命令复制到项目：
cp -r /tmp/ffmpeg-ohos-output/aarch64/include/* \
      entry/src/main/cpp/third_party/ffmpeg/include/
cp /tmp/ffmpeg-ohos-output/aarch64/lib/*.so \
   entry/src/main/cpp/third_party/ffmpeg/libs/arm64-v8a/
cp /tmp/ffmpeg-ohos-output/x86_64/lib/*.so \
   entry/src/main/cpp/third_party/ffmpeg/libs/x86_64/
```

### 关键编译参数说明

```bash
./configure \
    --target-os=android \
    --enable-cross-compile \
    --disable-static --enable-shared \
    --disable-encoders --disable-muxers \
    --disable-network --disable-protocols --enable-protocol=file \
    --disable-vulkan --disable-hwaccels \
    --cc="${OHOS_ARCH}-unknown-linux-ohos-clang" \
    --sysroot="${OHOS_SDK}/sysroot"
```

### 已应用的 ohos 兼容性补丁

1. **math.h 冲突**: `libavutil/libm.h` 中的静态数学函数与 ohos musl 的 `math.h` 冲突，通过将 `config.h` 中 `HAVE_*` 宏改为 1 解决。
2. **getenv 冲突**: 删除 `config.h` 中 `#define getenv(x) NULL`，改为 `HAVE_GETENV 1`。
3. **soname 链接错误**: `ffbuild/config.mak` 中的 `LD` 改为使用 `clang` 而非 `ld.lld`，使 `-Wl,-soname` 被正确解析。
