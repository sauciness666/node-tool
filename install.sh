#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------
# 全局变量定义
# ---------------------------------------------------------
INSTALL_DIR="$HOME/nodetool"
BINARY_NAME="NodeTool"
SERVICE_NAME="nodetool"
PORT=5000
LOG_FILE="$INSTALL_DIR/server.log"

# --- GitHub 配置 ---
REPO_OWNER="konxinhaos"               # 项目所属用户
REPO_NAME="node-tool"              # 仓库名称
# ---------------------

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}      NodeTool 安装/更新脚本                  ${NC}"
echo -e "${GREEN}=============================================${NC}"

# 检查当前用户是否有 root 权限或 sudo 命令
CMD_PREFIX=""
if [ "$EUID" -ne 0 ] && command -v sudo &> /dev/null; then
    CMD_PREFIX="sudo"
fi

# ---------------------------------------------------------
# 辅助函数：识别系统架构并设置变量
# ---------------------------------------------------------
function set_architecture_vars() {
    # 检查系统架构
    ARCH=$(uname -m)

    # 将 uname 的输出映射到压缩包命名规则
    case "$ARCH" in
        "x86_64" | "amd64")
            export TOOL_ARCH="amd64"
            ;;
        "aarch64" | "arm64" | "armv8")
            export TOOL_ARCH="arm64"
            ;;
        *)
            echo -e "${RED}错误: 不支持的系统架构 '$ARCH'。${NC}"
            echo "当前脚本仅支持 amd64 (x86_64) 和 arm64 (aarch64)。"
            exit 1
            ;;
    esac

    # 定义基础文件名
    BASE_ASSET_NAME="NodeTool-Linux"
    
    # 最终的压缩包文件名将是：NodeTool-Linux-amd64.zip 或 NodeTool-Linux-arm64.zip
    export ASSET_NAME="${BASE_ASSET_NAME}-${TOOL_ARCH}.zip"

    echo -e "✅ 系统架构: ${CYAN}$ARCH${NC}"
}

# 获取相应架构的最新 Release 下载链接
function get_latest_release_url() {
    # 1. 尝试请求 "Latest" (仅返回正式版)
    API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" 
    RELEASE_INFO=$(curl -s $API_URL)
    
    # 2. 回退机制：如果找不到 Latest，获取所有发布列表并取第一个
    if echo "$RELEASE_INFO" | grep -q "Not Found" || [ "$(echo "$RELEASE_INFO" | jq -r .tag_name)" == "null" ]; then
        echo -e "${YELLOW}提示: 未找到 'Latest' 正式版，尝试获取最新发布的版本列表...${NC}" >&2
        API_URL_ALL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases"
        # 获取列表并取第一个元素 [0]
        RELEASE_INFO=$(curl -s $API_URL_ALL | jq '.[0]')
    fi
    
    # 3. 再次检查是否成功
    if echo "$RELEASE_INFO" | grep -q "Not Found" || [ "$(echo "$RELEASE_INFO" | jq -r .tag_name)" == "null" ]; then
        echo -e "${RED}错误: GitHub 仓库 $REPO_OWNER/$REPO_NAME 未找到或无任何 Release (包括预发布版)。${NC}" >&2
        exit 1
    fi
    
    # 使用 jq 解析 JSON，提取动态生成的 $ASSET_NAME 对应的链接
    LATEST_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name == \"$ASSET_NAME\") | .browser_download_url")

    if [ -z "$LATEST_URL" ] || [ "$LATEST_URL" == "null" ]; then
        # 提示用户具体缺失的是哪个架构包
        echo -e "${RED}错误: 未能在版本 [$(echo "$RELEASE_INFO" | jq -r .tag_name)] 中找到名为 '$ASSET_NAME' 的附件。${NC}" >&2
        echo "架构需求: $TOOL_ARCH" >&2
        echo "请检查 Release 中是否存在该架构的压缩包。" >&2
        exit 1
    fi
    
    # 输出提示信息到 stderr (>&2)，防止污染返回值
    echo -e "${YELLOW}--- 正在从 GitHub Releases 获取下载链接 ---${NC}" >&2
    echo -e "✅ 成功获取版本链接！" >&2
    echo -e "版本: $(echo "$RELEASE_INFO" | jq -r .tag_name)" >&2
    echo -e "下载链接: ${CYAN}$LATEST_URL${NC}" >&2
    
    # 唯一输出到 stdout 的内容：URL
    echo "$LATEST_URL"
}

