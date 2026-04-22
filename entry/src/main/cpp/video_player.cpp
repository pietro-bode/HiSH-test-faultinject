#include "video_player.h"
#include "hilog/log.h"
#include <sys/mman.h>
#include <unistd.h>
#include <cstring>
#include <native_buffer/native_buffer.h>

// 兼容不同 SDK 版本的像素格式常量定义
#ifndef PIXEL_FMT_RGBA_8888
#define PIXEL_FMT_RGBA_8888 3
#endif

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

VideoPlayer::VideoPlayer() {}

VideoPlayer::~VideoPlayer() {
    Stop();
    Cleanup();
}

bool VideoPlayer::SetNativeWindow(OHNativeWindow *window) {
    std::lock_guard<std::mutex> lock(window_mutex_);
    if (native_window_ && native_window_ != window) {
        OH_NativeWindow_DestroyNativeWindow(native_window_);
    }
    native_window_ = window;
    return true;
}

bool VideoPlayer::OpenInput(const std::string &path) {
    int ret = avformat_open_input(&fmt_ctx_, path.c_str(), nullptr, nullptr);
    if (ret < 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to open input: %{public}s", path.c_str());
        return false;
    }

    ret = avformat_find_stream_info(fmt_ctx_, nullptr);
    if (ret < 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to find stream info");
        return false;
    }

    // 查找视频流
    video_stream_index_ = av_find_best_stream(fmt_ctx_, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_index_ < 0) {
        OH_LOG_ERROR(LOG_APP, "No video stream found");
        return false;
    }

    AVStream *stream = fmt_ctx_->streams[video_stream_index_];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        OH_LOG_ERROR(LOG_APP, "Codec not found");
        return false;
    }

    codec_ctx_ = avcodec_alloc_context3(codec);
    if (!codec_ctx_) {
        OH_LOG_ERROR(LOG_APP, "Failed to alloc codec context");
        return false;
    }

    ret = avcodec_parameters_to_context(codec_ctx_, stream->codecpar);
    if (ret < 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to copy codec params");
        return false;
    }

    ret = avcodec_open2(codec_ctx_, codec, nullptr);
    if (ret < 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to open codec");
        return false;
    }

    video_width_ = codec_ctx_->width;
    video_height_ = codec_ctx_->height;
    if (stream->avg_frame_rate.den > 0) {
        fps_ = av_q2d(stream->avg_frame_rate);
    } else if (stream->r_frame_rate.den > 0) {
        fps_ = av_q2d(stream->r_frame_rate);
    }

    OH_LOG_INFO(LOG_APP, "Video opened: %{public}dx%{public}d @ %{public}.2ffps",
                video_width_, video_height_, fps_);

    // 初始化 sws 转换器（YUV -> RGBA）
    sws_ctx_ = sws_getContext(video_width_, video_height_, codec_ctx_->pix_fmt,
                              video_width_, video_height_, AV_PIX_FMT_RGBA,
                              SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
    if (!sws_ctx_) {
        OH_LOG_ERROR(LOG_APP, "Failed to create sws context");
        return false;
    }

    // 预分配 RGBA 缓冲
    rgba_buffer_size_ = video_width_ * video_height_ * 4;
    rgba_buffer_ = static_cast<uint8_t *>(av_malloc(rgba_buffer_size_));
    if (!rgba_buffer_) {
        OH_LOG_ERROR(LOG_APP, "Failed to alloc rgba buffer");
        return false;
    }

    return true;
}

void VideoPlayer::Cleanup() {
    if (rgba_buffer_) {
        av_freep(&rgba_buffer_);
        rgba_buffer_ = nullptr;
    }
    if (sws_ctx_) {
        sws_freeContext(sws_ctx_);
        sws_ctx_ = nullptr;
    }
    if (codec_ctx_) {
        avcodec_free_context(&codec_ctx_);
        codec_ctx_ = nullptr;
    }
    if (fmt_ctx_) {
        avformat_close_input(&fmt_ctx_);
        fmt_ctx_ = nullptr;
    }
    video_stream_index_ = -1;
    video_width_ = 0;
    video_height_ = 0;
}

bool VideoPlayer::Play(const std::string &path, bool loop) {
    if (playing_.load()) {
        Stop();
    }

    Cleanup();
    current_path_ = path;
    loop_ = loop;

    if (!OpenInput(path)) {
        Cleanup();
        return false;
    }

    // 配置 NativeWindow（如果已绑定）
    {
        std::lock_guard<std::mutex> lock(window_mutex_);
        if (native_window_) {
            int32_t ret = OH_NativeWindow_NativeWindowHandleOpt(
                native_window_, SET_BUFFER_GEOMETRY, video_width_, video_height_);
            if (ret != 0) {
                OH_LOG_ERROR(LOG_APP, "Failed to set buffer geometry: %{public}d", ret);
            }
            ret = OH_NativeWindow_NativeWindowHandleOpt(
                native_window_, SET_FORMAT, PIXEL_FMT_RGBA_8888);
            if (ret != 0) {
                OH_LOG_ERROR(LOG_APP, "Failed to set format: %{public}d", ret);
            }
        } else {
            OH_LOG_WARN(LOG_APP, "NativeWindow not bound, video will decode without rendering");
        }
    }

    stop_requested_.store(false);
    playing_.store(true);
    decode_thread_ = std::thread(&VideoPlayer::DecodeLoop, this);

    return true;
}

