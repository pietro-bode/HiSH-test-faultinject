#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
鸿蒙应用崩溃循环测试脚本（改进版）

检测策略：
  1. 【主】故障日志文件出现：启动前记录基准文件列表，监控 faultlogger 目录是否有新文件
  2. 【辅】进程消失：pidof 检测应用进程从有到无
  3. 【辅】hilog 关键字：检测 SIGSEGV/SIGABRT/faultlogger/GWP-ASan 等关键字

用法:
    python crash_loop_test.py
    python crash_loop_test.py --max-iterations 10 --poll-interval 3
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'


def print_header(msg: str):
    print(f"\n{Colors.OKCYAN}{'='*50}{Colors.ENDC}")
    print(f"{Colors.OKCYAN}{msg}{Colors.ENDC}")
    print(f"{Colors.OKCYAN}{'='*50}{Colors.ENDC}")


def print_info(msg: str):
    print(f"{Colors.OKGREEN}[INFO]{Colors.ENDC} {msg}")


def print_warn(msg: str):
    print(f"{Colors.WARNING}[WARN]{Colors.ENDC} {msg}")


def print_error(msg: str):
    print(f"{Colors.FAIL}[ERROR]{Colors.ENDC} {msg}")


class HdcHelper:
    def __init__(self, hdc_path: str):
        self.hdc = hdc_path

    def _run(self, *args, timeout: int = 60) -> str:
        """运行 hdc 命令，子进程独立运行，确保 Ctrl+C 只发给 Python"""
        cmd = [self.hdc] + list(args)
        proc = None
        try:
            kwargs = {}
            if os.name == 'nt':
                # Windows: 让子进程在新进程组中运行，不接收 Ctrl+C
                kwargs['creationflags'] = subprocess.CREATE_NEW_PROCESS_GROUP
            else:
                # Unix: 让子进程在新会话中运行
                kwargs['start_new_session'] = True

            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding='utf-8',
                errors='replace',
                **kwargs
            )
            stdout, stderr = proc.communicate(timeout=timeout)
            return (stdout or "") + (stderr or "")
        except subprocess.TimeoutExpired:
            if proc:
                proc.kill()
                proc.wait()
            return ""
        except KeyboardInterrupt:
            if proc:
                proc.kill()
                proc.wait()
            raise
        except Exception as e:
            if proc:
                proc.kill()
                proc.wait()
            return str(e)

    def shell(self, command: str, timeout: int = 60) -> str:
        return self._run("shell", command, timeout=timeout)

    def file_recv(self, remote_path: str, local_dir: str) -> str:
        return self._run("file", "recv", remote_path, local_dir)

    def list_targets(self) -> str:
        return self._run("list", "targets")


