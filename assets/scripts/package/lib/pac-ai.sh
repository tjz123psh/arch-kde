# shellcheck shell=bash  # 这个文件由 pac / pacr source，不单独执行
# ==============================================================================
# AI 后端：直连 HTTP（OpenAI 兼容 / Anthropic），配置写在 ~/.config/pac/ai.conf
#   为什么不走 CLI：CLI 那套会把模型 id、额度、插件行为都绑在第三方工具上；
#   这里只要 url + 模型名 + key，HTTP 调用也天然没有工具可给模型用。
# ==============================================================================
AI_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pac"
AI_CONF="${AI_CONF_DIR}/ai.conf"
AI_URL=""
AI_MODEL=""
AI_KEY=""
AI_PROTOCOL="openai"
AI_TIMEOUT="${PAC_AI_TIMEOUT:-600}"
AI_MAX_TOKENS="${PAC_AI_MAX_TOKENS:-4096}"
AI_TEMPERATURE="${PAC_AI_TEMPERATURE:-0}"

ai_conf_get() {
  # ai_conf_get <键>：严格解析 "键 = 值"，不 source 配置文件（配置里塞命令也不会被执行）
  local key="$1" line k v
  [[ -r "$AI_CONF" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%% #*}"
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ "$k" == "$key" ]] || continue
    printf '%s' "$v"
    return 0
  done < "$AI_CONF"
  return 1
}

ai_config_load() {
  # 读配置 + 环境变量临时覆盖（PAC_AI_URL / PAC_AI_MODEL / PAC_AI_KEY）+ 权限检查
  local mode v

  AI_URL="$(ai_conf_get url || true)"
  AI_MODEL="$(ai_conf_get model || true)"
  AI_KEY="$(ai_conf_get key || true)"
  AI_PROTOCOL="$(ai_conf_get protocol || true)"
  AI_PROTOCOL="${AI_PROTOCOL:-openai}"

  v="$(ai_conf_get timeout || true)";     [[ "$v" =~ ^[0-9]+$ ]] && AI_TIMEOUT="$v"
  v="$(ai_conf_get max_tokens || true)";  [[ "$v" =~ ^[0-9]+$ ]] && AI_MAX_TOKENS="$v"
  v="$(ai_conf_get temperature || true)"; [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] && AI_TEMPERATURE="$v"

  AI_URL="${PAC_AI_URL:-$AI_URL}"
  AI_MODEL="${PAC_AI_MODEL:-$AI_MODEL}"
  AI_KEY="${PAC_AI_KEY:-$AI_KEY}"

  if [[ -n "$AI_KEY" && -r "$AI_CONF" ]]; then
    mode="$(stat -c %a -- "$AI_CONF" 2>/dev/null || printf '')"
    if [[ -n "$mode" && "$mode" != "600" ]]; then
      printf '\033[33mpac: %s 的权限是 %s，里面有 key，建议 chmod 600\033[0m\n' "$AI_CONF" "$mode" >&2
    fi
  fi

  [[ -n "$AI_URL" && -n "$AI_MODEL" && -n "$AI_KEY" ]]
}

ai_api_url() {
  # 把配置里的 url 归一化成完整请求地址
  local url="$1" proto="$2"

  url="${url%/}"
  case "$proto" in
    anthropic)
      case "$url" in
        *"/messages") ;;
        *"/v1") url="$url/messages" ;;
        *) url="$url/v1/messages" ;;
      esac
      ;;
    *)
      case "$url" in
        *"/chat/completions") ;;
        *"/v1") url="$url/chat/completions" ;;
        *) url="$url/v1/chat/completions" ;;
      esac
      ;;
  esac
  printf '%s' "$url"
}

ai_host() {
  printf '%s' "${AI_URL#*://}" | cut -d/ -f1
}

