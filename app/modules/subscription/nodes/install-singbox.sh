#!/usr/bin/env bash
# [重要] 移除 set -e，防止在 Systemd 不完整的 VPS 上因为 reload 失败导致脚本直接退出
# set -euo pipefail 

# =========================================================
# 基础配置区 (在此处修改默认端口)
# =========================================================
# VLESS Reality 端口
PORT_REALITY_FIXED=51811
# Shadowsocks 端口
PORT_SS_FIXED=51812
# Hysteria2 端口
PORT_HY2_FIXED=51813
# TUIC 端口
PORT_TUIC_FIXED=51814
# =========================================================

# -----------------------
# 初始化变量
# -----------------------
PORT_SS=""
PORT_HY2=""
PORT_TUIC=""
PORT_REALITY=""
PSK_SS=""
PSK_HY2=""
PSK_TUIC=""
UUID_TUIC=""
UUID=""
REALITY_PK=""
REALITY_PUB=""
REALITY_SID=""
REPORT_URL="" 

# -----------------------
# 彩色输出函数
# -----------------------
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 参数解析
# -----------------------
ENABLE_SS=false
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=false
PROTOCOL_SELECTED=false 

while [[ $# -gt 0 ]]; do
    case "$1" in
        shadowsocks|ss) 
            ENABLE_SS=true; PROTOCOL_SELECTED=true; shift ;;
        hysteria2|hy2)  
            ENABLE_HY2=true; PROTOCOL_SELECTED=true; shift ;;
        tuic)           
            ENABLE_TUIC=true; PROTOCOL_SELECTED=true; shift ;;
        vless|reality)  
            ENABLE_REALITY=true; PROTOCOL_SELECTED=true; shift ;;
        --report)
            if [[ -n "${2:-}" ]]; then
                REPORT_URL="$2"; shift 2
            else
                err "--report 参数需要提供 URL"; exit 1
            fi ;;
        *) shift ;;
    esac
done

if [ "$PROTOCOL_SELECTED" = false ]; then
    info "未指定具体协议，默认安装所有协议..."
    ENABLE_SS=true
    ENABLE_HY2=true
    ENABLE_TUIC=true
    ENABLE_REALITY=true
fi

# -----------------------
# 检测系统类型
# -----------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""; OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu"; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora"; then
        OS="redhat"
    else
        OS="unknown"
    fi
}
detect_os

if [ "$(id -u)" != "0" ]; then err "此脚本需要 root 权限"; exit 1; fi

# -----------------------
# 安装依赖
# -----------------------
install_deps() {
    info "安装系统依赖..."
    case "$OS" in
        alpine)
            apk update || true
            apk add --no-cache bash curl ca-certificates openssl openrc jq grep procps coreutils || { err "依赖安装失败"; exit 1; }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || true
            # 增加 procps(pgrep) 和 coreutils(nohup) 确保兜底机制可用
            apt-get install -y curl ca-certificates openssl jq grep procps coreutils || { err "依赖安装失败"; exit 1; }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq grep procps coreutils || { err "依赖安装失败"; exit 1; }
            ;;
    esac
}
install_deps

