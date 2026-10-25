#!/usr/bin/env python3
"""
launchd 接管流程集成测试（仅在 CI 的 macOS 上运行）。

模拟现有环境：临时家目录里有 sync.py 与两个带 StartInterval 的 LaunchAgent（使用随机的测试标签），
然后执行 `rclonebar-agent install` → 立即同步 → 安全结束 → `uninstall`，检查：
  - 原 LaunchAgent 改为按需执行、注入 RC，并由后台服务 kickstart；
  - 通过 RC 读到实时统计，且进程 pid 与本组一致；
  - 成功判定依据脚本退出码 + bisync listing；
  - SIGINT 只发给 rclone，结果记为“已手动结束”；
  - 回退后 plist 与原始文件逐字节一致。

为避免误伤真实环境，只有在 GITHUB_ACTIONS=true 时才会运行。
"""
import json
import os
import plistlib
import random
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("GITHUB_ACTIONS") != "true":
    print("跳过：只在 CI 中运行（会使用 launchctl）")
    sys.exit(0)

AGENT = os.path.abspath(sys.argv[1])
RCLONE = shutil.which("rclone")
UID = os.getuid()
if subprocess.run(["launchctl", "print", f"gui/{UID}"], capture_output=True).returncode != 0:
    print(f"跳过：没有 gui/{UID} 域")
    sys.exit(0)

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✔ " if cond else "  ✘ ") + name + ("" if cond else f"  —— {detail}"), flush=True)


def wait(cond, timeout, interval=0.5):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if cond():
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False


tag = f"test.rclonebar.{random.randint(10000, 99999)}"
home = tempfile.mkdtemp(prefix="rclonebar-launchd-")
legacy = os.path.join(home, "Library/Application Support/rclone-bisync")
rb = os.path.join(home, "Library/Application Support/RcloneBar")
la = os.path.join(home, "Library/LaunchAgents")
wd = os.path.join(home, "bisync-wd")
for d in [legacy + "/logs", legacy + "/state/vault", legacy + "/state/projects", rb, la, wd]:
    os.makedirs(d, exist_ok=True)
env = dict(os.environ, RCLONEBAR_HOME=home, RCLONEBAR_AGENT_LABEL=f"{tag}.agent", RCLONEBAR_RCLONE=RCLONE, RCLONEBAR_TICK="0.5")

jobs = {
    "vault": ("主仓库", os.path.join(home, "Documents/主仓库"), os.path.join(home, "Remote/其他/Obsidian/主仓库"), 57721),
    "projects": ("项目", os.path.join(home, "Documents/项目"), os.path.join(home, "Remote/项目"), 57722),
}

# 模拟用户现有的 sync.py：参数数组调用 rclone，继承环境，写状态文件与日志
sync_py = os.path.join(legacy, "sync.py")
open(sync_py, "w").write(f'''
import json, subprocess, sys, datetime, os
JOBS = {json.dumps({k: [v[1], v[2]] for k, v in jobs.items()}, ensure_ascii=False)}
job = sys.argv[1]
local, remote = JOBS[job]
base = {json.dumps(legacy)}
log = os.path.join(base, "logs", job + ".log")
cmd = [{json.dumps(RCLONE)}, "bisync", local, remote, "--workdir", {json.dumps(wd)}, "--resilient", "--recover",
       "--check-access", "--max-delete", "50", "--log-file", log, "-v", "--local-no-clone"]
started = datetime.datetime.now().astimezone().isoformat()
r = subprocess.run(cmd)
st = {{"state": "success" if r.returncode == 0 else "failed", "last_run": started, "exit_code": r.returncode}}
if r.returncode == 0:
    st["last_success"] = datetime.datetime.now().astimezone().isoformat()
json.dump(st, open(os.path.join(base, "state", job, "status.json"), "w"))
sys.exit(r.returncode)
''')

labels = {k: f"{tag}.{k}" for k in jobs}
plists = {}
for jid, (name, local, remote, port) in jobs.items():
    os.makedirs(local, exist_ok=True)
    os.makedirs(remote, exist_ok=True)
    open(os.path.join(local, "RCLONE_TEST"), "w").write("x")
    open(os.path.join(local, "说明.md"), "w").write("测试\n")
    subprocess.run([RCLONE, "bisync", local, remote, "--workdir", wd, "--resync", "-q", "--local-no-clone"], check=True)
    p = os.path.join(la, f"{labels[jid]}.plist")
    plistlib.dump({"Label": labels[jid], "ProgramArguments": [sys.executable, sync_py, jid], "StartInterval": 3600,
                   "RunAtLoad": False, "StandardOutPath": os.path.join(legacy, f"logs/{jid}.launchd.log"),
                   "StandardErrorPath": os.path.join(legacy, f"logs/{jid}.launchd.log"),
                   "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"}}, open(p, "wb"))
    plists[jid] = p
    subprocess.run(["launchctl", "bootstrap", f"gui/{UID}", p], check=True)
originals = {k: open(v, "rb").read() for k, v in plists.items()}

