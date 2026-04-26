#!/bin/bash
#
# Cloudflare IP 优选脚本
# 自动获取 Cloudflare IP 范围 → 采样 → 延迟过滤 → 测速优选 → 输出 Top N
#
# 用法: ./update_ips.sh
# 环境变量: TOTAL_SAMPLES=500 DELAY_THRESHOLD=300 ./update_ips.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ========== 配置 ==========
TOTAL_SAMPLES=${TOTAL_SAMPLES:-3000}
MAX_CONCURRENCY=${MAX_CONCURRENCY:-200}
DELAY_THRESHOLD=${DELAY_THRESHOLD:-300}
SPEED_TEST_THREADS=${SPEED_TEST_THREADS:-30}
TOP_N=${TOP_N:-50}
COMMON_PORTS=(443 2053 2083 2087 2096 8443)
WARP_CIDRS=("162.159.193.0/24" "162.159.197.0/24" "162.159.239.0/24")

# 中间文件
TMP_SAMPLE_IPS="ip_sample.txt"
TMP_RESULT_CSV="result_raw.csv"
OUTPUT_FILE="top50_ips.txt"
OUTPUT_CSV="top50_ips.csv"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
err() { echo "[$(date '+%H:%M:%S')] 错误: $*" >&2; }

check_locations() {
    if [ ! -f "locations.json" ]; then
        log "正在下载 locations.json..."
        curl -sL -o locations.json "https://locations-adw.pages.dev/" || {
            err "无法下载 locations.json，使用空数据"
            echo "[]" > locations.json
        }
    fi
}

# ========== 步骤 1 ==========
step1_get_ranges() {
    log "[1/4] 获取 Cloudflare IP 范围..."
    local ranges
    ranges=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4) || {
        err "无法获取 Cloudflare IP 范围"
        exit 1
    }
    local count; count=$(echo "$ranges" | wc -l | tr -d ' ')
    log "获取到 $count 个 IPv4 CIDR 段"
    echo "$ranges"
}

# ========== 步骤 2 ==========
step2_generate_ips() {
    local ranges="$1"
    log "[2/4] 生成 $TOTAL_SAMPLES 个采样 IP..."

    CF_RANGES="$ranges" TOTAL_SAMPLES="$TOTAL_SAMPLES" OUTFILE="$TMP_SAMPLE_IPS" \
    node -e "$(cat << 'NODE'
const ranges = (process.env.CF_RANGES || '').split('\n').filter(Boolean);
const WARP = ['162.159.193.0/24', '162.159.197.0/24', '162.159.239.0/24'];
const allRanges = ranges.concat(WARP);
const PORTS = [443, 2053, 2083, 2087, 2096, 8443];
const TOTAL = +process.env.TOTAL_SAMPLES;
const OUTFILE = process.env.OUTFILE;

const ipToInt = ip => ip.split('.').reduce((a, o) => (a << 8) + +o, 0) >>> 0;
const intToIp = v => [24,16,8,0].map(b => (v >>> b) & 255).join('.');
const cidrRange = cidr => {
    const [ip, bits] = cidr.split('/');
    const mask = ~(2 ** (32 - +bits) - 1);
    const start = ipToInt(ip) & mask;
    return { start, end: start + 2 ** (32 - +bits) - 1 };
};

let seed = Date.now() & 0xFFFFFFFF;
const rand = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 0xFFFFFFFF; };

const ips = new Set();
const perRange = Math.ceil(TOTAL / allRanges.length);

for (const cidr of allRanges) {
    const { start, end } = cidrRange(cidr);
    const limit = Math.min(perRange, end - start);
    for (let i = 0; i < limit; i++) {
        const ip = intToIp(start + Math.floor(rand() * (end - start + 1)));
        if (!ips.has(ip)) PORTS.forEach(p => ips.add(ip + ' ' + p));
    }
}

// 对 104.16.0.0/13 额外采样
const { start: s2, end: e2 } = cidrRange('104.16.0.0/13');
for (let i = 0; i < 60; i++) {
    const ip = intToIp(s2 + Math.floor(rand() * (e2 - s2 + 1)));
    if (!ips.has(ip + ' 443')) PORTS.forEach(p => ips.add(ip + ' ' + p));
}

require('fs').writeFileSync(OUTFILE, Array.from(ips).join('\n'));
console.log('生成 ' + ips.size + ' 个 IP:port 对');
NODE
)" 2>&1 || {
        err "IP 生成失败"
        exit 1
    }
    echo "" >> "$TMP_SAMPLE_IPS"
}

