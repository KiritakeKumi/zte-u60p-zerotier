#!/bin/sh
Module_dir="/data/kano_plugins/zerotier"
BIN_NAME="zerotier-one"
BOOT_CMD="sh $Module_dir/service.sh start"
STOP_CMD="sh $Module_dir/service.sh stop"
FILE="/etc/rc.local"

# ZeroTier 静态 ARM64 二进制来源
#DOWNLOAD_URL="https://github.com/rafalb8/ZeroTierOne-Static/releases/download/1.16.0/zerotier-one-aarch64.tar.gz"
# 如遇github速度慢可选择下面的链接
DOWNLOAD_URL="https://niconiconi.us/zerotier-one-aarch64.tar.gz"

write_service_sh() {
    cat >"$Module_dir/service.sh" <<'EOF'
#!/bin/sh
# ZeroTier 守护脚本 (由安装脚本生成)

MODULE_DIR="/data/kano_plugins/zerotier"
BIN="$MODULE_DIR/zerotier-one"
CLI="$MODULE_DIR/zerotier-cli"
PID_FILE="$MODULE_DIR/zerotier-one.pid"
LOG_FILE="$MODULE_DIR/zerotier-one.log"
HOME_DIR="$MODULE_DIR/home"

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
    if is_running; then
        echo "ZeroTier 已在运行 (pid=$(cat "$PID_FILE"))"
        return 0
    fi
    if [ ! -x "$BIN" ]; then
        chmod 755 "$BIN" 2>/dev/null || true
    fi
    # 确保 home 目录存在（存放 identity 和 planet 等）
    mkdir -p "$HOME_DIR" 2>/dev/null
    cd "$MODULE_DIR" || exit 1
    nohup "$BIN" -d "$HOME_DIR" >>"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    sleep 2
    if is_running; then
        echo "ZeroTier 启动成功 (pid=$(cat "$PID_FILE"))"
        echo "提示: 使用 $CLI join <网络ID> 加入网络"
        # 自动加入上次保存的网络
        if [ -f "$MODULE_DIR/networks.list" ]; then
            while read -r netid; do
                [ -n "$netid" ] && "$CLI" join "$netid" 2>/dev/null
            done <"$MODULE_DIR/networks.list"
        fi
    else
        echo "ZeroTier 启动失败, 详见 $LOG_FILE"
        return 1
    fi
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE")"
        if kill "$PID" 2>/dev/null; then
            # 退出前保存已加入的网络列表
            if [ -x "$CLI" ]; then
                "$CLI" listnetworks 2>/dev/null | awk 'NR>1{print $3}' >"$MODULE_DIR/networks.list"
            fi
            echo "已停止 (pid=$PID)"
        fi
        rm -f "$PID_FILE"
    fi
    # 兜底:按进程名结束残留
    pkill -f "zerotier-one.*$HOME_DIR" 2>/dev/null || true
}

status() {
    if is_running; then
        echo "running (pid=$(cat "$PID_FILE"))"
        if [ -x "$CLI" ]; then
            echo "已加入的网络:"
            "$CLI" listnetworks 2>/dev/null
        fi
    else
        echo "stopped"
    fi
}

join() {
    if ! is_running; then
        echo "ZeroTier 未运行，请先启动"
        return 1
    fi
    if [ -z "$1" ]; then
        echo "用法: $0 join <网络ID>"
        return 1
    fi
    "$CLI" join "$1"
    echo "已发送加入请求: $1"
    # 保存到持久化列表
    echo "$1" >>"$MODULE_DIR/networks.list"
    sort -u "$MODULE_DIR/networks.list" -o "$MODULE_DIR/networks.list"
}

leave() {
    if ! is_running; then
        echo "ZeroTier 未运行，请先启动"
        return 1
    fi
    if [ -z "$1" ]; then
        echo "用法: $0 leave <网络ID>"
        return 1
    fi
    "$CLI" leave "$1"
    echo "已离开网络: $1"
    sed -i "/^$1$/d" "$MODULE_DIR/networks.list" 2>/dev/null
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    join)    join "$2" ;;
    leave)   leave "$2" ;;
    *) echo "用法: $0 {start|stop|restart|status|join <netid>|leave <netid>}"; exit 1 ;;
esac
EOF
    chmod 755 "$Module_dir/service.sh"
}

