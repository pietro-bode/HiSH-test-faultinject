# HiSH-test-faultinject

## 项目背景说明

项目从 [HiSH-test-faultinject](https://gitcode.com/stesen1/HiSH-test-faultinject) clone 而来，而 HiSH-test-faultinject 则从 [HiSH](https://github.com/harmoninux/HiSH) (HarmonyOS版的termux) fork 而来，相比于 HiSH 主要增加了故障注入功能。

## 架构与当前问题

### 架构

HiSH-test-faultinject 通过 ffmpeg 播放视频模拟用户态负载，并在 entry 模块中增加一个 subThread ，令他每0.05s在给定的10种(当前实际只选了5种)故障注入中随机选择一种，若注入后崩溃则输出对应的日志，并由系统生成 cppcrash 记录，若未崩溃则继续随机注入。

并且，项目新开启了 GWP_ASan 机制，随机抽查一些 malloc 请求，如果抽查出问题就直接crash，主要用于检测 use after free.

目前启用的注入类型包含 Use after free(UAF), Double free, Stack overflow, Stack Use-After-Return.

关键代码信息在 `entry/src/main/cpp/fault_injection.cpp` 中。

### 问题

现在的问题在于，目前浏览过的几十个cppcrash的最终直接触发崩溃的原因都是 type=2(Double free) 或者是 type=3(Stack overflow)。

目前的推测是：

1. 这两者对于crash的触发都是即时性的，因为一者free函数存在安全检查，如果double free就会立刻crash。二者栈溢出一般都会覆盖canary——一种布置在栈帧上，用于检测栈溢出的数值，这会导致canary和全局canary不一致，校验不通过，进而直接crash。

2. 而其余几者(0, 1, 4)触发crash往往是非即时性的。例如UAF，如果隐式的在free之后写了堆的chunk中的内容，往往并不会导致直接crash，一般会在下一次用到被影响的数据时，才会出现问题。
3. 同时，由于 GWP_ASan机制 是抽查，在前面搅动堆布局malloc数据量较大，注入时malloc较少的情况下，可能抽查到的概率很低，所以没有显现出问题。

4. 0.05s的时间可能太短，导致没有足够的时间让问题发酵，在埋的雷炸掉之前，就已经因为新一轮随机到了即时性的注入，导致crash了，不会再有让隐藏的问题显现进而导致崩溃的机会。

即时性的问题相对而言是好分析的，因为捕捉到的crash现场基本就是造成崩溃的第一现场，追溯根因相对容易。然而静默执行下去的由于崩溃与异常的异步性相对难以追溯，也是想要攻克的。

### 可能的解决思路

1. 扩展注入类型，把文件中已有的10种都试一试，进一步查看上述推测是否成立。
2. 延长0.05s的时间，观察是否会导致长时间之后崩溃的情况。
3. 优化注入和用户态负载模拟，尝试更加真实的模拟是否会导致不同。
4. ...



## 环境部署

**通用部署（详见HiSH的README中构建指南章节）**：

* 下载安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)
* 克隆代码到本地 [修改版HiSH-test-faultinject](https://github.com/pietro-bode/HiSH-test-faultinject)
* 复制`build-profile.template.json5`到`build-profile.json5`
* 下载以下文件到指定位置：
  - [entry/libs.zip](https://github.com/harmoninux/qemu/releases/download/hish-20260110/libs.zip)（解压到`entry/libs`）
  - [entry/src/main/resources/rawfile/vm/kernel_aarch64](https://github.com/harmoninux/linux-config/releases/download/kernel-20260228/kernel_aarch64)
  - [entry/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2](https://github.com/harmoninux/linux-config/releases/download/rootfs-20260117/rootfs_aarch64.qcow2)



**HiSH-test-faultinject 附加部署**：

由于原项目中`.gitignore`忽略了.so文件，导致 `entry/src/main/cpp/third_party/ffmpeg/libs` 中缺少ffmpeg必要的库，需要自行编译。其中x86_64为模拟器所需，arm64为真机所需。

HarmonyOS版的ffmpeg libs需要根据 `entry/src/main/cpp/third_party/ffmpeg/README.md` 编译，目前已经编译了x86_64架构的libs，在模拟器上已经可以正常运行。arm64架构仍未构建。

- 下载x86_64架构的libs到指定位置：
  - [entry/src/main/cpp/third_party/ffmpeg/libs/x86_64.zip](https://drive.google.com/file/d/1fKY-L1ADbST-lKbfXjJFH9yuTsaIlzma/view?usp=sharing) （解压到 `entry/src/main/cpp/third_party/ffmpeg/libs/x86_64`）
- 修改 `entry/build-profile.json5` ：
  - 注释掉 `"abiFilters"` 中的 `"arm64-v8a",` （如果未来构建了arm64的libs，那么可以取消注释）
- 将 `entry/src/main/resources/rawfile/video/test.avi` 复制到 `entry/src/main/resources/rawfile/test.avi`

### libs编译指南（可选）

1. 准备ffmpeg源码：
   ```
   # 下载 FFmpeg 6.1.1 源码
   wget https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz
   tar -xf ffmpeg-6.1.1.tar.xz
   cd ffmpeg-6.1.1
   ```

2. 准备NDK：

   下载对应版本的command-line：[command-line](https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos)

   解压后，找到 `command-line-tools/sdk/default/openharmony/native` 目录

3. 安装工具链（x86_64所依赖）：
   ```
   sudo apt install yasm nasm 
   ```

4. 编译脚本（注意切换架构）：
   ```
   #!/bin/bash
   
   # 指向刚才解压出来的 native 目录
   export OHOS_SDK="path/to/command-line-tools/sdk/default/openharmony/native"
   
   # 把 Clang 编译器加入环境变量
   export PATH="${OHOS_SDK}/llvm/bin:${PATH}"
   
   #export OHOS_ARCH="aarch64"
   export OHOS_ARCH="x86_64"
   
   PREFIX_DIR="~/ohos_build/ffmpeg-ohos-output/x86_64"
   
   ./configure \
       --prefix="${PREFIX_DIR}" \
       --target-os=android \
       --arch=x86_64 \
       --enable-cross-compile \
       --disable-static --enable-shared \
       --disable-encoders --disable-muxers \
       --disable-network --disable-protocols --enable-protocol=file \
       --disable-vulkan --disable-hwaccels \
       --cc="${OHOS_ARCH}-unknown-linux-ohos-clang" \
       --sysroot="${OHOS_SDK}/sysroot"
   
   make -j4
   make install
   ```



## DevEco使用注意

### 模拟器注意事项

模拟器启动耗费3-5分钟是正常的。

- 在windows下，需要以管理员权限启动DevEco，否则模拟器会一直卡在HarmonyOS加载界面。

- 如果电脑内存不足（例如浏览器占用太多内存）也会导致上述现象，具体需要分析模拟器日志。

模拟器日志通过 `设备管理器->具体的设备最右边的箭头->显示在磁盘上` 打开。

- 如果 `kernel.log` 显示 `[QOS_CTRL] do_qos_ctrl_ioctl: pid not authorized` ，则为管理员权限问题；

- 如果是内存不够，那么日志中会有相关字段，建议交给AI分析。

相关问题贴 [DevEco Studio模拟器一直停留在开机页面转圈-华为开发者问答 ]([DevEco Studio模拟器，启动失败，一直停留在开机页面转圈-华为开发者问答 | 华为开发者联盟](https://developer.huawei.com/consumer/cn/forum/topic/0207167512608540136))

### DevEco配置

项目构建过程中IDE需要联网下载一些文件，代理配置在

`设置->外观与行为->系统设置->HTTP代理`

模拟器代理可以在 边栏的展开更多配置 中，通过网络选项进行设置。



------





> **以下为HiSH原README**


# HiSH

[GitHub](https://github.com/harmoninux/HiSH) | [GitCode](https://gitcode.com/realhackeris/HiSH) | [Gitee](https://gitee.com/hackeris/HiSH) | [English](README_EN.md)

在HarmonyOS设备上运行Linux Shell。基于[qemu-ohos](https://github.com/harmoninux/qemu)，支持2in1(PC)、平板和手机。

![多设备运行](docs/images/devices.png)

## 如何获取

可以选择下面任一方法获取HiSH：

- 通过[应用市场](https://appgallery.huawei.com/app/detail?id=app.hackeris.hish)安装（因应用市场政策限制，不支持JIT，运行效率一般）
- 从[Releases](https://github.com/harmoninux/HiSH/releases)下载hap文件，自行签名后安装到设备或模拟器（支持JIT，运行效率更高。安装方法见：[使用教程](https://github.com/harmoninux/HiSH/discussions/130)）（需要安装小白安装助手）
- 使用 DevEco Studio 编译源码安装，参考 [构建并安装HAP](#构建hap)（支持JIT，运行效率更高）

## 核心功能

- 完整的arm64 Linux内核
- 网络支持，并支持端口转发
- Alpine Linux根文件系统
- 虚拟按键（Tab/Ctrl/Esc/方向键）
- 共享文件夹
- JIT（仅开发者可用）
- 镜像导入（[Ubuntu24.04镜像](https://github.com/harmoninux/linux-config/releases/download/rootfs-20251213/ubuntu-base-24.04.zip) / [Debian12镜像](https://github.com/harmoninux/linux-config/releases/download/release-20251129-debian/debian12.zip)）

## 使用指南

参考 [使用指南](docs/guide)

## 讨论交流

QQ群二维码

<img src="docs/images/qq_group.jpg" width="200"/>

## 授权许可

使用本项目代码，按照[惯例](https://www.n.cn/share/r1/d256b59a563047a3a052e58042ae2547)需在软件本体"关于"中注明基于本项目（HiSH）以及本项目的仓库地址。

# 构建指南

- HAP包
- libqemu-system库（可选）
- Linux内核（可选）
- 根文件系统（可选）

## 构建HAP

* 下载安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)
* 克隆代码到本地
* 复制`build-profile.template.json5`到`build-profile.json5`
* 下载以下文件到指定位置：
  - [entry/libs.zip](https://github.com/harmoninux/qemu/releases/download/hish-20260110/libs.zip)（解压到`entry/libs`）
  - [entry/src/main/resources/rawfile/vm/kernel_aarch64](https://github.com/harmoninux/linux-config/releases/download/kernel-20260228/kernel_aarch64)
  - [entry/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2](https://github.com/harmoninux/linux-config/releases/download/rootfs-20260117/rootfs_aarch64.qcow2)
* 在DevEco Studio中构建项目
* 签名后在设备或模拟器上运行。参考 [本地真机运行应用](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-run-device) | [自动签名-未关联注册应用](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing#section151231211105010)

## 构建libqemu-system（可选）

在Ubuntu或Windows的WSL2环境下构建自定义的`libqemu-system-aarch64.so`：

* 安装依赖：

```shell 
sudo apt install -y build-essential cmake curl wget unzip python3 libncurses-dev \
    git flex bison bash make autoconf libcurl4-openssl-dev tcl \
    gettext zip pigz meson 
```

* 从[华为开发者官网](https://developer.huawei.com/consumer/cn/download/)下载Linux版"Command Line Tools"
* 解压后将`TOOL_HOME`环境变量设置为解压目录
* 进入`deps`目录运行构建脚本`build.sh`（默认针对x86_64模拟器）：
    * 针对真机的构建（arm64-v8a），需要将`build.sh`脚本中的`OHOS_ARCH`改为`aarch64`，`OHOS_ABI`改为`arm64-v8a`
```shell 
cd deps 
./build.sh 
```
* 构建产物位于`deps/output`目录

## 构建Linux内核（可选）

* 安装依赖：

```shell 
sudo apt install build-essential gcc bc bison flex libssl-dev \
 libncurses5-dev libelf-dev gcc-aarch64-linux-gnu \
 clang lld llvm make 
```

* 克隆Linux内核源码：

```shell 
git clone --depth=1 -b v6.12 https://github.com/torvalds/linux 
```

* 下载内核配置：

```shell 
cd linux 
curl https://raw.githubusercontent.com/harmoninux/linux-config/refs/heads/master/arm64_virt > .config 
```

* 编译内核：

```shell
export KCFLAGS='-march=armv8.5-a+crc+crypto+lse+rcpc+rng+sm4+sha3+dotprod+fp16 -mtune=neoverse-n1 -O2 -falign-functions=64 -fno-strict-aliasing -mllvm -vectorize-loops -mllvm -force-vector-width=2'
env KCFLAGS="$KCFLAGS" make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 menuconfig
env KCFLAGS="$KCFLAGS" make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 -j$(nproc)
```

* 内核镜像位于`arch/arm64/boot/Image`，复制到项目对应目录

## 构建Linux根文件系统（可选）

以下是构建自定义根文件系统的完整流程

* 准备Alpine根文件系统

```shell 
# 创建目录并解压Alpine最小根文件系统 
mkdir alpine 
wget https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.1-aarch64.tar.gz 
tar xvf alpine-minirootfs-3.22.1-aarch64.tar.gz -C alpine 
```

* 创建磁盘镜像文件

```shell 
# 创建8GB大小的原始镜像文件（可根据需要调整大小）
qemu-img create -f raw rootfs.img 8G 
 
# 格式化为ext4文件系统 
mkfs.ext4 rootfs.img 
```

* 挂载并填充文件系统

```shell 
# 创建挂载点并挂载镜像 
sudo mkdir -p /mnt/rootfs 
sudo mount -o loop rootfs.img /mnt/rootfs 
 
# 复制Alpine文件系统内容 
sudo cp -a alpine/* /mnt/rootfs/
 
# 卸载镜像 
sudo umount /mnt/rootfs 
```

* 转换为qcow2格式

```shell 
# 转换格式（qcow2支持动态分配空间）
qemu-img convert -p -f raw -O qcow2 rootfs.img rootfs.qcow2 
```

* 部署到项目

```shell 
# 将生成的文件放入项目目录 
mkdir -p entry/src/main/resources/rawfile/vm/
mv rootfs.qcow2 entry/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2 
```

# Star history

[![星标历史图表](https://api.star-history.com/svg?repos=harmoninux/hish&type=Date)](https://www.star-history.com/#harmoninux/hish&Date)