# ---------------------------------------------------------
# 辅助函数：核心文件处理逻辑 (区分安装和更新)
# ---------------------------------------------------------
function perform_file_operations() {
    local MODE="$1" # 接收模式参数: "install" 或 "update"
    local TEMP_DIR="$INSTALL_DIR/temp_update" 

    # 1. 获取下载链接
    DOWNLOAD_URL=$(get_latest_release_url)

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}错误: 无法获取下载链接。${NC}"
        return 1
    fi

    # 2. 下载到临时目录
    echo -e "${YELLOW}--- 正在下载文件到临时目录...${NC}"
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || return 1
    rm -f package.zip

    # 使用 curl 进行静默、带重试、失败即返回非零的下载
    curl -L --retry 3 --fail -o package.zip "$DOWNLOAD_URL" > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败。请检查网络连接或 GitHub API 限制。${NC}"
        cd "$INSTALL_DIR" || cd "$HOME" # 安全返回
        rm -rf "$TEMP_DIR"
        return 1
    fi

    # 3. 解压
    echo -e "${YELLOW}--- 正在解压文件...${NC}"
    unzip -o package.zip > /dev/null
    
    # 查找二进制文件以确定解压后的根目录结构
    FOUND_BIN=$(find . -name "$BINARY_NAME" -type f | head -n 1)

    if [ -z "$FOUND_BIN" ]; then
        echo -e "${RED}错误: 在压缩包中未找到二进制文件 '$BINARY_NAME'。${NC}"
        cd "$INSTALL_DIR" || cd "$HOME"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # 确定源文件所在的目录 (可能是 . 或者某个子目录)
    SOURCE_ROOT=$(dirname "$FOUND_BIN")

    # 4. 根据模式执行移动操作
    echo -e "${YELLOW}--- 正在部署文件 (模式: ${CYAN}$MODE${YELLOW})...${NC}"
    
    # 停止服务 (如果服务已配置)
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        echo -e "${CYAN}停止 NodeTool 服务...${NC}"
        $CMD_PREFIX systemctl stop $SERVICE_NAME > /dev/null 2>&1
    fi
    # 强制杀进程确保干净更新
    pkill -f "./$BINARY_NAME" > /dev/null 2>&1

    if [ "$MODE" == "install" ]; then
        # === 安装模式：移动所有文件 ===
        echo -e "执行全新安装，移动所有文件..."
        
        # 确保安装目录存在
        mkdir -p "$INSTALL_DIR"
        
        # 将源目录下的所有内容移动到安装目录
        # cp -r 覆盖移动
        cp -rf "$SOURCE_ROOT"/* "$INSTALL_DIR/"
        
    elif [ "$MODE" == "update" ]; then
        # === 更新模式：只替换二进制文件 ===
        echo -e "执行更新，仅替换二进制文件..."
        
        # 移动新的二进制文件覆盖旧的
        cp -f "$TEMP_DIR/$FOUND_BIN" "$INSTALL_DIR/$BINARY_NAME"
        
        # 可选：如果未来有其他必须更新的静态资源 (如 web 资源)，可以在这里添加
        # 例如: cp -rf "$SOURCE_ROOT/static" "$INSTALL_DIR/"
        
    else
        echo -e "${RED}内部错误: 未知的操作模式 '$MODE'${NC}"
        cd "$INSTALL_DIR" || cd "$HOME"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    # 设置权限
    chmod +x "$INSTALL_DIR/$BINARY_NAME"
    
    # 5. 清理
    cd "$INSTALL_DIR" || cd "$HOME"
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}🎉 文件部署完成。${NC}"

    return 0
}


# ---------------------------------------------------------
# 辅助函数：检查并卸载旧版本 (Clean Install)
# ---------------------------------------------------------
function check_and_uninstall_if_exists() {
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local CONTROL_SCRIPT_PATH="/usr/local/bin/nt"

    if [ -f "$SERVICE_FILE" ] || [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}--- 检测到 NodeTool 已安装 ---${NC}"
        read -r -p "是否要完全卸载旧版本并重新安装？(这将删除所有旧文件和数据库) [y/N] " response
        
        if [[ "$response" =~ ^([yY])$ ]]; then
            echo -e "${RED}执行完全卸载...${NC}"
            
            # 停止和禁用服务
            $CMD_PREFIX systemctl stop $SERVICE_NAME 2>/dev/null
            $CMD_PREFIX systemctl disable $SERVICE_NAME 2>/dev/null
            $CMD_PREFIX rm -f $SERVICE_FILE 2>/dev/null
            $CMD_PREFIX systemctl daemon-reload 2>/dev/null
            
            # 删除安装目录
            rm -rf $INSTALL_DIR
            
            # 删除控制命令
            $CMD_PREFIX rm -f $CONTROL_SCRIPT_PATH
            
            echo -e "${GREEN}🎉 旧版本已彻底卸载。${NC}"
            
        else
            echo -e "${CYAN}取消卸载。退出脚本。${NC}"
            exit 0
        fi
    fi
}


# ---------------------------------------------------------
# 辅助函数：安装 nt 控制脚本 (增强版：兼容 Systemd/Nohup)
# ---------------------------------------------------------
function install_control_script() {
    # 定义控制脚本路径
    local CONTROL_SCRIPT_PATH="/usr/local/bin/nt"
    # 使用 heredoc 创建 nt 脚本内容
    cat <<'NT_SCRIPT_EOF' | $CMD_PREFIX tee $CONTROL_SCRIPT_PATH > /dev/null
#!/bin/bash

# NodeTool 服务控制脚本
SERVICE_NAME="nodetool"
INSTALL_DIR="$HOME/nodetool"
START_SCRIPT="$INSTALL_DIR/start.sh"
LOG_FILE="$INSTALL_DIR/server.log"
# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查是否使用 sudo
if [ "$EUID" -ne 0 ] && command -v sudo &> /dev/null; then
    CMD_PREFIX="sudo"
else
    CMD_PREFIX=""
fi

# 显示服务状态
function show_status() {
    echo -e "\n${CYAN}--- ${SERVICE_NAME} 运行状态概览 ---${NC}"
    # 直接检查进程是否存在，这是最准确的
    if pgrep -f "NodeTool" > /dev/null; then
        echo -e "状态: ${GREEN}● 正在运行${NC}"
        # 尝试显示监听端口
        if command -v netstat &> /dev/null; then
             PORT=$(netstat -tuln | grep ":5000" | head -1)
             if [ -n "$PORT" ]; then echo -e "监听: ${GREEN}端口 5000${NC}"; fi
        fi
    else
        echo -e "状态: ${RED}○ 已停止${NC}"
    fi
    echo -e "日志查看: ${CYAN}nt log${NC}"
    echo "----------------------------------"
}

# 停止服务：尝试所有方法
function stop_service() {
    echo -e "${CYAN}正在停止服务...${NC}"
    # 1. 尝试 Systemd 停止
    if command -v systemctl &> /dev/null; then
        $CMD_PREFIX systemctl stop $SERVICE_NAME >/dev/null 2>&1
    fi
    
    # 2. 强制 Kill 进程 (防止 Nohup 启动的进程残留)
    pkill -f "NodeTool" >/dev/null 2>&1
    
    sleep 1
    show_status
}

# 启动服务：智能回退
function start_service() {
    echo -e "${CYAN}正在启动服务...${NC}"
    
    # 1. 优先尝试 Systemd
    if command -v systemctl &> /dev/null; then
        $CMD_PREFIX systemctl start $SERVICE_NAME >/dev/null 2>&1
    fi
    
    sleep 2
    
    # 2. 检查启动结果
    if ! pgrep -f "NodeTool" > /dev/null; then
        echo -e "${YELLOW}Systemd 启动无响应，切换到直接启动模式...${NC}"
        
        if [ -f "$START_SCRIPT" ]; then
            $CMD_PREFIX bash "$START_SCRIPT"
            sleep 2
            
            if pgrep -f "NodeTool" > /dev/null; then
                 echo -e "${GREEN}✅ 已通过后台模式启动成功。${NC}"
            else
                 echo -e "${RED}❌ 启动失败。请检查日志。${NC}"
            fi
        else
            echo -e "${RED}错误: 找不到启动脚本 $START_SCRIPT${NC}"
        fi
    fi
    
    show_status
}

# 卸载功能
function uninstall() {
    read -r -p "警告：您确定要彻底卸载 NodeTool 吗？(这将删除服务和安装目录：$INSTALL_DIR) [y/N] " response
    if [[ "$response" =~ ^([yY])$ ]]; then
        echo -e "${YELLOW}停止并禁用服务...${NC}"
        stop_service # 使用增强的停止函数
        
        if command -v systemctl &> /dev/null; then
            $CMD_PREFIX systemctl disable $SERVICE_NAME > /dev/null 2>&1
            $CMD_PREFIX rm -f /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null
            $CMD_PREFIX systemctl daemon-reload > /dev/null 2>&1
        fi
        
        echo -e "${YELLOW}删除安装目录 $INSTALL_DIR...${NC}"
        rm -rf $INSTALL_DIR
        
        echo -e "${YELLOW}删除控制命令 'nt'...${NC}"
        $CMD_PREFIX rm -f "/usr/local/bin/nt"
        
        echo -e "${GREEN}🎉 NodeTool 已彻底卸载。${NC}"
        exit 0
    else
        echo -e "${CYAN}取消卸载。${NC}"
    fi
}

# 核心更新功能
function update() {
    INSTALL_SCRIPT="$HOME/install.sh" 
    
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo -e "${RED}错误: 未找到主安装脚本 $INSTALL_SCRIPT，无法执行核心更新。${NC}"
        echo "请确保 install.sh 文件在您的 $HOME 目录下。"
        return 1
    fi
    
    echo -e "${CYAN}执行核心更新流程...${NC}"
    
    # 传入 "core-update" 参数触发 install.sh 的更新逻辑
    $CMD_PREFIX bash "$INSTALL_SCRIPT" "core-update"
    
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}重新启动 NodeTool 服务...${NC}"
        start_service # 使用增强的启动函数
    else
        echo -e "${RED}更新失败，请检查 $INSTALL_SCRIPT 脚本的输出。${NC}"
    fi
}


# ---------------------------------------------------------
# 主控制逻辑
# ---------------------------------------------------------
if [ -z "$1" ]; then
    while true; do
        echo -e "\n${GREEN}--- NodeTool 控制台 ---${NC}"
        echo -e "1) ${CYAN}查看状态 (status)${NC}"
        echo -e "2) ${CYAN}启动服务 (start)${NC}"
        echo -e "3) ${CYAN}重启服务 (restart)${NC}"
        echo -e "4) ${CYAN}停止服务 (stop)${NC}"
        echo -e "5) ${CYAN}更新程序 (update)${NC}"
        echo -e "6) ${RED}查看日志 (log)${NC}"
        echo -e "7) ${RED}完全卸载 (uninstall)${NC}"
        echo -e "0) ${YELLOW}退出面板${NC}"
        read -r -p "请输入选项 [0-7]: " choice
        
        case "$choice" in
            1) show_status ;;
            2) start_service ;;
            3) stop_service; start_service ;;
            4) stop_service ;;
            5) update ;;
            6)
                echo -e "${CYAN}--- NodeTool 实时日志 (Ctrl+C 退出) ---${NC}"
                tail -f "$LOG_FILE"
                ;;
            7) uninstall; break ;;
            0) echo -e "${CYAN}退出控制面板。${NC}"; break ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}" ;;
        esac
    done
else
    case "$1" in
        start) start_service ;;
        stop) stop_service ;;
        restart) stop_service; start_service ;;
        status) show_status ;;
        update) update ;;
        log)
            echo -e "${CYAN}--- NodeTool 实时日志 (Ctrl+C 退出) ---${NC}"
            tail -f "$LOG_FILE"
            ;;
        uninstall) uninstall ;;
        *)
            echo -e "${RED}NodeTool 控制台${NC}"
            echo -e "${CYAN}用法: nt [start | stop | restart | status | update | log | uninstall]${NC}"
            ;;
    esac
fi
NT_SCRIPT_EOF

    # 赋予执行权限
    $CMD_PREFIX chmod +x $CONTROL_SCRIPT_PATH
    echo -e "✅ 'nt' 命令已安装到 $CONTROL_SCRIPT_PATH"
}


# ---------------------------------------------------------
# 辅助函数：运行完整的流程 (依赖检查 -> 下载/安装)
# ---------------------------------------------------------
function run_full_install_flow() {
    local OPERATION_MODE="$1" # "install" 或 "update"

    echo -e "${YELLOW} 检查系统环境...${NC}"
    DEPENDENCIES=("unzip" "curl" "wget" "pgrep" "jq" "timeout") 
    INSTALL_TIMEOUT=120

    for cmd in "${DEPENDENCIES[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}未找到 '$cmd'，正在安装...${NC}"
            INSTALL_SUCCESS=0
            INSTALL_CMD=""
            
            if [ -x "$(command -v apt-get)" ]; then
                $CMD_PREFIX apt-get update > /dev/null 2>&1
                INSTALL_CMD="$CMD_PREFIX apt-get install -y $cmd"
            elif [ -x "$(command -v yum)" ]; then
                INSTALL_CMD="$CMD_PREFIX yum install -y $cmd"
            fi
            
            if [ -n "$INSTALL_CMD" ]; then
                if command -v timeout &> /dev/null; then
                    timeout $INSTALL_TIMEOUT $INSTALL_CMD > /dev/null 2>&1
                    INSTALL_SUCCESS=$?
                else
                    $INSTALL_CMD > /dev/null 2>&1
                    INSTALL_SUCCESS=$?
                fi
            else
                INSTALL_SUCCESS=1
            fi
            
            if [ $INSTALL_SUCCESS -eq 124 ]; then
                echo -e "${RED}❌ 错误: '$cmd' 安装超时。${NC}"
                exit 1
            elif [ $INSTALL_SUCCESS -ne 0 ]; then
                echo -e "${RED}❌ 错误: 无法自动安装 '$cmd'。${NC}"
                exit 1
            fi
            echo -e "✅ '$cmd' 安装成功。"
        fi
    done
    
    # 执行文件操作 (传入模式参数)
    perform_file_operations "$OPERATION_MODE"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}文件部署失败，退出。${NC}"
        exit 1
    fi
}


# ---------------------------------------------------------
# 主脚本开始
# ---------------------------------------------------------

# 调用架构识别函数
set_architecture_vars

# 1. 判断是否为更新模式
if [ "$1" == "core-update" ]; then
    echo -e "${YELLOW}识别到更新模式，跳过卸载检查...${NC}"
    # 传递 "update" 模式给处理函数
    run_full_install_flow "update"
    exit 0
fi

# 2. 正常安装模式
# 检查并卸载旧版本
check_and_uninstall_if_exists

# 传递 "install" 模式给处理函数
run_full_install_flow "install"

# 3. 配置 Systemd 和控制脚本 (仅在安装模式下继续执行)
echo -e "${YELLOW} 正在设置自启与控制脚本...${NC}"
ABS_DIR=$(cd "$INSTALL_DIR" && pwd)
CURRENT_USER=$(whoami)

# 清理旧日志
rm -f "$LOG_FILE"

# nt 面板和 fallback 逻辑都将共用此脚本，确保启动方式一致
START_SCRIPT="$INSTALL_DIR/start.sh"
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
cd "$ABS_DIR"
# 强制切断 stdin (< /dev/null)，防止 nohup 在 Docker 中挂起
# 合并 stdout 和 stderr 到日志文件
nohup ./$BINARY_NAME > "$LOG_FILE" 2>&1 < /dev/null &
echo \$! > app.pid
EOF
chmod +x "$START_SCRIPT"

# 这样 Systemd 和 Nohup 使用完全相同的启动命令，减少差异带来的 Bug
cat <<EOF > ${SERVICE_NAME}.service
[Unit]
Description=NodeTool Web Service
After=network.target

[Service]
Type=forking
User=$CURRENT_USER
ExecStart=$START_SCRIPT
PIDFile=$INSTALL_DIR/app.pid
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 如果有 root/sudo 权限，安装服务
if [ -n "$CMD_PREFIX" ] || [ "$EUID" -eq 0 ]; then
    # 安装服务
    $CMD_PREFIX mv ${SERVICE_NAME}.service /etc/systemd/system/${SERVICE_NAME}.service
    $CMD_PREFIX systemctl daemon-reload > /dev/null 2>&1
    $CMD_PREFIX systemctl enable ${SERVICE_NAME} > /dev/null 2>&1
    
    echo "尝试通过 Systemd 启动服务..."
    $CMD_PREFIX systemctl restart ${SERVICE_NAME} 
fi

# 安装 nt 面板
install_control_script

# 回退检测
echo "正在验证服务状态..."
sleep 3

if pgrep -f "./$BINARY_NAME" > /dev/null; then
    echo -e "✅ 服务通过 Systemd 启动成功！"
else
    echo -e "${YELLOW}⚠️ Systemd 启动失败 (常见于 Docker/容器 环境)。${NC}"
    echo -e "${YELLOW}👉 正在尝试自动切换到 Nohup 后台模式启动...${NC}"
    
    # 停止可能卡住的服务
    $CMD_PREFIX systemctl stop ${SERVICE_NAME} >/dev/null 2>&1
    
    # 强制使用 start.sh 启动
    bash "$START_SCRIPT"
    sleep 3
    
    if pgrep -f "./$BINARY_NAME" > /dev/null; then
        echo -e "✅ 服务已通过后台模式 (Nohup) 成功启动！"
    else
        echo -e "${RED}❌ 启动失败。${NC}"
        echo -e "依赖库检查:"
        ldd "$INSTALL_DIR/$BINARY_NAME"
        echo -e "请尝试手动运行: cd $INSTALL_DIR && ./$BINARY_NAME"
        exit 1
    fi
fi

# 最终总结
IP=$(curl -s ifconfig.me)
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}🎉 NodeTool 正在运行！${NC}"
echo -e "---------------------------------------------"
echo -e "管理命令: ${CYAN}nt [start|stop|restart|status|update|log]${NC}"
echo -e "日志查看: ${CYAN}tail -f $LOG_FILE${NC}" 
echo -e "公网地址:   ${YELLOW}http://$IP:$PORT${NC}"
echo -e "${GREEN}=============================================${NC}"