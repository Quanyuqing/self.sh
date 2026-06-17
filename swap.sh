#!/bin/bash

# ============================================================
# Swap 管理工具
# 仅管理 /swapfile，不会操作其他 Swap 分区、Swap 文件或 ZRAM
# ============================================================

SWAP_FILE="/swapfile"
SYSCTL_FILE="/etc/sysctl.d/99-swap.conf"

# ====================== 辅助函数 ======================

format_size() {
    local size_mb="$1"

    if [ "$size_mb" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1fGB\", $size_mb / 1024}"
    else
        echo "${size_mb}MB"
    fi
}

pause_menu() {
    echo ""
    read -r -p "👉 按回车键返回主菜单..."
}

check_dependencies() {
    local commands=(
        awk
        grep
        sed
        df
        free
        dd
        chmod
        mkswap
        swapon
        swapoff
        sysctl
    )

    local missing=0
    local cmd

    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "❌ 缺少必要命令：$cmd"
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        echo ""
        echo "请先安装缺少的软件包后再运行。"
        echo "Debian/Ubuntu 通常可以执行："
        echo "apt update && apt install -y util-linux procps coreutils"
        exit 1
    fi
}

get_physical_memory_mb() {
    awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo
}

get_recommended_swap_mb() {
    local mem_mb="$1"

    # 面向普通 VPS / Linux 服务器的通用推荐规则
    if [ "$mem_mb" -le 1024 ]; then
        echo 2048
    elif [ "$mem_mb" -le 2048 ]; then
        echo $((mem_mb * 2))
    elif [ "$mem_mb" -le 4096 ]; then
        echo "$mem_mb"
    elif [ "$mem_mb" -le 8192 ]; then
        echo 4096
    elif [ "$mem_mb" -le 16384 ]; then
        echo 4096
    elif [ "$mem_mb" -le 32768 ]; then
        echo 8192
    else
        echo 8192
    fi
}

get_root_available_mb() {
    df -Pk / | awk 'NR == 2 {print int($4 / 1024)}'
}

get_root_total_mb() {
    df -Pk / | awk 'NR == 2 {print int($2 / 1024)}'
}

get_reserved_space_mb() {
    local total_mb
    local ten_percent_mb
    local minimum_reserve_mb=1024

    total_mb=$(get_root_total_mb)
    ten_percent_mb=$((total_mb / 10))

    if [ "$ten_percent_mb" -gt "$minimum_reserve_mb" ]; then
        echo "$ten_percent_mb"
    else
        echo "$minimum_reserve_mb"
    fi
}

check_disk_space_mb() {
    local required_mb="$1"
    local avail_mb
    local reserve_mb
    local needed_mb

    avail_mb=$(get_root_available_mb)
    reserve_mb=$(get_reserved_space_mb)
    needed_mb=$((required_mb + reserve_mb))

    echo ""
    echo "📊 磁盘空间检查："
    echo "   当前可用：$(format_size "$avail_mb")"
    echo "   Swap 大小：$(format_size "$required_mb")"
    echo "   安全预留：$(format_size "$reserve_mb")"

    if [ "$avail_mb" -lt "$needed_mb" ]; then
        echo ""
        echo "❌ 磁盘空间不足。"
        echo "至少需要可用空间：$(format_size "$needed_mb")"
        echo "当前只有：$(format_size "$avail_mb")"
        return 1
    fi

    echo "✅ 磁盘空间充足"
    return 0
}

check_swapfile_safety() {
    if [ -L "$SWAP_FILE" ]; then
        echo "❌ 安全检查失败：$SWAP_FILE 是符号链接。"
        echo "为避免误删或覆盖其他文件，脚本已停止操作。"
        return 1
    fi

    if [ -e "$SWAP_FILE" ] && [ ! -f "$SWAP_FILE" ]; then
        echo "❌ 安全检查失败：$SWAP_FILE 不是普通文件。"
        echo "请手动检查后再操作。"
        return 1
    fi

    return 0
}

is_swapfile_active() {
    swapon --show=NAME --noheadings 2>/dev/null |
        awk '{$1=$1; print}' |
        grep -Fxq "$SWAP_FILE"
}

remove_swapfile_fstab_entry() {
    if [ ! -f /etc/fstab ]; then
        echo "⚠️  未找到 /etc/fstab"
        return 0
    fi

    sed -i -E '\|^[[:space:]]*/swapfile[[:space:]]+|d' /etc/fstab
}

add_swapfile_fstab_entry() {
    remove_swapfile_fstab_entry
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
}

# ====================== Swappiness ======================

set_swappiness() {
    local current_value
    local swappiness

    current_value=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 40)

    echo ""
    echo "【Swappiness 设置】"
    echo "📌 当前值：$current_value"
    echo ""
    echo "参考建议："
    echo "  10：尽量少使用 Swap"
    echo "  40：普通 VPS 推荐值"
    echo "  60：Linux 常见默认值"
    echo " 100：更积极使用 Swap"
    echo ""

    while true; do
        read -r -p "👉 请输入 Swappiness 值，直接回车使用 40： " swappiness

        if [ -z "$swappiness" ]; then
            swappiness=40
            break
        fi

        if [[ "$swappiness" =~ ^[0-9]+$ ]] &&
            [ "$swappiness" -ge 0 ] &&
            [ "$swappiness" -le 200 ]; then
            break
        fi

        echo "⚠️  请输入 0—200 之间的整数"
    done

    printf 'vm.swappiness=%s\n' "$swappiness" > "$SYSCTL_FILE"

    if ! sysctl -w "vm.swappiness=$swappiness" >/dev/null 2>&1; then
        echo "❌ Swappiness 临时设置失败"
        return 1
    fi

    echo "✅ Swappiness 已设置为：$swappiness"
    echo "✅ 持久化配置已写入：$SYSCTL_FILE"
}

