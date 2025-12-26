#!/usr/bin/env bash
# ============================================================================
# 文件: deploy.sh
# 描述: 发布控制脚本，用于同步文件到远程服务器
# 作者: lujian <lujian0571@gmail.com>
# GitHub: https://github.com/lujian0571
# ============================================================================
# 设置脚本执行选项
# -e: 遇到错误时退出
# -u: 使用未定义变量时退出
# -o pipefail: 管道中任何命令失败时退出
set -euo pipefail

#######################################
# 基本参数
#######################################

# 脚本所在目录的绝对路径
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# rsync 排除文件列表
IGNORE_FILE="$BASE_DIR/rsync_ignore.txt"

#######################################
# 全局变量
#######################################
# 是否自动确认部署（跳过确认提示）
ARF_YES_FLAG=false
# 执行部署参数标记，带-d，-1表示未设置，0表示已设置但未激活，1表示激活
ARG_D_FLAG=-1
# 脚本参数标记，带-s，-1表示未设置，0表示已设置但未激活，1表示激活
ARG_S_FLAG=-1

# 环境相关变量
ENVS=()          # 环境目录名列表
ENVS_DISPLAY=()  # 环境显示名列表（目录名 → NAME）
SELECTED_ENV=""  # 当前选择的环境

# 远程执行相关变量
SCRIPTS=()            # 远程脚本列表
REMOTE_SCRIPT=""      # 选择的远程 shell 脚本
REMOTE_SCRIPT_ARGS="" # 远程脚本的参数

# 服务器相关变量
SERVER_LIST=()       # 解析出的服务器列表
SERVER_SELECTED=""   # 选中的服务器字符串

# 服务器连接参数
SERVER_NAME=""     # 服务器别名（可选）
SERVER_IP=""       # 服务器 IP
SERVER_PORT=""     # SSH 端口
USERNAME="root"    # SSH 用户名

# 特殊规则：如果第一个参数不是以-开头（即不是选项），则将其视为环境参数
if [[ $# -gt 0 && "$1" != -* ]]; then
    SELECTED_ENV="$1"
    shift
fi

# 显示脚本使用帮助信息
function usage() {
   echo "Usage: $(basename "$0") [env] [options]"
   echo "Options:"
   echo "  -h, --help                 显示帮助信息"
   #
   echo "  -e, --env <env>            指定环境"
   echo "  -m, --machine <machine>    指定服务器"
   #
   echo "  -d, --deploy               部署"
   echo "  -y, --yes                  部署确认"
   #
   echo "  -s, --script <script>      指定远程脚本"
   echo "  --script-args <args>       远程脚本参数"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -y|--yes)
            # 设置自动确认标志，跳过部署确认提示
            ARF_YES_FLAG=true
            shift 1
            ;;
        -e|--env)
            # 解析环境参数
            if [[ -n "${2:-}" && "$2" != -* ]]; then
                SELECTED_ENV="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        -m|--machine)
            # 解析服务器参数
            if [[ -n "${2:-}" && "$2" != -* ]]; then
                SERVER_SELECTED="$2"
                shift 2
            else
                die "未指定服务器"
            fi
            ;;
        -d|--deploy)
            # 设置部署标志
            [ $ARG_S_FLAG == -1 ] && ARG_S_FLAG=0
            ARG_D_FLAG=1
            shift 1
            ;;
        -s|--script)
            # 设置远程脚本标志
            [ $ARG_D_FLAG == -1 ] && ARG_D_FLAG=0
            ARG_S_FLAG=1
            if [[ -n "${2:-}" && "$2" != -* ]]; then
                REMOTE_SCRIPT="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --script-args)
            # 解析远程脚本参数
            if [[ -n "${2:-}" ]]; then
                REMOTE_SCRIPT_ARGS="$2"
                shift 2
            else
                shift 1
            fi
        ;;
        *)
            echo "❌ 不支持的参数: $1"
            usage
            exit 1
            ;;
    esac
done

#######################################
# 输出函数
#######################################
# 定义颜色变量
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
GRAY="\033[37;2m"       # 淡色/灰色
TITLE_COLOR="\033[32m"  # 标题绿色
CONTENT_COLOR="\033[33m"  # 内容黄色

