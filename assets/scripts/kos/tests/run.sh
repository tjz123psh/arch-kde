#!/usr/bin/env bash
# 描述：KOS 更新器的回归测试套件（隔离环境，不碰真实源码检出 / 安装 / 系统服务）
# Description: Regression suite for the KOS updater; runs in throwaway dirs.
#
# 用法：bash ~/scripts/kos/tests/run.sh [-v]
# 退出码：0 全部通过；1 有失败；127 缺依赖

set -uo pipefail

SUITE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SUITE_DIR/../update.sh"
VERBOSE=${1:-}

PASS=0
FAIL=0
FAILED_NAMES=()
WORK=""

if [[ ! -x "$SCRIPT" ]]; then
  printf '错误: 找不到可执行脚本 %s\n' "$SCRIPT" >&2
  exit 127
fi
for dep in git python3 desktop-file-validate; do
  command -v "$dep" >/dev/null 2>&1 || { printf '错误: 缺少依赖 %s\n' "$dep" >&2; exit 127; }
done

# shellcheck disable=SC2329  # 由 trap 间接调用
cleanup() {
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf -- "$WORK"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  printf '  ✗ %s — %s\n' "$1" "${2:-}"
  [[ -n "$VERBOSE" ]] && printf '%s\n' "${3:-}"
}

# 每个用例一个干净的临时世界：state / prefix / 假仓库
new_world() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/state" "$WORK/prefix/share/kos" "$WORK/repo/tools"
  printf '{"version":"%s","revision":"deadbeef","tag":"","dirty":false}\n' "${1:-0.1.1}" \
    > "$WORK/prefix/share/kos/release.json"
}

fake_repo() {
  local repo="$WORK/repo"
  printf '0.1.1\n' > "$repo/VERSION"
  printf 'a\nb\nc\n' > "$repo/a.txt"
  cat > "$repo/tools/kosctl" <<'STUB'
#!/usr/bin/env bash
# 假 kosctl：update 只切 HEAD，其余打印 ok
case "$1" in
  update) git -C "$(dirname "$0")/.." checkout -q HEAD~1 2>/dev/null || true; echo "Selected fake"; exit 0 ;;
  shortcuts) echo "Usage: kos-platform daemon" >&2; exit 2 ;;
  *) echo "ok $*"; exit 0 ;;
esac
STUB
  chmod +x "$repo/tools/kosctl"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm base
  printf 'b-changed\n' > /dev/null
  printf 'a\nb2\nc\n' > "$repo/a.txt"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qam change
}

make_dirty() { printf 'a\nb-patched\nc\n' > "$WORK/repo/a.txt"; }

kh() { # kh <args...> —— 在隔离世界里跑更新器
  XDG_STATE_HOME="$WORK/state" KOS_PREFIX="$WORK/prefix" KOS_REPO_DIR="$WORK/repo" \
    KOS_GIT_TIMEOUT=2 KOS_SRC_URL="${KOS_SRC_URL_OVERRIDE:-https://127.0.0.1:1/x.git}" \
    "$SCRIPT" "$@"
}

head_sha() { git -C "$WORK/repo" rev-parse HEAD 2>/dev/null; }
worktree_dirty() { git -C "$WORK/repo" status --porcelain 2>/dev/null; }

expect_rc() { # expect_rc <want> <got> <name> [out]
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3" "期望 rc=$1 实际 rc=$2" "${4:-}"; fi
}

expect_contains() { # expect_contains <haystack> <needle> <name>
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else bad "$3" "输出里没有：$2" "$1"; fi
}

# ── 1. 帮助与错误用法 ───────────────────────────────────────────
printf '\n[1] 用法与参数\n'
new_world; fake_repo
out=$("$SCRIPT" --help 2>&1); expect_rc 0 $? "help 退出码 0"
expect_contains "$out" '--hold' 'help 列出 --hold'
expect_contains "$out" '--json' 'help 列出 --json'
"$SCRIPT" bogus >/dev/null 2>&1; expect_rc 2 $? "未知命令 退出 2"
"$SCRIPT" status extra >/dev/null 2>&1; expect_rc 2 $? "多余参数 退出 2"
"$SCRIPT" --bogus >/dev/null 2>&1; expect_rc 2 $? "未知选项 退出 2"
out=$(kh -n status 2>&1); expect_rc 0 $? "选项写在子命令前（-n status）"
expect_contains "$out" 'KOS 桌面' '-n status 真的执行了 status'

