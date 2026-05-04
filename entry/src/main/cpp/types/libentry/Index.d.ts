export type NapiVmOptions = {
  argsLines: string
  unixSocket: string
  qmpSocket: string
}

export const startVM: (options: NapiVmOptions) => void;

export const onData: (callback: (ArrayBuffer) => void) => void;

export const onShutdown: (callback: () => void) => void;

export const sendInput: (content: ArrayBuffer) => void;

export const checkPortUsed: (port: number) => boolean;

/**
 * 获取 QCOW2 镜像的详细信息
 * @param imagePath 镜像文件的完整路径
 * @returns JSON 格式的镜像信息字符串
 */
export const getImageInfo: (imagePath: string) => string;

// ================== 快照管理功能 ==================

/**
 * 获取 QCOW2 镜像的快照列表
 * @param imagePath 镜像文件的完整路径
 * @returns JSON 格式的快照列表 {snapshots: [{id, name, vm_size, date, vm_clock}]}
 */
export const getSnapshots: (imagePath: string) => string;

/**
 * 创建快照
 * @param imagePath 镜像文件的完整路径
 * @param snapshotName 快照名称
 * @returns JSON 格式的结果 {success: true} 或 {error: string, need_restart?: boolean}
 */
export const createSnapshot: (imagePath: string, snapshotName: string) => string;

/**
 * 恢复快照
 * @param imagePath 镜像文件的完整路径
 * @param snapshotName 快照名称
 * @returns JSON 格式的结果
 */
export const applySnapshot: (imagePath: string, snapshotName: string) => string;

/**
 * 删除快照
 * @param imagePath 镜像文件的完整路径
 * @param snapshotName 快照名称
 * @returns JSON 格式的结果
 */
export const deleteSnapshot: (imagePath: string, snapshotName: string) => string;

/**
 * 优化镜像
 * @param imagePath 输入镜像文件路径
 * @param outputPath 输出镜像文件路径
 * @param mode 优化模式: 'sparse' (稀疏压缩), 'prealloc' (预分配), 'cleanup' (清理预分配), 'optimize' (仅优化格式参数)
 * @returns JSON 格式的结果
 */
export const optimizeImage: (imagePath: string, outputPath: string, mode: 'sparse' | 'prealloc' | 'cleanup' | 'optimize') => string;

// ================== FFmpeg 视频播放功能 ==================

/**
 * 绑定 XComponent 的 Surface 到视频播放器
 * @param surfaceId XComponent Surface ID (通过 context.getXComponentSurfaceId() 获取)
 * @returns 是否成功
 */
export const setVideoSurface: (surfaceId: string) => boolean;

/**
 * 播放本地视频文件（默认循环播放）
 * @param path 视频文件的完整沙箱路径
 * @returns 是否成功开始播放
 */
export const playVideo: (path: string) => boolean;

/**
 * 停止视频播放
 */
export const stopVideo: () => void;

/**
 * 释放视频播放器资源
 */
export const releaseVideoPlayer: () => void;

// ================== GWP-ASAN 故障检测与注入控制 ==================

/**
 * 设置 GWP-ASAN 事件检测标志。一旦设置为 true，后续的故障注入将被跳过。
 * @param detected 是否检测到 GWP-ASAN 事件
 */
export const setGwpAsanDetected: (detected: boolean) => void;

/**
 * 在指定秒数后调用 abort() 终止进程。用于 GWP-ASAN 检测后的延迟自杀。
 * @param delaySeconds 延迟秒数，默认 300（5分钟）
 */
export const scheduleAbort: (delaySeconds: number) => void;