class CrashLoopTester:
    CRASH_KEYWORDS = [
        "SIGSEGV", "SIGABRT", "SIGILL", "SIGBUS", "SIGFPE", "SIGTRAP",
        "faultlogger", "GWP-ASan", "AddressSanitizer", "MemoryTagging",
        "HeapBufferOverflow", "UseAfterFree", "DoubleFree",
        "Abort message", "runtime error"
    ]

    def __init__(self, args: argparse.Namespace):
        self.bundle_name = args.bundle_name
        self.ability_name = args.ability_name
        self.log_dir = Path(args.log_dir).resolve()
        self.poll_interval = args.poll_interval
        self.post_crash_delay = args.post_crash_delay
        self.max_iterations = args.max_iterations
        self.clean_device_logs = args.clean_device_logs
        self.launch_mode = args.launch_mode
        self.hdc = None
        self._baseline_logs = set()

    def find_hdc(self) -> str:
        hdc = shutil.which("hdc")
        if hdc:
            return hdc
        home = Path.home()
        patterns = [
            str(home / "AppData" / "Local" / "OpenHarmony" / "Sdk" / "*" / "toolchains" / "*" / "hdc.exe"),
            str(home / "AppData" / "Local" / "Huawei" / "Sdk" / "*" / "toolchains" / "*" / "hdc.exe"),
            "/opt/harmonyos/sdk/*/toolchains/*/hdc",
            "/opt/openharmony/sdk/*/toolchains/*/hdc",
        ]
        for pattern in patterns:
            matches = glob.glob(pattern)
            if matches:
                return matches[0]
        print_error("未找到 hdc 命令。请确保鸿蒙 SDK 已安装，并将 hdc 所在目录添加到系统 PATH。")
        sys.exit(1)

    def init(self):
        hdc_path = self.find_hdc()
        print_info(f"使用 hdc: {hdc_path}")
        self.hdc = HdcHelper(hdc_path)

        print_info("检查设备连接...")
        devices = self.hdc.list_targets()
        if not devices or "Empty" in devices or "error" in devices.lower():
            print_error("没有检测到已连接的设备，请通过 hdc 连接设备后再试。")
            sys.exit(1)
        print_info(f"已连接设备:\n{devices}")

        self.log_dir.mkdir(parents=True, exist_ok=True)
        print_info(f"PC 端日志保存目录: {self.log_dir}")

    def enable_gwp_asan_prop(self) -> str:
        prop = f"gwp_asan.enable.app.{self.bundle_name}"
        print_info(f"设置 GWP-ASan 系统属性: {prop}=true")
        result = self.hdc.shell(f"param set {prop} true")
        print_info(f"设置结果: {result}")
        return result

    def start_app(self) -> str:
        if self.launch_mode == "test":
            cmd = f"aa test -b {self.bundle_name} -m entry_test"
            print_info(f"通过测试框架启动: {cmd}")
        else:
            cmd = f"aa start -a {self.ability_name} -b {self.bundle_name}"
            print_info(f"直接启动应用: {cmd}")
        result = self.hdc.shell(cmd)
        print_info(f"启动结果: {result}")
        return result

    def stop_app(self) -> str:
        print_info(f"强制停止应用: {self.bundle_name}")
        result = self.hdc.shell(f"aa force-stop {self.bundle_name}")
        time.sleep(1)
        return result

    def clear_device_logs(self):
        print_info("清理设备旧故障日志...")
        self.hdc.shell("rm -f /data/log/faultlog/faultlogger/*")

    def get_app_pid(self) -> str | None:
        result = self.hdc.shell(f"pidof {self.bundle_name}")
        if not result or "fail" in result.lower() or "error" in result.lower():
            return None
        pid = result.split()[0].strip()
        if pid.isdigit():
            return pid
        return None

    def list_faultlogger_files(self) -> set[str]:
        result = self.hdc.shell("ls -1 /data/log/faultlog/faultlogger/ 2>/dev/null")
        if not result or "No such file" in result:
            return set()
        return {f.strip() for f in result.splitlines() if f.strip() and not f.strip().startswith("total")}

    def check_new_fault_logs(self) -> list[str]:
        current = self.list_faultlogger_files()
        new_files = current - self._baseline_logs
        return list(new_files)

    def check_hilog_crash_keywords(self) -> list[str]:
        result = self.hdc.shell("hilog -d | tail -n 200")
        if not result:
            return []
        matched = []
        for kw in self.CRASH_KEYWORDS:
            if kw in result:
                matched.append(kw)
        return matched

    def wait_for_crash(self, timeout_seconds: int = 0) -> tuple[bool, str]:
        start_time = time.time()
        last_pid = None
        print_info("开始监控崩溃（检测方式：故障日志/进程消失/hilog关键字）...")

        while True:
            time.sleep(self.poll_interval)

            # 检测 1：新的故障日志文件出现（最可靠）
            new_logs = self.check_new_fault_logs()
            if new_logs:
                print_info(f"检测到新故障日志: {', '.join(new_logs)}")
                return True, "faultlogger"

            # 检测 2：进程消失
            current_pid = self.get_app_pid()
            if last_pid and not current_pid:
                print_info(f"检测到应用进程已退出 (原 PID: {last_pid})")
                return True, "pid_gone"
            if current_pid:
                last_pid = current_pid

            # 检测 3：hilog 关键字
            keywords = self.check_hilog_crash_keywords()
            if keywords:
                print_info(f"检测到 hilog 崩溃关键字: {', '.join(keywords)}")
                return True, "hilog_keyword"

            if current_pid:
                print(f"  应用运行中 (PID: {current_pid}) ...")
            else:
                print("  等待应用启动...")

            if timeout_seconds > 0:
                if time.time() - start_time >= timeout_seconds:
                    print_warn(f"等待超时 ({timeout_seconds}s)")
                    return False, "timeout"

    def collect_fault_logs(self, target_dir: Path, run_index: int) -> int:
        collected = 0

        # 只采集 faultlogger 下与目标应用相关的故障日志
        fault_dir = "/data/log/faultlog/faultlogger/"
        print_info(f"扫描故障日志目录: {fault_dir}")
        files = self.hdc.shell(f"ls -1 {fault_dir} 2>/dev/null")
        if files and "No such file" not in files:
            for file in files.splitlines():
                file = file.strip()
                if not file or file.startswith("total"):
                    continue
                # 只采集属于目标应用的故障日志
                if self.bundle_name not in file:
                    continue
                remote = f"{fault_dir}{file}"
                print_info(f"  拉取故障日志: {file}")
                self.hdc.file_recv(remote, str(target_dir))
                collected += 1
        else:
            print_warn("faultlogger 目录为空")

        if collected == 0:
            print_warn(f"未找到 {self.bundle_name} 的故障日志文件")

        # 同时导出 hilog 和 dump 作为上下文参考
        hilog_file = target_dir / f"hilog_{run_index}.txt"
        print_info(f"  导出完整 hilog 到: {hilog_file}")
        hilog = self.hdc.shell("hilog -d | tail -n 1000")
        if hilog:
            hilog_file.write_text(hilog, encoding="utf-8")

        dump_file = target_dir / f"app_dump_{run_index}.txt"
        dump = self.hdc.shell("aa dump -a")
        if dump:
            dump_file.write_text(dump, encoding="utf-8")

        return collected

    def run(self):
        print_header("鸿蒙崩溃循环测试开始")
        print_info(f"目标应用: {self.bundle_name}/{self.ability_name}")
        print_info(f"启动模式: {self.launch_mode}")
        if self.max_iterations == 0:
            print_info("循环次数: 无限 (按 Ctrl+C 停止)")
        else:
            print_info(f"循环次数: {self.max_iterations}")

        iteration = 0
        total_logs = 0

        try:
            while True:
                if self.max_iterations > 0 and iteration >= self.max_iterations:
                    print_header(f"已达到最大迭代次数 {self.max_iterations}")
                    break
                iteration += 1

                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                run_dir = self.log_dir / f"run_{timestamp}_#{iteration:03d}"
                run_dir.mkdir(parents=True, exist_ok=True)

                print_header(f"第 {iteration} 轮测试")
                print_info(f"开始时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
                print_info(f"本轮日志目录: {run_dir}")

                if self.clean_device_logs:
                    self.clear_device_logs()

                self.stop_app()
                time.sleep(1)

                self._baseline_logs = self.list_faultlogger_files()
                print_info(f"启动前故障日志基准: {len(self._baseline_logs)} 个文件")

                self.enable_gwp_asan_prop()
                self.start_app()
                time.sleep(3)

                crashed, detect_method = self.wait_for_crash()

                if not crashed:
                    print_warn("本轮未检测到崩溃，强制停止应用后继续下一轮")
                    self.stop_app()
                else:
                    print_info(f"崩溃检测方式: {detect_method}")
                    print_info(f"等待 {self.post_crash_delay}s 让日志完成写入...")
                    time.sleep(self.post_crash_delay)

                print_info("收集故障日志...")
                count = self.collect_fault_logs(run_dir, iteration)
                total_logs += count
                print_info(f"本轮收集到 {count} 个日志文件")
                print_info(f"第 {iteration} 轮完成")
                time.sleep(2)

        except KeyboardInterrupt:
            print_warn("\n======================================")
            print_warn("用户中断测试 (Ctrl+C)")
            print_warn("======================================")
        except Exception as e:
            print_error(f"发生异常: {e}")
            import traceback
            traceback.print_exc()
        finally:
            print_header("测试结束")
            print_info(f"总轮数: {iteration}")
            print_info(f"总日志文件数: {total_logs}")
            print_info(f"日志根目录: {self.log_dir}")
            print_info(f"如需停止应用，请运行: hdc shell aa force-stop {self.bundle_name}")


def main():
    parser = argparse.ArgumentParser(description="鸿蒙应用崩溃循环测试脚本（改进版）")
    parser.add_argument("--bundle-name", default="dev.hackeris.hish.test", help="应用包名")
    parser.add_argument("--ability-name", default="EntryAbility", help="入口 Ability 名称")
    parser.add_argument("--log-dir", default="./crash_logs", help="PC 端日志保存目录")
    parser.add_argument("--poll-interval", type=int, default=3, help="检测轮询间隔（秒），默认 3")
    parser.add_argument("--post-crash-delay", type=int, default=5, help="崩溃后等待日志写入的时间（秒）")
    parser.add_argument("--max-iterations", type=int, default=0, help="最大循环次数，0 表示无限")
    parser.add_argument("--no-clean-device-logs", action="store_true", help="每轮开始前不清理设备上的旧故障日志")
    parser.add_argument("--launch-mode", choices=["start", "test"], default="start", help="启动模式")

    args = parser.parse_args()
    args.clean_device_logs = not args.no_clean_device_logs

    tester = CrashLoopTester(args)
    tester.init()
    tester.run()


if __name__ == "__main__":
    main()