# ========== 步骤 2b：从 FOFA 导入已知 IP ==========
step2b_import_fofa() {
    local files=("hk.csv" "tw.csv")
    log "[2b/4] 从 FOFA 导出文件导入 IP..."
    local count=0
    for f in "${files[@]}"; do
        if [ -f "$f" ]; then
            # 解析 CSV：第2列=IP，第3列=端口，跳过表头
            tail -n +2 "$f" | awk -F',' '$2!="" && $3!="" {print $2, $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' >> "$TMP_SAMPLE_IPS"
            local n; n=$(tail -n +2 "$f" | awk -F',' '$2!="" && $3!="" {print $2, $3}' | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
            log "  从 $f 导入 $n 个 IP"
            count=$((count + n))
        else
            log "  $f 不存在，跳过"
        fi
    done
    local total; total=$(wc -l < "$TMP_SAMPLE_IPS")
    log "导入完成，共 $count 个，总采样 $total 个 IP:port 对"
}

# ========== 步骤 3 ==========
step3_latency_test() {
    local attempt=1 max_retries=1
    local orig_samples=$TOTAL_SAMPLES

    while [ $attempt -le $((max_retries + 1)) ]; do
        log "[3/4] 延迟测试（阈值 ${DELAY_THRESHOLD}ms，并发 ${MAX_CONCURRENCY}）..."

        check_locations

        go run iptest.go \
            -file "$TMP_SAMPLE_IPS" \
            -outfile "$TMP_RESULT_CSV" \
            -max "$MAX_CONCURRENCY" \
            -speedtest "$SPEED_TEST_THREADS" \
            -delay "$DELAY_THRESHOLD" 2>&1

        if [ ! -f "$TMP_RESULT_CSV" ]; then
            err "延迟测试未生成结果"
            count=0
        else
            local count; count=$(tail -n +2 "$TMP_RESULT_CSV" | wc -l | tr -d ' ')
        fi
        if [ "$count" -gt 0 ]; then
            log "发现 $count 个有效 IP"
            return 0
        fi

        err "第 ${attempt} 次延迟测试未发现有效 IP"
        if [ $attempt -le $max_retries ]; then
            TOTAL_SAMPLES=$((orig_samples * 2))
            log "重试: 扩大采样至 ${TOTAL_SAMPLES}，重新生成 IP..."
            CF_RANGES="$CF_RANGES" TOTAL_SAMPLES="$TOTAL_SAMPLES" OUTFILE="$TMP_SAMPLE_IPS" \
            node -e "$(cat << 'NODE')
const ranges = (process.env.CF_RANGES || '').split('\n').filter(Boolean);
const WARP = ['162.159.193.0/24', '162.159.197.0/24', '162.159.239.0/24'];
const allRanges = ranges.concat(WARP);
const PORTS = [443, 2053, 2083, 2087, 2096, 8443];
const TOTAL = +process.env.TOTAL_SAMPLES;
const OUTFILE = process.env.OUTFILE;

const ipToInt = ip => ip.split('.').reduce((a, o) => (a << 8) + +o, 0) >>> 0;
const intToIp = v => [24,16,8,0].map(b => (v >>> b) & 255).join('.');
const cidrRange = cidr => {
    const [ip, bits] = cidr.split('/');
    const mask = ~(2 ** (32 - +bits) - 1);
    const start = ipToInt(ip) & mask;
    return { start, end: start + 2 ** (32 - +bits) - 1 };
};

let seed = Date.now() & 0xFFFFFFFF;
const rand = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 0xFFFFFFFF; };

const ips = new Set();
const perRange = Math.ceil(TOTAL / allRanges.length);

for (const cidr of allRanges) {
    const { start, end } = cidrRange(cidr);
    const limit = Math.min(perRange, end - start);
    for (let i = 0; i < limit; i++) {
        const ip = intToIp(start + Math.floor(rand() * (end - start + 1)));
        if (!ips.has(ip)) PORTS.forEach(p => ips.add(ip + ' ' + p));
    }
}

// 对 104.16.0.0/13 额外采样
const { start: s2, end: e2 } = cidrRange('104.16.0.0/13');
for (let i = 0; i < 60; i++) {
    const ip = intToIp(s2 + Math.floor(rand() * (e2 - s2 + 1)));
    if (!ips.has(ip + ' 443')) PORTS.forEach(p => ips.add(ip + ' ' + p));
}

require('fs').writeFileSync(OUTFILE, Array.from(ips).join('\n'));
console.log('生成 ' + ips.size + ' 个 IP:port 对');
NODE
)" 2>&1 || {
                err "IP 重新生成失败"
                exit 1
            }
            echo "" >> "$TMP_SAMPLE_IPS"
        fi
        attempt=$((attempt + 1))
    done

    err "经 $((max_retries + 1)) 次尝试仍未发现有效 IP，退出"
    exit 1
}