job_defs = []
for jid, (name, local, remote, port) in jobs.items():
    job_defs.append(dict(id=jid, displayName=name, localPath=local, remotePath=remote, legacyLabel=labels[jid],
                         legacyPlistPath=plists[jid], statusFile=os.path.join(legacy, f"state/{jid}/status.json"),
                         logFiles=[os.path.join(legacy, f"logs/{jid}.log")], rcPort=port, launchMode="launchd"))
json.dump(dict(version=1, jobs=job_defs, createdAt="2026-10-25T00:00:00Z"), open(os.path.join(rb, "jobs.json"), "w"), ensure_ascii=False)


def cli(*a):
    r = subprocess.run([AGENT, *a], env=env, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def runtime(j):
    try:
        return json.load(open(os.path.join(rb, "agent-state.json")))["jobs"][j]
    except Exception:
        return {}


def runs():
    p = os.path.join(rb, "runs.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def status():
    return {j["id"]: j for j in json.loads(cli("status", "--json")[1])["jobs"]}


try:
    print("\n[1] 接入检查与接管")
    code, out = cli("inspect")
    check("接入检查可运行", code == 0 and "主仓库" in out, out[-800:])
    code, out = cli("install")
    print(out)
    check("接管成功", code == 0, out)
    p = plistlib.load(open(plists["vault"], "rb"))
    check("原 LaunchAgent 去掉了 StartInterval", "StartInterval" not in p, p)
    check("注入了 RC 地址与 htpasswd（无明文口令）", p["EnvironmentVariables"].get("RCLONE_RC_ADDR") == "127.0.0.1:57721"
          and "RCLONE_RC_PASS" not in p["EnvironmentVariables"], p["EnvironmentVariables"])
    info = subprocess.run(["launchctl", "print", f"gui/{UID}/{labels['vault']}"], capture_output=True, text=True).stdout
    check("原 LaunchAgent 仍已加载（按需执行）", "state = " in info, info[:300])
    check("后台服务已运行", wait(lambda: subprocess.run(["launchctl", "print", f"gui/{UID}/{tag}.agent"], capture_output=True, text=True).stdout.count("state = running") > 0, 15))
    check("后台服务写出状态", wait(lambda: runtime("vault") != {}, 15))

    print("\n[2] 立即同步（launchctl kickstart → sync.py → rclone）")
    for i in range(20):
        open(os.path.join(jobs["vault"][1], f"大文件 {i}.bin"), "wb").write(os.urandom(6 * 1024 * 1024))
    s = json.load(open(os.path.join(rb, "settings.json")))
    s.update(bandwidthControlEnabled=True, uploadLimitKiB=10240, downloadLimitKiB=10240)
    json.dump(s, open(os.path.join(rb, "settings.json"), "w"))
    time.sleep(2)
    code, out = cli("sync", "vault")
    check("立即同步被接受", "已开始" in out, out)
    connected = wait(lambda: status()["vault"]["rc"] == "实时数据已连接", 30)
    check("RC 实时数据已连接（pid 校验通过）", connected, status()["vault"])
    st = status()
    check("项目组保持空闲", st["projects"]["activity"] == "idle", st["projects"])
    wait(lambda: runtime("vault").get("phase") == "idle", 120)
    last = [r for r in runs() if r["jobID"] == "vault"][-1]
    check("结果成功（脚本退出码 + listing）", last["outcome"] == "success" and any("执行脚本" in e for e in last["evidence"]), last)
    check("RC 已开启", last["rcEnabled"] is True, last)

    print("\n[3] 安全结束（SIGINT 只发给 rclone 子进程）")
    for i in range(30):
        open(os.path.join(jobs["vault"][1], f"再来 {i}.bin"), "wb").write(os.urandom(6 * 1024 * 1024))
    cli("sync", "vault")
    wait(lambda: runtime("vault").get("rclonePID") is not None, 30)
    time.sleep(2)
    code, out = cli("stop", "vault")
    check("安全结束被接受", "安全结束" in out, out)
    wait(lambda: runtime("vault").get("phase") == "idle", 150)
    last = [r for r in runs() if r["jobID"] == "vault"][-1]
    check("结果不是成功", last["outcome"] in ("stoppedByUser", "needsAttention"), last)

    print("\n[4] 回退")
    code, out = cli("uninstall")
    print(out)
    check("回退成功", code == 0, out)
    check("plist 恢复为原始内容", all(open(plists[k], "rb").read() == originals[k] for k in plists))
    check("后台服务已移除", subprocess.run(["launchctl", "print", f"gui/{UID}/{tag}.agent"], capture_output=True).returncode != 0)
finally:
    for l in list(labels.values()) + [f"{tag}.agent"]:
        subprocess.run(["launchctl", "bootout", f"gui/{UID}/{l}"], capture_output=True)
    shutil.rmtree(home, ignore_errors=True)

print(f"\n通过 {len(PASS)} 项，失败 {len(FAIL)} 项")
for f in FAIL:
    print("  失败：", f)
sys.exit(1 if FAIL else 0)