ai_chat() {
  # ai_chat <提示词文件> <用户内容文件> <输出文件>：发一次请求，正文写进输出文件
  local sys="$1" user="$2" out="$3"
  local endpoint payload body http_code rc=0

  ai_config_load || {
    printf '\033[33mpac: AI 后端还没配好（%s）。先运行 pac ai init，再填 url / model / key。\033[0m\n' "$AI_CONF" >&2
    return 2
  }

  endpoint="$(ai_api_url "$AI_URL" "$AI_PROTOCOL")"
  payload="$(mktemp)"
  body="$(mktemp)"

  # 请求体一律用 jq 组，提示词/证据包里的引号换行不会把 JSON 拼坏
  if [[ "$AI_PROTOCOL" == "anthropic" ]]; then
    jq -n --arg model "$AI_MODEL" --argjson max "$AI_MAX_TOKENS" \
      --rawfile system "$sys" --rawfile msg "$user" \
      '{model:$model, max_tokens:$max, system:$system,
        messages:[{role:"user", content:$msg}]}' > "$payload"
  else
    jq -n --arg model "$AI_MODEL" --argjson max "$AI_MAX_TOKENS" --argjson temp "$AI_TEMPERATURE" \
      --rawfile system "$sys" --rawfile msg "$user" \
      '{model:$model, temperature:$temp, max_tokens:$max,
        messages:[{role:"system", content:$system}, {role:"user", content:$msg}]}' > "$payload"
  fi

  set +e
  if [[ "$AI_PROTOCOL" == "anthropic" ]]; then
    http_code="$(curl --silent --show-error --location --connect-timeout 10 --max-time "$AI_TIMEOUT" \
      --output "$body" --write-out '%{http_code}' \
      -H "x-api-key: $AI_KEY" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
      --data-binary "@$payload" "$endpoint" 2>&1)"
  else
    http_code="$(curl --silent --show-error --location --connect-timeout 10 --max-time "$AI_TIMEOUT" \
      --output "$body" --write-out '%{http_code}' \
      -H "Authorization: Bearer $AI_KEY" -H 'content-type: application/json' \
      --data-binary "@$payload" "$endpoint" 2>&1)"
  fi
  rc=$?
  set -e

  if (( rc != 0 )) || [[ ! "$http_code" =~ ^2 ]]; then
    printf '\033[31mpac: AI 请求失败（HTTP %s）\033[0m\n' "${http_code:-?}" >&2
    [[ -s "$body" ]] && head -c 500 -- "$body" | sed 's/^/    /' >&2
    case "$http_code" in
      401|403) printf '\033[33m     多半是 key 不对或没权限（看 %s）\033[0m\n' "$AI_CONF" >&2 ;;
      402)     printf '\033[33m     账户额度不足\033[0m\n' >&2 ;;
      429)     printf '\033[33m     被限流了，过一会儿再试\033[0m\n' >&2 ;;
      404)     printf '\033[33m     地址不对：%s（检查配置里的 url）\033[0m\n' "$endpoint" >&2 ;;
    esac
    rm -f -- "$payload" "$body"
    return 1
  fi

  if [[ "$AI_PROTOCOL" == "anthropic" ]]; then
    jq -r '[.content[]? | select(.type == "text") | .text] | join("")' "$body" > "$out" 2>/dev/null || true
  else
    jq -r '.choices[0].message.content // empty' "$body" > "$out" 2>/dev/null || true
  fi
  rm -f -- "$payload" "$body"

  if [[ ! -s "$out" ]]; then
    printf '\033[31mpac: AI 返回里没有正文\033[0m\n' >&2
    return 1
  fi
  return 0
}

ai_models_list() {
  # 拉 {url}/models 的模型列表（端点不支持就返回空）
  local url
  [[ -n "$AI_URL" && -n "$AI_KEY" ]] || return 1
  url="${AI_URL%/}"
  case "$url" in
    *"/models") ;;
    *"/v1") url="$url/models" ;;
    *) url="$url/v1/models" ;;
  esac
  curl --silent --show-error --fail --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $AI_KEY" "$url" 2>/dev/null |
    jq -r '.data[]?.id // empty' 2>/dev/null
}