void VideoPlayer::Stop() {
    if (!playing_.load()) {
        return;
    }
    stop_requested_.store(true);
    if (decode_thread_.joinable()) {
        decode_thread_.join();
    }
    playing_.store(false);
    Cleanup();
}

void VideoPlayer::GetVideoSize(int &width, int &height) const {
    width = video_width_;
    height = video_height_;
}

bool VideoPlayer::WriteFrameToWindow(AVFrame *frame) {
    std::lock_guard<std::mutex> lock(window_mutex_);
    if (!native_window_) {
        // 没有 NativeWindow，只解码不渲染
        return true;
    }

    // 1. YUV -> RGBA
    uint8_t *dst_data[1] = {rgba_buffer_};
    int dst_linesize[1] = {video_width_ * 4};
    sws_scale(sws_ctx_, frame->data, frame->linesize, 0, video_height_, dst_data, dst_linesize);

    // 2. 请求 NativeWindow Buffer
    OHNativeWindowBuffer *buffer = nullptr;
    int fenceFd = -1;
    int32_t ret = OH_NativeWindow_NativeWindowRequestBuffer(native_window_, &buffer, &fenceFd);
    if (ret != 0 || !buffer) {
        OH_LOG_ERROR(LOG_APP, "RequestBuffer failed: %{public}d", ret);
        return false;
    }

    // 3. 获取 BufferHandle 并 mmap
    BufferHandle *handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
    if (!handle) {
        OH_LOG_ERROR(LOG_APP, "GetBufferHandle failed");
        Region emptyRegion{};
        OH_NativeWindow_NativeWindowFlushBuffer(native_window_, buffer, fenceFd, emptyRegion);
        return false;
    }

    void *addr = mmap(nullptr, handle->size, PROT_READ | PROT_WRITE, MAP_SHARED, handle->fd, 0);
    if (addr == MAP_FAILED) {
        OH_LOG_ERROR(LOG_APP, "mmap failed");
        Region emptyRegion{};
        OH_NativeWindow_NativeWindowFlushBuffer(native_window_, buffer, fenceFd, emptyRegion);
        return false;
    }

    // 4. 拷贝 RGBA 数据（按 stride 逐行拷贝）
    uint8_t *dst = static_cast<uint8_t *>(addr);
    int dst_stride = handle->stride;
    uint8_t *src = rgba_buffer_;
    int src_stride = video_width_ * 4;
    int copy_height = video_height_;
    int copy_stride = (src_stride < dst_stride) ? src_stride : dst_stride;

    for (int y = 0; y < copy_height; ++y) {
        memcpy(dst + y * dst_stride, src + y * src_stride, copy_stride);
    }

    // 5. munmap 并提交 buffer
    munmap(addr, handle->size);

    Region region;
    Region::Rect rect;
    rect.x = 0;
    rect.y = 0;
    rect.w = video_width_;
    rect.h = video_height_;
    region.rects = &rect;
    region.rectNumber = 1;

    ret = OH_NativeWindow_NativeWindowFlushBuffer(native_window_, buffer, fenceFd, region);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "FlushBuffer failed: %{public}d", ret);
        return false;
    }

    return true;
}

void VideoPlayer::DecodeLoop() {
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    if (!frame || !packet) {
        OH_LOG_ERROR(LOG_APP, "Failed to alloc frame/packet");
        playing_.store(false);
        return;
    }

    int64_t frame_interval_us = static_cast<int64_t>(1000000.0 / fps_);

    do {
        while (av_read_frame(fmt_ctx_, packet) >= 0) {
            if (stop_requested_.load()) {
                av_packet_unref(packet);
                break;
            }

            if (packet->stream_index != video_stream_index_) {
                av_packet_unref(packet);
                continue;
            }

            int ret = avcodec_send_packet(codec_ctx_, packet);
            av_packet_unref(packet);
            if (ret < 0) {
                continue;
            }

            while (ret >= 0) {
                ret = avcodec_receive_frame(codec_ctx_, frame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                    break;
                }
                if (ret < 0) {
                    OH_LOG_ERROR(LOG_APP, "Decode error");
                    break;
                }

                if (native_window_) {
                    WriteFrameToWindow(frame);
                } else {
                    // 无渲染模式：只做 YUV->RGBA 转换以消耗 CPU/内存
                    if (sws_ctx_ && rgba_buffer_) {
                        uint8_t *dst_data[1] = {rgba_buffer_};
                        int dst_linesize[1] = {video_width_ * 4};
                        sws_scale(sws_ctx_, frame->data, frame->linesize, 0, video_height_, dst_data, dst_linesize);
                    }
                }
                av_frame_unref(frame);

                // 简单帧率控制
                usleep(static_cast<useconds_t>(frame_interval_us));

                if (stop_requested_.load()) {
                    break;
                }
            }

            if (stop_requested_.load()) {
                break;
            }
        }

        if (stop_requested_.load()) {
            break;
        }

        // 循环播放：seek 到开头
        if (loop_) {
            avformat_seek_file(fmt_ctx_, video_stream_index_, 0, 0, 0, 0);
            avcodec_flush_buffers(codec_ctx_);
            OH_LOG_INFO(LOG_APP, "Video loop seek to start");
        }
    } while (loop_ && !stop_requested_.load());

    av_packet_free(&packet);
    av_frame_free(&frame);
    playing_.store(false);
}