# ====================== Swap 删除 ======================

remove_existing_swapfile() {
    if ! check_swapfile_safety; then
        return 1
    fi

    if is_swapfile_active; then
        echo "📴 正在禁用 $SWAP_FILE ..."

        if ! swapoff "$SWAP_FILE"; then
            echo "❌ 禁用 Swap 失败。"
            echo "可能是当前内存不足，系统无法把 Swap 中的数据迁回物理内存。"
            return 1
        fi

        echo "✅ Swap 已禁用"
    fi

    if [ -f "$SWAP_FILE" ]; then
        echo "🗑️  正在删除 $SWAP_FILE ..."

        if ! rm -f -- "$SWAP_FILE"; then
            echo "❌ 删除 $SWAP_FILE 失败"
            return 1
        fi

        echo "✅ Swap 文件已删除"
    else
        echo "ℹ️  未检测到 $SWAP_FILE"
    fi

    remove_swapfile_fstab_entry
    echo "✅ 已清理 /etc/fstab 中的 /swapfile 配置"

    return 0
}

# ====================== Swap 创建 ======================

create_swap_file() {
    local size_mb="$1"

    if ! check_swapfile_safety; then
        return 1
    fi

    echo ""
    echo "⚙️  正在创建 $(format_size "$size_mb") 的 Swap 文件..."
    echo "文件路径：$SWAP_FILE"

    if ! dd \
        if=/dev/zero \
        of="$SWAP_FILE" \
        bs=1M \
        count="$size_mb" \
        status=progress \
        conv=fsync; then

        echo ""
        echo "❌ 创建 Swap 文件失败，正在清理残留文件..."
        rm -f -- "$SWAP_FILE"
        return 1
    fi

    if ! chmod 600 "$SWAP_FILE"; then
        echo "❌ 设置 Swap 文件权限失败"
        rm -f -- "$SWAP_FILE"
        return 1
    fi

    if ! mkswap "$SWAP_FILE" >/dev/null; then
        echo "❌ 格式化 Swap 文件失败"
        rm -f -- "$SWAP_FILE"
        return 1
    fi

    if ! swapon "$SWAP_FILE"; then
        echo "❌ 启用 Swap 文件失败"
        rm -f -- "$SWAP_FILE"
        return 1
    fi

    add_swapfile_fstab_entry

    echo "✅ Swap 文件创建成功"
    echo "✅ Swap 已启用"
    echo "✅ 已配置开机自动启用"

    return 0
}

# ====================== 主功能 ======================

