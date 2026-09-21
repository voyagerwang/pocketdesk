#!/bin/zsh
# [INPUT]: 当前分支已配置的 Git 上游、干净工作区及本机构建环境。
# [OUTPUT]: 仅快进当前上游后重装本机 PocketDesk；拒绝未提交、分叉和未完成的 Git 操作。
# [POS]: 分支开发的一键更新入口，不切换 main、不删除锁或操作状态、不绕过 SSH 主机校验。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 '工作区有未提交内容，请先提交或自行暂存，再更新。'
  exit 1
fi
for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if [[ -e "$(git rev-parse --git-path "$state")" ]]; then
    print -u2 '存在未完成的 Git 操作，请先完成或自行取消，再更新。'
    exit 1
  fi
done
git symbolic-ref --quiet --short HEAD >/dev/null || { print -u2 '当前未处于分支，请先切换到开发分支。'; exit 1; }
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null || { print -u2 '当前分支没有上游，请先设置上游分支。'; exit 1; }
git pull --ff-only
exec zsh scripts/rebuild-safe.sh