# -----------------------
# 工具函数 (密钥生成)
# -----------------------
rand_ss_key() {
    openssl rand -base64 16 2>/dev/null | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

rand_pass_safe() {
    head -c 500 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16
}

rand_uuid() {
    if [ -f /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; else
        openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'
    fi
}

# -----------------------
# 设置主机名后缀
# -----------------------
HOST_NAME=$(hostname)
# 过滤掉不安全字符，防止报错
SAFE_HOST_NAME=$(echo "$HOST_NAME" | tr -cd 'a-zA-Z0-9_-')
if [[ -n "$SAFE_HOST_NAME" ]]; then suffix="-${SAFE_HOST_NAME}"; else suffix=""; fi
echo "$suffix" > /root/node_names.txt
info "节点名称后缀已设置为: $suffix"

# -----------------------
# 生成变量配置
# -----------------------
export ENABLE_SS ENABLE_HY2 ENABLE_TUIC ENABLE_REALITY

get_config() {
    info "正在生成配置信息..."
    
    if $ENABLE_SS; then
        PORT_SS=$PORT_SS_FIXED
        PSK_SS=$(rand_ss_key)
        info "SS 端口: $PORT_SS"
    fi
    if $ENABLE_HY2; then
        PORT_HY2=$PORT_HY2_FIXED
        PSK_HY2=$(rand_pass_safe)
        info "HY2 端口: $PORT_HY2"
    fi
    if $ENABLE_TUIC; then
        PORT_TUIC=$PORT_TUIC_FIXED
        PSK_TUIC=$(rand_pass_safe)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
    fi
    if $ENABLE_REALITY; then
        PORT_REALITY=$PORT_REALITY_FIXED
        UUID=$(rand_uuid)
        info "Reality 端口: $PORT_REALITY"
    fi
}
get_config

# -----------------------
# 安装 sing-box
# -----------------------
install_singbox() {
    info "检查 sing-box 安装..."
    if command -v sing-box >/dev/null 2>&1; then
        info "sing-box 已安装"
        return 0
    fi
    case "$OS" in
        alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
        debian|redhat) 
            # 使用官方脚本安装
            bash <(curl -fsSL https://sing-box.app/install.sh) || warn "官方安装脚本可能报错，但如果不影响二进制文件运行则忽略。"
            ;;
    esac
}
install_singbox

# -----------------------
# 生成密钥与证书
# -----------------------
generate_keys_and_certs() {
    mkdir -p /etc/sing-box/certs
    
    if $ENABLE_REALITY; then
        info "生成 Reality 密钥..."
        REALITY_KEYS=$(sing-box generate reality-keypair 2>&1)
        REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
        REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
        REALITY_SID=$(sing-box generate rand 8 --hex 2>&1)
        echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
        echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    fi

    if $ENABLE_HY2 || $ENABLE_TUIC; then
        info "生成自签证书..."
        if [ ! -f /etc/sing-box/certs/fullchain.pem ]; then
            openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout /etc/sing-box/certs/privkey.pem \
            -out /etc/sing-box/certs/fullchain.pem \
            -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
        fi
    fi
}
generate_keys_and_certs

# -----------------------
# 生成配置文件 config.json
# -----------------------
CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"

create_config() {
    info "写入配置文件..."
    mkdir -p "$(dirname "$CONFIG_PATH")"
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$$.json"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    # SS 配置
    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<EOF
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": $PORT_SS,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$PSK_SS",
      "tag": "ss-in"
    }
EOF
        need_comma=true
    fi
    
    # HY2 配置
    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $PORT_HY2,
      "users": [{ "password": "$PSK_HY2" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
EOF
        need_comma=true
    fi
    
    # TUIC 配置
    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<EOF
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $PORT_TUIC,
      "users": [{ "uuid": "$UUID_TUIC", "password": "$PSK_TUIC" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
EOF
        need_comma=true
    fi
    
    # Reality 配置
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<EOF
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT_REALITY,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "learn.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "learn.microsoft.com", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      }
    }
EOF
    fi

    cat > "$CONFIG_PATH" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
EOF
    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    cat >> "$CONFIG_PATH" <<EOF
  ],
  "outbounds": [{ "type": "direct", "tag": "direct-out" }]
}
EOF
    rm -f "$TEMP_INBOUNDS"

    cat > "$CACHE_FILE" <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
PORT_SS="$PORT_SS"
PORT_HY2="$PORT_HY2"
PORT_TUIC="$PORT_TUIC"
PORT_REALITY="$PORT_REALITY"
PSK_SS="$PSK_SS"
PSK_HY2="$PSK_HY2"
PSK_TUIC="$PSK_TUIC"
UUID_TUIC="$UUID_TUIC"
UUID="$UUID"
REALITY_PK="$REALITY_PK"
REALITY_PUB="$REALITY_PUB"
REALITY_SID="$REALITY_SID"
EOF
    
    # 修复权限问题：确保所有用户（包括 nobody/sing-box 用户）可读
    chmod -R 755 /etc/sing-box
}
create_config

# -----------------------
# 配置并启动服务 (针对环境修复)
# -----------------------
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /var/log; checkpath --directory --mode 0755 /run; }
OPENRC
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || true
        rc-service sing-box restart
    else
        # 兼容性修复：覆盖 Service 文件，强制使用 Root 避免权限问题
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
After=network.target nss-lookup.target

[Service]
# [关键修复] 强制 Root 运行，解决权限和用户不存在问题
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD

        # 在容器中 daemon-reload 可能会失败，忽略它，不让脚本退出
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable sing-box >/dev/null 2>&1 || true
    fi
}
setup_service

# -----------------------
# 部署增强版 sb 管理脚本 (引入三级启动保障)
# -----------------------
SB_PATH="/usr/local/bin/sb"
cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*"; }

CACHE_FILE="/etc/sing-box/.config_cache"
CONFIG_PATH="/etc/sing-box/config.json"
LOG_FILE="/var/log/sing-box.log"

