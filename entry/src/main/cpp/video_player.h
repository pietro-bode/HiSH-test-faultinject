#ifndef VIDEO_PLAYER_H
#define VIDEO_PLAYER_H

#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>

#ifdef __cplusplus
extern "C" {
#endif
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
#ifdef __cplusplus
}
#endif

#include <native_window/external_window.h>

class VideoPlayer {
public:
    VideoPlayer();
    ~VideoPlayer();

    // 绑定 NativeWindow（由 XComponent surface 创建）
    bool SetNativeWindow(OHNativeWindow *window);

    // 开始播放本地视频文件，loop 为 true 时循环播放
    bool Play(const std::string &path, bool loop = true);

    // 停止播放
    void Stop();

    // 是否正在播放
    bool IsPlaying() const { return playing_.load(); }

    // 获取当前视频宽高
    void GetVideoSize(int &width, int &height) const;

private:
    void DecodeLoop();
    void Cleanup();
    bool OpenInput(const std::string &path);
    bool WriteFrameToWindow(AVFrame *frame);

    std::atomic<bool> playing_{false};
    std::atomic<bool> stop_requested_{false};
    std::thread decode_thread_;
    std::string current_path_;
    bool loop_ = true;

    std::mutex window_mutex_;
    OHNativeWindow *native_window_ = nullptr;

    // FFmpeg context
    AVFormatContext *fmt_ctx_ = nullptr;
    AVCodecContext *codec_ctx_ = nullptr;
    SwsContext *sws_ctx_ = nullptr;
    int video_stream_index_ = -1;

    // 视频参数
    int video_width_ = 0;
    int video_height_ = 0;
    double fps_ = 30.0;

    // RGBA 帧缓冲
    uint8_t *rgba_buffer_ = nullptr;
    int rgba_buffer_size_ = 0;
};

#endif // VIDEO_PLAYER_H
