#!/bin/bash
# ─────────────────────────────────────────
# 多业务线定时调度器
# 格式: "CRON|team_id"
# ─────────────────────────────────────────

CONFIG_FILE="$(dirname "$0")/pipeline_config.json"
JOBS=()
while IFS= read -r line; do JOBS+=("$line"); done < <(jq -r '.schedule.jobs[] | "\(.cron)|\(.team)"' "$CONFIG_FILE")

LOGS_DIR="$(dirname "$0")/logs"
mkdir -p "$LOGS_DIR"
LOG="$LOGS_DIR/scheduled_job_$(TZ=Asia/Shanghai date +%G-W%V).log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

# 判断当前时间是否匹配 cron 表达式（只支持 分 时 * * *）
matches_cron() {
    local cron="$1"
    local cron_min cron_hour _rest
    read cron_min cron_hour _rest <<< "$cron"
    local cur_min=$(TZ=Asia/Shanghai date +%-M)
    local cur_hour=$(TZ=Asia/Shanghai date +%-H)

    # 匹配分钟
    local min_ok=false
    if [ "$cron_min" = "*" ]; then
        min_ok=true
    else
        IFS=',' read -ra mins <<< "$cron_min"
        for m in "${mins[@]}"; do
            [ "$m" -eq "$cur_min" ] && min_ok=true && break
        done
    fi

    # 匹配小时
    local hour_ok=false
    if [ "$cron_hour" = "*" ]; then
        hour_ok=true
    else
        IFS=',' read -ra hours <<< "$cron_hour"
        for h in "${hours[@]}"; do
            [ "$h" -eq "$cur_hour" ] && hour_ok=true && break
        done
    fi

    [ "$min_ok" = "true" ] && [ "$hour_ok" = "true" ]
}

# 等待到下一个整分钟
sleep_to_next_minute() {
    local now_sec=$(date +%S)
    # 去掉前导零避免被当作八进制
    now_sec=$((10#$now_sec))
    local wait=$(( 60 - now_sec ))
    sleep "$wait"
}

log "=== Scheduler started ==="
for job in "${JOBS[@]}"; do
    cron="${job%%|*}"
    team="${job##*|}"
    log "  Registered: team=${team}  cron=\"${cron}\""
done

# 先对齐到整分钟
sleep_to_next_minute

while true; do
    LOG="$LOGS_DIR/scheduled_job_$(TZ=Asia/Shanghai date +%G-W%V).log"
    to_fire=()
    for job in "${JOBS[@]}"; do
        cron="${job%%|*}"
        if matches_cron "$cron"; then
            to_fire+=("$job")
        fi
    done

    for job in "${to_fire[@]}"; do
        cron="${job%%|*}"
        team="${job##*|}"
        log ">>> Firing job: team=${team}  (cron=\"${cron}\")"

        claude --dangerously-skip-permissions \
          --print \
          --output-format stream-json \
          --verbose \
          "Run the Web3 intel pipeline for team ${team} and push to Lark" < /dev/null 2>&1 | \
          python3 -u -c "
import sys, json

for line in sys.stdin:
    line = line.rstrip()
    print(f'[debug] {repr(line)}')
    if not line:
        print(flush=True)
        continue
    try:
        data = json.loads(line)
        event_type = data.get('type', '')
        if event_type == 'assistant':
            for block in data.get('message', {}).get('content', []):
                if block.get('type') == 'text':
                    print(block['text'], end='', flush=True)
        elif event_type in ('tool_result', 'system', 'result'):
            print(f'[{event_type}] {line}', flush=True)
    except json.JSONDecodeError:
        print(line, flush=True)
" >> "$LOG" 2>&1

        EXIT_CODE=${PIPESTATUS[0]}
        if [ $EXIT_CODE -ne 0 ]; then
            log "!!! Job failed: team=${team}  exit_code=${EXIT_CODE}"
        else
            log "<<< Job done:   team=${team}"
        fi
    done

    sleep_to_next_minute
done