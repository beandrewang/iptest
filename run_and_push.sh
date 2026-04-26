#!/bin/bash
#
# 自动执行 Cloudflare IP 优选并推送到 GitHub
# 供 launchd 定时调用
#

# 错误时退出
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 日志文件
LOG_FILE="$SCRIPT_DIR/auto_run.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "===== 开始自动执行 ====="

# 执行优选脚本
log "运行 update_ips.sh..."
bash update_ips.sh 2>&1 | tee -a "$LOG_FILE"
RUN_EXIT=${PIPESTATUS[0]}

if [ $RUN_EXIT -ne 0 ]; then
    log "update_ips.sh 失败 (exit code: $RUN_EXIT)"
    exit $RUN_EXIT
fi

# 检查输出文件
if [ ! -f "$SCRIPT_DIR/top50_ips.txt" ]; then
    log "错误: top50_ips.txt 未生成"
    exit 1
fi

# 提交到 GitHub
log "提交结果到 GitHub..."

git add top50_ips.txt top50_ips.csv
# 检查是否有变更
if ! git diff --cached --quiet; then
    git commit -m "auto: update IP results $(date '+%Y-%m-%d')"
    git push origin main 2>&1 | tee -a "$LOG_FILE"
    log "推送成功"
else
    log "IP 结果无变更，跳过提交"
fi

log "===== 完成 ====="
echo ""
