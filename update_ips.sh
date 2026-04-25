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
TOTAL_SAMPLES=${TOTAL_SAMPLES:-500}
MAX_CONCURRENCY=${MAX_CONCURRENCY:-200}
DELAY_THRESHOLD=${DELAY_THRESHOLD:-300}
SPEED_TEST_THREADS=${SPEED_TEST_THREADS:-30}
TOP_N=${TOP_N:-50}
COMMON_PORTS=(443 2053 2083 2087 2096 8443)

# 中间文件
TMP_SAMPLE_IPS="ip_sample.txt"
TMP_RESULT_CSV="result_raw.csv"
TMP_VALID_IPS="ip_valid.txt"
TMP_SPEED_RESULT="speed_result.txt"
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
    log "[1/5] 获取 Cloudflare IP 范围..."
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
    log "[2/5] 生成 $TOTAL_SAMPLES 个采样 IP..."

    CF_RANGES="$ranges" TOTAL_SAMPLES="$TOTAL_SAMPLES" OUTFILE="$TMP_SAMPLE_IPS" \
    node -e "$(cat << 'NODE'
const ranges = (process.env.CF_RANGES || '').split('\n').filter(Boolean);
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
const perRange = Math.ceil(TOTAL / ranges.length);

for (const cidr of ranges) {
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
}

