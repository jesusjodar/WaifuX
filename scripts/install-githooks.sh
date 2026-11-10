#!/bin/sh
# 启用仓库内 hooks：
# - pre-commit：禁止误提交 AGENTS.md 等 AI 本地说明
# - prepare-commit-msg：不自动更改版本或更新源
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git config core.hooksPath scripts/githooks
echo "已设置: git config core.hooksPath scripts/githooks"
echo "版本变更请显式运行 scripts/bump-version-patch.sh；提交不会生成更新公告。"