# ── 2. status / JSON ──────────────────────────────────────────
printf '\n[2] status 与 JSON 契约\n'
out=$(kh status 2>&1); expect_rc 0 $? "status 退出码 0"
expect_contains "$out" '已装' 'status 显示已装版本'
json=$(kh status --json 2>/dev/null); rc=$?
expect_rc 0 "$rc" "status --json 退出码 0"
shape=$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
need={"installed","source","latest","updateAvailable","checked","dev","patches","apps","lockscreen","log"}
missing=need-set(d)
print("missing:"+",".join(sorted(missing)) if missing else "ok")
print("lines:%d" % len(sys.stdin.read().splitlines()))
' 2>&1)
expect_contains "$shape" 'ok' 'JSON 字段齐全（含 dev）'
if [[ $(printf '%s' "$json" | wc -l) -eq 0 ]]; then ok "JSON 是单行"; else bad "JSON 是单行" "存在换行"; fi
# dev 版判定：把 release.json 改成 *-dev，updateAvailable 必须为 false
printf '{"version":"0.1.0-dev","revision":"deadbeef","tag":"","dirty":false}\n' \
  > "$WORK/prefix/share/kos/release.json"
json=$(kh status --json 2>/dev/null)
dev=$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["dev"],d["updateAvailable"])' 2>&1)
expect_contains "$dev" 'True None' 'dev 且无缓存时 updateAvailable 为 null'

# ── 3. 缺源码 / 离线降级 ──────────────────────────────────────
printf '\n[3] 降级路径\n'
new_world 0.1.1; fake_repo
out=$(XDG_STATE_HOME="$WORK/state" KOS_PREFIX="$WORK/prefix" KOS_REPO_DIR=/nonexistent "$SCRIPT" status 2>&1)
expect_rc 0 $? "缺源码检出时 status 仍可用"
expect_contains "$out" '缺失' '状态卡标注源码缺失'
XDG_STATE_HOME="$WORK/state" KOS_PREFIX="$WORK/prefix" KOS_REPO_DIR=/nonexistent \
  "$SCRIPT" check --notify --quiet >/dev/null 2>&1
expect_rc 0 $? "离线 + --notify 按 0 退出（不把 timer 标 failed）"
kh check >/dev/null 2>&1
expect_rc 1 $? "离线且无 --notify 时 check 报错 1"
"$SCRIPT" menu </dev/null >/dev/null 2>&1
expect_rc 1 $? "非 TTY 菜单被拒绝"

# ── 4. dry-run 与补丁状态机 ───────────────────────────────────
printf '\n[4] 补丁与 dry-run\n'
new_world; fake_repo
make_dirty
before=$(head_sha); dirty_before=$(worktree_dirty)
out=$(kh update -n -y main 2>&1); expect_rc 0 $? "update -n -y main 退出码 0"
expect_contains "$out" '计划' 'dry-run 打印计划'
expect_contains "$out" '6/6' 'dry-run 走完全部阶段'
if [[ "$(head_sha)" == "$before" ]]; then ok "dry-run 未切换源码"; else bad "dry-run 未切换源码" "HEAD 变了"; fi
if [[ "$(worktree_dirty)" == "$dirty_before" ]]; then ok "dry-run 未改动工作区"; else bad "dry-run 未改动工作区" "$(worktree_dirty)"; fi
if ! find "$WORK/state/kos/local-patches" -name "*.patch" -print -quit 2>/dev/null | grep -q .; then ok "dry-run 未导出补丁"; else bad "dry-run 未导出补丁" "补丁目录非空"; fi
head_before=$(head_sha); dirty_before=$(worktree_dirty)
out=$(kh patch drop -n 2>&1)
expect_contains "$out" 'dry-run' 'patch drop -n 只打印计划'
if [[ "$(head_sha)" == "$head_before" && "$(worktree_dirty)" == "$dirty_before" ]]; then
  ok "patch drop -n 保持原样"
else
  bad "patch drop -n 保持原样" "工作区/HEAD 被改动"
fi

# 真实补丁流程：make dirty → save → clean → apply
make_dirty
kh patch save >/dev/null 2>&1; expect_rc 0 $? "patch save 退出码 0"
n=$(find "$WORK/state/kos/local-patches" -name "*.patch" 2>/dev/null | wc -l)
if [[ "$n" -eq 1 ]]; then ok "patch save 产出 1 个补丁文件"; else bad "patch save 产出 1 个补丁文件" "实际 $n"; fi
out=$(kh patch apply 2>&1); expect_rc 0 $? "patch apply 退出码 0"
expect_contains "$out" '已在位' '重复 apply 识别为已在位'

