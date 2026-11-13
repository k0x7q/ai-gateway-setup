#!/bin/bash
# Double-click in Finder. No packages are downloaded or installed.
show_boot_error() {
  local text="$1"
  if [ -x /usr/bin/osascript ]; then
    /usr/bin/osascript - "$text" <<'APPLESCRIPT'
on run argv
  set diagnosis to item 1 of argv
  repeat
    set response to display dialog diagnosis with title "Codex 配置失败" buttons {"复制诊断信息", "关闭"} default button "关闭"
    if button returned of response is "关闭" then exit repeat
    set the clipboard to diagnosis
  end repeat
end run
APPLESCRIPT
    if [ "$?" -ne 0 ]; then printf '%s\n' "$text" >&2; fi
  else
    printf '%s\n' "$text" >&2
  fi
}
BASE="$(cd "$(dirname "$0")" && pwd -P)" || {
  show_boot_error $'启动失败 [BOOT-PATH-001]\n阶段：启动配置程序\n原因：无法访问脚本所在目录\n配置状态：配置文件未修改'
  exit 1
}
if [ ! -x /usr/bin/ruby ]; then
  show_boot_error $'启动失败 [BOOT-RUBY-001]\n阶段：启动配置程序\n原因：/usr/bin/ruby 不存在或不可执行\n配置状态：配置文件未修改'
  exit 1
fi
if [ ! -r "$BASE/辅助文件/codex_setup.rb" ]; then
  show_boot_error $'启动失败 [BOOT-SCRIPT-001]\n阶段：启动配置程序\n原因：codex_setup.rb 缺失或不可读取\n配置状态：配置文件未修改'
  exit 1
fi
exec /usr/bin/ruby "$BASE/辅助文件/codex_setup.rb"