# ========== 步骤 3 ==========
step3_latency_test() {
    local attempt=1 max_retries=1
    local orig_samples=$TOTAL_SAMPLES

    while [ $attempt -le $((max_retries + 1)) ]; do
        log "[3/5] 延迟测试（阈值 ${DELAY_THRESHOLD}ms，并发 ${MAX_CONCURRENCY}）..."

        check_locations

        go run iptest.go \
            -file "$TMP_SAMPLE_IPS" \
            -outfile "$TMP_RESULT_CSV" \
            -max "$MAX_CONCURRENCY" \
            -speedtest 0 \
            -delay "$DELAY_THRESHOLD" 2>&1 | tr -d '\r' | sed 's/\x1b\[2J//g'

        if [ ! -f "$TMP_RESULT_CSV" ]; then
            err "延迟测试未生成结果"
            exit 1
        fi
        local count; count=$(tail -n +2 "$TMP_RESULT_CSV" | wc -l | tr -d ' ')
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
const perRange = Math.ceil(TOTAL / ranges.length);

for (const cidr of ranges) {
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
        fi
        attempt=$((attempt + 1))
    done

    err "经 $((max_retries + 1)) 次尝试仍未发现有效 IP，退出"
    exit 1
}

# ========== 步骤 4 ==========
step4_speed_test() {
    log "[4/5] 测速中（${SPEED_TEST_THREADS} 线程）..."

    tail -n +2 "$TMP_RESULT_CSV" | awk -F',' '{print $1, $2}' > "$TMP_VALID_IPS"
    local total; total=$(wc -l < "$TMP_VALID_IPS")
    log "对 $total 个 IP 进行下载测速..."
    > "$TMP_SPEED_RESULT"

    # 创建测速脚本（多一个参数记录进度）
    local worker="/tmp/speed_w_$$.sh"
    local prog_file="/tmp/speed_prog_$$.txt"
    > "$prog_file"
    cat > "$worker" << 'SCRIPT'
#!/bin/bash
ip=$1 port=$2 out=$3 prog=$4
s=$(curl -s -o /dev/null -w "%{speed_download}" --max-time 8 \
    --connect-to "cdnjs.cloudflare.com:${port}:${ip}:${port}" \
    "https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js" 2>/dev/null)
echo "x" >> "$prog"
[ -n "$s" ] && [ "$s" != "0" ] && echo "$ip $port $(echo scale=0\; $s/1024 | bc)" >> "$out"
SCRIPT
    chmod +x "$worker"

    # 后台显示进度
    (
        while true; do
            sleep 3
            local done; done=$(wc -l < "$prog_file" 2>/dev/null || echo 0)
            local succ; succ=$(wc -l < "$TMP_SPEED_RESULT" 2>/dev/null || echo 0)
            printf "\r  [测速] %d/%d (成功 %d)" "$done" "$total" "$succ" >&2
            [ "$done" -ge "$total" ] && break
        done
    ) &
    local prog_pid=$!

    # 用 xargs -P 并行执行（macOS 兼容）
    awk -v out="$TMP_SPEED_RESULT" -v prog="$prog_file" \
        '{print $1, $2, out, prog}' "$TMP_VALID_IPS" | \
        xargs -P "$SPEED_TEST_THREADS" -n4 bash "$worker"

    kill $prog_pid 2>/dev/null; wait $prog_pid 2>/dev/null
    echo "" >&2
    rm -f "$worker" "$prog_file"

    local tested; tested=$(wc -l < "$TMP_SPEED_RESULT" 2>/dev/null || echo 0)
    if [ "$tested" -eq 0 ]; then
        err "测速全部失败"
        exit 1
    fi
    log "测速完成，$tested 个 IP 有有效速度"
}

# ========== 步骤 5 ==========
step5_output_top() {
    log "[5/5] 筛选亚太区域 IP，生成结果..."

    # 用 Node.js 过滤亚太区域并按速度排序，输出 Top N
    TMP_SPEED_RESULT="$TMP_SPEED_RESULT" \
    TMP_RESULT_CSV="$TMP_RESULT_CSV" \
    OUTFILE="$OUTPUT_FILE" \
    OUTFILE_CSV="$OUTPUT_CSV" \
    TOP_N="$TOP_N" \
    node -e "$(cat << 'NODEOUT'
const fs = require('fs');

// 读取 CSV 位置数据
const lookup = {};
const csvFile = process.env.TMP_RESULT_CSV;
if (fs.existsSync(csvFile)) {
    const lines = fs.readFileSync(csvFile, 'utf8').trim().split('\n').slice(1);
    lines.forEach(line => {
        const f = line.split(',');
        if (f.length >= 12) lookup[f[0] + ':' + f[1]] = {
            dc: f[3], region: f[5], city: f[6],
            region_zh: f[7], country: f[8], city_zh: f[9],
            flag: f[10], latency: f[11], tls: f[2]
        };
    });
}

// 读取测速结果
const speedLines = fs.readFileSync(process.env.TMP_SPEED_RESULT, 'utf8')
    .trim().split('\n').filter(Boolean);

// 解析并打标签
const entries = speedLines.map(line => {
    const [ip, port, speed] = line.split(/\s+/);
    const key = ip + ':' + port;
    const d = lookup[key] || {};
    const flag = d.flag || '';
    const city = d.city_zh || d.city || d.dc || '?';
    const region = d.dc || '';
    // 按速度降序排列
    return { ip, port, speed: parseInt(speed), flag, city, region, data: d };
});

// 排序：按速度降序排列
entries.sort((a, b) => b.speed - a.speed);

const topN = parseInt(process.env.TOP_N) || 50;
const selected = entries.slice(0, topN);

console.log('');
console.log('==========================================');
console.log('  Cloudflare IP 优选结果 (Top ' + selected.length + ')');
console.log('==========================================');
console.log('');
console.log(' #  | IP地址              | 端口  | 速度(kB/s) | 延迟    | 位置');
console.log('--- | ------------------- | ----- | ---------- | ------- | ---------------');

selected.forEach((e, i) => {
    const lat = e.data.latency || '?';
    console.log(
        ' ' + ('' + (i+1)).padStart(1) + ' | ' +
        e.ip.padEnd(19) + ' | ' +
        e.port.padEnd(5) + ' | ' +
        ('' + e.speed).padStart(10) + ' | ' +
        lat.padEnd(7) + ' | ' +
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

// 输出 TXT：ip:port#flagCity
const simpleOutput = selected.map(e => {
    const tag = e.flag + e.city;
    return e.ip + ':' + e.port + (tag ? '#' + tag : '');
}).join('\n');
fs.writeFileSync(process.env.OUTFILE, simpleOutput);

// 输出 CSV：IP地址,端口,回源端口,TLS,数据中心,地区,城市,TCP延迟(ms),速度(MB/s)
const csvHeader = 'IP地址,端口,回源端口,TLS,数据中心,地区,城市,TCP延迟(ms),速度(MB/s)';
const csvRows = selected.map(e => {
    const d = e.data;
    const region = d.region_zh || d.region || '';
    const city = d.city_zh || d.city || '';
    const dc = d.dc || '';
    const tls = d.tls || 'true';
    const latency = d.latency ? d.latency.replace(/\s*ms/, '') : '';
    const speedMB = (e.speed / 1024).toFixed(2);
    return [e.ip, e.port, e.port, tls, dc, region, city, latency, speedMB].join(',');
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
    rm -f "$TMP_SAMPLE_IPS" "$TMP_RESULT_CSV" "$TMP_VALID_IPS" "$TMP_SPEED_RESULT" "$OUTPUT_FILE" "$OUTPUT_CSV"
}

# ========== 主流程 ==========
cleanup
CF_RANGES=$(step1_get_ranges)
step2_generate_ips "$CF_RANGES"
step3_latency_test
step4_speed_test
step5_output_top
