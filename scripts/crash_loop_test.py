#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
鸿蒙应用崩溃循环测试脚本（GWP-ASan 恢复模式增强版）

三种情况处理：
  1. 应用退出，只产生 crash 日志 -> 只收集 crash 日志
  2. 应用退出，产生了 crash + gwpasan 日志 -> 同时收集到同一目录
  3. 应用产生了 gwpasan 日志但没有 crash 退出 -> 5分钟超时后 kill，重新测试

用法:
    python crash_loop_test.py
    python crash_loop_test.py --gwpasan-dir /data/log/gwpasan
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
        cmd = [self.hdc] + list(args)
        proc = None
        try:
            kwargs = {}
            if os.name == 'nt':
                kwargs['creationflags'] = subprocess.CREATE_NEW_PROCESS_GROUP
            else:
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

    # GWP-ASan 日志可能的存放路径（按优先级尝试）
    GWPASAN_CANDIDATE_DIRS = [
        "/data/log/gwpasan/",
        "/data/log/faultlog/gwpasan/",
        "/dev/asanlog/",
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
        self.gwpasan_dir = args.gwpasan_dir
        self.timeout_seconds = args.timeout_seconds
        self.hdc = None
        self._baseline_fault = set()
        self._baseline_gwpasan = set()
        self._actual_gwpasan_dir = None

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

        # 探测 GWP-ASan 日志实际路径
        self._detect_gwpasan_dir()

    def _detect_gwpasan_dir(self):
        """探测设备上 GWP-ASan 日志的实际存放路径"""
        if self.gwpasan_dir:
            self._actual_gwpasan_dir = self.gwpasan_dir
            print_info(f"使用指定的 GWP-ASan 日志路径: {self._actual_gwpasan_dir}")
            return

        for d in self.GWPASAN_CANDIDATE_DIRS:
            result = self.hdc.shell(f"ls -d {d} 2>/dev/null")
            if result and "No such file" not in result and "not exist" not in result.lower():
                self._actual_gwpasan_dir = d
                print_info(f"探测到 GWP-ASan 日志路径: {self._actual_gwpasan_dir}")
                return

        print_warn("未探测到 GWP-ASan 日志目录，将尝试使用默认路径 /data/log/gwpasan/")
        self._actual_gwpasan_dir = "/data/log/gwpasan/"

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
        if self._actual_gwpasan_dir:
            self.hdc.shell(f"rm -f {self._actual_gwpasan_dir}*")

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
        return {f.strip() for f in result.splitlines()
                if f.strip()
                and not f.strip().startswith("total")
                and not f.strip().startswith("stacktrace")}

    def list_gwpasan_files(self) -> set[str]:
        if not self._actual_gwpasan_dir:
            return set()
        result = self.hdc.shell(f"ls -1 {self._actual_gwpasan_dir} 2>/dev/null")
        if not result or "No such file" in result:
            return set()
        return {f.strip() for f in result.splitlines() if f.strip() and not f.strip().startswith("total")}

    def check_new_fault_logs(self) -> list[str]:
        current = self.list_faultlogger_files()
        new_files = current - self._baseline_fault
        return list(new_files)

    def check_new_gwpasan_logs(self) -> list[str]:
        current = self.list_gwpasan_files()
        new_files = current - self._baseline_gwpasan
        return list(new_files)

    def enable_gwp_asan_prop(self) -> str:
        # 开启 GWP-ASan
        prop = f"gwp_asan.enable.app.{self.bundle_name}"
        print_info(f"设置 GWP-ASan 系统属性: {prop}=true")
        result1 = self.hdc.shell(f"param set {prop} true")
        print_info(f"设置结果: {result1}")
        # 设置可恢复模式（崩溃后不杀死进程，便于采集日志）
        recoverable = f"gwp_asan.recoverable.app.{self.bundle_name}"
        print_info(f"设置 GWP-ASan 恢复属性: {recoverable}=true")
        result2 = self.hdc.shell(f"param set {recoverable} true")
        print_info(f"设置结果: {result2}")
        return result1 + "; " + result2

    def wait_for_crash(self) -> tuple[bool, str, list[str], list[str]]:
        """
        等待崩溃或超时，返回 (是否检测到异常, 检测方式, crash日志列表, gwpasan日志列表)
        检测方式: crash_only | crash_and_gwpasan | gwpasan_only_timeout | timeout | interrupted
        """
        start_time = time.time()
        last_pid = None
        has_new_crash = False
        has_new_gwpasan = False
        crash_logs = []
        gwpasan_logs = []

        print_info("开始监控崩溃（检测方式：faultlogger/gwpasan/进程消失/5分钟超时）...")

        while True:
            time.sleep(self.poll_interval)
            elapsed = time.time() - start_time

            # 检查新日志
            current_crash = self.check_new_fault_logs()
            current_gwpasan = self.check_new_gwpasan_logs()
            if current_crash:
                has_new_crash = True
                crash_logs = current_crash
            if current_gwpasan:
                has_new_gwpasan = True
                gwpasan_logs = current_gwpasan

            current_pid = self.get_app_pid()

            # 进程从有到无 -> 退出/崩溃
            if last_pid and not current_pid:
                print_info(f"检测到应用进程已退出 (原 PID: {last_pid})")
                # 等待日志完全写入
                time.sleep(self.post_crash_delay)
                # 最终检查
                final_crash = self.check_new_fault_logs()
                final_gwpasan = self.check_new_gwpasan_logs()
                if final_crash:
                    has_new_crash = True
                    crash_logs = final_crash
                if final_gwpasan:
                    has_new_gwpasan = True
                    gwpasan_logs = final_gwpasan

                if has_new_crash and has_new_gwpasan:
                    print_info(f"情况2: 进程退出，检测到 crash({len(crash_logs)}个) + gwpasan({len(gwpasan_logs)}个) 日志")
                    return True, "crash_and_gwpasan", crash_logs, gwpasan_logs
                elif has_new_crash and not has_new_gwpasan:
                    print_info(f"情况1: 进程退出，检测到 crash({len(crash_logs)}个) 日志，无 gwpasan 日志")
                    return True, "crash_only", crash_logs, []
                elif not has_new_crash and has_new_gwpasan:
                    print_info(f"进程退出，检测到 gwpasan({len(gwpasan_logs)}个) 日志，无 crash 日志")
                    return True, "gwpasan_only", [], gwpasan_logs
                else:
                    print_warn("进程退出但未检测到任何日志，视为正常退出")
                    return True, "pid_gone_no_logs", [], []

            if current_pid:
                last_pid = current_pid

            # 应用启动后快速崩溃：从未检测到PID，但已有新日志
            if not current_pid and (has_new_crash or has_new_gwpasan):
                print_info(f"检测到新日志但进程未运行，可能启动后快速崩溃 (crash={len(crash_logs)}, gwpasan={len(gwpasan_logs)})...")
                time.sleep(self.post_crash_delay)
                final_crash = self.check_new_fault_logs()
                final_gwpasan = self.check_new_gwpasan_logs()
                if final_crash:
                    has_new_crash = True
                    crash_logs = final_crash
                if final_gwpasan:
                    has_new_gwpasan = True
                    gwpasan_logs = final_gwpasan

                if has_new_crash and has_new_gwpasan:
                    print_info(f"情况2: 快速崩溃，检测到 crash({len(crash_logs)}个) + gwpasan({len(gwpasan_logs)}个) 日志")
                    return True, "crash_and_gwpasan", crash_logs, gwpasan_logs
                elif has_new_crash:
                    print_info(f"情况1: 快速崩溃，检测到 crash({len(crash_logs)}个) 日志，无 gwpasan 日志")
                    return True, "crash_only", crash_logs, []
                elif has_new_gwpasan:
                    print_info(f"快速崩溃，检测到 gwpasan({len(gwpasan_logs)}个) 日志，无 crash 日志")
                    return True, "gwpasan_only", [], gwpasan_logs

            # 5分钟超时检查
            if elapsed >= self.timeout_seconds:
                if has_new_gwpasan and current_pid:
                    # 情况3: 有gwpasan但进程未退出，超时kill
                    print_warn(f"情况3: 检测到 GWP-ASan 日志但进程未退出，{self.timeout_seconds}s 超时，强制终止应用")
                    self.stop_app()
                    time.sleep(self.post_crash_delay)
                    final_crash = self.check_new_fault_logs()
                    final_gwpasan = self.check_new_gwpasan_logs()
                    return True, "gwpasan_only_timeout", final_crash, final_gwpasan
                else:
                    print_warn(f"等待超时 ({self.timeout_seconds}s)，未检测到异常")
                    return False, "timeout", [], []

            # 状态打印
            if current_pid:
                status = ""
                if has_new_gwpasan:
                    status = " [GWP-ASan detected]"
                if has_new_crash:
                    status += " [Crash detected]"
                print(f"  应用运行中 (PID: {current_pid}){status}，已运行 {int(elapsed)}s ...")
            else:
                if has_new_crash or has_new_gwpasan:
                    status = ""
                    if has_new_gwpasan:
                        status = " [GWP-ASan detected]"
                    if has_new_crash:
                        status += " [Crash detected]"
                    print(f"  等待应用启动... 已等待 {int(elapsed)}s (日志已检测到{status})")
                else:
                    print(f"  等待应用启动... 已等待 {int(elapsed)}s")

    def collect_fault_logs(self, target_dir: Path, run_index: int,
                           crash_logs: list[str], gwpasan_logs: list[str]) -> int:
        collected = 0

        # 1. 收集 crash 日志 (faultlogger)
        fault_dir = "/data/log/faultlog/faultlogger/"
        if crash_logs:
            print_info(f"收集 crash 日志 ({len(crash_logs)} 个)...")
            for file in crash_logs:
                if self.bundle_name not in file:
                    continue
                if file.startswith("stacktrace"):
                    continue
                remote = f"{fault_dir}{file}"
                print_info(f"  拉取 crash 日志: {file}")
                self.hdc.file_recv(remote, str(target_dir))
                collected += 1
        else:
            # 兜底：扫描目录下所有属于该应用的日志
            print_info("扫描 crash 日志目录...")
            files = self.hdc.shell(f"ls -1 {fault_dir} 2>/dev/null")
            if files and "No such file" not in files:
                for file in files.splitlines():
                    file = file.strip()
                    if not file or file.startswith("total"):
                        continue
                    if file.startswith("stacktrace"):
                        continue
                    if self.bundle_name not in file:
                        continue
                    remote = f"{fault_dir}{file}"
                    print_info(f"  拉取 crash 日志: {file}")
                    self.hdc.file_recv(remote, str(target_dir))
                    collected += 1

        # 2. 收集 GWP-ASan 日志
        if gwpasan_logs:
            print_info(f"收集 GWP-ASan 日志 ({len(gwpasan_logs)} 个)...")
            for file in gwpasan_logs:
                remote = f"{self._actual_gwpasan_dir}{file}"
                print_info(f"  拉取 GWP-ASan 日志: {file}")
                self.hdc.file_recv(remote, str(target_dir))
                collected += 1
        else:
            # 兜底扫描
            if self._actual_gwpasan_dir:
                print_info("扫描 GWP-ASan 日志目录...")
                files = self.hdc.shell(f"ls -1 {self._actual_gwpasan_dir} 2>/dev/null")
                if files and "No such file" not in files:
                    for file in files.splitlines():
                        file = file.strip()
                        if not file or file.startswith("total"):
                            continue
                        remote = f"{self._actual_gwpasan_dir}{file}"
                        print_info(f"  拉取 GWP-ASan 日志: {file}")
                        self.hdc.file_recv(remote, str(target_dir))
                        collected += 1

        # 3. hilog 上下文
        hilog_file = target_dir / f"hilog_{run_index}.txt"
        print_info(f"  导出完整 hilog 到: {hilog_file}")
        hilog = self.hdc.shell("hilog -d | tail -n 1000")
        if hilog:
            hilog_file.write_text(hilog, encoding="utf-8")

        # 4. dump
        dump_file = target_dir / f"app_dump_{run_index}.txt"
        dump = self.hdc.shell("aa dump -a")
        if dump:
            dump_file.write_text(dump, encoding="utf-8")

        return collected

    def run(self):
        print_header("鸿蒙崩溃循环测试开始 [GWP-ASan 恢复模式]")
        print_info(f"目标应用: {self.bundle_name}/{self.ability_name}")
        print_info(f"启动模式: {self.launch_mode}")
        print_info(f"超时时间: {self.timeout_seconds}s")
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

                # 记录基准
                self._baseline_fault = self.list_faultlogger_files()
                self._baseline_gwpasan = self.list_gwpasan_files()
                print_info(f"启动前基准 - crash日志: {len(self._baseline_fault)} 个, gwpasan日志: {len(self._baseline_gwpasan)} 个")

                self.enable_gwp_asan_prop()
                self.start_app()
                time.sleep(3)

                crashed, detect_method, crash_logs, gwpasan_logs = self.wait_for_crash()

                if detect_method == "timeout":
                    print_warn("本轮未检测到异常，继续下一轮")
                    self.stop_app()
                elif detect_method == "gwpasan_only_timeout":
                    print_info("情况3处理完成: 已强制终止应用并收集日志")
                elif not crashed:
                    print_warn("本轮异常，继续下一轮")
                    self.stop_app()
                else:
                    print_info(f"检测方式: {detect_method}")

                print_info("收集日志...")
                count = self.collect_fault_logs(run_dir, iteration, crash_logs, gwpasan_logs)
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
    parser = argparse.ArgumentParser(description="鸿蒙崩溃循环测试脚本（GWP-ASan 恢复模式）")
    parser.add_argument("--bundle-name", default="dev.hackeris.hish.test", help="应用包名")
    parser.add_argument("--ability-name", default="EntryAbility", help="入口 Ability 名称")
    parser.add_argument("--log-dir", default="./crash_logs", help="PC 端日志保存目录")
    parser.add_argument("--poll-interval", type=int, default=3, help="检测轮询间隔（秒），默认 3")
    parser.add_argument("--post-crash-delay", type=int, default=5, help="崩溃后等待日志写入的时间（秒）")
    parser.add_argument("--max-iterations", type=int, default=0, help="最大循环次数，0 表示无限")
    parser.add_argument("--no-clean-device-logs", action="store_true", help="每轮开始前不清理设备上的旧故障日志")
    parser.add_argument("--launch-mode", choices=["start", "test"], default="start", help="启动模式")
    parser.add_argument("--gwpasan-dir", default="", help="GWP-ASan 日志目录，默认自动探测")
    parser.add_argument("--timeout", type=int, default=300, help="单轮测试超时时间（秒），默认 300（5分钟）")

    args = parser.parse_args()
    args.clean_device_logs = not args.no_clean_device_logs
    args.timeout_seconds = args.timeout

    tester = CrashLoopTester(args)
    tester.init()
    tester.run()


if __name__ == "__main__":
    main()
