import nativeModule from 'libentry.so';
import { router } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';

interface XComponentLoadContext {
  getXComponentSurfaceId(): string;
}

@Entry
@Component
struct VideoPlayerPage {
  @State videoPath: string = '';
  @State isPlaying: boolean = false;
  @State statusText: string = '准备就绪';
  @State hasSurface: boolean = false;

  aboutToAppear() {
    this.videoPath = 'test.avi';
  }

  onPageShow() {
    console.info('[HiSH] VideoPlayerPage onPageShow');
    // 页面显示后自动开始播放
    if (!this.isPlaying) {
      this.startPlay();
    }
  }

  aboutToDisappear() {
    this.stopPlay();
    nativeModule.releaseVideoPlayer();
  }

  async startPlay() {
    if (this.isPlaying) {
      return;
    }
    const context = getContext(this);

    // 优先使用用户指定的 el2 路径（用户级加密）
    const el2Path = '/data/storage/el2/base/files/media/test.avi';
    // 备用 el1 路径（设备级加密）
    const el1Path = context.filesDir + '/media/test.avi';

    let fullPath = el2Path;
    let pathFound = false;

    // 检查文件是否存在
    try {
      await fs.access(el2Path);
      pathFound = true;
      console.info('[HiSH] Found video at el2 path: ' + el2Path);
    } catch (e) {
      console.warn('[HiSH] el2 path not accessible: ' + el2Path);
      try {
        await fs.access(el1Path);
        fullPath = el1Path;
        pathFound = true;
        console.info('[HiSH] Found video at el1 path: ' + el1Path);
      } catch (e2) {
        console.warn('[HiSH] el1 path not accessible: ' + el1Path);
      }
    }

    if (!pathFound) {
      this.statusText = '视频文件不存在，请确认已放置到: ' + el2Path;
      console.error('[HiSH] Video file not found at el2: ' + el2Path + ' or el1: ' + el1Path);
      return;
    }

    this.statusText = '正在加载: ' + this.videoPath;
    console.info('[HiSH] playVideo path=' + fullPath);
    const ok = nativeModule.playVideo(fullPath);
    if (ok) {
      this.isPlaying = true;
      this.statusText = '播放中 (后台解码模式): ' + this.videoPath;
    } else {
      this.statusText = '播放失败，请检查视频文件格式是否支持: ' + fullPath;
    }
  }

  stopPlay() {
    if (!this.isPlaying) {
      return;
    }
    nativeModule.stopVideo();
    this.isPlaying = false;
    this.statusText = '已停止';
  }

  build() {
    Column() {
      // 顶部标题栏
      Row() {
        Button('返回')
          .fontSize(14)
          .onClick(() => {
            router.back();
          })
        Text('FFmpeg 视频播放器')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Blank().width(60)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F1F3F5')

      // 视频渲染区域
      Stack({ alignContent: Alignment.Center }) {
        XComponent({ id: 'videoSurface', type: XComponentType.SURFACE })
          .width('100%')
          .height(240)
          .backgroundColor('#000000')
          .onLoad((context: XComponentLoadContext | undefined) => {
            console.info('[HiSH] XComponent onLoad triggered');
            if (!context) {
              console.error('[HiSH] XComponent onLoad context is undefined');
              return;
            }
            try {
              const surfaceId = context.getXComponentSurfaceId();
              console.info('[HiSH] surfaceId=' + surfaceId);
              const ok = nativeModule.setVideoSurface(surfaceId);
              if (ok) {
                this.hasSurface = true;
              }
              console.info('[HiSH] setVideoSurface result=' + ok);
            } catch (e) {
              console.error('[HiSH] Failed to init video surface: ' + e);
            }
          })

        // 覆盖提示：当前SDK版本Surface渲染不可用
        Column() {
          Text('🎬 FFmpeg 后台解码模式')
            .fontSize(16)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
          Text('当前 SDK 版本不支持 XComponent Surface 渲染')
            .fontSize(12)
            .fontColor('#AAAAAA')
            .margin({ top: 4 })
          Text('FFmpeg 将在 Native 层持续解码视频帧')
            .fontSize(12)
            .fontColor('#AAAAAA')
        }
        .width('100%')
        .height(240)
        .backgroundColor('#000000')
        .justifyContent(FlexAlign.Center)
        .visibility(this.hasSurface ? Visibility.Hidden : Visibility.Visible)
      }
      .width('100%')
      .height(240)

      // 状态显示
      Text(this.statusText)
        .fontSize(14)
        .fontColor(Color.Gray)
        .margin({ top: 8, bottom: 8 })

      // 控制按钮区
      Row({ space: 16 }) {
        Button(this.isPlaying ? '停止' : '播放')
          .width(100)
          .onClick(() => {
            if (this.isPlaying) {
              this.stopPlay();
            } else {
              this.startPlay();
            }
          })

        Button('循环切换')
          .width(100)
          .enabled(false)
          .fontColor(Color.Gray)
      }
      .margin({ top: 16 })

      // 提示信息
      Column({ space: 8 }) {
        Text('使用说明：')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .width('100%')
        Text('1. 将 test.avi 放入 entry/src/main/resources/rawfile/')
          .fontSize(12)
          .fontColor(Color.Gray)
          .width('100%')
        Text('2. 点击播放后，FFmpeg 在 Native 层持续解码')
          .fontSize(12)
          .fontColor(Color.Gray)
          .width('100%')
        Text('3. 视频循环播放，用于内存压力与故障注入测试')
          .fontSize(12)
          .fontColor(Color.Gray)
          .width('100%')
        Text('4. 当前为后台解码模式，画面不渲染到屏幕')
          .fontSize(12)
          .fontColor('#FF6600')
          .width('100%')
      }
      .padding(16)
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