ai_write_conf() {
  # ai_write_conf <键> <值>：只改这一行，其它字段和注释都留着
  local key="$1" value="$2" tmp
  mkdir -p -- "$AI_CONF_DIR"
  chmod 700 -- "$AI_CONF_DIR" 2>/dev/null || true
  tmp="$(mktemp)"
  if [[ -r "$AI_CONF" ]]; then
    awk -v k="$key" -v v="$value" '
      { probe = $0; sub(/#.*/, "", probe)
        if (probe ~ "^[[:space:]]*" k "[[:space:]]*=") { print k " = " v; done = 1; next }
        print }
      END { if (!done) print k " = " v }
    ' "$AI_CONF" > "$tmp"
  else
    printf '%s = %s\n' "$key" "$value" > "$tmp"
  fi
  install -m 600 -- "$tmp" "$AI_CONF" 2>/dev/null || { mv -f -- "$tmp" "$AI_CONF"; chmod 600 -- "$AI_CONF"; }
  rm -f -- "$tmp"
}

ai_init() {
  mkdir -p -- "$AI_CONF_DIR"
  chmod 700 -- "$AI_CONF_DIR" 2>/dev/null || true
  if [[ -e "$AI_CONF" ]]; then
    printf 'pac: 配置已存在：%s（用 pac ai show 查看，或直接编辑）\n' "$AI_CONF" >&2
    return 0
  fi
  cat > "$AI_CONF" <<'EOF'
# pac 的 AI 审查后端（OpenAI 兼容或 Anthropic 接口）
# 这个文件里有 key，权限保持 600。
#
# url 三种写法都行：https://api.deepseek.com
#                   https://api.deepseek.com/v1
#                   https://api.deepseek.com/v1/chat/completions
url         = https://api.deepseek.com
model       = deepseek-chat
key         = 在这里填你的 API key

# 可选
protocol    = openai
timeout     = 600
max_tokens  = 4096
temperature = 0
EOF
  chmod 600 -- "$AI_CONF"
  printf '\033[36mpac: 已生成 %s（权限 600）\033[0m\n' "$AI_CONF"
  printf '     把 url / model / key 填好就能用了。\n'
}

ai_show() {
  local key_masked mode masked_tail show_url show_model
  if [[ ! -r "$AI_CONF" ]]; then
    printf 'pac: 还没有配置（%s）。先运行：pac ai init\n' "$AI_CONF" >&2
    return 1
  fi
  ai_config_load || true
  mode="$(stat -c %a -- "$AI_CONF" 2>/dev/null || printf '?')"
  key_masked="（未设置）"
  if [[ -n "$AI_KEY" ]]; then
    masked_tail="$(printf '%s' "$AI_KEY" | tail -c 4)"
    key_masked="…${masked_tail}"
  fi
  show_url="$AI_URL";     [[ -n "$show_url" ]]   || show_url="（未设置）"
  show_model="$AI_MODEL"; [[ -n "$show_model" ]] || show_model="（未设置）"
  printf '配置文件：%s（权限 %s）\n' "$AI_CONF" "$mode"
  printf '  url        = %s\n' "$show_url"
  printf '  model      = %s\n' "$show_model"
  printf '  key        = %s\n' "$key_masked"
  printf '  protocol   = %s\n' "$AI_PROTOCOL"
  printf '  timeout    = %s 秒 · max_tokens = %s\n' "$AI_TIMEOUT" "$AI_MAX_TOKENS"
  if [[ -z "$AI_URL" || -z "$AI_MODEL" || -z "$AI_KEY" ]]; then
    printf '\033[33m  还缺字段，AI 审查用不了（装包不受影响）\033[0m\n'
  fi
}

ai_select_model() {
  local selected models
  ai_config_load || {
    printf 'pac: 还没配好后端（%s）。先运行 pac ai init\n' "$AI_CONF" >&2
    return 1
  }
  models="$(ai_models_list || true)"
  if [[ -z "$models" ]]; then
    printf 'pac: 这个端点没给出模型列表，请直接输入模型名：' >&2
    read -r selected || return 1
  else
    selected="$(printf '%s\n' "$models" | fzf --height=80% --layout=reverse --border=rounded \
      --header='选择审查模型  Enter 选择  Esc 取消')" || return 1
  fi
  [[ -n "$selected" ]] || return 1
  ai_write_conf model "$selected"
  AI_MODEL="$selected"
  printf '\033[36mpac: 审查模型已设为：\033[0m %s\n' "$selected"
}

ai_usage() {
  cat <<'EOF'
用法: pac ai [子命令]

  init           生成配置模板（~/.config/pac/ai.conf，权限 600）
  show           显示当前配置（key 打码）
  model <名字>   直接设置模型名
  models         从端点的 /models 拉列表，用 fzf 选

一次性参数：--ai-init / --ai-show / --ai-model <名字> / --ai-models
EOF
}

ai_command() {
  local sub="show" name=""
  [[ $# -gt 0 ]] && sub="$1"
  case "$sub" in
    init)   ai_init ;;
    show)   ai_show ;;
    models) ai_select_model ;;
    model)
      [[ $# -gt 1 ]] && name="$2"
      if [[ -z "$name" ]]; then
        printf '用法: pac ai model <模型名>\n' >&2
        return 1
      fi
      ai_write_conf model "$name"
      printf '\033[36mpac: 审查模型已设为：\033[0m %s\n' "$name"
      ;;
    -h|--help|help) ai_usage ;;
    *) ai_usage >&2; return 1 ;;
  esac
}