# 冲突：补丁上下文对不上时不许半应用
new_world; fake_repo
mkdir -p "$WORK/state/kos/local-patches"
cat > "$WORK/state/kos/local-patches/conflict.patch" <<'PATCH'
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 a
-nonexistent-line
+something-else
 c
PATCH
head_before=$(head_sha)
out=$(kh patch apply 2>&1); rc=$?
expect_rc 1 "$rc" "补丁冲突返回 1"
expect_contains "$out" '未做任何修改' '冲突时说明未改动工作区'
if [[ -z "$(worktree_dirty)" ]]; then ok "冲突后工作区仍然干净"; else bad "冲突后工作区仍然干净" "$(worktree_dirty)"; fi
if find "$WORK/repo" -name "*.rej" | grep -q .; then bad "冲突后仓库无 .rej" "留下了 .rej"; else ok "冲突后仓库无 .rej"; fi

# dry-run 之后 update.lock 必须可再次获取（release_lock 生效）
new_world; fake_repo
kh update -n -y main >/dev/null 2>&1
if flock -n "$WORK/state/kos/update.lock" true 2>/dev/null; then ok "update.lock 用后已释放"; else bad "update.lock 用后已释放" "锁仍被占"; fi

# 同一进程内两次 acquire_lock 必须都能成功（曾因每次新开 fd 而第二次必失败）
lock_probe=$(WORK="$WORK" SCRIPT="$SCRIPT" bash -c '
set -uo pipefail
STATE_DIR="$WORK/state/kos"; LOCK_FILE="$STATE_DIR/update.lock"; LOCK_FD=-1
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "DIE:$*"; exit 1; }
die_missing() { echo "MISSING:$*"; exit 1; }
eval "$(sed -n "/^acquire_lock() {/,/^}/p" "$SCRIPT")"
eval "$(sed -n "/^release_lock() {/,/^}/p" "$SCRIPT")"
mkdir -p "$STATE_DIR"
acquire_lock && echo first-ok
acquire_lock && echo second-ok
release_lock
acquire_lock && echo third-ok
release_lock
' 2>&1)
expect_contains "$lock_probe" 'first-ok' "锁可获取"
expect_contains "$lock_probe" 'second-ok' "同进程二次获取不被自己的锁挡住"
expect_contains "$lock_probe" 'third-ok' "释放后可再次获取"