add_or_replace_swap() {
    local mem_mb
    local recommended_mb
    local size_mb
    local confirm

    echo ""
    echo "【添加或重新创建 Swap】"

    mem_mb=$(get_physical_memory_mb)
    recommended_mb=$(get_recommended_swap_mb "$mem_mb")

    echo ""
    echo "💡 当前物理内存：$(format_size "$mem_mb")"
    echo "💡 推荐 Swap 大小：$(format_size "$recommended_mb")"
    echo ""
    echo "推荐值仅供参考，你可以："
    echo "  1. 直接回车，使用推荐值"
    echo "  2. 输入自定义大小，单位为 MB"
    echo ""

    while true; do
        read -r -p "👉 Swap 大小 [默认 ${recommended_mb}MB]： " size_mb

        if [ -z "$size_mb" ]; then
            size_mb="$recommended_mb"
            echo "📌 已使用推荐值：$(format_size "$size_mb")"
            break
        fi

        if [[ "$size_mb" =~ ^[0-9]+$ ]] && [ "$size_mb" -gt 0 ]; then
            break
        fi

        echo "⚠️  请输入大于 0 的整数，单位为 MB"
    done

    if ! check_disk_space_mb "$size_mb"; then
        pause_menu
        return
    fi

    if [ -e "$SWAP_FILE" ] || is_swapfile_active; then
        echo ""
        echo "⚠️  检测到现有 $SWAP_FILE"
        echo "重新创建会先禁用并删除当前 /swapfile。"
        echo "其他 Swap 分区、Swap 文件和 ZRAM 不会受到影响。"
        echo ""

        read -r -p "确认替换现有 /swapfile？[Y/n]： " confirm

        if [ -n "$confirm" ] && [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "❌ 操作已取消"
            pause_menu
            return
        fi

        if ! remove_existing_swapfile; then
            pause_menu
            return
        fi
    fi

    if ! create_swap_file "$size_mb"; then
        pause_menu
        return
    fi

    if ! set_swappiness; then
        echo "⚠️  Swap 已成功创建，但 Swappiness 设置失败"
    fi

    echo ""
    echo "🎉 Swap 配置完成"
    echo "========================================"
    free -h
    echo "========================================"
    swapon --show
    echo "========================================"
    echo "当前 Swappiness：$(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo "========================================"

    pause_menu
}

remove_swap_only() {
    local confirm

    echo ""
    echo "【删除 /swapfile】"
    echo ""
    echo "本操作只会删除："
    echo "  $SWAP_FILE"
    echo "  /etc/fstab 中对应的 /swapfile 配置"
    echo ""
    echo "不会删除："
    echo "  其他 Swap 文件"
    echo "  Swap 磁盘分区"
    echo "  ZRAM"
    echo ""

    read -r -p "⚠️  确认删除 /swapfile？[Y/n]： " confirm

    if [ -z "$confirm" ] || [[ "$confirm" =~ ^[Yy]$ ]]; then
        if remove_existing_swapfile; then
            echo ""
            echo "✅ /swapfile 已完全移除"
        fi
    else
        echo ""
        echo "❌ 操作已取消"
    fi

    pause_menu
}

show_swap_status() {
    echo ""
    echo "【当前内存和 Swap 状态】"
    echo "========================================"
    free -h
    echo "========================================"

    if swapon --show | grep -q .; then
        swapon --show
    else
        echo "当前没有启用任何 Swap"
    fi

    echo "========================================"
    echo "Swappiness：$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 未知)"

    if [ -f "$SWAP_FILE" ]; then
        echo "/swapfile 状态：文件存在"
        echo "/swapfile 大小：$(du -h "$SWAP_FILE" 2>/dev/null | awk '{print $1}')"
    else
        echo "/swapfile 状态：不存在"
    fi

    echo "========================================"

    pause_menu
}

# ====================== 菜单系统 ======================

show_menu() {
    local choice

    clear

    cat <<'EOF'
=============================================
             Swap 管理工具
=============================================
1. 添加或重新创建 Swap
   推荐大小，可直接使用或自定义输入

2. 删除 /swapfile
   不影响其他 Swap 分区或 ZRAM

3. 查看当前 Swap 状态

4. 退出
=============================================
EOF

    read -r -p "👉 请选择操作 [1-4]： " choice

    case "$choice" in
        1)
            add_or_replace_swap
            ;;
        2)
            remove_swap_only
            ;;
        3)
            show_swap_status
            ;;
        4)
            echo ""
            echo "👋 已退出"
            exit 0
            ;;
        *)
            echo "⚠️  无效选项"
            sleep 1
            ;;
    esac
}

# ====================== 启动 ======================

main() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ 请使用 root 权限运行"
        echo "例如：sudo bash swap.sh"
        exit 1
    fi

    check_dependencies

    while true; do
        show_menu
    done
}

main