get_pid() {
    pgrep -x "sing-box" || echo ""
}

# --- 核心：多重启动机制 (Fix for US-BWG) ---
restart_service() {
    info "正在尝试重启服务..."
    
    # 0. 先清理
    killall sing-box >/dev/null 2>&1
    sleep 1

    # 1. 尝试 Systemd (标准)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop sing-box >/dev/null 2>&1
        systemctl start sing-box >/dev/null 2>&1
        sleep 2
        if [ -n "$(get_pid)" ]; then info "✅ Systemd 启动成功"; return; fi
    fi
    
    # 2. 尝试 Service (旧式)
    if command -v service >/dev/null 2>&1; then
        service sing-box start >/dev/null 2>&1
        sleep 2
        if [ -n "$(get_pid)" ]; then info "✅ Service 启动成功"; return; fi
    fi
    
    # 3. Alpine OpenRC
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box restart >/dev/null 2>&1
        sleep 2
        if [ -n "$(get_pid)" ]; then info "✅ OpenRC 启动成功"; return; fi
    fi

    # 4. [核弹级兜底] 强制 Nohup 后台运行
    warn "⚠️ 常规服务启动失败 (可能是容器环境)，尝试强制后台运行..."
    # 确保日志文件可写
    touch "$LOG_FILE" && chmod 666 "$LOG_FILE"
    nohup /usr/bin/sing-box run -c "$CONFIG_PATH" > "$LOG_FILE" 2>&1 &
    sleep 2
    
    if [ -n "$(get_pid)" ]; then
        info "✅ 强制启动成功! (PID: $(get_pid))"
        info "日志已重定向至: $LOG_FILE"
    else
        err "❌ 所有启动方式均失败。"
        err "请选择菜单中的 [5] 诊断模式 查看具体报错！"
    fi
}

# 查看日志功能 (自动判断日志位置)
view_logs() {
    echo ""
    info "正在获取最近 20 行日志..."
    echo "--------------------------------"
    
    has_logs=false
    
    # 1. 检查 nohup 日志 (兜底模式产生的)
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        echo ">>> 来自文件日志 ($LOG_FILE):"
        tail -n 20 "$LOG_FILE"
        has_logs=true
    fi

    # 2. 检查 systemd 日志
    if command -v journalctl >/dev/null 2>&1; then
        if ! journalctl -u sing-box --no-pager -n 1 2>&1 | grep -q "No entries"; then
            echo ">>> 来自 Systemd 日志:"
            journalctl -u sing-box --no-pager -n 20
            has_logs=true
        fi
    fi

    if [ "$has_logs" = false ]; then
        warn "暂无日志产生，服务可能从未启动成功。"
    fi
    echo "--------------------------------"
    read -p "按回车键返回菜单..."
}

# 诊断模式 (前台运行)
debug_mode() {
    echo ""
    warn "=== 进入诊断模式 ==="
    warn "程序将直接在前台运行，任何报错都会显示在屏幕上。"
    warn "按 Ctrl+C 可以退出诊断。"
    echo "Executing: /usr/bin/sing-box run -c $CONFIG_PATH"
    echo "------------------------------------------------"
    /usr/bin/sing-box run -c "$CONFIG_PATH"
    echo "------------------------------------------------"
    read -p "诊断结束。按回车返回..."
}

show_links() {
    if [ -f "$CACHE_FILE" ]; then
        source "$CACHE_FILE"
        suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
        PUB_IP=$(curl -s --max-time 4 "https://api64.ipify.org" || echo "YOUR_SERVER_IP")
        if [[ "$PUB_IP" == *":"* ]]; then PUB_IP="[$PUB_IP]"; fi
        
        echo ""
        info "📜 节点链接列表 (IP: $PUB_IP):"
        
        if [ "${ENABLE_SS:-false}" = "true" ]; then
            ss_info="2022-blake3-aes-128-gcm:${PSK_SS}"
            ss_b64=$(printf "%s" "$ss_info" | base64 | tr -d '\n')
            echo "   ss://${ss_b64}@${PUB_IP}:${PORT_SS}#ss${suffix}"
        fi
        if [ "${ENABLE_HY2:-false}" = "true" ]; then
            echo "   hy2://${PSK_HY2}@${PUB_IP}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        fi
        if [ "${ENABLE_TUIC:-false}" = "true" ]; then
            echo "   tuic://${UUID_TUIC}:${PSK_TUIC}@${PUB_IP}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        fi
        if [ "${ENABLE_REALITY:-false}" = "true" ]; then
            echo "   vless://${UUID}@${PUB_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=learn.microsoft.com&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        fi
        echo ""
        read -p "按回车键返回菜单..."
    else
        err "未找到配置缓存文件，无法生成链接。"
        read -p "按回车键返回菜单..."
    fi
}