# 正常信息输出
info() { echo -e "${GREEN}$*${RESET}"; }
# 警告信息输出
warn() { echo -e "${YELLOW}$*${RESET}"; }
# 错误退出
die()  { warn "ERROR: $*"; exit 1; }

# 是否开启调试
DEBUG="${DEBUG:-0}"
# 调试信息输出
debug() {
      if [ "$DEBUG" -eq 1 ]; then
          echo "DEBUG: $*"
      fi
}

#######################################
# 公共函数
#######################################

# 提示用户输入并返回输入值
# 参数: $1 - 提示信息，$2 - 提示颜色
prompt_input() {
    local message="${1:-请输入序号或字符进行匹配（/ 重置列表）:}"  # 默认提示语
    local color="${2:-$YELLOW}"
    local input
    # 显示带颜色的提示并读取用户输入
    read -r -p "$(echo -e "${color}${message}${RESET} ")" input
    input="${input// /}"  # 移除输入中的所有空格
    echo "$input"
}

# 打印格式化的表格，支持带序号的项目列表
# 参数: $1 - 表格标题，其余参数为表格项（格式: 左侧→右侧）
print_table() {
    local title="$1"
    shift
    [ -n "$title" ] && info "$title"

    local left=() right=()
    local max_left=0

    # 第一遍计算左侧列内容与最大宽度
    for item in "$@"; do
        if [[ "$item" == *"→"* ]]; then
            local l="${item%%→*}"
            local r="${item#*→}"
            l="${l// /}"
            r="${r#"${r%%[! ]*}"}"
            left+=("$l")
            right+=("$r")
            (( ${#l} > max_left )) && max_left=${#l}
        else
            left+=("$item")
            right+=("")
        fi
    done

    # 第二遍输出
    for i in "${!left[@]}"; do
        if [ -n "${right[$i]}" ]; then
            printf "  ${YELLOW}[%d]${RESET} %-*s ${GRAY}→${RESET} %s\n" "$((i+1))" "$max_left" "${left[$i]}" "${right[$i]}"
        else
            printf "  ${YELLOW}[%d]${RESET} %s\n" "$((i+1))" "${left[$i]}"
        fi
    done
}

# 根据关键词过滤列表
# 参数: $1 - 过滤关键词, $2 - 源环境数组名(使用nameref)
filter_table() {
    local keyword="$1"
    local -n _src="$2"
    local result=()

    # 小写关键字用于忽略大小写匹配
    local kw_lc="${keyword,,}"

    for env in "${_src[@]}"; do
        local str_lc="${env,,}"  # 小写环境名
        if [[ "$str_lc" == *"$kw_lc"* ]]; then
            result+=("$env")
        fi
    done

    # 输出非空元素
    for r in "${result[@]}"; do
        [ -n "$r" ] && printf '%s\n' "$r"
    done
}

# 通用列表选择函数
# 参数:
#   $1 - 标题
#   $2 - 原始选项数组名（src_list）
#   $3 - 显示名称数组名（display_list，可选）
#   $4 - 初始输入（可选）
select_from_list() {
    local title="$1"
    local -n src_list="$2"
    local -n display_list="${3:-src_list}"
    local initial="${4:-}"

    local input="$initial"
    local candidates=("${src_list[@]}")  # 初始候选列表
    local tmp_display=("${display_list[@]}")  # 初始显示列表

    show_candidates() {
        print_table "$title" "${tmp_display[@]}"
    }

    while true; do
        [ -z "$input" ] && show_candidates && input=$(prompt_input)

        case "$input" in
            ""|"/")
                candidates=("${src_list[@]}")
                tmp_display=("${display_list[@]}")
                input=""
                continue
                ;;
            q) die "已取消" ;;
        esac

        # 先处理序号选择
        if [[ "$input" =~ ^[0-9]+$ ]] && ((input >=1 && input <= ${#candidates[@]})); then
            SELECTED_ITEM="${candidates[$((input-1))]}"
            return
        fi

        # 基于上一次候选列表模糊匹配
        mapfile -t filtered < <(filter_table "$input" candidates)

        if [ "${#filtered[@]}" -eq 0 ]; then
            warn "未匹配到选项($input)，请重新输入"
            input=""
            continue
        fi

        # 匹配到结果，更新 candidates 和 tmp_display
        candidates=("${filtered[@]}")
        tmp_display=()
        for val in "${candidates[@]}"; do
            for i in "${!src_list[@]}"; do
                [[ "${src_list[$i]}" == "$val" ]] && tmp_display+=("${display_list[$i]}") && break
            done
        done

        # 如果只剩一个候选，直接选择
        if [ "${#candidates[@]}" -eq 1 ]; then
            SELECTED_ITEM="${candidates[0]}"
            return
        fi
        input=""
    done
}

#######################################
# 功能函数
#######################################

# 收集所有包含.env文件的环境目录
collect_envs() {
    ENVS=()
    ENVS_DISPLAY=()
    debug "当前目录 $(pwd)"

    for f in "$BASE_DIR"/*/.env; do
        [ -f "$f" ] || continue

        local env_dir env_name env_display name_value
        env_dir="$(dirname "$f")"
        env_name="${env_dir##*/}"
        env_display="$env_name"

        # 使用 grep 提取 NAME 的值，忽略注释和空行
        name_value=$(grep -E '^[[:space:]]*NAME=' "$f" | sed -E 's/^[[:space:]]*NAME=//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')
        # 如果有值则更新显示名称
        [ -n "$name_value" ] && env_display="$env_name → $name_value"

        ENVS+=("$env_name")
        ENVS_DISPLAY+=("$env_display")
    done

    [ "${#ENVS[@]}" -gt 0 ] || die "未发现任何可用环境"
}


# 选择环境
select_env() {
    collect_envs
    select_from_list "环境列表：" ENVS ENVS_DISPLAY "$SELECTED_ENV"
    SELECTED_ENV="$SELECTED_ITEM"
}

# 确认是否继续执行同步操作
confirm_or_exit() {
    local ans
    # 提示用户确认是否执行真实同步
    ans=$(prompt_input "确认执行真实同步？输入 y/yes 继续，其它退出: ")
    # 检查输入是否为y或yes（使用${ans,,}转换为小写）
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "已取消"
}

# 收集指定目录和公共目录下的shell脚本
# 参数: $1 - 环境目录路径
collect_shell_scripts() {
    local dir="$1"  # 传入的环境目录
    # 定义脚本目录列表：环境目录下的shell和公共shell目录
    local script_dirs=("$dir/shell" "$BASE_DIR/common/shell")
    local all_scripts=()  # 存储所有找到的脚本
    local file rel_path base_len

    # 遍历脚本目录
    for sd in "${script_dirs[@]}"; do
        [ -d "$sd" ] || continue  # 如果目录不存在则跳过
        base_len=${#sd}  # 记录目录路径长度

        # 使用find命令查找所有.sh文件，以null分隔避免文件名包含特殊字符的问题
        while IFS= read -r -d '' file; do
            # 计算相对于shell目录的路径
            rel_path="shell/${file:$base_len+1}"
            all_scripts+=("$rel_path")  # 添加到脚本列表
        done < <(find "$sd" -type f -name "*.sh" -print0)
    done

    # 如果没有找到脚本则返回错误
    [ "${#all_scripts[@]}" -gt 0 ] || return 1
    # 对脚本列表去重并排序，存储到全局变量SCRIPTS
    # shellcheck disable=SC2034
    mapfile -t SCRIPTS < <(printf '%s\n' "${all_scripts[@]}" | sort -u)
}

# 交互式选择要远程执行的shell脚本
# 参数: $1 - 环境目录路径
execute_remote_script() {
    local dir="$1"
    collect_shell_scripts "$dir" || return
    select_from_list "可执行脚本列表：" SCRIPTS SCRIPTS "$REMOTE_SCRIPT"
    REMOTE_SCRIPT="$SELECTED_ITEM"
}

# 解析服务器字符串，提取服务器名、用户名、IP、端口等信息
# 参数: $1 - 服务器字符串，格式为 [name-][user@]host[:port]
parse_server() {
    local server_str="$1"
    SERVER_NAME=""        # 重置服务器名
    SERVER_IP=""          # 重置服务器IP
    SERVER_PORT="22"      # 重置并设置默认端口为22
    USERNAME="root"       # 重置并设置默认用户名为root

    # 使用正则表达式解析服务器字符串
    # 格式: [name-][user@]host[:port]
    if [[ "$server_str" =~ ^(([a-zA-Z0-9_-]+)-)?(([a-zA-Z0-9_-]+)@)?([a-zA-Z0-9.-]+)(:([0-9]+))?$ ]]; then
        # BASH_REMATCH[2]: 服务器别名部分
        [[ -n "${BASH_REMATCH[2]}" ]] && SERVER_NAME="${BASH_REMATCH[2]}"
        # BASH_REMATCH[4]: 用户名部分
        [[ -n "${BASH_REMATCH[4]}" ]] && USERNAME="${BASH_REMATCH[4]}"
        # BASH_REMATCH[5]: IP地址部分
        SERVER_IP="${BASH_REMATCH[5]}"
        # BASH_REMATCH[7]: 端口号部分
        [[ -n "${BASH_REMATCH[7]}" ]] && SERVER_PORT="${BASH_REMATCH[7]}"
    else
        # 如果无法解析，输出警告并返回错误
        warn "无法解析服务器配置: $server_str"
        return 1
    fi

    # 输出解析结果的调试信息
    debug "解析服务器: ${USERNAME}@${SERVER_IP}:${SERVER_PORT}${SERVER_NAME:+ ($SERVER_NAME)}"
}

# 选择并解析目标服务器
select_server() {
    local env="$SELECTED_ENV"
    local dir="$BASE_DIR/$env"
    local env_file="$dir/.env"
    [ -f "$env_file" ] || die ".env 不存在: $env"
    unset IP PORT USERNAME TARGET_DIR NAME SERVER_LIST SERVER_NAME SERVER_IP SERVER_PORT INIT_SCRIPT
    # shellcheck disable=SC1090
    source "$env_file"
    : "${IP:?IP 未配置}"
    PORT="${PORT:-22}"
    TARGET_DIR="${TARGET_DIR:-/opt/install}"
    IFS=',' read -ra SERVER_LIST <<< "$IP"

    if [ "${#SERVER_LIST[@]}" -gt 1 ]; then
        select_from_list "目标服务器列表：" SERVER_LIST SERVER_LIST "$SERVER_SELECTED"
        SERVER_SELECTED="$SELECTED_ITEM"
    else
        SERVER_SELECTED="${SERVER_LIST[0]}"
    fi
    parse_server "$SERVER_SELECTED"
}

# 执行rsync同步操作
# 参数: $1 - 是否为dry-run模式（"true"表示预览，其他值表示实际同步）
run_rsync() {
    local dry_run="${1:-false}"  # 默认为非dry-run模式
    # 定义rsync选项
    # -a: 归档模式，保持文件属性
    # -v: 详细输出
    # -z: 压缩传输
    # -i: 显示同步过程中的变化
    # -P: 显示进度并保留部分传输
    # --delete: 删除目标中源不存在的文件
    # --no-perms: 不保留权限
    # --no-owner: 不保留所有者
    # --no-group: 不保留组
    local rsync_opts=(-avziP --delete --no-perms --no-owner --no-group --exclude-from="$IGNORE_FILE" -e "ssh -p $SERVER_PORT")

    # 定义源目录：当前环境目录和公共目录
    local src_dirs=("$dir/" "$BASE_DIR/common/")
    # 定义目标：远程服务器和目录
    local dest="${USERNAME}@${SERVER_IP}:${TARGET_DIR}/"

    # 如果是dry-run模式，只预览将要执行的操作
    if [[ "$dry_run" == "true" ]]; then
        rsync "${rsync_opts[@]}" --dry-run "${src_dirs[@]}" "$dest" | tee /dev/tty
        return
    fi

    # 执行实际的rsync同步
    rsync "${rsync_opts[@]}" "${src_dirs[@]}" "$dest"
}

# 在远程服务器上执行脚本
# 参数: $1 - 脚本路径, $2 - 脚本参数
remote_execute_script() {
    local script_path="$1"      # 远程脚本路径
    local script_args="${2:-}"  # 脚本参数，默认为空

    [ -z "$script_path" ] && return  # 如果脚本路径为空则返回

    # 构建远程脚本的完整路径
    local remote_path="${TARGET_DIR}/${script_path}"
    warn ">>> 远程执行脚本: $remote_path ${script_args}"  # 输出执行信息
    # 通过SSH执行远程脚本
    ssh -t -p "$SERVER_PORT" "${USERNAME}@${SERVER_IP}" "bash $remote_path $script_args"
    info ">>> 脚本执行完成"  # 输出完成信息
}

# 发布文件到远程服务器
publish_files() {
    # 检查是否设置了部署标志，如果没有则返回
    [ "$ARG_D_FLAG" -eq 0 ] && return

    local env="$SELECTED_ENV"  # 当前环境
    local dir="$BASE_DIR/$env"  # 环境目录

    # 获取环境的显示名称
    local display_name="$env"
    for i in "${!ENVS[@]}"; do
        [[ "${ENVS[$i]}" == "$env" ]] && display_name="${ENVS_DISPLAY[$i]}" && break
    done

    # 打印发布信息，显示当前操作的详细信息
    echo -e "${GRAY}=======================================${RESET}"
    echo -e "${TITLE_COLOR}发布环境:${RESET} ${CONTENT_COLOR}$display_name${RESET}"
    if [ -n "$SERVER_NAME" ]; then
        # 如果有服务器别名，显示别名
        echo -e "${TITLE_COLOR}目标主机:${RESET} ${CONTENT_COLOR}${USERNAME}@${SERVER_IP}:${SERVER_PORT} ($SERVER_NAME)${RESET}"
    else
        # 否则只显示基本连接信息
        echo -e "${TITLE_COLOR}目标主机:${RESET} ${CONTENT_COLOR}${USERNAME}@${SERVER_IP}:${SERVER_PORT}${RESET}"
    fi
    echo -e "${TITLE_COLOR}目标目录:${RESET} ${CONTENT_COLOR}$TARGET_DIR${RESET}"
    echo -e "${GRAY}=======================================${RESET}"

    # 运行dry-run模式获取将要同步的文件列表
    DRY_OUTPUT=$(run_rsync true)
    # 检查dry-run输出是否包含文件变更（><c分别表示：传输、删除、变更）
    if echo "$DRY_OUTPUT" | grep -q '^[><c]'; then
        # 如果设置了自动确认标志则跳过确认，否则要求用户确认
        $ARF_YES_FLAG || confirm_or_exit
        warn ">>> rsync 正式同步"  # 提示开始正式同步
        run_rsync false  # 执行实际的同步操作

        # 如果定义了初始化脚本，则在远程执行
        [ -n "${INIT_SCRIPT:-}" ] && remote_execute_script "$INIT_SCRIPT"
    else
        warn ">>> 没有文件变动，跳过同步确认"  # 没有文件需要同步
    fi
}


# 执行远程脚本
execute_remote() {
    # 检查是否设置了远程执行标志，如果没有则返回
    [ "$ARG_S_FLAG" -eq 0 ] && return

    local env="$SELECTED_ENV"  # 当前环境
    local dir="$BASE_DIR/$env"  # 环境目录
    execute_remote_script "$dir"  # 选择并执行远程脚本
    # 如果已指定远程脚本，则执行该脚本并传递参数
    [ -n "$REMOTE_SCRIPT" ] && remote_execute_script "$REMOTE_SCRIPT" "$REMOTE_SCRIPT_ARGS"
}

#######################################
# 主入口
#######################################
# 脚本主函数，按顺序执行各个步骤
main() {
    select_env      # 选择部署环境
    select_server   # 选择目标服务器
    publish_files   # 发布文件到远程服务器
    execute_remote  # 执行远程脚本
}

main  # 调用主函数启动脚本