install() {
    # 确保目标目录存在
    mkdir -p "$Module_dir"

    echo "下载 ZeroTier One (ARM64 静态编译)..."
    if ! curl -fSL "$DOWNLOAD_URL" \
        --output "$Module_dir/zerotier-one-aarch64.tar.gz"; then
        echo "下载失败，请检查网络或链接"
        exit 1
    fi

    # 校验二进制是否就位
    if [ ! -f "$Module_dir/zerotier-one-aarch64.tar.gz" ]; then
        echo "未找到下载包，安装中止"
        exit 1
    fi

    echo "解压中..."
    if ! tar -zxvf "$Module_dir/zerotier-one-aarch64.tar.gz" -C "$Module_dir"; then
        echo "解压失败"
        rm -f "$Module_dir/zerotier-one-aarch64.tar.gz"
        exit 1
    fi

    rm -f "$Module_dir/zerotier-one-aarch64.tar.gz"
    [ -f "$Module_dir/$BIN_NAME" ] && chmod 755 "$Module_dir/$BIN_NAME"

    # zerotier-cli 是 zerotier-one 的别名（调用方式不同，行为不同）
    if [ -f "$Module_dir/$BIN_NAME" ] && [ ! -f "$Module_dir/zerotier-cli" ]; then
        ln -sf "$Module_dir/$BIN_NAME" "$Module_dir/zerotier-cli"
    fi

    # 生成/覆盖守护脚本
    write_service_sh

    # 确保 rc.local 存在
    if [ ! -f "$FILE" ]; then
        echo "没有找到 /etc/rc.local，插件不会开机自启"
    else
        echo "设置开机自启..."
        if grep -F "$BOOT_CMD" "$FILE" >/dev/null 2>&1; then
            echo "开机脚本已存在，无需重复添加"
        else
            sed -i "/^exit 0/i $BOOT_CMD" "$FILE"
            echo "已添加: $BOOT_CMD"
        fi
    fi

    # 启动
    echo "启动 ZeroTier 中..."
    $STOP_CMD
    if ! $BOOT_CMD; then
        echo "启动失败，请检查 $Module_dir/zerotier-one.log"
        exit 1
    fi

    sleep 3
    clear
    echo "ZeroTier 已安装并部署"
    echo "------------------------------------------"
    echo "快捷方式（务必记住）："
    echo "  启动服务    : $BOOT_CMD"
    echo "  停止服务    : $STOP_CMD"
    echo "  查看状态    : sh $Module_dir/service.sh status"
    echo "  加入网络    : sh $Module_dir/service.sh join <网络ID>"
    echo "  离开网络    : sh $Module_dir/service.sh leave <网络ID>"
    echo "  CLI 命令行  : $Module_dir/zerotier-cli"
    echo "  数据目录    : $Module_dir/home"
    echo "  日志文件    : $Module_dir/zerotier-one.log"
    echo "------------------------------------------"
    echo "注意: 加入网络后需要在 ZeroTier Central 面板批准"
    echo "      https://my.zerotier.com/"
}

remove() {
    clear
    # 停止
    if ! $STOP_CMD 2>/dev/null; then
        echo "停止失败或服务未运行"
    fi

    # 删除 rc.local 中的相关行（用 | 作分隔符）
    if [ -f "$FILE" ]; then
        sed -i "\|$BOOT_CMD|d" "$FILE"
    fi

    # 删除目录
    rm -rf "$Module_dir"

    echo "卸载完成"
    echo "注意: ZeroTier Central 上仍需手动删除该设备"
}

check_is_installed() {
    if [ ! -f "$Module_dir/service.sh" ] || [ ! -f "$Module_dir/$BIN_NAME" ]; then
        echo "未检测到 ZeroTier，请先安装"
        exit 1
    fi
}

start() {
    check_is_installed
    $BOOT_CMD
}

stop() {
    check_is_installed
    $STOP_CMD
}

join_network() {
    check_is_installed
    read -rp "请输入要加入的网络 ID (16位): " netid </dev/tty
    if [ -n "$netid" ]; then
        sh "$Module_dir/service.sh" join "$netid"
    fi
}

leave_network() {
    check_is_installed
    sh "$Module_dir/service.sh" status
    echo
    read -rp "请输入要离开的网络 ID: " netid </dev/tty
    if [ -n "$netid" ]; then
        sh "$Module_dir/service.sh" leave "$netid"
    fi
}

while true; do
    clear
    echo "======================================"
    echo "       ZeroTier(虚拟局域网) 管理脚本"
    echo "--------------------------------------"
    echo "  Author : nico"
    echo "  Version: 1.0.0"
    echo "  Date   : 2026-06-12"
    echo "--------------------------------------"
    echo "  1) 安装 (install)"
    echo "  2) 卸载 (remove)"
    echo "  3) 启动 (start)"
    echo "  4) 停止 (stop)"
    echo "  5) 加入网络 (join)"
    echo "  6) 离开网络 (leave)"
    echo "  7) 查看状态 (status)"
    echo "  0) 退出 (exit)"
    echo "======================================"
    echo
    read -rp "请输入选择 [0-7]: " choice </dev/tty

    case "$choice" in
        1)
            install
            read -rp "按回车键继续..." dummy </dev/tty
            ;;
        2)
            remove
            read -rp "按回车键继续..." dummy </dev/tty
            ;;
        3)
            start
            read -rp "按回车键继续..." dummy </dev/tty
            ;;
        4)
            stop
            read -rp "按回车键继续..." dummy </dev/tty
            ;;
        5)
            join_network
            read -rp "按回车键继续..." dummy </dev/tty
            ;;
        6)
            leave_network
            read -rp "按回车键继续..." dummy </dev/tty
            ;;
        7)
            check_is_installed
            sh "$Module_dir/service.sh" status
            read -rp "按回车键继续..." dummy </dev/tty
            ;;
        0)
            echo "已退出"
            exit 0
            ;;
        *)
            echo "无效的选择，请输入 0-7"
            sleep 1
            ;;
    esac
done