uninstall_singbox() {
    echo ""
    read -p "⚠️ 确定要完全卸载 sing-box 吗？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消"
        return
    fi
    
    info "正在停止服务..."
    killall sing-box >/dev/null 2>&1
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable sing-box >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
    fi
    
    info "正在清理文件..."
    rm -rf /etc/sing-box
    rm -f /usr/bin/sing-box
    rm -f /usr/local/bin/sb
    rm -f /root/node_names.txt
    rm -f /var/log/sing-box.log
    
    info "✅ 卸载完成。"
    exit 0
}

show_menu() {
    clear
    echo "=============================="
    echo "   Sing-box 管理面板 (sb)   "
    echo "=============================="
    
    local pid=$(get_pid)
    if [ -n "$pid" ]; then
        echo -e " 运行状态: \033[1;32m运行中 (PID: $pid)\033[0m"
    else
        echo -e " 运行状态: \033[1;31m未运行\033[0m"
    fi
    
    echo "------------------------------"
    echo " 1) 查看节点链接"
    echo " 2) 重启服务 (及状态检查)"
    echo " 3) 查看运行日志 (排错用)"
    echo " 4) 编辑配置文件 (vi)"
    echo " 5) 诊断模式 (直接显示报错)"
    echo " 6) 卸载程序"
    echo " 0) 退出"
    echo "------------------------------"
}

while true; do
    show_menu
    read -p "请输入选项 [0-6]: " opt
    case "$opt" in
        1) show_links;;
        2) restart_service; read -p "按回车键继续..." ;;
        3) view_logs;;
        4) 
            ${EDITOR:-vi} "$CONFIG_PATH"
            read -p "配置已修改，是否重启服务生效? (y/n): " confirm
            if [[ "$confirm" == "y" ]]; then restart_service; fi
            ;;
        5) debug_mode;;
        6) uninstall_singbox;;
        0) exit 0;;
        *) echo "无效选项，请重试。"; sleep 1;;
    esac
done
SB_SCRIPT
chmod +x "$SB_PATH"

# -----------------------
# 输出与上报逻辑 (首次安装尝试启动)
# -----------------------
get_public_ip() { curl -s --max-time 5 "https://api64.ipify.org" || echo "YOUR_SERVER_IP"; }
PUB_IP=$(get_public_ip)

report_node() {
    local proto=$1
    local link=$2
    if [ -z "$REPORT_URL" ]; then return; fi
    info "☁️ 正在上报 [${proto}] 节点信息到服务器..."
    local node_name="${HOST_NAME:-Node}"
    local json_payload="{\"name\":\"${node_name}\", \"protocol\":\"${proto}\", \"link\":\"${link}\"}"
    curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$REPORT_URL" >/dev/null || warn "⚠️ 上报 [${proto}] 失败"
}

print_info() {
    local host="$PUB_IP"
    if [[ "$host" == *":"* ]]; then host="[$host]"; fi

    echo ""
    info "📜 节点链接列表:"
    
    if $ENABLE_SS; then
        local ss_info="2022-blake3-aes-128-gcm:${PSK_SS}"
        local ss_b64=$(printf "%s" "$ss_info" | base64 | tr -d '\n')
        local link="ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo "   $link"
        report_node "ss" "$link"
    fi
    
    if $ENABLE_HY2; then
        local link="hy2://${PSK_HY2}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        echo "   $link"
        report_node "hy2" "$link"
    fi
    if $ENABLE_TUIC; then
        local link="tuic://${UUID_TUIC}:${PSK_TUIC}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo "   $link"
        report_node "tuic" "$link"
    fi
    if $ENABLE_REALITY; then
        local link="vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=learn.microsoft.com&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo "   $link"
        report_node "vless" "$link"
    fi

    echo ""
    if [ -n "$REPORT_URL" ]; then
        info "✅ 节点自动上报已完成。"
    fi
}

# 首次安装尝试调用 sb 进行启动
info "正在尝试启动服务..."
/usr/local/bin/sb <<EOF
2
0
EOF

if pgrep -x "sing-box" >/dev/null; then
    print_info
else
    warn "服务似乎未启动，请运行 'sb' 并选择 '5) 诊断模式' 查看原因。"
fi

echo ""
info "🎉 安装完成! 输入 'sb' 可调用管理菜单。"