# 预览在无缓存时也必须零网络零写盘（曾因守卫位置写错而联网+写盘）
rm -f "$WORK/state/kos/main-head"
t0=$(date +%s%N)
out=$(XDG_STATE_HOME="$WORK/state" KOS_PREFIX="$WORK/prefix" KOS_REPO_DIR="$WORK/repo" \
  KOS_SRC_URL=https://127.0.0.1:1/x.git KOS_GIT_TIMEOUT=3 "$SCRIPT" __preview main 2>&1)
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
if (( ms < 1500 )); then ok "preview main 不联网（${ms}ms）"; else bad "preview main 不联网" "耗时 ${ms}ms"; fi
if [[ ! -s "$WORK/state/kos/main-head" ]]; then ok "preview main 不写缓存"; else bad "preview main 不写缓存" "main-head 被写"; fi

# 补丁归属：导出时写基线，基线不符时跳过而不是盲打
new_world; fake_repo
make_dirty
kh patch save >/dev/null 2>&1
pf=$(find "$WORK/state/kos/local-patches" -maxdepth 1 -name '*.patch' | head -n1)
if head -n1 "$pf" | grep -q '^# kos-source: '; then ok "补丁写入基线头"; else bad "补丁写入基线头" "首行: $(head -n1 "$pf")"; fi
# 造一个基线不匹配的补丁：应跳过且不改工作区
rm -f "$WORK/state/kos/local-patches"/*.patch
cat > "$WORK/state/kos/local-patches/foreign.patch" <<'PATCH'
# kos-source: main@0000000
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 a
-b
+B
 c
PATCH
dirty_before=$(worktree_dirty)
out=$(kh patch apply 2>&1); rc=$?
expect_rc 1 "$rc" "基线不符的补丁被跳过（返回 1）"
expect_contains "$out" '跳过补丁' '提示跳过原因'
if [[ "$(worktree_dirty)" == "$dirty_before" ]]; then ok "被跳过的补丁未改动工作区"; else bad "被跳过的补丁未改动工作区" "$(worktree_dirty)"; fi

# ── 4b. main 追踪（dev 版） ───────────────────────────────────
printf '\n[4b] main 追踪\n'
new_world 0.1.0-dev; fake_repo
mkdir -p "$WORK/state/kos"
# 造一个"上游 main 已前进"的缓存（sha 与已部署 revision 不同）
printf 'aaaabbbbccccdddd|2026-10-29|feat: fake upstream commit\n' > "$WORK/state/kos/main-head"
out=$(kh status 2>&1)
expect_contains "$out" '有新提交' 'status 显示 main 有新提交'
expect_contains "$out" 'update main' 'status 给出重建命令'
json=$(kh status --json 2>/dev/null)
val=$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["main"]["behind"],d["updateAvailable"])' 2>&1)
expect_contains "$val" 'True True' 'status --json 里 main.behind/updateAvailable 为 true'
# 一致时不该报可更新
printf 'deadbeef|2026-10-28|same\n' > "$WORK/state/kos/main-head"
json=$(kh status --json 2>/dev/null)
val=$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["main"]["behind"],d["updateAvailable"])' 2>&1)
expect_contains "$val" 'False False' '已部署与上游一致时不报可更新'
# 过期缓存：文本标"未核对"，JSON 里 behind/updateAvailable 必须是 null
printf 'aaaabbbbccccdddd|2026-10-29|new\n' > "$WORK/state/kos/main-head"
touch -d '3 hours ago' "$WORK/state/kos/main-head"
out=$(kh status 2>&1); plain=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
expect_contains "$plain" '未核对' '过期缓存时状态卡标注未核对'
json=$(kh status --json 2>/dev/null)
val=$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["main"]["stale"],d["main"]["behind"],d["updateAvailable"])' 2>&1)
expect_contains "$val" 'True None None' '过期缓存时 JSON 给 stale=true / behind=null'
touch "$WORK/state/kos/main-head"

# 菜单顶部状态（dev 版必须按 main 判定，不能再报"可更新 v0.1.1"）
printf 'deadbeef|2026-10-28|same\n' > "$WORK/state/kos/main-head"
out=$(kh __header 2>&1); plain=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
expect_contains "$plain" 'main 一致' 'header 在 main 一致时显示一致'
printf 'aaaabbbbccccdddd|2026-10-30|feat: x\n' > "$WORK/state/kos/main-head"
out=$(kh __header 2>&1); plain=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
expect_contains "$plain" 'main 有新提交' 'header 在 main 前进时提示重建'
if [[ "$plain" == *'可更新 v'* ]]; then bad "header 不再误报正式 tag" "仍显示可更新"; else ok "header 不再误报正式 tag"; fi

# ── 5. 通知与定时契约 ────────────────────────────────────────
printf '\n[5] 通知与 unit 契约\n'
new_world; fake_repo
unit_files=("$HOME/.config/systemd/user/kos-update-check.service" "$HOME/.config/systemd/user/kos-update-check.timer")
if systemd-analyze verify "${unit_files[@]}" >/dev/null 2>&1; then ok "systemd 单元校验通过"; else bad "systemd 单元校验通过" "systemd-analyze verify 失败"; fi
if systemctl --user is-enabled kos-update-check.timer >/dev/null 2>&1; then ok "timer 已启用"; else bad "timer 已启用" "未 enable"; fi
ses=$(systemctl --user show kos-update-check.service -p SuccessExitStatus --value 2>/dev/null)
if [[ " $ses " == *" 0 "* ]]; then ok "SuccessExitStatus 精确含 0"; else bad "SuccessExitStatus 精确含 0" "实际: $ses"; fi
if [[ " $ses " == *" 10 "* ]]; then ok "SuccessExitStatus 精确含 10"; else bad "SuccessExitStatus 精确含 10" "实际: $ses"; fi
cal=$(systemctl --user show kos-update-check.timer -p NextElapseUSecRealtime --value 2>/dev/null)
if [[ -n "$cal" ]]; then ok "timer 有下次触发时间"; else bad "timer 有下次触发时间" "空"; fi

# 桌面启动器
desk="$HOME/.local/share/applications/kos-update.desktop"
if desktop-file-validate "$desk" >/dev/null 2>&1; then ok "启动器 desktop 校验通过"; else bad "启动器 desktop 校验通过" "desktop-file-validate 失败"; fi
if grep -q -- "--hold" "$desk"; then ok "启动器带 --hold"; else bad "启动器带 --hold" "缺 --hold"; fi
if grep -q "Exec=kitty" "$desk"; then ok "启动器用 kitty 启动"; else bad "启动器用 kitty 启动" "Exec 异常"; fi

# 软链入口
if [[ -L "$HOME/bin/kos" ]]; then
  out=$("$HOME/bin/kos" --help 2>&1)
  expect_contains "$out" 'kos [命令]' 'kos 软链显示正确调用名'
else
  bad "kos 软链存在" "$HOME/bin/kos 不是软链"
fi

# ── 6. 交互会话（pty） ───────────────────────────────────────
printf '\n[6] 交互会话（pty）\n'
new_world; fake_repo
pty_result=$(XDG_STATE_HOME="$WORK/state" KOS_PREFIX="$WORK/prefix" KOS_REPO_DIR="$WORK/repo" \
  KOS_SRC_URL=https://127.0.0.1:1/x.git KOS_GIT_TIMEOUT=2 python3 - "$SCRIPT" <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time
script = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
    os.execvp('bash', ['bash', '-c', f'exec "{script}" --hold check'])
buf = b''
start = time.time()
exited = False
while time.time() - start < 6:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            exited = True
            break
        if not chunk:
            exited = True
            break
        buf += chunk
alive = not exited
if alive:
    os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
text = buf.decode('utf-8', 'replace')
print('ALIVE' if alive else 'EXITED', 'PROMPT' if '按任意键关闭窗口' in text else 'NOPROMPT')
PY
)
expect_contains "$pty_result" 'ALIVE' "--hold 在出错路径上停住（不秒关窗口）"
expect_contains "$pty_result" 'PROMPT' "--hold 打印按任意键提示"

# 菜单退出后不残留
menu_result=$(XDG_STATE_HOME="$WORK/state" KOS_PREFIX="$WORK/prefix" KOS_REPO_DIR="$WORK/repo" \
  python3 - "$SCRIPT" <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time
script = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
    os.execvp('bash', ['bash', '-c', f'printf "PRIOR\\n"; exec "{script}"'])
buf = b''
start = time.time()
sent = False
exited = False
while time.time() - start < 8:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            exited = True
            break
        if not chunk:
            exited = True
            break
        buf += chunk
    if not sent and time.time() - start > 2:
        os.write(fd, b'\x1b')
        sent = True
    if sent and time.time() - start > 4:
        break
if not exited:
    os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
text = buf.decode('utf-8', 'replace')
h, l = text.count('\x1b[?1049h'), text.count('\x1b[?1049l')
print('BALANCED' if h == l and h > 0 else f'UNBALANCED {h}/{l}', 'RECEIPT' if 'KOS 更新器' in text else 'NORECEIPT')
PY
)
expect_contains "$menu_result" 'BALANCED' "菜单退出后备用屏配平"
expect_contains "$menu_result" 'RECEIPT' "退出后打印收据"

# 单实例：第二个菜单必须立刻退出并给出提示
dup_result=$(XDG_STATE_HOME="$WORK/state" KOS_PREFIX="$WORK/prefix" KOS_REPO_DIR="$WORK/repo" \
  python3 - "$SCRIPT" <<'PY2'
import fcntl, os, pty, select, signal, struct, sys, termios, time
script = sys.argv[1]
def spawn(cmd):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
        os.execvp('bash', ['bash', '-c', cmd])
    return pid, fd
p1, f1 = spawn(f'exec "{script}" --hold')
time.sleep(2.0)
p2, f2 = spawn(f'exec "{script}" --hold')
buf = b''
start = time.time()
exited = False
while time.time() - start < 5:
    r, _, _ = select.select([f2], [], [], 0.05)
    if r:
        try:
            chunk = os.read(f2, 65536)
        except OSError:
            exited = True
            break
        if not chunk:
            exited = True
            break
        buf += chunk
text = buf.decode('utf-8', 'replace')
print('EXITED' if exited else 'ALIVE', 'HINT' if '已有一个更新窗口在运行' in text else 'NOHINT')
for pid, _ in ((p1, f1), (p2, f2)):
    try: os.kill(pid, signal.SIGKILL)
    except OSError: pass
    os.waitpid(pid, 0)
PY2
)
expect_contains "$dup_result" 'EXITED' "重复启动时第二个实例立即退出"
expect_contains "$dup_result" 'HINT' "重复启动时提示已有一个窗口"

# ── 汇总 ─────────────────────────────────────────────────────
printf '\n──────────────\n通过 %d，失败 %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '失败用例：\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