# ========== 步骤 4 ==========
step5_output_top() {
    log "[4/4] 筛选并输出结果..."

    # 用 Node.js 过滤亚太区域并按速度排序，输出 Top N
    TMP_RESULT_CSV="$TMP_RESULT_CSV" \
    OUTFILE="$OUTPUT_FILE" \
    OUTFILE_CSV="$OUTPUT_CSV" \
    TOP_N="$TOP_N" \
    node -e "$(cat << 'NODEOUT'
const fs = require('fs');

const csvFile = process.env.TMP_RESULT_CSV;
const topN = parseInt(process.env.TOP_N) || 50;

const lines = fs.readFileSync(csvFile, 'utf8').trim().split('\n').slice(1);
const entries = lines.map(line => {
    const f = line.split(',');
    const ip = f[0], port = f[1];
    const speed = parseFloat(f[12]) || 0;
    const flag = f[10] || '';
    const city = f[9] || f[6] || f[3] || '?';
    const latency = f[11] || '?';
    return { ip, port, speed, flag, city, latency };
});

entries.sort((a, b) => b.speed - a.speed);
const selected = entries.slice(0, topN);

console.log('');
console.log('==========================================');
console.log('  Cloudflare IP 优选结果 (Top ' + selected.length + ')');
console.log('==========================================');
console.log('');
console.log(' #  | IP地址              | 端口  | 速度(kB/s) | 延迟    | 位置');
console.log('--- | ------------------- | ----- | ---------- | ------- | ---------------');

selected.forEach((e, i) => {
    console.log(
        ' ' + ('' + (i+1)).padStart(1) + ' | ' +
        e.ip.padEnd(19) + ' | ' +
        e.port.padEnd(5) + ' | ' +
        ('' + e.speed).padStart(10) + ' | ' +
        e.latency.padEnd(7) + ' | ' +
        e.flag + e.city
    );
});

// 统计区域分布
const regions = {};
selected.forEach(e => {
    const r = e.flag || '未知';
    regions[r] = (regions[r] || 0) + 1;
});
console.log('');
console.log('区域分布:');
Object.entries(regions).sort((a, b) => b[1] - a[1]).forEach(([flag, count]) => {
    console.log('  ' + flag + ': ' + count + ' 个');
});

// 输出 TXT
const simpleOutput = selected.map(e => {
    const tag = e.flag + e.city;
    return e.ip + ':' + e.port + (tag ? '#' + tag : '');
}).join('\n');
fs.writeFileSync(process.env.OUTFILE, simpleOutput);

// 输出 CSV
const csvHeader = 'IP地址,端口,回源端口,TLS,数据中心,地区,城市,TCP延迟(ms),速度(MB/s)';
const csvRows = selected.map(e => {
    const speedMB = (e.speed / 1024).toFixed(2);
    return [e.ip, e.port, e.port, 'true', '', '', '', e.latency.replace(/\s*ms/, ''), speedMB].join(',');
});
fs.writeFileSync(process.env.OUTFILE_CSV, csvHeader + '\n' + csvRows.join('\n'));
NODEOUT
)" 2>&1

    echo ""
    log "完成! 最优 ${TOP_N} 个 IP 已保存到"
    log "  TXT: $(pwd)/${OUTPUT_FILE}"
    log "  CSV: $(pwd)/${OUTPUT_CSV}"
}

# ========== 清理 ==========
cleanup() {
    log "清理之前生成的中间文件..."
    rm -f "$TMP_SAMPLE_IPS" "$TMP_RESULT_CSV" "$OUTPUT_FILE" "$OUTPUT_CSV"
}

# ========== 主流程 ==========
cleanup
CF_RANGES=$(step1_get_ranges)
step2_generate_ips "$CF_RANGES"
step2b_import_fofa
step3_latency_test
step5_output_top
