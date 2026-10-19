#!/usr/bin/env bash
# AI 端：往 Supabase 信箱投递一条命令，并等待手机端执行结果。
#
# 需要环境变量：
#   TOY_SUPABASE_URL   https://xxxx.supabase.co
#   TOY_ANON_KEY       Supabase anon / publishable key
#   TOY_TOKEN          bridge token
#
# 用法：
#   send.sh pulse <channel> <intensity> <seconds> [pattern]
#   send.sh combo '<channels json>'
#   send.sh stop [channel]
#   send.sh status
#
# 例子：
#   send.sh pulse vibration 30 20 wave
#   send.sh combo '{"suction":{"intensity":30,"duration_seconds":20},"vibration":{"pattern":"pulse","intensity":25,"duration_seconds":30}}'
set -euo pipefail

: "${TOY_SUPABASE_URL:?需要 TOY_SUPABASE_URL}"
: "${TOY_ANON_KEY:?需要 TOY_ANON_KEY}"
: "${TOY_TOKEN:?需要 TOY_TOKEN}"

rpc() {
  # 旧版 anon key 是 JWT，要同时放进 Authorization；新版 sb_publishable_ key 只放 apikey
  local auth=()
  [[ "$TOY_ANON_KEY" == eyJ* ]] && auth=(-H "Authorization: Bearer $TOY_ANON_KEY")
  curl -sS -X POST "${TOY_SUPABASE_URL%/}/rest/v1/rpc/$1" \
    -H "apikey: $TOY_ANON_KEY" \
    "${auth[@]}" \
    -H "Content-Type: application/json" \
    -d "$2"
}

action="${1:-}"
case "$action" in
  pulse)
    body=$(jq -n --arg t "$TOY_TOKEN" --arg c "$2" --argjson i "$3" --argjson d "$4" --arg p "${5:-steady}" \
      '{p_token:$t, p_action:"pulse", p_channel:$c, p_intensity:$i, p_duration_seconds:$d, p_pattern:$p}')
    ;;
  combo)
    body=$(jq -n --arg t "$TOY_TOKEN" --argjson ch "$2" '{p_token:$t, p_action:"combo", p_channels:$ch}')
    ;;
  stop)
    body=$(jq -n --arg t "$TOY_TOKEN" --arg c "${2:-}" '{p_token:$t, p_action:"stop", p_channel:($c | if . == "" then null else . end)}')
    ;;
  status)
    body=$(jq -n --arg t "$TOY_TOKEN" '{p_token:$t, p_action:"status"}')
    ;;
  *)
    sed -n '2,20p' "$0"; exit 1
    ;;
esac

resp=$(rpc toy_enqueue "$body")
id=$(jq -r 'if type == "array" then .[0].id else empty end' <<<"$resp")
if [[ -z "$id" ]]; then
  echo "投递失败：$resp" >&2
  exit 1
fi
echo "已投递 $action ($id)，等待手机执行…"

for _ in $(seq 1 15); do
  sleep 1
  row=$(rpc toy_get "$(jq -n --arg t "$TOY_TOKEN" --arg id "$id" '{p_token:$t, p_id:$id}')")
  state=$(jq -r '.[0].state' <<<"$row")
  if [[ "$state" != "pending" && "$state" != "claimed" ]]; then
    jq '.[0] | {state, result}' <<<"$row"
    exit 0
  fi
done
echo "15 秒内手机没有领取：确认页面开着、AI 联动已打开、屏幕没锁。" >&2
exit 2
