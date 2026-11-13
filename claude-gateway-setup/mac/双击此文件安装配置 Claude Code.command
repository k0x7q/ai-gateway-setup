#!/bin/bash
# Double-click in Finder. Keep the whole extracted package together.
# Clear only the visible display, not scrollback or the user's shell history.
if [ -t 0 ] && [ -t 1 ]; then
  printf '\033[2J\033[H'
fi
finish() {
  local setup_exit="$1"
  if [ -t 0 ] && [ -t 1 ]; then
    printf '\n流程已结束，可以关闭此终端窗口。\n'
    # Keep the outer login shell from printing its exit/session-saving chatter.
    # Enter leaves the result visible; closing the window ends this wait.
    while IFS= read -r unused; do :; done
  fi
  exit "$setup_exit"
}
entry_failure() {
  local diagnostic
  diagnostic="错误编号：MAC_ENTRY
阶段：preflight
原因：$1
软件安装：未开始
配置保存：未修改
PATH：未修改"
  printf '%s\n' "$diagnostic" >&2
  # Startup diagnostics are fixed labels, never credentials or configuration bodies.
  /usr/bin/osascript - "$diagnostic" >/dev/null 2>/dev/null <<'APPLESCRIPT'
on run argv
  set diagnosticText to item 1 of argv
  set chosen to button returned of (display dialog diagnosticText buttons {"关闭", "复制诊断信息"} default button "关闭" with title "Claude Code 配置未完成")
  if chosen is "复制诊断信息" then set the clipboard to diagnosticText
end run
APPLESCRIPT
  if [ "$?" -ne 0 ]; then
    printf '系统诊断窗口未能显示；请复制上面的诊断信息。\n' >&2
  fi
  finish 1
}
ENTRY_DIR="$(/usr/bin/dirname "$0")"
dir_status=$?
if [ "$dir_status" -ne 0 ] || [ -z "$ENTRY_DIR" ]; then
  entry_failure "无法识别入口所在目录（退出码 $dir_status）。请完整解压后重试。"
fi
BASE="$(cd "$ENTRY_DIR" && pwd -P)"
base_status=$?
if [ "$base_status" -ne 0 ] || [ -z "$BASE" ]; then
  entry_failure "无法定位入口所在目录（退出码 $base_status）。请完整解压后重试。"
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
if [ ! -x /usr/bin/ruby ]; then
  entry_failure '此 macOS 缺少可执行的系统 Ruby。'
fi
if [ ! -f "$BASE/辅助文件/setup.rb" ] || [ -L "$BASE/辅助文件/setup.rb" ]; then
  entry_failure '辅助文件 setup.rb 不可用，请完整解压后重试。'
fi
/usr/bin/ruby "$BASE/辅助文件/setup.rb"
finish "$?"
