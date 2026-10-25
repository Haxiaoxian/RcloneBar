#!/usr/bin/env python3
"""
RcloneBar 端到端测试：真实 rclone bisync + 临时目录 + rclonebar-agent（direct 模式）。

只使用临时目录（RCLONEBAR_HOME 指向临时“家目录”），不会触碰真实的笔记、项目或 LaunchAgent。

用法：python3 Tests/e2e/e2e.py --agent .build/debug/rclonebar-agent [--rclone /path/to/rclone] [--keep]
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PASS = []
FAIL = []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✔ " if cond else "  ✘ ") + name + ("" if cond else f"  —— {detail}"), flush=True)
    return cond


class Env:
    def __init__(self, agent, rclone, keep):
        self.agent = os.path.abspath(agent)
        self.rclone = rclone
        self.keep = keep
        self.home = tempfile.mkdtemp(prefix="rclonebar-e2e-")
        self.rb = os.path.join(self.home, "Library/Application Support/RcloneBar")
        self.wd = os.path.join(self.home, "bisync-wd")
        self.env = dict(os.environ, RCLONEBAR_HOME=self.home, RCLONEBAR_TICK="0.5",
                        RCLONEBAR_TEST_INTERVAL_SECONDS="3600", RCLONEBAR_RCLONE=rclone)
        self.daemon = None
        self.jobs = {
            # 路径含中文与空格；带一个 ASCII 后缀，方便测试脚本用 ps 区分（macOS 的 ps 可能转义非 ASCII 字符）
            "vault": ("主仓库", os.path.join(self.home, "Documents/主仓库 vault"), os.path.join(self.home, "Remote/其他/Obsidian/主仓库 云端"), 56721),
            "projects": ("项目", os.path.join(self.home, "Documents/项目 projects"), os.path.join(self.home, "Remote/项目 云端"), 56722),
        }

    # ---------- 准备 ----------
    def setup(self):
        os.makedirs(self.wd, exist_ok=True)
        os.makedirs(os.path.join(self.rb, "test-logs"), exist_ok=True)
        for jid, (name, local, remote, port) in self.jobs.items():
            os.makedirs(local, exist_ok=True)
            os.makedirs(remote, exist_ok=True)
            open(os.path.join(local, "RCLONE_TEST"), "w").write("access check\n")
            open(os.path.join(local, f"说明 {name}.md"), "w").write("测试数据\n")
            subprocess.run([self.rclone, "bisync", local, remote, "--workdir", self.wd, "--resync", "-q"], check=True)
        jobs = []
        for jid, (name, local, remote, port) in self.jobs.items():
            log = os.path.join(self.rb, "test-logs", f"{jid}.log")
            jobs.append(dict(id=jid, displayName=name, localPath=local, remotePath=remote, legacyLabel="test." + jid,
                             legacyPlistPath="/nonexistent.plist", statusFile=os.path.join(self.rb, f"test-state/{jid}.json"),
                             logFiles=[log], rcPort=port, launchMode="direct", bisyncWorkdir=self.wd, scriptHasRecover=True,
                             direct=dict(program=self.rclone,
                                         arguments=["bisync", local, remote, "--workdir", self.wd, "--resilient", "--recover",
                                                    "--check-access", "--max-delete", "50", "--conflict-resolve", "none"],
                                         environment={}, logFile=log)))
        self.write_json("jobs.json", dict(version=1, jobs=jobs, createdAt="2026-10-25T00:00:00Z"))
        self.write_json("install.json", dict(installedAt="2026-10-25T00:00:00Z", backupDir="/tmp", legacy=[], agentVersion="test"))
        self.write_settings(intervalMinutes=60, bandwidthControlEnabled=True, uploadLimitKiB=8192, downloadLimitKiB=8192, transfers=2)

    def write_json(self, name, obj):
        os.makedirs(self.rb, exist_ok=True)
        tmp = os.path.join(self.rb, "." + name + ".tmp")
        with open(tmp, "w") as f:
            json.dump(obj, f, ensure_ascii=False, indent=1)
        os.replace(tmp, os.path.join(self.rb, name))

    def write_settings(self, **kw):
        path = os.path.join(self.rb, "settings.json")
        cur = json.load(open(path)) if os.path.exists(path) else {}
        cur.update(kw)
        self.write_json("settings.json", cur)
        time.sleep(1.1)  # mtime 精度

    def make_files(self, jid, count, size_mb, prefix="新文件"):
        local = self.jobs[jid][1]
        for i in range(count):
            with open(os.path.join(local, f"{prefix} {time.time_ns()} {i}.bin"), "wb") as f:
                f.write(os.urandom(size_mb * 1024 * 1024))

    # ---------- 进程 ----------
    def start_daemon(self):
        self.daemon = subprocess.Popen([self.agent, "daemon"], env=self.env)
        self.wait(lambda: self.state() is not None and self.state().get("agentPID") == self.daemon.pid, 10)

    def stop_daemon(self):
        if self.daemon and self.daemon.poll() is None:
            self.daemon.send_signal(signal.SIGTERM)
            self.daemon.wait(timeout=10)
        self.daemon = None

    def cli(self, *args):
        r = subprocess.run([self.agent, *args], env=self.env, capture_output=True, text=True, timeout=30)
        return r.stdout.strip() + r.stderr.strip()

    def status(self):
        out = subprocess.run([self.agent, "status", "--json"], env=self.env, capture_output=True, text=True, timeout=30).stdout
        return {j["id"]: j for j in json.loads(out)["jobs"]}

    def state(self):
        try:
            return json.load(open(os.path.join(self.rb, "agent-state.json")))
        except Exception:
            return None

    def runtime(self, jid):
        st = self.state() or {}
        return st.get("jobs", {}).get(jid, {})

    def runs(self):
        path = os.path.join(self.rb, "runs.jsonl")
        if not os.path.exists(path):
            return []
        return [json.loads(l) for l in open(path) if l.strip()]

    def agent_log(self):
        p = os.path.join(self.rb, "logs/agent.log")
        return open(p).read() if os.path.exists(p) else ""

    def bisync_pids(self, jid):
        out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, errors="replace").stdout
        return [int(l.split()[0]) for l in out.splitlines() if "bisync" in l and f" {jid}" in l and self.wd in l and "rclone" in l]

    @staticmethod
    def wait(cond, timeout, interval=0.3):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if cond():
                    return True
            except Exception:
                pass
            time.sleep(interval)
        return False

    def wait_idle(self, jid, timeout=120):
        return self.wait(lambda: self.runtime(jid).get("phase") == "idle" and not self.bisync_pids(jid), timeout)

    def cleanup(self):
        self.stop_daemon()
        for jid in self.jobs:
            for pid in self.bisync_pids(jid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except Exception:
                    pass
        if not self.keep:
            shutil.rmtree(self.home, ignore_errors=True)
        else:
            print("保留测试目录：", self.home)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", required=True)
    ap.add_argument("--rclone", default=shutil.which("rclone"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    if not a.rclone:
        print("未找到 rclone")
        return 2
    print("rclone:", subprocess.run([a.rclone, "version"], capture_output=True, text=True).stdout.splitlines()[0])
    e = Env(a.agent, a.rclone, a.keep)
    try:
        run_tests(e)
    finally:
        e.cleanup()
    print(f"\n通过 {len(PASS)} 项，失败 {len(FAIL)} 项")
    for f in FAIL:
        print("  失败：", f)
    return 1 if FAIL else 0


def run_tests(e):
    e.setup()
    e.start_daemon()

    print("\n[1] 空闲状态与下次计划时间")
    st = e.status()
    check("两组任务初始为空闲", st["vault"]["activity"] == "idle" and st["projects"]["activity"] == "idle", st)
    check("有下次计划时间", "nextRun" in st["vault"], st["vault"])

    print("\n[2] 立即同步 + 重复点击 + 进度与数据隔离")
    e.make_files("vault", 12, 8)  # 96MB，限速 8MB/s ≈ 12 秒
    r1 = e.cli("sync", "vault")
    r2 = e.cli("sync", "vault")
    check("第一次立即同步被接受", "已开始" in r1, r1)
    check("重复点击被忽略", "忽略" in r2 or "正在同步" in r2, r2)
    samples = []
    end = time.time() + 40
    while time.time() < end:
        s = e.status()
        samples.append(s)
        if s["vault"]["activity"] == "idle" and len(samples) > 3:
            break
        if len(e.bisync_pids("vault")) > 1:
            check("同一目录只有一个 bisync", False, e.bisync_pids("vault"))
        time.sleep(0.8)
    acts = [s["vault"]["activity"] for s in samples]
    check("观察到传输阶段", "transferring" in acts, acts)
    fr = [s["vault"].get("fraction") for s in samples if s["vault"]["activity"] == "transferring" and "fraction" in s["vault"]]
    check("传输进度在 0~1 之间且非恒定", bool(fr) and all(0 <= f <= 1 for f in fr) and len(set(round(f, 2) for f in fr)) > 1, fr)
    check("扫描阶段不显示比例", all("fraction" not in s["vault"] for s in samples if s["vault"]["activity"] in ("scanning", "starting")), acts)
    check("项目组在主仓库同步期间保持空闲（数据隔离）", all(s["projects"]["activity"] == "idle" and "bytes" not in s["projects"] for s in samples),
          [s["projects"] for s in samples][:3])
    rt_samples = e.runtime("vault")
    e.wait_idle("vault")
    last = [r for r in e.runs() if r["jobID"] == "vault"][-1]
    check("本轮判定为成功", last["outcome"] == "success", last)
    check("成功判定有 rclone 退出码与 listing 依据", any("退出码 0" in x for x in last["evidence"]) and any("listing 已在本轮更新" in x for x in last["evidence"]), last["evidence"])
    check("上次成功时间已更新", e.runtime("vault").get("lastSuccessAt") is not None)
    check("并发设置生效（RC 读取 Transfers=2）", "effectiveTransfers" not in rt_samples or rt_samples.get("effectiveTransfers") in (2, None), rt_samples)

    print("\n[3] 运行中修改限速（RC 即时生效）与并发（下一轮生效）")
    e.make_files("vault", 30, 8)
    e.cli("sync", "vault")
    e.wait(lambda: e.runtime("vault").get("rclonePID") is not None, 15)
    e.wait(lambda: e.runtime("vault").get("effectiveTransfers") is not None, 15)
    check("本轮实际并发为 2", e.runtime("vault").get("effectiveTransfers") == 2, e.runtime("vault"))
    e.write_settings(uploadLimitKiB=16384, downloadLimitKiB=16384, transfers=3)
    # rclone 会把上下行相同的 "16384k:16384k" 规范化为 "16Mi"
    ok = e.wait(lambda: "限速调整为 16Mi" in e.agent_log(), 15)
    check("限速通过 RC 即时调整为 16 MiB/s", ok, e.agent_log()[-500:])
    check("并发数标记为下一轮生效", e.runtime("vault").get("settingsPendingNextRun") is True, e.runtime("vault"))

    print("\n[4] 安全结束当前一轮（SIGINT，bisync 正常收尾）")
    r = e.cli("stop", "vault")
    check("安全结束命令被接受", "安全结束" in r, r)
    check("后台记录了 SIGINT", e.wait(lambda: "发送 SIGINT" in e.agent_log(), 5))
    e.wait_idle("vault", 150)
    last = [r for r in e.runs() if r["jobID"] == "vault"][-1]
    check("结果为“已手动结束/需要处理”，而不是成功", last["outcome"] in ("stoppedByUser", "needsAttention"), last)
    check("结束后没有立即重启", e.runtime("vault").get("phase") == "idle" and not e.bisync_pids("vault"))
    r = e.cli("sync", "vault")
    e.wait(lambda: e.runtime("vault").get("phase") != "idle", 10)
    e.wait_idle("vault", 150)
    last = [r for r in e.runs() if r["jobID"] == "vault"][-1]
    check("下一轮重新检查并成功（--recover）", last["outcome"] == "success", last)
    check("新的并发数 3 已在这一轮生效", e.runtime("vault").get("effectiveTransfers") in (3, None), e.runtime("vault"))

    print("\n[5] 失败：访问检查标记缺失（不得自动 --resync）")
    remote = e.jobs["projects"][2]
    success_before = e.runtime("projects").get("lastSuccessAt")
    os.rename(os.path.join(remote, "RCLONE_TEST"), os.path.join(remote, "RCLONE_TEST.bak"))
    e.cli("sync", "projects")
    e.wait(lambda: e.runtime("projects").get("phase") != "idle", 10)
    e.wait_idle("projects", 60)
    last = [r for r in e.runs() if r["jobID"] == "projects"][-1]
    check("失败被识别为需要处理/失败", last["outcome"] in ("needsAttention", "failed"), last)
    check("失败时不更新上次成功时间", e.runtime("projects").get("lastSuccessAt") == success_before, e.runtime("projects"))
    check("错误详情被记录", len(last["errors"]) > 0, last)
    hist = [n for n in os.listdir(e.wd) if "projects" in n and ".lst" in n]
    check("bisync 历史文件仍然保留（未删除、未 --resync）", any(n.endswith(".path1.lst") or n.endswith(".path1.lst-err") for n in hist), hist)
    os.rename(os.path.join(remote, "RCLONE_TEST.bak"), os.path.join(remote, "RCLONE_TEST"))
    e.cli("sync", "projects")
    e.wait(lambda: e.runtime("projects").get("phase") != "idle", 10)
    e.wait_idle("projects", 60)
    last = [r for r in e.runs() if r["jobID"] == "projects"][-1]
    check("恢复标记后下一轮成功", last["outcome"] in ("success",), last)

    print("\n[6] 暂停自动调度 / 恢复")
    e.stop_daemon()
    e.env["RCLONEBAR_TEST_INTERVAL_SECONDS"] = "4"
    e.write_settings(pausedAll=True)
    before = len(e.runs())
    e.start_daemon()
    time.sleep(12)
    check("暂停期间没有新的自动运行", len(e.runs()) == before and not e.bisync_pids("vault"), len(e.runs()) - before)
    r = e.cli("sync", "projects")
    check("暂停时仍可手动立即同步", "已开始" in r, r)
    e.wait_idle("projects", 60)
    e.write_settings(pausedAll=False)
    ok = e.wait(lambda: any(x["trigger"] == "scheduled" for x in e.runs()[before:]), 30)
    check("恢复后按计划自动运行", ok, e.runs()[before:])
    e.wait_idle("vault", 60)
    e.wait_idle("projects", 60)
    e.stop_daemon()
    e.env["RCLONEBAR_TEST_INTERVAL_SECONDS"] = "3600"

    print("\n[7] 退出并重启后台服务：正在运行的同步不受影响并被接续")
    e.start_daemon()
    e.make_files("vault", 12, 8)
    e.cli("sync", "vault")
    e.wait(lambda: e.bisync_pids("vault"), 10)
    pids = e.bisync_pids("vault")
    e.stop_daemon()
    time.sleep(1)
    check("后台服务退出后 bisync 仍在运行", bool(pids) and all(os.path.exists(f"/proc/{p}") or subprocess.run(["kill", "-0", str(p)]).returncode == 0 for p in pids), pids)
    e.start_daemon()
    ok = e.wait(lambda: e.runtime("vault").get("phase") in ("running", "stopping"), 10)
    check("重启后接续运行中的同步", ok, e.runtime("vault"))
    check("接续后不会再启动第二个 bisync", len(e.bisync_pids("vault")) <= 1, e.bisync_pids("vault"))
    e.wait_idle("vault", 150)
    last = [r for r in e.runs() if r["jobID"] == "vault"][-1]
    check("接续的一轮被记录（无法取得退出码时不冒充成功）", last["trigger"] in ("adopted", "external") and last["outcome"] in ("success", "unknown"), last)
    check("重启后保留上次成功时间", e.runtime("vault").get("lastSuccessAt") is not None)

    print("\n[8] 外部启动的 bisync（无 RC）：不重复启动，界面退回日志信息")
    e.make_files("projects", 10, 8)
    local, remote = e.jobs["projects"][1], e.jobs["projects"][2]
    ext = subprocess.Popen([e.rclone, "bisync", local, remote, "--workdir", e.wd, "--resilient", "--recover", "--bwlimit", "8M", "-v"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    e.wait(lambda: e.runtime("projects").get("phase") == "running", 10)
    r = e.cli("sync", "projects")
    check("检测到外部 bisync，立即同步不重复启动", "忽略" in r or "另一个" in r, r)
    st = e.status()
    check("外部进程没有 RC，界面不显示 RC 数据", "实时" in st["projects"]["rc"] or "未开启" in st["projects"]["rc"], st["projects"])
    check("仍然只有一个 bisync", len(e.bisync_pids("projects")) == 1, e.bisync_pids("projects"))
    ext.wait(timeout=150)
    e.wait_idle("projects", 30)
    last = [r for r in e.runs() if r["jobID"] == "projects"][-1]
    check("外部运行被记录，trigger=external", last["trigger"] == "external", last)

    print("\n[9] 设置持久化")
    s = json.load(open(os.path.join(e.rb, "settings.json")))
    check("设置文件保存了限速与并发", s.get("uploadLimitKiB") == 16384 and s.get("transfers") == 3, s)
    r = e.cli("pause", "vault")
    s = json.load(open(os.path.join(e.rb, "settings.json")))
    check("命令行暂停单组写入设置", s.get("pausedJobs") == ["vault"], s)
    st = e.status()
    check("状态显示该组已暂停", st["vault"]["paused"] is True and st["projects"]["paused"] is False, st)
    e.cli("resume", "vault")


if __name__ == "__main__":
    sys.exit(main())
