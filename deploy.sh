#!/bin/bash

# CIAO-CORS 一键部署和管理脚本
# 支持安装、配置、监控、更新、卸载等完整功能
# 版本: 1.3.1
# 作者: bestZwei
# 项目: https://github.com/bestZwei/ciao-cors

# ==================== 全局变量 ====================
SCRIPT_VERSION="1.3.1"
PROJECT_NAME="ciao-cors"
DEFAULT_PORT=3000
INSTALL_DIR="/opt/ciao-cors"
SERVICE_NAME="ciao-cors"
CONFIG_FILE="/etc/ciao-cors/config.env"
LOG_FILE="/var/log/ciao-cors.log"
GITHUB_REPO="https://raw.githubusercontent.com/bestZwei/ciao-cors/main"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BACKUP_DIR="/opt/ciao-cors/backups"
LOCK_FILE="/var/lock/ciao-cors-deploy.lock"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 错误退出码定义
EXIT_SUCCESS=0
EXIT_GENERAL_ERROR=1
EXIT_PERMISSION_ERROR=2
EXIT_NETWORK_ERROR=3
EXIT_CONFIG_ERROR=4
EXIT_SERVICE_ERROR=5

# ==================== 基础功能函数 ====================

# 安全检查函数
security_check() {
    print_status "info" "执行安全检查..."

    # 检查是否在容器中运行
    if [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        print_status "warning" "检测到容器环境，某些安全功能可能受限"
    fi

    # 检查SELinux状态
    if command -v getenforce &> /dev/null; then
        local selinux_status=$(getenforce 2>/dev/null)
        if [[ "$selinux_status" == "Enforcing" ]]; then
            print_status "info" "SELinux已启用 (Enforcing模式)"
        elif [[ "$selinux_status" == "Permissive" ]]; then
            print_status "warning" "SELinux处于Permissive模式"
        else
            print_status "info" "SELinux已禁用"
        fi
    fi

    # 检查AppArmor状态
    if command -v aa-status &> /dev/null; then
        if aa-status --enabled 2>/dev/null; then
            print_status "info" "AppArmor已启用"
        else
            print_status "info" "AppArmor未启用"
        fi
    fi

    # 检查系统更新状态
    local updates_available=false
    if command -v apt &> /dev/null; then
        if apt list --upgradable 2>/dev/null | grep -q upgradable; then
            updates_available=true
        fi
    elif command -v yum &> /dev/null; then
        if yum check-update &>/dev/null; then
            updates_available=true
        fi
    fi

    if [[ "$updates_available" == "true" ]]; then
        print_status "warning" "系统有可用更新，建议先更新系统"
        read -p "是否现在更新系统? (y/N): " update_system
        if [[ "$update_system" =~ ^[Yy]$ ]]; then
            if command -v apt &> /dev/null; then
                apt update && apt upgrade -y
            elif command -v yum &> /dev/null; then
                yum update -y
            fi
        fi
    fi

    print_status "success" "安全检查完成"
}

# 显示彩色输出
print_status() {
    local type=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $type in
        "info")    echo -e "${BLUE}[INFO]${NC} [$timestamp] $message" ;;
        "success") echo -e "${GREEN}[SUCCESS]${NC} [$timestamp] $message" ;;
        "warning") echo -e "${YELLOW}[WARNING]${NC} [$timestamp] $message" ;;
        "error")   echo -e "${RED}[ERROR]${NC} [$timestamp] $message" ;;
        "title")   echo -e "${PURPLE}$message${NC}" ;;
        "cyan")    echo -e "${CYAN}$message${NC}" ;;
    esac

    # 同时写入日志文件（如果存在）
    if [[ -w "$(dirname "$LOG_FILE")" ]] 2>/dev/null; then
        echo "[$timestamp] [$type] $message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# 显示分割线
print_separator() {
    echo -e "${CYAN}=====================================================${NC}"
}

# 创建锁文件防止并发执行
create_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            print_status "error" "脚本已在运行中 (PID: $lock_pid)"
            exit $EXIT_GENERAL_ERROR
        else
            print_status "warning" "发现过期锁文件，正在清理..."
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_status "error" "此脚本需要root权限运行，请使用 sudo"
        exit $EXIT_PERMISSION_ERROR
    fi
}

# 检查网络连接
check_network() {
    print_status "info" "检查网络连接..."

    # 首先尝试 curl 方式检查（更可靠）
    local test_urls=("https://raw.githubusercontent.com" "https://github.com" "https://deno.land")
    local network_ok=false

    for url in "${test_urls[@]}"; do
        if timeout 15 curl -s --connect-timeout 10 --max-time 10 --head "$url" &>/dev/null; then
            network_ok=true
            print_status "success" "网络连接正常 (通过 $url)"
            break
        fi
    done

    # 如果 curl 失败，尝试 ping
    if [[ "$network_ok" == "false" ]]; then
        local ping_urls=("8.8.8.8" "1.1.1.1" "github.com")
        for url in "${ping_urls[@]}"; do
            if ping -c 1 -W 5 "$url" &>/dev/null 2>&1; then
                network_ok=true
                print_status "success" "网络连接正常 (通过 ping $url)"
                break
            fi
        done
    fi

    if [[ "$network_ok" != "true" ]]; then
        print_status "error" "网络连接失败，请检查网络设置"
        print_status "info" "请确保可以访问 GitHub 和相关服务"
        return $EXIT_NETWORK_ERROR
    fi

    return $EXIT_SUCCESS
}

# 检查系统要求
check_requirements() {
  print_status "info" "检查系统要求..."

  # 检查网络连接
  check_network || return $EXIT_NETWORK_ERROR

  # 检查Linux发行版
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    print_status "info" "检测到操作系统: $NAME $VERSION_ID"

    # 检查支持的发行版
    case "$ID" in
      ubuntu|debian|centos|rhel|fedora|rocky|almalinux)
        print_status "success" "支持的操作系统"
        ;;
      *)
        print_status "warning" "未测试的操作系统，可能存在兼容性问题"
        read -p "是否继续? (y/N): " continue_install
        if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
          print_status "error" "安装取消"
          return $EXIT_GENERAL_ERROR
        fi
        ;;
    esac
  else
    print_status "warning" "未能识别操作系统类型，将尝试继续安装"
  fi

  # 检查系统架构
  local arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      print_status "success" "支持的系统架构: $arch"
      ;;
    aarch64|arm64)
      print_status "info" "ARM64架构，将使用对应的Deno版本"
      ;;
    *)
      print_status "error" "不支持的系统架构: $arch"
      return $EXIT_GENERAL_ERROR
      ;;
  esac

  # 检查基本命令并安装
  local required_commands=("curl" "wget" "systemctl")
  local optional_commands=("ss" "netstat" "lsof")
  local missing_commands=()
  local missing_optional=()

  for cmd in "${required_commands[@]}"; do
      if ! command -v "$cmd" &> /dev/null; then
          missing_commands+=("$cmd")
      fi
  done

  for cmd in "${optional_commands[@]}"; do
      if ! command -v "$cmd" &> /dev/null; then
          missing_optional+=("$cmd")
      fi
  done

  if [[ ${#missing_commands[@]} -gt 0 ]]; then
      print_status "warning" "缺少必要命令: ${missing_commands[*]}"
      print_status "info" "尝试自动安装..."

      if command -v yum &> /dev/null; then
          yum update -y || print_status "warning" "yum update失败，继续安装"
          yum install -y curl wget || {
              print_status "error" "无法安装必要软件包"
              return $EXIT_GENERAL_ERROR
          }
      elif command -v apt &> /dev/null; then
          apt update || print_status "warning" "apt update失败，继续安装"
          apt install -y curl wget || {
              print_status "error" "无法安装必要软件包"
              return $EXIT_GENERAL_ERROR
          }
      elif command -v dnf &> /dev/null; then
          dnf install -y curl wget || {
              print_status "error" "无法安装必要软件包"
              return $EXIT_GENERAL_ERROR
          }
      else
          print_status "error" "未找到支持的包管理器，请手动安装: ${missing_commands[*]}"
          return $EXIT_GENERAL_ERROR
      fi
  fi

  # 安装可选的网络工具
  if [[ ${#missing_optional[@]} -gt 0 ]]; then
      print_status "info" "缺少网络工具: ${missing_optional[*]}"
      read -p "是否安装这些工具以获得更好的监控体验? (Y/n): " install_optional
      install_optional=${install_optional:-Y}

      if [[ "$install_optional" =~ ^[Yy]$ ]]; then
          if command -v yum &> /dev/null; then
              # RHEL/CentOS系列
              yum install -y net-tools iproute lsof || print_status "warning" "部分网络工具安装失败"
          elif command -v apt &> /dev/null; then
              # Debian/Ubuntu系列
              apt install -y net-tools iproute2 lsof || print_status "warning" "部分网络工具安装失败"
          elif command -v dnf &> /dev/null; then
              # Fedora系列
              dnf install -y net-tools iproute lsof || print_status "warning" "部分网络工具安装失败"
          fi
          print_status "success" "网络工具安装完成"
      else
          print_status "info" "跳过网络工具安装，部分监控功能可能受限"
      fi
  fi



  # 检查防火墙工具
  if ! command -v firewall-cmd &> /dev/null && ! command -v ufw &> /dev/null && ! command -v iptables &> /dev/null; then
      print_status "warning" "未找到防火墙管理工具，尝试安装firewalld..."
      if command -v yum &> /dev/null; then
          yum install -y firewalld 2>/dev/null && systemctl enable firewalld 2>/dev/null || print_status "warning" "firewalld安装失败"
      elif command -v apt &> /dev/null; then
          apt install -y firewalld 2>/dev/null && systemctl enable firewalld 2>/dev/null || print_status "warning" "firewalld安装失败"
      elif command -v dnf &> /dev/null; then
          dnf install -y firewalld 2>/dev/null && systemctl enable firewalld 2>/dev/null || print_status "warning" "firewalld安装失败"
      fi
  fi

  # 检查磁盘空间
  local free_space=$(df -m / | awk 'NR==2 {print $4}')
  if [[ $free_space -lt 100 ]]; then
    print_status "warning" "可用磁盘空间不足 100MB (当前: ${free_space}MB)"
    read -p "是否继续? (y/N): " continue_install
    if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
      print_status "error" "安装取消"
      return $EXIT_GENERAL_ERROR
    fi
  else
    print_status "success" "磁盘空间充足 (${free_space}MB)"
  fi

  # 检查内存
  local mem_total=$(free -m | awk '/^Mem:/{print $2}')
  if [[ $mem_total -lt 256 ]]; then
    print_status "warning" "内存不足 256MB (当前: ${mem_total}MB)，可能影响性能"
  else
    print_status "success" "内存充足 (${mem_total}MB)"
  fi

  print_status "success" "系统要求检查完成"
  return $EXIT_SUCCESS
}

# 检查Deno安装状态
check_deno_installation() {
    if command -v deno &> /dev/null; then
        local version=$(deno --version 2>/dev/null | head -n 1 | awk '{print $2}')
        if [[ -n "$version" ]]; then
            print_status "success" "Deno已安装 (版本: $version)"

            # 检查版本是否过旧
            local major_version=$(echo "$version" | cut -d. -f1)
            if [[ "$major_version" -lt 1 ]]; then
                print_status "warning" "Deno版本过旧 ($version)，建议更新到最新版本"
                read -p "是否更新Deno? (Y/n): " update_deno
                if [[ ! "$update_deno" =~ ^[Nn]$ ]]; then
                    return 1  # 触发重新安装
                fi
            fi
            return 0
        else
            print_status "warning" "Deno命令存在但无法获取版本信息"
            return 1
        fi
    else
        print_status "warning" "Deno未安装"
        return 1
    fi
}

# ==================== 安装和配置函数 ====================

# 安装Deno
install_deno() {
  print_status "info" "开始安装Deno..."

  # 检查依赖
  local deps=("curl" "unzip")
  for dep in "${deps[@]}"; do
    if ! command -v $dep &> /dev/null; then
      print_status "info" "安装依赖: $dep"
      if command -v apt &> /dev/null; then
        apt update && apt install -y $dep || {
          print_status "error" "安装依赖 $dep 失败"
          return $EXIT_GENERAL_ERROR
        }
      elif command -v yum &> /dev/null; then
        yum install -y $dep || {
          print_status "error" "安装依赖 $dep 失败"
          return $EXIT_GENERAL_ERROR
        }
      elif command -v dnf &> /dev/null; then
        dnf install -y $dep || {
          print_status "error" "安装依赖 $dep 失败"
          return $EXIT_GENERAL_ERROR
        }
      else
        print_status "error" "无法安装依赖 $dep，请手动安装"
        return $EXIT_GENERAL_ERROR
      fi
    fi
  done

  # 检测系统架构
  local arch=$(uname -m)
  local deno_arch=""
  case "$arch" in
    x86_64|amd64)
      deno_arch="x86_64-unknown-linux-gnu"
      ;;
    aarch64|arm64)
      deno_arch="aarch64-unknown-linux-gnu"
      ;;
    *)
      print_status "error" "不支持的系统架构: $arch"
      return $EXIT_GENERAL_ERROR
      ;;
  esac

  # 创建安装目录
  local deno_install_dir="/usr/local/deno"
  mkdir -p "$deno_install_dir"

  # 尝试使用官方安装脚本
  print_status "info" "使用官方安装脚本..."
  print_status "info" "正在下载和安装Deno，这可能需要几分钟时间，请耐心等待..."

  # 创建临时文件来监控进度
  local progress_file=$(mktemp)
  local install_log=$(mktemp)

  # 在后台运行安装脚本并监控进度
  (
    timeout 300 bash -c "curl -fsSL https://deno.land/x/install/install.sh | DENO_INSTALL='$deno_install_dir' sh" > "$install_log" 2>&1
    echo $? > "$progress_file"
  ) &

  local install_pid=$!
  local dots=0

  # 显示进度点
  while kill -0 $install_pid 2>/dev/null; do
    sleep 5
    dots=$((dots + 1))
    case $((dots % 4)) in
      1) echo -n "." ;;
      2) echo -n ".." ;;
      3) echo -n "..." ;;
      0) echo -ne "\r正在安装Deno    \r正在安装Deno" ;;
    esac
  done

  wait $install_pid
  local exit_code=$(cat "$progress_file" 2>/dev/null || echo "1")

  echo  # 换行

  if [[ "$exit_code" -eq 0 ]]; then
    print_status "success" "官方安装脚本执行成功"
    rm -f "$progress_file" "$install_log"
  else
    print_status "warning" "官方安装脚本失败，尝试手动安装..."
    # 显示错误日志（如果有的话）
    if [[ -s "$install_log" ]]; then
      print_status "debug" "安装日志: $(tail -3 "$install_log" | tr '\n' ' ')"
    fi
    rm -f "$progress_file" "$install_log"

    # 手动下载安装
    local download_url="https://github.com/denoland/deno/releases/latest/download/deno-${deno_arch}.zip"
    local temp_file=$(mktemp --suffix=.zip)

    print_status "info" "下载Deno二进制文件..."
    print_status "info" "下载地址: $download_url"
    print_status "info" "正在下载，请稍候..."

    # 使用curl显示进度
    if timeout 300 curl -L --connect-timeout 30 --max-time 180 --retry 3 --retry-delay 10 \
       --progress-bar "$download_url" -o "$temp_file" 2>/dev/null; then
      print_status "success" "下载完成"

      # 验证下载的文件
      if [[ ! -s "$temp_file" ]]; then
        print_status "error" "下载的文件为空"
        rm -f "$temp_file"
        return $EXIT_NETWORK_ERROR
      fi

      # 检查文件大小是否合理（Deno二进制文件通常大于10MB）
      local file_size=$(stat -c%s "$temp_file" 2>/dev/null || wc -c < "$temp_file")
      if [[ $file_size -lt 10485760 ]]; then  # 小于10MB
        print_status "error" "下载的文件大小异常 (${file_size} bytes)"
        rm -f "$temp_file"
        return $EXIT_NETWORK_ERROR
      fi
    else
      print_status "error" "下载失败，请检查网络连接"
      rm -f "$temp_file"
      return $EXIT_NETWORK_ERROR
    fi

    # 解压安装
    if unzip -o "$temp_file" -d "$deno_install_dir" 2>/dev/null; then
      print_status "success" "解压完成"
      rm -f "$temp_file"

      # 验证安装
      if [[ ! -f "$deno_install_dir/deno" ]]; then
        print_status "error" "Deno二进制文件未找到"
        return $EXIT_GENERAL_ERROR
      fi
    else
      print_status "error" "解压失败"
      rm -f "$temp_file"
      return $EXIT_GENERAL_ERROR
    fi
  fi

  # 设置权限和创建符号链接
  chmod +x "$deno_install_dir/deno" 2>/dev/null || chmod +x "$deno_install_dir/bin/deno"

  # 创建全局链接
  if [[ -f "$deno_install_dir/deno" ]]; then
    ln -sf "$deno_install_dir/deno" /usr/local/bin/deno
  elif [[ -f "$deno_install_dir/bin/deno" ]]; then
    ln -sf "$deno_install_dir/bin/deno" /usr/local/bin/deno
  else
    print_status "error" "找不到Deno可执行文件"
    return $EXIT_GENERAL_ERROR
  fi

  # 验证安装
  if command -v deno &> /dev/null; then
    local version=$(deno --version 2>/dev/null | head -n 1 | awk '{print $2}')
    if [[ -n "$version" ]]; then
      print_status "success" "Deno安装成功 (版本: $version)"
      return $EXIT_SUCCESS
    else
      print_status "error" "Deno安装后无法获取版本信息"
      return $EXIT_GENERAL_ERROR
    fi
  else
    print_status "error" "Deno安装失败，命令不可用"
    return $EXIT_GENERAL_ERROR
  fi
}

# 下载或更新项目文件
download_project() {
    print_status "info" "下载项目文件..."

    # 创建安装目录和备份目录
    mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"

    # 备份现有文件
    if [[ -f "$INSTALL_DIR/server.ts" ]]; then
        local backup_file="$BACKUP_DIR/server.ts.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$INSTALL_DIR/server.ts" "$backup_file"
        print_status "info" "已备份现有文件到: $backup_file"
    fi

    cd "$INSTALL_DIR" || {
        print_status "error" "无法进入安装目录: $INSTALL_DIR"
        return $EXIT_GENERAL_ERROR
    }

    # 下载主文件，增加重试机制和安全验证
    local max_retries=3
    local retry_count=0
    local expected_min_size=10240  # 最小10KB
    local expected_max_size=2097152  # 最大2MB

    while [[ $retry_count -lt $max_retries ]]; do
        print_status "info" "尝试下载项目文件 (第 $((retry_count + 1)) 次)..."

        # 增加更严格的安全检查和错误处理
        if timeout 180 curl -fsSL --connect-timeout 30 --max-time 120 --retry 2 --retry-delay 5 \
           --user-agent "CIAO-CORS-Deploy/1.3.1" --fail --location \
           "$GITHUB_REPO/server.ts" -o server.ts.tmp 2>/dev/null; then
            # 验证下载的文件
            if [[ -s server.ts.tmp ]]; then
                # 检查文件大小是否合理
                local file_size=$(stat -c%s server.ts.tmp 2>/dev/null || wc -c < server.ts.tmp)
                if [[ $file_size -gt $expected_min_size ]] && [[ $file_size -lt $expected_max_size ]]; then
                    # 检查文件头部是否包含预期的注释
                    if head -10 server.ts.tmp | grep -q "CIAO-CORS"; then
                        # 检查是否包含关键函数和结构
                        if grep -q "class CiaoCorsServer" server.ts.tmp && \
                           grep -q "export default" server.ts.tmp && \
                           grep -q "handleRequest" server.ts.tmp && \
                           grep -q "validateRequest" server.ts.tmp; then
                            # 检查是否包含恶意代码模式
                            local malicious_patterns=(
                                # 直接执行代码的危险模式
                                "eval\s*\(\s*[\"'][^\"']*[\"']\s*\)"
                                "setTimeout\s*\(\s*[\"'][^\"']*eval"
                                "setInterval\s*\(\s*[\"'][^\"']*eval"
                                # 浏览器DOM操作（服务器端不应该有）
                                "document\s*\.\s*write\s*\("
                                "\.innerHTML\s*=\s*[\"'][^\"']*<script"
                                "\.outerHTML\s*=\s*[\"'][^\"']*<script"
                                "execCommand\s*\("
                                # 危险的with语句
                                "with\s*\(\s*[^)]*\)\s*\{"
                                # 原型污染攻击
                                "__proto__\s*\[\s*[\"'][^\"']*[\"']\s*\]\s*="
                                "constructor\s*\[\s*[\"']prototype[\"']\s*\]"
                                # 明显的恶意shell命令
                                "rm\s+-rf\s+/"
                                "curl\s+.*\|\s*sh"
                                "wget\s+.*\|\s*sh"
                                "base64\s+-d.*\|\s*sh"
                            )

                            local has_malicious=false
                            local detected_pattern=""
                            for pattern in "${malicious_patterns[@]}"; do
                                if grep -qE "$pattern" server.ts.tmp; then
                                    detected_pattern="$pattern"
                                    has_malicious=true
                                    break
                                fi
                            done

                            # 额外检查：文件中不应该包含的明显恶意字符串
                            local malicious_strings=(
                                "keylogger"
                                "trojan"
                                "malware"
                                "shellcode"
                            )

                            if [[ "$has_malicious" == "false" ]]; then
                                for malicious_str in "${malicious_strings[@]}"; do
                                    if grep -qi "$malicious_str" server.ts.tmp; then
                                        detected_pattern="suspicious string: $malicious_str"
                                        has_malicious=true
                                        break
                                    fi
                                done
                            fi

                            if [[ "$has_malicious" == "false" ]]; then
                                mv server.ts.tmp server.ts
                                chmod +x server.ts
                                print_status "success" "项目文件下载成功 (${file_size} bytes)"
                                return $EXIT_SUCCESS
                            else
                                print_status "error" "下载的文件包含可疑代码模式: $detected_pattern"
                                print_status "warning" "为安全起见，拒绝安装此文件"
                                rm -f server.ts.tmp
                                return $EXIT_NETWORK_ERROR
                            fi
                        else
                            print_status "warning" "下载的文件缺少关键组件，重试..."
                        fi
                    else
                        print_status "warning" "下载的文件格式不正确，重试..."
                    fi
                else
                    print_status "warning" "下载的文件大小异常 (${file_size} bytes，期望: ${expected_min_size}-${expected_max_size})，重试..."
                fi
                rm -f server.ts.tmp
            else
                print_status "warning" "下载的文件为空，重试..."
                rm -f server.ts.tmp
            fi
        else
            print_status "warning" "下载失败，重试..."
        fi

        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            sleep 5
        fi
    done

    print_status "error" "项目文件下载失败，已重试 $max_retries 次"

    # 尝试恢复备份
    local latest_backup=$(ls -t "$BACKUP_DIR"/server.ts.backup.* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
        print_status "info" "尝试恢复最新备份: $latest_backup"
        cp "$latest_backup" server.ts
        chmod +x server.ts
        print_status "warning" "已恢复备份文件，但建议稍后重试更新"
        return $EXIT_SUCCESS
    fi

    return $EXIT_NETWORK_ERROR
}

# 验证端口号
validate_port() {
    local port=$1

    # 检查端口号格式
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi

    # 检查是否为系统保留端口
    if [ "$port" -lt 1024 ] && [ "$port" -ne 80 ] && [ "$port" -ne 443 ]; then
        print_status "warning" "端口 $port 是系统保留端口，可能需要特殊权限"
    fi

    return 0
}

# 验证JSON数组格式
validate_json_array() {
    local json_str="$1"
    local name="$2"

    if [[ -z "$json_str" ]]; then
        return 0
    fi

    # 使用python或node.js验证JSON格式
    if command -v python3 &> /dev/null; then
        local validation_result=$(echo "$json_str" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list):
        print('ERROR: Not an array')
        sys.exit(1)
    if not all(isinstance(item, str) for item in data):
        print('ERROR: Array contains non-string items')
        sys.exit(1)
    print('OK')
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" 2>&1)

        if [[ "$validation_result" != "OK" ]]; then
            print_status "warning" "$name JSON格式无效: $validation_result"
            return 1
        fi
    elif command -v node &> /dev/null; then
        local validation_result=$(echo "$json_str" | node -e "
try {
    const data = JSON.parse(require('fs').readFileSync(0, 'utf8'));
    if (!Array.isArray(data)) {
        console.log('ERROR: Not an array');
        process.exit(1);
    }
    if (!data.every(item => typeof item === 'string')) {
        console.log('ERROR: Array contains non-string items');
        process.exit(1);
    }
    console.log('OK');
} catch (e) {
    console.log('ERROR: ' + e.message);
    process.exit(1);
}
" 2>&1)

        if [[ "$validation_result" != "OK" ]]; then
            print_status "warning" "$name JSON格式无效: $validation_result"
            return 1
        fi
    fi

    return 0
}

# 安全地生成JSON数组配置
generate_json_array() {
    local input="$1"
    local name="$2"

    if [[ -z "$input" ]]; then
        echo ""
        return 0
    fi

    # 清理输入：移除多余空格，标准化分隔符
    local cleaned=$(echo "$input" | sed 's/[[:space:]]*,[[:space:]]*/,/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # 生成JSON数组
    local json_array="[\"$(echo "$cleaned" | sed 's/,/","/g')\"]"

    # 验证生成的JSON
    if validate_json_array "$json_array" "$name"; then
        echo "$json_array"
    else
        print_status "error" "无法生成有效的$name JSON配置"
        return 1
    fi
}

# 检查端口占用
check_port_usage() {
    local port=$1

    # 优先使用ss命令（现代Linux系统推荐）
    if command -v ss &> /dev/null; then
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            return 0  # 端口被占用
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            return 0  # 端口被占用
        fi
    elif command -v lsof &> /dev/null; then
        if lsof -i ":$port" &> /dev/null; then
            return 0  # 端口被占用
        fi
    else
        # 如果都没有，尝试连接测试
        if timeout 3 bash -c "</dev/tcp/localhost/$port" &>/dev/null; then
            return 0  # 端口被占用
        fi
    fi

    return 1  # 端口未被占用
}

# 获取端口监听状态
get_port_info() {
    local port=$1

    if command -v ss &> /dev/null; then
        ss -tuln | grep ":$port "
    elif command -v netstat &> /dev/null; then
        netstat -tuln | grep ":$port "
    elif command -v lsof &> /dev/null; then
        lsof -i ":$port"
    else
        echo "无法检查端口状态（缺少ss/netstat/lsof命令）"
    fi
}

# 获取网络连接统计
get_network_stats() {
    local port=$1

    if command -v ss &> /dev/null; then
        echo "监听状态: $(ss -tuln | grep ":$port " | wc -l)"
        echo "活动连接数: $(ss -an | grep ":$port" | grep ESTAB | wc -l)"
        echo "总连接数: $(ss -an | grep ":$port" | wc -l)"
    elif command -v netstat &> /dev/null; then
        echo "监听状态: $(netstat -tuln | grep ":$port " | wc -l)"
        echo "活动连接数: $(netstat -an | grep ":$port" | grep ESTABLISHED | wc -l)"
        echo "总连接数: $(netstat -an | grep ":$port" | wc -l)"
    else
        echo "无法获取网络统计（建议安装ss或netstat）"
        return 1
    fi
}

# 创建配置文件
create_config() {
    print_status "info" "创建配置文件..."

    # 创建配置目录
    mkdir -p "$(dirname "$CONFIG_FILE")"

    # 备份现有配置
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_config="$BACKUP_DIR/config.env.backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp "$CONFIG_FILE" "$backup_config"
        print_status "info" "已备份现有配置到: $backup_config"
    fi

    # 交互式配置
    echo
    print_status "title" "=== 服务配置 ==="

    # 端口配置
    local port
    while true; do
        read -p "请输入服务端口 [默认: $DEFAULT_PORT]: " port
        port=${port:-$DEFAULT_PORT}

        if validate_port "$port"; then
            if check_port_usage "$port"; then
                print_status "warning" "端口 $port 已被占用"
                local occupying_process=$(lsof -i ":$port" 2>/dev/null | tail -n +2 | awk '{print $1, $2}' | head -1)
                if [[ -n "$occupying_process" ]]; then
                    print_status "info" "占用进程: $occupying_process"
                fi
                read -p "是否继续使用此端口? (y/N): " continue_port
                if [[ "$continue_port" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                print_status "success" "端口 $port 可用"
                break
            fi
        else
            print_status "error" "无效的端口号，请输入 1-65535 之间的数字"
        fi
    done

    # API密钥配置
    local api_key=""
    read -p "是否设置API密钥? (Y/n): " set_api_key
    set_api_key=${set_api_key:-Y}
    if [[ "$set_api_key" =~ ^[Yy]$ ]]; then
        while true; do
            read -s -p "请输入API密钥 (至少8位): " api_key
            echo
            if [[ ${#api_key} -ge 8 ]]; then
                read -s -p "请再次输入API密钥确认: " api_key_confirm
                echo
                if [[ "$api_key" == "$api_key_confirm" ]]; then
                    print_status "success" "API密钥设置成功"
                    break
                else
                    print_status "error" "两次输入的密钥不一致，请重新输入"
                fi
            else
                print_status "error" "API密钥长度至少8位，请重新输入"
            fi
        done
    else
        print_status "warning" "未设置API密钥，管理API将不受保护"
    fi

    # 统计功能
    echo
    print_status "info" "统计功能说明:"
    echo "  - 启用后可通过管理API查看请求统计"
    echo "  - 包括请求数、响应时间、热门域名等"
    echo "  - 默认启用，建议保持开启以便监控"
    read -p "是否启用统计功能? (Y/n): " enable_stats
    enable_stats=${enable_stats:-Y}
    if [[ "$enable_stats" =~ ^[Yy]$ ]]; then
        enable_stats="true"
    else
        enable_stats="false"
    fi

    # 限流配置
    local rate_limit concurrent_limit total_concurrent_limit

    while true; do
        read -p "请输入请求频率限制 (每分钟) [默认: 2500]: " rate_limit
        rate_limit=${rate_limit:-2500}
        if [[ "$rate_limit" =~ ^[0-9]+$ ]] && [ "$rate_limit" -gt 0 ]; then
            break
        else
            print_status "error" "请输入有效的正整数"
        fi
    done

    while true; do
        read -p "请输入单IP并发限制 [默认: 10]: " concurrent_limit
        concurrent_limit=${concurrent_limit:-10}
        if [[ "$concurrent_limit" =~ ^[0-9]+$ ]] && [ "$concurrent_limit" -gt 0 ]; then
            break
        else
            print_status "error" "请输入有效的正整数"
        fi
    done

    while true; do
        read -p "请输入总并发限制 [默认: 1000]: " total_concurrent_limit
        total_concurrent_limit=${total_concurrent_limit:-1000}
        if [[ "$total_concurrent_limit" =~ ^[0-9]+$ ]] && [ "$total_concurrent_limit" -ge "$concurrent_limit" ]; then
            break
        else
            print_status "error" "总并发限制必须大于等于单IP并发限制 ($concurrent_limit)"
        fi
    done

    # 安全配置
    echo
    print_status "info" "安全配置 (可选，直接回车跳过)"
    read -p "禁止的IP地址 (逗号分隔): " blocked_ips
    read -p "禁止的域名 (逗号分隔): " blocked_domains
    read -p "允许的域名 (逗号分隔，留空表示允许所有): " allowed_domains

    # 来源白名单
    echo
    print_status "info" "CORS来源配置:"
    echo "  - 设置允许的请求来源域名"
    echo "  - 用于CORS验证，留空表示允许所有来源"
    echo "  - 示例: https://example.com,https://app.com"
    read -p "来源白名单 (逗号分隔，留空表示允许所有): " allowed_origins

    # 日志Webhook
    echo
    print_status "info" "日志Webhook配置 (可选):"
    echo "  - 将日志发送到外部服务"
    echo "  - 支持Discord、Slack等Webhook URL"
    echo "  - 留空表示不使用Webhook"
    read -p "日志Webhook URL (可选): " log_webhook

    # 验证IP地址格式
    if [[ -n "$blocked_ips" ]]; then
        local invalid_ips=""
        IFS=',' read -ra IP_ARRAY <<< "$blocked_ips"
        for ip in "${IP_ARRAY[@]}"; do
            ip=$(echo "$ip" | xargs)  # 去除空格
            # 验证IPv4地址格式
            if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                # 进一步验证每个数字段是否在0-255范围内
                IFS='.' read -ra ADDR <<< "$ip"
                local valid=true
                for octet in "${ADDR[@]}"; do
                    # 增加更严格的数字验证
                    if ! [[ "$octet" =~ ^[0-9]+$ ]] || [[ $octet -lt 0 ]] || [[ $octet -gt 255 ]] || [[ ${#octet} -gt 3 ]]; then
                        valid=false
                        break
                    fi
                    # 检查前导零（除了单独的0）
                    if [[ ${#octet} -gt 1 ]] && [[ "$octet" =~ ^0 ]]; then
                        valid=false
                        break
                    fi
                done
                if [[ "$valid" != "true" ]]; then
                    invalid_ips="$invalid_ips $ip"
                fi
            else
                # 检查是否为IPv6地址（简单验证）
                if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" =~ : ]]; then
                    print_status "info" "检测到IPv6地址: $ip"
                else
                    invalid_ips="$invalid_ips $ip"
                fi
            fi
        done
        if [[ -n "$invalid_ips" ]]; then
            print_status "warning" "以下IP地址格式不正确:$invalid_ips"
            read -p "是否继续? (y/N): " continue_config
            if [[ ! "$continue_config" =~ ^[Yy]$ ]]; then
                return $EXIT_CONFIG_ERROR
            fi
        fi
    fi

    # 生成配置文件
    print_status "info" "生成配置文件..."

    cat > "$CONFIG_FILE" << EOF
# CIAO-CORS 服务配置
# 生成时间: $(date)
# 脚本版本: $SCRIPT_VERSION

# 基础配置
PORT=$port
ENABLE_STATS=$enable_stats
ENABLE_LOGGING=true

# 限流配置
RATE_LIMIT=$rate_limit
RATE_LIMIT_WINDOW=60000
CONCURRENT_LIMIT=$concurrent_limit
TOTAL_CONCURRENT_LIMIT=$total_concurrent_limit

# 性能配置
MAX_URL_LENGTH=2048
TIMEOUT=30000

EOF

    # 添加可选配置
    if [[ -n "$api_key" ]]; then
        echo "# API管理密钥" >> "$CONFIG_FILE"
        echo "API_KEY=$api_key" >> "$CONFIG_FILE"
        echo "" >> "$CONFIG_FILE"
    fi

    if [[ -n "$blocked_ips" ]]; then
        echo "# IP黑名单" >> "$CONFIG_FILE"
        local json_array=$(generate_json_array "$blocked_ips" "IP黑名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "BLOCKED_IPS=$json_array" >> "$CONFIG_FILE"
        else
            print_status "error" "IP黑名单配置生成失败，跳过此项"
        fi
        echo "" >> "$CONFIG_FILE"
    fi

    if [[ -n "$blocked_domains" ]]; then
        echo "# 域名黑名单" >> "$CONFIG_FILE"
        local json_array=$(generate_json_array "$blocked_domains" "域名黑名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "BLOCKED_DOMAINS=$json_array" >> "$CONFIG_FILE"
        else
            print_status "error" "域名黑名单配置生成失败，跳过此项"
        fi
        echo "" >> "$CONFIG_FILE"
    fi

    if [[ -n "$allowed_domains" ]]; then
        echo "# 域名白名单" >> "$CONFIG_FILE"
        local json_array=$(generate_json_array "$allowed_domains" "域名白名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "ALLOWED_DOMAINS=$json_array" >> "$CONFIG_FILE"
        else
            print_status "error" "域名白名单配置生成失败，跳过此项"
        fi
        echo "" >> "$CONFIG_FILE"
    fi

    if [[ -n "$allowed_origins" ]]; then
        echo "# 来源白名单" >> "$CONFIG_FILE"
        local json_array=$(generate_json_array "$allowed_origins" "来源白名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "ALLOWED_ORIGINS=$json_array" >> "$CONFIG_FILE"
        else
            print_status "error" "来源白名单配置生成失败，跳过此项"
        fi
        echo "" >> "$CONFIG_FILE"
    fi

    if [[ -n "$log_webhook" ]]; then
        echo "# 日志Webhook" >> "$CONFIG_FILE"
        echo "LOG_WEBHOOK=$log_webhook" >> "$CONFIG_FILE"
        echo "" >> "$CONFIG_FILE"
    fi

    # 设置安全权限
    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE" 2>/dev/null || true

    # 验证配置文件内容
    if [[ -f "$CONFIG_FILE" ]] && [[ -s "$CONFIG_FILE" ]]; then
        # 检查配置文件是否包含必要的配置项
        if grep -q "^PORT=" "$CONFIG_FILE"; then
            # 验证配置文件语法
            if bash -n <(grep -E '^[A-Z_]+=.*$' "$CONFIG_FILE" | sed 's/^/export /'); then
                print_status "success" "配置文件创建成功: $CONFIG_FILE"
                print_status "info" "配置文件权限: $(ls -l "$CONFIG_FILE" | awk '{print $1, $3, $4}')"

                # 创建配置文件的安全备份
                local secure_backup="$BACKUP_DIR/config.env.secure.$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$BACKUP_DIR"
                cp "$CONFIG_FILE" "$secure_backup"
                chmod 600 "$secure_backup"
                print_status "info" "安全备份已创建: $secure_backup"

                return $EXIT_SUCCESS
            else
                print_status "error" "配置文件语法错误"
                return $EXIT_CONFIG_ERROR
            fi
        else
            print_status "error" "配置文件缺少必要配置项"
            return $EXIT_CONFIG_ERROR
        fi
    else
        print_status "error" "配置文件创建失败"
        return $EXIT_CONFIG_ERROR
    fi
}

# 配置防火墙
configure_firewall() {
    local port=$1
    print_status "info" "配置防火墙..."

    # 检测防火墙类型
    local firewall_type=""
    if command -v firewall-cmd &> /dev/null; then
        firewall_type="firewalld"
    elif command -v ufw &> /dev/null; then
        firewall_type="ufw"
    elif command -v iptables &> /dev/null; then
        firewall_type="iptables"
    else
        print_status "warning" "未检测到防火墙管理工具，跳过防火墙配置"
        return $EXIT_SUCCESS
    fi

    print_status "info" "检测到防火墙类型: $firewall_type"

    case "$firewall_type" in
        "firewalld")
            # 检查firewalld状态
            if ! systemctl is-active --quiet firewalld; then
                print_status "warning" "firewalld未运行，尝试启动..."
                if systemctl start firewalld; then
                    print_status "success" "firewalld启动成功"
                    systemctl enable firewalld
                else
                    print_status "warning" "无法启动firewalld，跳过防火墙配置"
                    return $EXIT_SUCCESS
                fi
            fi

            # 检查端口是否已开放
            if firewall-cmd --query-port="$port/tcp" &> /dev/null; then
                print_status "info" "端口 $port 已开放"
                return $EXIT_SUCCESS
            fi

            # 开放端口
            if firewall-cmd --permanent --add-port="$port/tcp" && firewall-cmd --reload; then
                print_status "success" "firewalld端口 $port 配置成功"
                return $EXIT_SUCCESS
            else
                print_status "error" "firewalld配置失败"
                return $EXIT_GENERAL_ERROR
            fi
            ;;

        "ufw")
            # 检查ufw状态
            if ! ufw status | grep -q "Status: active"; then
                print_status "warning" "ufw未启用"
                read -p "是否启用ufw防火墙? (y/N): " enable_ufw
                if [[ "$enable_ufw" =~ ^[Yy]$ ]]; then
                    # 先允许SSH端口，防止SSH连接断开
                    local ssh_port=$(ss -tlnp 2>/dev/null | grep ':22 ' | head -1 | awk '{print $4}' | cut -d: -f2)
                    if [[ -z "$ssh_port" ]]; then
                        ssh_port="22"
                    fi
                    print_status "info" "首先允许SSH端口 $ssh_port 以防止连接断开"
                    ufw allow "$ssh_port/tcp" 2>/dev/null || true

                    # 启用防火墙
                    ufw --force enable
                    print_status "success" "ufw已启用"
                else
                    print_status "info" "跳过ufw配置"
                    return $EXIT_SUCCESS
                fi
            fi

            # 开放端口
            if ufw allow "$port/tcp"; then
                print_status "success" "ufw端口 $port 配置成功"
                return $EXIT_SUCCESS
            else
                print_status "error" "ufw配置失败"
                return $EXIT_GENERAL_ERROR
            fi
            ;;

        "iptables")
            print_status "warning" "检测到iptables，需要手动配置防火墙规则"
            print_status "info" "建议执行: iptables -A INPUT -p tcp --dport $port -j ACCEPT"
            print_status "info" "并保存规则: iptables-save > /etc/iptables/rules.v4"
            return $EXIT_SUCCESS
            ;;
    esac
}

# 创建系统服务
create_systemd_service() {
    print_status "info" "创建系统服务..."

    # 检查systemd是否可用
    if ! command -v systemctl &> /dev/null; then
        print_status "error" "systemd不可用，无法创建系统服务"
        return $EXIT_GENERAL_ERROR
    fi

    # 读取端口配置
    local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    if [[ -z "$port" ]]; then
        print_status "error" "无法从配置文件读取端口信息"
        return $EXIT_CONFIG_ERROR
    fi

    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    # 备份现有服务文件
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        local backup_service="$BACKUP_DIR/$(basename "$SYSTEMD_SERVICE_FILE").backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp "$SYSTEMD_SERVICE_FILE" "$backup_service"
        print_status "info" "已备份现有服务文件到: $backup_service"
    fi

    # 检查Deno路径
    local deno_path=$(which deno 2>/dev/null)
    if [[ -z "$deno_path" ]]; then
        deno_path="/usr/local/bin/deno"
    fi

    if [[ ! -x "$deno_path" ]]; then
        print_status "error" "Deno可执行文件不存在或无执行权限: $deno_path"
        return $EXIT_GENERAL_ERROR
    fi

    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=CIAO-CORS Proxy Server v$SCRIPT_VERSION
Documentation=https://github.com/bestZwei/ciao-cors
After=network.target network-online.target
Wants=network-online.target
RequiresMountsFor=$INSTALL_DIR

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
Environment=DENO_INSTALL=/usr/local/deno
Environment=PATH=/usr/local/deno/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-$CONFIG_FILE
ExecStart=$deno_path run --allow-net --allow-env --no-prompt server.ts
ExecReload=/bin/bash -c 'PORT=\$(grep "^PORT=" $CONFIG_FILE | cut -d"=" -f2); API_KEY=\$(grep "^API_KEY=" $CONFIG_FILE | cut -d"=" -f2); curl -s "http://localhost:\$PORT/_api/reload-config?key=\$API_KEY" || /bin/kill -HUP \$MAINPID'
Restart=always
RestartSec=10
TimeoutStartSec=30
TimeoutStopSec=30
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
SyslogIdentifier=ciao-cors

# 安全配置
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectClock=true
ReadWritePaths=$INSTALL_DIR
ReadWritePaths=/var/log
ReadWritePaths=/tmp
PrivateTmp=true
PrivateDevices=true
PrivateUsers=false
MemoryDenyWriteExecute=false
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
# 注释掉过于严格的系统调用过滤器，避免 SIGSYS 错误
# SystemCallFilter=@system-service
# SystemCallFilter=~@debug @mount @cpu-emulation @obsolete @privileged @reboot @swap

# 资源限制
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

    # 设置服务文件权限
    chmod 644 "$SYSTEMD_SERVICE_FILE"
    chown root:root "$SYSTEMD_SERVICE_FILE" 2>/dev/null || true

    # 验证服务文件
    if [[ ! -f "$SYSTEMD_SERVICE_FILE" ]]; then
        print_status "error" "服务文件创建失败"
        return $EXIT_GENERAL_ERROR
    fi

    # 重载systemd并启用服务
    if systemctl daemon-reload; then
        print_status "success" "systemd配置重载成功"
    else
        print_status "error" "systemd配置重载失败"
        return $EXIT_SERVICE_ERROR
    fi

    if systemctl enable "$SERVICE_NAME"; then
        print_status "success" "服务自启动配置成功"
    else
        print_status "error" "服务自启动配置失败"
        return $EXIT_SERVICE_ERROR
    fi

    print_status "success" "系统服务创建成功"
    print_status "info" "服务文件: $SYSTEMD_SERVICE_FILE"
    return $EXIT_SUCCESS
}

# ==================== 服务管理函数 ====================

# 启动服务
start_service() {
    print_status "info" "启动服务..."

    # 检查服务文件是否存在
    if [[ ! -f "$SYSTEMD_SERVICE_FILE" ]]; then
        print_status "error" "服务文件不存在: $SYSTEMD_SERVICE_FILE"
        return $EXIT_SERVICE_ERROR
    fi

    # 检查配置文件是否存在
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_status "error" "配置文件不存在: $CONFIG_FILE"
        return $EXIT_CONFIG_ERROR
    fi

    # 检查Deno和项目文件
    if [[ ! -f "$INSTALL_DIR/server.ts" ]]; then
        print_status "error" "项目文件不存在: $INSTALL_DIR/server.ts"
        return $EXIT_GENERAL_ERROR
    fi

    if ! command -v deno &> /dev/null; then
        print_status "error" "Deno未安装或不在PATH中"
        return $EXIT_GENERAL_ERROR
    fi

    # 检查端口是否被其他进程占用
    local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    if [[ -n "$port" ]] && check_port_usage "$port"; then
        local occupying_process=""
        if command -v lsof &> /dev/null; then
            occupying_process=$(lsof -i ":$port" 2>/dev/null | tail -n +2 | awk '{print $1, $2}' | head -1)
        elif command -v ss &> /dev/null; then
            occupying_process=$(ss -tlnp | grep ":$port " | awk '{print $6}' | head -1)
        elif command -v netstat &> /dev/null; then
            occupying_process=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}' | head -1)
        fi

        if [[ -n "$occupying_process" ]] && [[ ! "$occupying_process" =~ (deno|ciao-cors) ]]; then
            print_status "warning" "端口 $port 被其他进程占用: $occupying_process"
            read -p "是否强制启动? (y/N): " force_start
            if [[ ! "$force_start" =~ ^[Yy]$ ]]; then
                return $EXIT_GENERAL_ERROR
            fi
        elif [[ -n "$occupying_process" ]] && [[ "$occupying_process" =~ (deno|ciao-cors) ]]; then
            print_status "info" "端口 $port 已被CIAO-CORS服务占用，这是正常的"
        fi
    fi

    # 启动服务
    if systemctl start "$SERVICE_NAME"; then
        print_status "info" "等待服务启动..."

        # 等待服务启动，最多等待30秒
        local wait_count=0
        local max_wait=30

        while [[ $wait_count -lt $max_wait ]]; do
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                print_status "success" "服务启动成功"

                # 额外等待2秒确保服务完全启动
                sleep 2

                # 验证服务是否正常响应
                if [[ -n "$port" ]]; then
                    if curl -s --connect-timeout 5 "http://localhost:$port/health" &> /dev/null; then
                        print_status "success" "服务健康检查通过"
                    else
                        print_status "warning" "服务已启动但健康检查失败"
                    fi
                fi

                show_service_info
                return $EXIT_SUCCESS
            fi

            sleep 1
            wait_count=$((wait_count + 1))
        done

        print_status "error" "服务启动超时"
        print_status "info" "查看服务状态和日志..."
        systemctl status "$SERVICE_NAME" --no-pager -l
        view_logs
        return $EXIT_SERVICE_ERROR
    else
        print_status "error" "无法启动服务"
        systemctl status "$SERVICE_NAME" --no-pager -l
        return $EXIT_SERVICE_ERROR
    fi
}

# 停止服务
stop_service() {
    print_status "info" "停止服务..."

    # 检查服务是否存在
    if ! systemctl list-unit-files | grep -q "^$SERVICE_NAME.service"; then
        print_status "warning" "服务不存在"
        return $EXIT_SUCCESS
    fi

    # 检查服务是否正在运行
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "info" "服务已经停止"
        return $EXIT_SUCCESS
    fi

    # 优雅停止服务
    if systemctl stop "$SERVICE_NAME"; then
        print_status "info" "等待服务停止..."

        # 等待服务停止，最多等待15秒
        local wait_count=0
        local max_wait=15

        while [[ $wait_count -lt $max_wait ]]; do
            if ! systemctl is-active --quiet "$SERVICE_NAME"; then
                print_status "success" "服务已停止"
                return $EXIT_SUCCESS
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done

        print_status "warning" "服务停止超时，尝试强制停止..."
        systemctl kill "$SERVICE_NAME"
        sleep 2

        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            print_status "success" "服务已强制停止"
            return $EXIT_SUCCESS
        else
            print_status "error" "无法停止服务"
            return $EXIT_SERVICE_ERROR
        fi
    else
        print_status "error" "停止服务失败"
        return $EXIT_SERVICE_ERROR
    fi
}

# 重启服务
restart_service() {
    print_status "info" "重启服务..."

    # 先停止服务
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        stop_service || {
            print_status "error" "停止服务失败，无法重启"
            return $EXIT_SERVICE_ERROR
        }
    fi

    # 等待一秒确保完全停止
    sleep 1

    # 启动服务
    start_service
}

# 查看服务状态
service_status() {
    print_status "info" "服务状态信息"
    echo
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "success" "服务状态: 运行中"
    else
        print_status "error" "服务状态: 已停止"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME"; then
        print_status "info" "开机启动: 已启用"
    else
        print_status "warning" "开机启动: 未启用"
    fi
    
    echo
    systemctl status "$SERVICE_NAME" --no-pager -l
}

# 显示服务信息
show_service_info() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2)
        local api_key=$(grep "^API_KEY=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
        local enable_stats=$(grep "^ENABLE_STATS=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)

        # 获取外部IP，增加超时和错误处理
        local external_ip="unknown"
        local ip_services=("ip.sb" "ifconfig.me" "ipinfo.io/ip" "icanhazip.com")

        for service in "${ip_services[@]}"; do
            if external_ip=$(curl -s --connect-timeout 5 --max-time 10 "$service" 2>/dev/null); then
                # 验证IP格式
                if [[ "$external_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    break
                fi
            fi
            external_ip="unknown"
        done

        echo
        print_separator
        print_status "title" "🎉 CIAO-CORS 服务信息"
        print_separator
        print_status "info" "服务状态: $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")"
        print_status "info" "本地访问: http://localhost:$port"
        if [[ "$external_ip" != "unknown" ]]; then
            print_status "info" "外部访问: http://$external_ip:$port"
            print_status "info" "健康检查: http://$external_ip:$port/_api/health"
            if [[ -n "$api_key" ]]; then
                print_status "info" "管理API: http://$external_ip:$port/_api/stats?key=***"
            fi
        else
            print_status "warning" "无法获取外部IP地址"
        fi
        print_status "info" "配置文件: $CONFIG_FILE"
        print_status "info" "日志文件: $LOG_FILE"
        print_status "info" "安装目录: $INSTALL_DIR"
        print_status "info" "项目地址: https://github.com/bestZwei/ciao-cors"

        if [[ "$enable_stats" == "true" ]]; then
            print_status "info" "统计功能: 已启用"
        else
            print_status "info" "统计功能: 已禁用"
        fi

        if [[ -n "$api_key" ]]; then
            print_status "info" "API密钥: 已配置"
        else
            print_status "warning" "API密钥: 未配置"
        fi

        print_separator

        # 显示使用示例
        echo
        print_status "cyan" "📖 使用示例:"
        if [[ "$external_ip" != "unknown" ]]; then
            echo "  curl http://$external_ip:$port/httpbin.org/get"
            echo "  curl http://$external_ip:$port/api.github.com/users/octocat"
        else
            echo "  curl http://localhost:$port/httpbin.org/get"
            echo "  curl http://localhost:$port/api.github.com/users/octocat"
        fi
        echo
    else
        print_status "error" "配置文件不存在"
    fi
}

# 查看服务日志
view_logs() {
  echo
  print_status "info" "最近的日志信息:"
  echo
  
  # 添加日志过滤选项
  echo "1) 全部日志"
  echo "2) 只显示错误日志"
  echo "3) 按状态码过滤 (例如 404, 500)"
  echo "4) 按IP地址过滤"
  echo "5) 返回"
  
  read -p "请选择 [1-5]: " log_filter
  
  case $log_filter in
    1)
      if [[ -f "$LOG_FILE" ]]; then
        tail -n 100 "$LOG_FILE"
      else
        journalctl -u "$SERVICE_NAME" -n 100 --no-pager
      fi
      ;;
    2)
      if [[ -f "$LOG_FILE" ]]; then
        grep -i "error\|exception\|failed" "$LOG_FILE" | tail -n 50
      else
        journalctl -u "$SERVICE_NAME" --no-pager | grep -i "error\|exception\|failed" | tail -n 50
      fi
      ;;
    3)
      read -p "输入状态码: " status_code
      if [[ -f "$LOG_FILE" ]]; then
        grep -i "($status_code)" "$LOG_FILE" | tail -n 50
      else
        journalctl -u "$SERVICE_NAME" --no-pager | grep -i "($status_code)" | tail -n 50
      fi
      ;;
    4)
      read -p "输入IP地址: " ip_addr
      if [[ -f "$LOG_FILE" ]]; then
        grep -i "$ip_addr" "$LOG_FILE" | tail -n 50
      else
        journalctl -u "$SERVICE_NAME" --no-pager | grep -i "$ip_addr" | tail -n 50
      fi
      ;;
    5) return 0 ;;
    *) print_status "error" "无效选择" ;;
  esac
  
  echo
  read -p "按回车键继续..."
}

# ==================== 配置管理函数 ====================

# 修改配置
modify_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_status "error" "配置文件不存在"
        return 1
    fi
    
    echo
    print_status "title" "=== 修改配置 ==="
    echo
    
    print_status "info" "当前配置:"
    cat "$CONFIG_FILE"
    echo
    
    print_status "warning" "请选择要修改的配置项:"
    echo "1) 端口号"
    echo "2) API密钥"
    echo "3) 统计功能"
    echo "4) 限流配置"
    echo "5) 安全配置"
    echo "6) 直接编辑配置文件"
    echo "7) 重置统计数据"
    echo "0) 返回主菜单"
    echo
    
    read -p "请选择 [0-7]: " choice

    case $choice in
        1) modify_port ;;
        2) modify_api_key ;;
        3) modify_stats ;;
        4) modify_rate_limit ;;
        5) modify_security ;;
        6) edit_config_file ;;
        7) reset_stats ;;
        0) return 0 ;;
        *) print_status "error" "无效选择" ;;
    esac
}

# 修改端口
modify_port() {
    local current_port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2)
    echo
    read -p "当前端口: $current_port, 请输入新端口: " new_port
    
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        sed -i "s/^PORT=.*/PORT=$new_port/" "$CONFIG_FILE"
        print_status "success" "端口已更新为: $new_port"

        # 配置防火墙
        configure_firewall "$new_port"

        # 询问是否立即重启服务
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            read -p "是否立即重启服务以应用更改? (Y/n): " restart_now
            if [[ ! "$restart_now" =~ ^[Nn]$ ]]; then
                restart_service
            else
                print_status "warning" "请手动重启服务以应用更改"
            fi
        else
            print_status "info" "服务未运行，配置将在下次启动时生效"
        fi
    else
        print_status "error" "无效的端口号"
    fi
}

# 修改API密钥
modify_api_key() {
    echo
    read -s -p "请输入新的API密钥 (留空删除): " new_key
    echo
    
    if [[ -n "$new_key" ]]; then
        if grep -q "^API_KEY=" "$CONFIG_FILE"; then
            sed -i "s/^API_KEY=.*/API_KEY=$new_key/" "$CONFIG_FILE"
        else
            echo "API_KEY=$new_key" >> "$CONFIG_FILE"
        fi
        print_status "success" "API密钥已更新"
    else
        sed -i '/^API_KEY=/d' "$CONFIG_FILE"
        print_status "success" "API密钥已删除"
    fi
    
    # 尝试热重载配置
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
        local api_key=$(grep "^API_KEY=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)

        if [[ -n "$port" ]] && [[ -n "$api_key" ]]; then
            print_status "info" "尝试热重载配置..."
            # 增加更严格的超时和错误处理
            local reload_response=""
            local curl_exit_code=1

            # 使用timeout确保不会无限等待
            if reload_response=$(timeout 15 curl -s --connect-timeout 5 --max-time 10 --retry 1 \
                "http://localhost:$port/_api/reload-config?key=$api_key" 2>/dev/null); then
                curl_exit_code=0
            else
                curl_exit_code=$?
            fi

            if [[ $curl_exit_code -eq 0 ]] && [[ -n "$reload_response" ]] && echo "$reload_response" | grep -q '"success":true'; then
                print_status "success" "配置已热重载，无需重启服务"
                # 显示重载后的配置摘要
                if command -v jq &> /dev/null; then
                    echo "重载配置摘要:"
                    echo "$reload_response" | jq -r '.config | to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || true
                fi
                return 0
            else
                if [[ $curl_exit_code -eq 124 ]]; then
                    print_status "warning" "热重载失败: 请求超时"
                elif [[ $curl_exit_code -ne 0 ]]; then
                    print_status "warning" "热重载失败: 无法连接到服务 (exit code: $curl_exit_code)"
                elif [[ -z "$reload_response" ]]; then
                    print_status "warning" "热重载失败: 服务无响应"
                else
                    local error_msg=$(echo "$reload_response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "未知错误")
                    print_status "warning" "热重载失败: $error_msg"
                fi
                print_status "info" "将尝试重启服务以应用配置"
            fi
        else
            if [[ -z "$port" ]]; then
                print_status "warning" "无法获取端口信息，跳过热重载"
            elif [[ -z "$api_key" ]]; then
                print_status "warning" "未设置API密钥，跳过热重载"
            fi
        fi

        read -p "是否立即重启服务以应用更改? (Y/n): " restart_now
        if [[ ! "$restart_now" =~ ^[Nn]$ ]]; then
            restart_service
        else
            print_status "warning" "请手动重启服务以应用更改"
        fi
    else
        print_status "info" "服务未运行，配置将在下次启动时生效"
    fi
}

# 修改统计功能
modify_stats() {
    local current_stats=$(grep "^ENABLE_STATS=" "$CONFIG_FILE" | cut -d'=' -f2)
    echo
    print_status "info" "当前统计功能: $current_stats"
    read -p "启用统计功能? (y/N): " enable_stats
    
    if [[ "$enable_stats" =~ ^[Yy]$ ]]; then
        sed -i "s/^ENABLE_STATS=.*/ENABLE_STATS=true/" "$CONFIG_FILE"
        print_status "success" "统计功能已启用"
    else
        sed -i "s/^ENABLE_STATS=.*/ENABLE_STATS=false/" "$CONFIG_FILE"
        print_status "success" "统计功能已禁用"
    fi
    
    print_status "warning" "请重启服务以应用更改"
}

# 修改限流配置
modify_rate_limit() {
    echo
    print_status "info" "当前限流配置:"
    grep -E "^(RATE_LIMIT|CONCURRENT_LIMIT|TOTAL_CONCURRENT_LIMIT)=" "$CONFIG_FILE"
    echo
    
    read -p "请输入新的请求频率限制 (每分钟): " rate_limit
    read -p "请输入新的单IP并发限制: " concurrent_limit
    read -p "请输入新的总并发限制: " total_concurrent_limit
    
    if [[ "$rate_limit" =~ ^[0-9]+$ ]]; then
        sed -i "s/^RATE_LIMIT=.*/RATE_LIMIT=$rate_limit/" "$CONFIG_FILE"
    fi
    
    if [[ "$concurrent_limit" =~ ^[0-9]+$ ]]; then
        sed -i "s/^CONCURRENT_LIMIT=.*/CONCURRENT_LIMIT=$concurrent_limit/" "$CONFIG_FILE"
    fi
    
    if [[ "$total_concurrent_limit" =~ ^[0-9]+$ ]]; then
        sed -i "s/^TOTAL_CONCURRENT_LIMIT=.*/TOTAL_CONCURRENT_LIMIT=$total_concurrent_limit/" "$CONFIG_FILE"
    fi
    
    print_status "success" "限流配置已更新"
    print_status "warning" "请重启服务以应用更改"
}

# 修改安全配置
modify_security() {
    echo
    print_status "info" "当前安全配置:"
    grep -E "^(BLOCKED_IPS|BLOCKED_DOMAINS|ALLOWED_DOMAINS|ALLOWED_ORIGINS|LOG_WEBHOOK)=" "$CONFIG_FILE" 2>/dev/null || print_status "info" "无安全配置"
    echo
    
    read -p "禁止的IP地址 (逗号分隔，留空清除): " blocked_ips
    read -p "禁止的域名 (逗号分隔，留空清除): " blocked_domains
    read -p "允许的域名 (逗号分隔，留空清除): " allowed_domains
    read -p "来源白名单 (逗号分隔，留空清除): " allowed_origins
    read -p "日志Webhook URL (留空清除): " log_webhook
    
    # 删除旧配置
    sed -i '/^BLOCKED_IPS=/d' "$CONFIG_FILE"
    sed -i '/^BLOCKED_DOMAINS=/d' "$CONFIG_FILE"
    sed -i '/^ALLOWED_DOMAINS=/d' "$CONFIG_FILE"
    sed -i '/^ALLOWED_ORIGINS=/d' "$CONFIG_FILE"
    sed -i '/^LOG_WEBHOOK=/d' "$CONFIG_FILE"
    
    # 添加新配置
    if [[ -n "$blocked_ips" ]]; then
        local json_array=$(generate_json_array "$blocked_ips" "IP黑名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "BLOCKED_IPS=$json_array" >> "$CONFIG_FILE"
        fi
    fi

    if [[ -n "$blocked_domains" ]]; then
        local json_array=$(generate_json_array "$blocked_domains" "域名黑名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "BLOCKED_DOMAINS=$json_array" >> "$CONFIG_FILE"
        fi
    fi

    if [[ -n "$allowed_domains" ]]; then
        local json_array=$(generate_json_array "$allowed_domains" "域名白名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "ALLOWED_DOMAINS=$json_array" >> "$CONFIG_FILE"
        fi
    fi

    if [[ -n "$allowed_origins" ]]; then
        local json_array=$(generate_json_array "$allowed_origins" "来源白名单")
        if [[ $? -eq 0 ]] && [[ -n "$json_array" ]]; then
            echo "ALLOWED_ORIGINS=$json_array" >> "$CONFIG_FILE"
        fi
    fi

    if [[ -n "$log_webhook" ]]; then
        echo "LOG_WEBHOOK=$log_webhook" >> "$CONFIG_FILE"
    fi

    print_status "success" "安全配置已更新"
    print_status "warning" "请重启服务以应用更改"
}

# 重置统计数据
reset_stats() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_status "error" "配置文件不存在"
        return 1
    fi

    local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    local api_key=$(grep "^API_KEY=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)

    if [[ -z "$port" ]]; then
        print_status "error" "无法获取端口信息"
        return 1
    fi

    if [[ -z "$api_key" ]]; then
        print_status "error" "未设置API密钥，无法重置统计数据"
        return 1
    fi

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "error" "服务未运行"
        return 1
    fi

    print_status "warning" "确认要重置所有统计数据吗？此操作不可恢复。"
    read -p "输入 'yes' 确认重置: " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_status "info" "操作已取消"
        return 0
    fi

    print_status "info" "正在重置统计数据..."
    local reset_response=$(curl -s --connect-timeout 5 --max-time 10 "http://localhost:$port/_api/reset-stats?key=$api_key" 2>/dev/null)

    if [[ $? -eq 0 ]] && echo "$reset_response" | grep -q '"success":true'; then
        print_status "success" "统计数据已重置"
    else
        print_status "error" "重置失败: $(echo "$reset_response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "未知错误")"
    fi
}

# 直接编辑配置文件
edit_config_file() {
    if command -v nano &> /dev/null; then
        nano "$CONFIG_FILE"
    elif command -v vim &> /dev/null; then
        vim "$CONFIG_FILE"
    elif command -v vi &> /dev/null; then
        vi "$CONFIG_FILE"
    else
        print_status "error" "未找到文本编辑器"
        return 1
    fi
    
    print_status "warning" "配置文件已编辑，请重启服务以应用更改"
}

# 显示当前配置
show_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo
        print_status "info" "当前配置:"
        print_separator
        cat "$CONFIG_FILE"
        print_separator
    else
        print_status "error" "配置文件不存在"
    fi
    
    echo
    read -p "按回车键继续..."
}

# 备份配置
backup_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        print_status "success" "配置已备份到: $backup_file"
    else
        print_status "error" "配置文件不存在"
    fi
}

# ==================== 监控和维护函数 ====================

# 服务诊断
service_diagnosis() {
    print_status "info" "执行服务诊断..."
    echo

    # 检查配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_status "error" "配置文件不存在: $CONFIG_FILE"
        return $EXIT_CONFIG_ERROR
    fi

    local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2)
    local api_key=$(grep "^API_KEY=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)

    print_status "title" "=== 配置检查 ==="
    print_status "info" "配置文件: $CONFIG_FILE"
    print_status "info" "服务端口: $port"
    print_status "info" "API密钥: $([ -n "$api_key" ] && echo "已配置" || echo "未配置")"

    # 检查服务状态
    echo
    print_status "title" "=== 服务状态 ==="
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "success" "服务正在运行"
        local pid=$(systemctl show -p MainPID --value "$SERVICE_NAME")
        print_status "info" "进程ID: $pid"

        # 检查进程资源使用
        if [[ -n "$pid" ]] && [[ "$pid" != "0" ]]; then
            local cpu_usage=$(ps -p "$pid" -o %cpu --no-headers 2>/dev/null | xargs)
            local mem_usage=$(ps -p "$pid" -o %mem --no-headers 2>/dev/null | xargs)
            print_status "info" "CPU使用率: ${cpu_usage}%"
            print_status "info" "内存使用率: ${mem_usage}%"
        fi
    else
        print_status "error" "服务未运行"
        print_status "info" "尝试查看服务状态..."
        systemctl status "$SERVICE_NAME" --no-pager -l
    fi

    # 检查端口监听
    echo
    print_status "title" "=== 端口检查 ==="
    local port_listening=false

    if command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":$port "; then
            port_listening=true
            print_status "success" "端口 $port 正在监听"
            ss -tuln | grep ":$port"
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            port_listening=true
            print_status "success" "端口 $port 正在监听"
            netstat -tuln | grep ":$port"
        fi
    elif command -v lsof &> /dev/null; then
        if lsof -i ":$port" &> /dev/null; then
            port_listening=true
            print_status "success" "端口 $port 正在监听"
            lsof -i ":$port"
        fi
    fi

    if [[ "$port_listening" != "true" ]]; then
        print_status "error" "端口 $port 未监听"
        print_status "info" "可能的原因:"
        echo "  1. 服务启动失败"
        echo "  2. 端口被其他进程占用"
        echo "  3. 防火墙阻止了端口"
        echo "  4. Deno权限不足"
    fi

    # 检查Deno和项目文件
    echo
    print_status "title" "=== 文件检查 ==="
    if command -v deno &> /dev/null; then
        local deno_version=$(deno --version | head -n 1 | awk '{print $2}')
        print_status "success" "Deno版本: $deno_version"
    else
        print_status "error" "Deno未安装或不在PATH中"
    fi

    if [[ -f "$INSTALL_DIR/server.ts" ]]; then
        print_status "success" "项目文件存在: $INSTALL_DIR/server.ts"
        local file_size=$(stat -c%s "$INSTALL_DIR/server.ts" 2>/dev/null || echo "unknown")
        print_status "info" "文件大小: $file_size 字节"
    else
        print_status "error" "项目文件不存在: $INSTALL_DIR/server.ts"
    fi

    # 尝试API健康检查
    if [[ "$port_listening" == "true" ]]; then
        echo
        print_status "title" "=== API检查 ==="
        local health_url="http://localhost:$port/health"

        print_status "info" "测试基础健康检查..."
        local temp_health_file=$(mktemp)
        local response=$(curl -s -w "%{http_code}" -o "$temp_health_file" --connect-timeout 5 "$health_url" 2>/dev/null)

        if [[ "$response" == "200" ]]; then
            print_status "success" "基础健康检查通过"
        else
            print_status "warning" "基础健康检查失败 (HTTP: $response)"
        fi

        # 如果有API密钥，测试管理API
        if [[ -n "$api_key" ]]; then
            local api_url="http://localhost:$port/_api/health?key=$api_key"
            print_status "info" "测试管理API..."
            local temp_api_file=$(mktemp)
            response=$(curl -s -w "%{http_code}" -o "$temp_api_file" --connect-timeout 5 "$api_url" 2>/dev/null)

            if [[ "$response" == "200" ]]; then
                print_status "success" "管理API检查通过"
                if [[ -f /tmp/api_check.json ]]; then
                    echo
                    print_status "info" "API响应:"
                    cat /tmp/api_check.json | python3 -m json.tool 2>/dev/null || cat /tmp/api_check.json
                fi

                # 测试统计API
                local enable_stats=$(grep "^ENABLE_STATS=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
                if [[ "$enable_stats" == "true" ]]; then
                    print_status "info" "测试统计API..."
                    local stats_url="http://localhost:$port/_api/stats?key=$api_key"
                    local temp_stats_file=$(mktemp)
                    local stats_response=$(curl -s -w "%{http_code}" -o "$temp_stats_file" --connect-timeout 5 "$stats_url" 2>/dev/null)

                    if [[ "$stats_response" == "200" ]]; then
                        print_status "success" "统计API检查通过"
                        if [[ -f "$temp_stats_file" ]]; then
                            echo
                            print_status "info" "统计数据预览:"
                            if command -v jq &> /dev/null; then
                                echo "总请求数: $(cat "$temp_stats_file" | jq -r '.stats.totalRequests // "0"')"
                                echo "成功请求数: $(cat "$temp_stats_file" | jq -r '.stats.successfulRequests // "0"')"
                            elif command -v python3 &> /dev/null; then
                                echo "总请求数: $(cat "$temp_stats_file" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('stats',{}).get('totalRequests',0))" 2>/dev/null || echo "0")"
                            fi
                        fi
                        rm -f "$temp_stats_file"
                    else
                        print_status "warning" "统计API检查失败 (HTTP: $stats_response)"
                    fi
                fi
            else
                print_status "warning" "管理API检查失败 (HTTP: $response)"
            fi
        fi

        # 清理临时文件
        rm -f "$temp_health_file" "$temp_api_file" 2>/dev/null
    fi

    echo
    print_status "info" "诊断完成"
}

# 服务健康检查（增强版）
health_check() {
    print_status "info" "执行健康检查..."

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_status "error" "配置文件不存在"
        return $EXIT_CONFIG_ERROR
    fi

    local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2)
    local api_key=$(grep "^API_KEY=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)

    if [[ -z "$port" ]]; then
        print_status "error" "无法从配置文件获取端口信息"
        return $EXIT_CONFIG_ERROR
    fi

    # 检查服务状态
    print_status "info" "检查服务进程状态..."
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "error" "服务未运行"
        print_status "info" "服务状态详情:"
        systemctl status "$SERVICE_NAME" --no-pager -l | head -10
        return $EXIT_SERVICE_ERROR
    fi
    print_status "success" "服务进程运行正常"

    # 检查端口监听
    print_status "info" "检查端口 $port 监听状态..."
    local port_check=false
    local port_info=""

    if command -v ss &> /dev/null; then
        port_info=$(ss -tuln | grep ":$port ")
        [[ -n "$port_info" ]] && port_check=true
    elif command -v netstat &> /dev/null; then
        port_info=$(netstat -tuln | grep ":$port ")
        [[ -n "$port_info" ]] && port_check=true
    elif command -v lsof &> /dev/null; then
        port_info=$(lsof -i ":$port" 2>/dev/null)
        [[ -n "$port_info" ]] && port_check=true
    else
        # 使用连接测试作为最后手段
        if timeout 3 bash -c "</dev/tcp/localhost/$port" &>/dev/null; then
            port_check=true
            port_info="端口可连接（通过连接测试验证）"
        fi
    fi

    if [[ "$port_check" == "true" ]]; then
        print_status "success" "端口 $port 正在监听"
        if [[ -n "$port_info" ]]; then
            print_status "info" "端口详情: $port_info"
        fi
    else
        print_status "error" "端口 $port 未监听"
        print_status "info" "可能原因:"
        echo "  1. 服务启动失败"
        echo "  2. 端口配置错误"
        echo "  3. 防火墙阻止"
        echo "  4. 权限问题"
        return $EXIT_SERVICE_ERROR
    fi

    # 检查API响应
    print_status "info" "检查API响应..."
    local health_url="http://localhost:$port/health"
    local temp_health_response=$(mktemp)
    local response=$(curl -s -w "%{http_code}" -o "$temp_health_response" --connect-timeout 10 --max-time 30 "$health_url" 2>/dev/null)

    if [[ "$response" == "200" ]]; then
        print_status "success" "基础健康检查通过"
    else
        # 尝试管理API健康检查
        health_url="http://localhost:$port/_api/health"
        if [[ -n "$api_key" ]]; then
            health_url="${health_url}?key=$api_key"
        fi

        response=$(curl -s -w "%{http_code}" -o "$temp_health_response" --connect-timeout 10 --max-time 30 "$health_url" 2>/dev/null)
    fi

    if [[ "$response" == "200" ]]; then
        print_status "success" "服务健康检查通过"

        # 显示健康检查响应
        if [[ -f "$temp_health_response" ]] && [[ -s "$temp_health_response" ]]; then
            echo
            print_status "info" "健康检查响应:"
            if command -v jq &> /dev/null; then
                jq . "$temp_health_response" 2>/dev/null || cat "$temp_health_response"
            elif command -v python3 &> /dev/null; then
                python3 -m json.tool "$temp_health_response" 2>/dev/null || cat "$temp_health_response"
            else
                cat "$temp_health_response"
            fi
        fi

        rm -f "$temp_health_response"
        return $EXIT_SUCCESS
    else
        print_status "error" "健康检查失败 (HTTP: $response)"
        print_status "info" "测试的URL: $health_url"

        # 显示错误响应
        if [[ -f "$temp_health_response" ]] && [[ -s "$temp_health_response" ]]; then
            print_status "info" "错误响应:"
            cat "$temp_health_response"
        fi

        rm -f "$temp_health_response"

        # 提供故障排除建议
        echo
        print_status "info" "故障排除建议:"
        echo "  1. 检查服务日志: sudo journalctl -u $SERVICE_NAME -n 50"
        echo "  2. 检查配置文件: cat $CONFIG_FILE"
        echo "  3. 手动测试连接: curl -v http://localhost:$port/health"
        echo "  4. 检查防火墙: sudo firewall-cmd --list-ports"

        return $EXIT_SERVICE_ERROR
    fi
}

# 性能监控
performance_monitor() {
    print_status "info" "性能监控数据"
    echo
    
    # 系统资源
    print_status "title" "=== 系统资源 ==="
    echo "CPU使用率: $(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')"
    echo "内存使用: $(free -h | awk 'NR==2{printf "%.1f%% (%s/%s)\n", $3/$2*100, $3, $2}')"
    echo "磁盘使用: $(df -h / | awk 'NR==2{printf "%s (%s)\n", $5, $4}')"
    
    # 服务进程
    echo
    print_status "title" "=== 服务进程 ==="
    ps aux | grep "[d]eno.*server.ts" | head -5
    
    # 网络连接
    echo
    print_status "title" "=== 网络连接 ==="
    if [[ -f "$CONFIG_FILE" ]]; then
        local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2)

        # 使用多种方法检查端口监听
        if command -v ss &> /dev/null; then
            echo "端口监听状态:"
            ss -tuln | grep ":$port" || echo "端口 $port 未监听"
            echo "活动连接数: $(ss -an | grep ":$port" | grep ESTAB | wc -l)"
        elif command -v netstat &> /dev/null; then
            echo "端口监听状态:"
            netstat -tuln | grep ":$port" || echo "端口 $port 未监听"
            echo "活动连接数: $(netstat -an | grep ":$port" | grep ESTABLISHED | wc -l)"
        elif command -v lsof &> /dev/null; then
            echo "端口监听状态:"
            lsof -i ":$port" || echo "端口 $port 未监听"
            echo "活动连接数: $(lsof -i ":$port" | grep ESTABLISHED | wc -l)"
        else
            echo "无法检查网络连接状态（缺少 ss/netstat/lsof 命令）"
            print_status "warning" "建议安装 net-tools 或 iproute2 包"
        fi
    fi
    
    # 统计数据
    echo
    print_status "title" "=== 请求统计 ==="

    # 首先尝试从API获取统计数据
    local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    local api_key=$(grep "^API_KEY=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    local enable_stats=$(grep "^ENABLE_STATS=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)

    if [[ "$enable_stats" == "true" ]] && [[ -n "$port" ]]; then
        local stats_url="http://localhost:$port/_api/stats"
        if [[ -n "$api_key" ]]; then
            stats_url="${stats_url}?key=$api_key"
        fi

        print_status "info" "从API获取统计数据..."
        local api_response=$(curl -s --connect-timeout 5 --max-time 10 "$stats_url" 2>/dev/null)

        if [[ $? -eq 0 ]] && [[ -n "$api_response" ]]; then
            # 尝试解析JSON响应
            if command -v jq &> /dev/null; then
                echo "总请求数: $(echo "$api_response" | jq -r '.stats.totalRequests // "N/A"')"
                echo "成功请求数: $(echo "$api_response" | jq -r '.stats.successfulRequests // "N/A"')"
                echo "失败请求数: $(echo "$api_response" | jq -r '.stats.failedRequests // "N/A"')"
                echo "平均响应时间: $(echo "$api_response" | jq -r '.stats.averageResponseTime // "N/A"')ms"
                echo "活动IP数: $(echo "$api_response" | jq -r '.rateLimiter.totalIPs // "N/A"')"
                echo "当前并发数: $(echo "$api_response" | jq -r '.concurrency.totalCount // "N/A"')"
            elif command -v python3 &> /dev/null; then
                echo "总请求数: $(echo "$api_response" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('stats',{}).get('totalRequests','N/A'))" 2>/dev/null || echo "N/A")"
                echo "成功请求数: $(echo "$api_response" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('stats',{}).get('successfulRequests','N/A'))" 2>/dev/null || echo "N/A")"
                echo "失败请求数: $(echo "$api_response" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('stats',{}).get('failedRequests','N/A'))" 2>/dev/null || echo "N/A")"
                echo "平均响应时间: $(echo "$api_response" | python3 -c "import sys,json; data=json.load(sys.stdin); print(str(data.get('stats',{}).get('averageResponseTime','N/A'))+'ms')" 2>/dev/null || echo "N/A")"
            else
                # 简单的文本解析
                echo "API响应: $api_response"
            fi
        else
            print_status "warning" "无法从API获取统计数据，尝试从日志获取..."
            # 从日志文件获取统计
            if [[ -f "$LOG_FILE" ]]; then
                echo "最近1小时请求数: $(grep "$(date -d '1 hour ago' '+%Y-%m-%d %H')" "$LOG_FILE" 2>/dev/null | wc -l)"
                echo "最近24小时请求数: $(grep "$(date -d '1 day ago' '+%Y-%m-%d')" "$LOG_FILE" 2>/dev/null | wc -l)"
            else
                echo "无统计数据可用"
            fi
        fi
    elif [[ "$enable_stats" != "true" ]]; then
        print_status "warning" "统计功能未启用"
        echo "要启用统计功能，请运行脚本选择 '修改配置' -> '统计功能'"
        echo "或手动设置环境变量: ENABLE_STATS=true"
    else
        print_status "warning" "无法获取端口信息，从日志获取统计..."
        if [[ -f "$LOG_FILE" ]]; then
            echo "最近1小时请求数: $(grep "$(date -d '1 hour ago' '+%Y-%m-%d %H')" "$LOG_FILE" 2>/dev/null | wc -l)"
            echo "最近24小时请求数: $(grep "$(date -d '1 day ago' '+%Y-%m-%d')" "$LOG_FILE" 2>/dev/null | wc -l)"
        else
            echo "无统计数据可用"
        fi
    fi
    
    echo
    read -p "按回车键继续..."
}

# 测试统计功能
test_stats_function() {
    print_status "info" "测试统计功能..."

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_status "error" "配置文件不存在"
        return $EXIT_CONFIG_ERROR
    fi

    local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    local api_key=$(grep "^API_KEY=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    local enable_stats=$(grep "^ENABLE_STATS=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)

    if [[ "$enable_stats" != "true" ]]; then
        print_status "warning" "统计功能未启用"
        read -p "是否启用统计功能? (Y/n): " enable_now
        if [[ ! "$enable_now" =~ ^[Nn]$ ]]; then
            sed -i "s/^ENABLE_STATS=.*/ENABLE_STATS=true/" "$CONFIG_FILE"
            print_status "success" "统计功能已启用"
            print_status "info" "重启服务以应用更改..."
            restart_service
            if [[ $? -ne 0 ]]; then
                print_status "error" "服务重启失败"
                return $EXIT_SERVICE_ERROR
            fi
        else
            print_status "info" "测试取消"
            return 0
        fi
    fi

    # 检查服务是否运行
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "error" "服务未运行，请先启动服务"
        return $EXIT_SERVICE_ERROR
    fi

    print_status "info" "发送测试请求..."

    # 发送几个测试请求
    local test_urls=("httpbin.org/get" "httpbin.org/ip" "httpbin.org/user-agent")
    local success_count=0

    for url in "${test_urls[@]}"; do
        print_status "info" "测试请求: $url"
        local response=$(curl -s -w "%{http_code}" -o /dev/null --connect-timeout 10 "http://localhost:$port/$url" 2>/dev/null)

        if [[ "$response" == "200" ]]; then
            print_status "success" "请求成功 (HTTP: $response)"
            success_count=$((success_count + 1))
        else
            print_status "warning" "请求失败 (HTTP: $response)"
        fi
        sleep 1
    done

    print_status "info" "等待统计数据更新..."
    sleep 2

    # 检查统计数据
    print_status "info" "获取统计数据..."
    local stats_url="http://localhost:$port/_api/stats"
    if [[ -n "$api_key" ]]; then
        stats_url="${stats_url}?key=$api_key"
    fi

    local stats_response=$(curl -s --connect-timeout 10 "$stats_url" 2>/dev/null)

    if [[ $? -eq 0 ]] && [[ -n "$stats_response" ]]; then
        echo
        print_status "success" "统计数据获取成功！"
        print_separator

        if command -v jq &> /dev/null; then
            echo "📊 统计摘要:"
            echo "  总请求数: $(echo "$stats_response" | jq -r '.stats.totalRequests // "0"')"
            echo "  成功请求数: $(echo "$stats_response" | jq -r '.stats.successfulRequests // "0"')"
            echo "  失败请求数: $(echo "$stats_response" | jq -r '.stats.failedRequests // "0"')"
            echo "  平均响应时间: $(echo "$stats_response" | jq -r '.stats.averageResponseTime // "0"')ms"
            echo "  活动IP数: $(echo "$stats_response" | jq -r '.rateLimiter.totalIPs // "0"')"
            echo "  当前并发数: $(echo "$stats_response" | jq -r '.concurrency.totalCount // "0"')"

            echo
            echo "🌐 热门域名:"
            echo "$stats_response" | jq -r '.stats.topDomains | to_entries[] | "  \(.key): \(.value) 次"' 2>/dev/null || echo "  无数据"

        elif command -v python3 &> /dev/null; then
            echo "📊 统计摘要:"
            echo "  总请求数: $(echo "$stats_response" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('stats',{}).get('totalRequests',0))" 2>/dev/null || echo "0")"
            echo "  成功请求数: $(echo "$stats_response" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('stats',{}).get('successfulRequests',0))" 2>/dev/null || echo "0")"
            echo "  失败请求数: $(echo "$stats_response" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('stats',{}).get('failedRequests',0))" 2>/dev/null || echo "0")"
        else
            echo "📊 原始统计数据:"
            echo "$stats_response"
        fi

        print_separator
        print_status "success" "统计功能测试完成！"

        if [[ $success_count -gt 0 ]]; then
            print_status "info" "✅ 统计功能正常工作"
            print_status "info" "✅ 成功处理 $success_count 个测试请求"
        else
            print_status "warning" "⚠️ 所有测试请求都失败了，请检查网络连接"
        fi

    else
        print_status "error" "无法获取统计数据"
        print_status "info" "可能的原因:"
        echo "  1. API密钥不正确"
        echo "  2. 统计功能未正确启用"
        echo "  3. 服务内部错误"
        echo "  4. 网络连接问题"

        # 提供调试信息
        echo
        print_status "info" "调试信息:"
        echo "  统计API URL: $stats_url"
        echo "  配置文件中的统计设置: $enable_stats"
        echo "  API密钥设置: $([ -n "$api_key" ] && echo "已设置" || echo "未设置")"
    fi
}

# 获取当前版本
get_current_service_version() {
    if [[ -f "$INSTALL_DIR/server.ts" ]]; then
        # 尝试从健康检查端点获取版本
        local port=$(grep "^PORT=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 || echo "$DEFAULT_PORT")
        local current_version=""

        # 如果服务正在运行，尝试从API获取版本
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            current_version=$(curl -s --connect-timeout 5 "http://localhost:$port/version" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4 2>/dev/null)
        fi

        # 如果API获取失败，从 server.ts 的 VERSION 常量中提取
        if [[ -z "$current_version" ]]; then
            current_version=$(grep -o "const VERSION = '[0-9]\+\.[0-9]\+\.[0-9]\+'" "$INSTALL_DIR/server.ts" 2>/dev/null | head -1 | sed "s/const VERSION = '//;s/'//")
        fi

        echo "$current_version"
    fi
}

# 获取远程版本
get_remote_service_version() {
    local remote_version=""
    if remote_version=$(timeout 30 curl -s --connect-timeout 10 --max-time 25 --retry 2 \
        "$GITHUB_REPO/server.ts" 2>/dev/null | grep -o "const VERSION = '[0-9]\+\.[0-9]\+\.[0-9]\+'" | head -1 | sed "s/const VERSION = '//;s/'//" 2>/dev/null); then
        echo "$remote_version"
    fi
}

# 更新服务
update_service() {
  print_status "info" "开始更新服务..."

  # 检查网络连接
  check_network || {
      print_status "error" "网络连接失败，无法更新"
      return $EXIT_NETWORK_ERROR
  }

  # 获取当前版本和远程版本
  local current_version=$(get_current_service_version)
  local remote_version=$(get_remote_service_version)

  if [[ -n "$current_version" ]] && [[ -n "$remote_version" ]]; then
      print_status "info" "当前版本: $current_version"
      print_status "info" "远程版本: $remote_version"

      if [[ "$current_version" == "$remote_version" ]]; then
          print_status "success" "服务已是最新版本"
          return $EXIT_SUCCESS
      fi
  else
      print_status "warning" "无法获取版本信息，继续更新..."
  fi

  # 创建备份目录
  mkdir -p "$BACKUP_DIR"

  # 备份当前版本
  if [[ -f "$INSTALL_DIR/server.ts" ]]; then
      local backup_file="$BACKUP_DIR/server.ts.backup.$(date +%Y%m%d_%H%M%S)"
      cp "$INSTALL_DIR/server.ts" "$backup_file"
      print_status "info" "当前版本已备份到: $backup_file"
  fi

  # 备份配置文件
  if [[ -f "$CONFIG_FILE" ]]; then
      local config_backup="$BACKUP_DIR/config.env.backup.$(date +%Y%m%d_%H%M%S)"
      cp "$CONFIG_FILE" "$config_backup"
      print_status "info" "配置文件已备份到: $config_backup"
  fi

  # 停止服务
  local was_running=false
  if systemctl is-active --quiet "$SERVICE_NAME"; then
      was_running=true
      print_status "info" "停止服务..."
      stop_service || {
          print_status "error" "无法停止服务"
          return $EXIT_SERVICE_ERROR
      }
  fi

  # 下载新版本
  if download_project; then
      print_status "success" "新版本下载成功"

      # 如果服务之前在运行，则重新启动
      if [[ "$was_running" == "true" ]]; then
          if start_service; then
              print_status "success" "服务更新完成"
              return $EXIT_SUCCESS
          else
              print_status "error" "服务启动失败，尝试恢复备份..."

              # 恢复备份
              local backup_file=$(ls -t "$BACKUP_DIR"/server.ts.backup.* 2>/dev/null | head -1)
              if [[ -n "$backup_file" ]]; then
                  cp "$backup_file" "$INSTALL_DIR/server.ts"
                  if start_service; then
                      print_status "warning" "已恢复到之前版本"
                      return $EXIT_SUCCESS
                  else
                      print_status "error" "恢复备份后仍无法启动服务"
                      return $EXIT_SERVICE_ERROR
                  fi
              else
                  print_status "error" "未找到备份文件"
                  return $EXIT_GENERAL_ERROR
              fi
          fi
      else
          print_status "success" "服务更新完成（服务未启动）"
          return $EXIT_SUCCESS
      fi
  else
      print_status "error" "更新失败"

      # 如果服务之前在运行，尝试启动原服务
      if [[ "$was_running" == "true" ]]; then
          start_service || print_status "warning" "原服务也无法启动"
      fi

      return $EXIT_NETWORK_ERROR
  fi
}

# 添加系统优化功能
optimize_system() {
  print_status "info" "系统优化..."
  
  echo
  print_status "warning" "请选择要优化的项目:"
  echo "1) 优化系统限制 (文件描述符、最大连接数)"
  echo "2) 优化内核网络参数"
  echo "3) 创建SWAP空间 (如果内存小于2GB)"
  echo "4) 全部优化"
  echo "0) 返回主菜单"
  echo
  
  read -p "请选择 [0-4]: " choice
  
  case $choice in
    1) optimize_system_limits ;;
    2) optimize_network_params ;;
    3) create_swap ;;
    4)
      optimize_system_limits
      optimize_network_params
      create_swap
      ;;
    0) return 0 ;;
    *) print_status "error" "无效选择" ;;
  esac
}

# 优化系统限制
optimize_system_limits() {
  print_status "info" "优化系统限制..."
  
  # 设置文件描述符限制
  if ! grep -q "* soft nofile 65535" /etc/security/limits.conf; then
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf
    print_status "success" "文件描述符限制已优化"
  else
    print_status "info" "文件描述符限制已设置"
  fi
  
  # 设置最大进程数
  if ! grep -q "* soft nproc 65535" /etc/security/limits.conf; then
    echo "* soft nproc 65535" >> /etc/security/limits.conf
    echo "* hard nproc 65535" >> /etc/security/limits.conf
    print_status "success" "最大进程数限制已优化"
  else
    print_status "info" "最大进程数限制已设置"
  fi
  
  print_status "info" "系统限制优化完成，重启后生效"
}

# 优化网络参数
optimize_network_params() {
  print_status "info" "优化网络参数..."
  
  local sysctl_file="/etc/sysctl.d/99-ciao-cors.conf"
  
  cat > "$sysctl_file" << EOF
# CIAO-CORS 网络优化参数
# 增加连接队列
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768

# 优化TCP参数
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200

# 增加端口范围
net.ipv4.ip_local_port_range = 1024 65535
EOF

  sysctl -p "$sysctl_file"
  print_status "success" "网络参数优化完成"
}

# 创建SWAP空间
create_swap() {
  # 检查内存大小和已有SWAP
  local mem_total=$(free -m | awk '/^Mem:/{print $2}')
  local swap_total=$(free -m | awk '/^Swap:/{print $2}')

  if [[ $mem_total -ge 2048 ]]; then
    print_status "info" "内存大于2GB (${mem_total}MB)，无需创建SWAP"
    return 0
  fi

  if [[ $swap_total -gt 0 ]]; then
    print_status "info" "已存在${swap_total}MB SWAP空间，无需创建"
    return 0
  fi

  # 检查磁盘空间
  local free_space=$(df -m / | awk 'NR==2 {print $4}')
  local swap_size=$((mem_total * 2))
  if [[ $swap_size -gt 4096 ]]; then
    swap_size=4096
  fi

  if [[ $free_space -lt $((swap_size + 500)) ]]; then
    print_status "warning" "磁盘空间不足，无法创建${swap_size}MB SWAP空间"
    return 1
  fi

  print_status "info" "创建SWAP空间..."

  # 安全地创建SWAP文件
  if fallocate -l "${swap_size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size 2>/dev/null; then
    chmod 600 /swapfile
    if mkswap /swapfile && swapon /swapfile; then
      # 添加到fstab
      if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
      fi
      print_status "success" "创建了${swap_size}MB SWAP空间"
    else
      print_status "error" "SWAP文件创建失败"
      rm -f /swapfile
      return 1
    fi
  else
    print_status "error" "无法创建SWAP文件"
    return 1
  fi
}

# ==================== 卸载函数 ====================

# 检查脚本更新
check_script_update() {
    print_status "info" "检查脚本更新..."

    local remote_version=""
    # 增加更宽松的超时设置和更好的错误处理
    if remote_version=$(timeout 60 curl -s --connect-timeout 15 --max-time 45 --retry 3 --retry-delay 5 \
        --user-agent "CIAO-CORS-Deploy/$SCRIPT_VERSION" \
        "$GITHUB_REPO/deploy.sh" 2>/dev/null | grep "^SCRIPT_VERSION=" | head -1 | cut -d'"' -f2 2>/dev/null); then

        # 验证版本号格式
        if [[ -n "$remote_version" ]] && [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if [[ "$remote_version" != "$SCRIPT_VERSION" ]]; then
                print_status "warning" "发现新版本: $remote_version (当前: $SCRIPT_VERSION)"
                read -p "是否更新脚本? (y/N): " update_script
                if [[ "$update_script" =~ ^[Yy]$ ]]; then
                    print_status "info" "下载新版本脚本..."
                    local script_backup="$(dirname "$0")/deploy.sh.backup.$(date +%Y%m%d_%H%M%S)"

                    # 确保备份目录存在且可写
                    if ! cp "$0" "$script_backup" 2>/dev/null; then
                        print_status "error" "无法创建备份文件"
                        return $EXIT_GENERAL_ERROR
                    fi

                    # 下载新脚本到临时文件，增加更宽松的超时
                    if timeout 120 curl -fsSL --connect-timeout 20 --max-time 90 --retry 3 --retry-delay 5 \
                       --user-agent "CIAO-CORS-Deploy/$SCRIPT_VERSION" \
                       "$GITHUB_REPO/deploy.sh" -o "$0.new" 2>/dev/null; then

                        # 验证下载的脚本
                        if [[ -s "$0.new" ]] && head -1 "$0.new" | grep -q "^#!/bin/bash"; then
                            # 额外验证：检查脚本是否包含关键函数
                            if grep -q "main()" "$0.new" && grep -q "SCRIPT_VERSION=" "$0.new"; then
                                chmod +x "$0.new"
                                if mv "$0.new" "$0" 2>/dev/null; then
                                    print_status "success" "脚本更新成功，请重新运行脚本"
                                    print_status "info" "旧版本已备份到: $script_backup"
                                    exit $EXIT_SUCCESS
                                else
                                    print_status "error" "无法替换脚本文件"
                                    rm -f "$0.new"
                                fi
                            else
                                print_status "error" "下载的脚本文件不完整"
                                rm -f "$0.new"
                            fi
                        else
                            print_status "error" "下载的脚本文件无效"
                            rm -f "$0.new"
                        fi
                    else
                        print_status "error" "脚本更新失败，请检查网络连接"
                        rm -f "$0.new"
                    fi
                fi
            else
                print_status "success" "脚本已是最新版本"
            fi
        else
            print_status "warning" "远程版本号格式无效: $remote_version"
        fi
    else
        print_status "warning" "无法检查脚本更新，请检查网络连接或稍后重试"
        print_status "info" "你也可以手动从 https://github.com/bestZwei/ciao-cors 下载最新版本"
    fi

    # 一并检查服务（server.ts）是否有更新
    check_service_update
}

# 检查服务更新（仅检测并提示，实际更新交给 update_service）
check_service_update() {
    print_status "info" "检查服务更新..."

    local current_version=$(get_current_service_version)
    local remote_version=$(get_remote_service_version)

    if [[ -z "$current_version" ]]; then
        print_status "warning" "未找到已安装的服务 ($INSTALL_DIR/server.ts)，无法检查服务更新"
        return $EXIT_GENERAL_ERROR
    fi

    if [[ -z "$remote_version" ]]; then
        print_status "warning" "无法获取远程服务版本，请检查网络连接"
        return $EXIT_NETWORK_ERROR
    fi

    print_status "info" "当前服务版本: $current_version"
    print_status "info" "远程服务版本: $remote_version"

    if [[ "$current_version" != "$remote_version" ]]; then
        print_status "warning" "发现服务新版本: $remote_version (当前: $current_version)"
        read -p "是否更新服务? (y/N): " update_svc
        if [[ "$update_svc" =~ ^[Yy]$ ]]; then
            update_service
        else
            print_status "info" "已跳过服务更新"
        fi
    else
        print_status "success" "服务已是最新版本"
    fi
}

# 完全卸载
uninstall_service() {
    echo
    print_status "warning" "⚠️  即将完全卸载 CIAO-CORS 服务"
    print_status "warning" "这将删除所有相关文件和配置"
    echo

    # 显示将要删除的内容
    print_status "info" "将要删除的内容:"
    echo "  - 服务文件: $SYSTEMD_SERVICE_FILE"
    echo "  - 安装目录: $INSTALL_DIR"
    echo "  - 配置文件: $CONFIG_FILE"
    echo "  - 日志文件: $LOG_FILE"
    echo "  - 备份目录: $BACKUP_DIR"
    echo

    read -p "确定要卸载吗? (输入 'YES' 确认): " confirm

    if [[ "$confirm" != "YES" ]]; then
        print_status "info" "取消卸载"
        return $EXIT_SUCCESS
    fi

    print_status "info" "开始卸载..."

    # 停止并禁用服务
    if systemctl list-unit-files | grep -q "^$SERVICE_NAME.service"; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            print_status "info" "停止服务..."
            systemctl stop "$SERVICE_NAME" || print_status "warning" "停止服务失败"
        fi

        if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            print_status "info" "禁用服务自启动..."
            systemctl disable "$SERVICE_NAME" || print_status "warning" "禁用服务失败"
        fi
    fi

    # 删除服务文件
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        rm -f "$SYSTEMD_SERVICE_FILE"
        systemctl daemon-reload
        print_status "info" "系统服务已删除"
    fi

    # 获取端口信息（用于后续防火墙配置）
    local port=""
    if [[ -f "$CONFIG_FILE" ]]; then
        port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2 2>/dev/null)
    fi

    # 删除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        print_status "info" "安装目录已删除"
    fi

    # 删除配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        print_status "info" "配置文件已删除"
    fi

    # 删除配置目录（如果为空）
    rmdir "$(dirname "$CONFIG_FILE")" 2>/dev/null || true

    # 删除日志文件
    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
        print_status "info" "日志文件已删除"
    fi

    # 删除备份目录
    if [[ -d "$BACKUP_DIR" ]]; then
        read -p "是否删除备份目录? (y/N): " remove_backups
        if [[ "$remove_backups" =~ ^[Yy]$ ]]; then
            rm -rf "$BACKUP_DIR"
            print_status "info" "备份目录已删除"
        else
            print_status "info" "备份目录保留: $BACKUP_DIR"
        fi
    fi

    # 关闭防火墙端口（可选）
    if [[ -n "$port" ]]; then
        read -p "是否关闭防火墙端口 $port? (y/N): " close_port
        if [[ "$close_port" =~ ^[Yy]$ ]]; then
            # 检查是否为SSH端口，避免关闭SSH端口导致连接断开
            local ssh_ports=("22" "2222" "2022")
            local is_ssh_port=false
            for ssh_port in "${ssh_ports[@]}"; do
                if [[ "$port" == "$ssh_port" ]]; then
                    is_ssh_port=true
                    break
                fi
            done

            if [[ "$is_ssh_port" == "true" ]]; then
                print_status "warning" "端口 $port 可能是SSH端口，为安全起见不会关闭"
            else
                if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
                    firewall-cmd --permanent --remove-port="$port/tcp" 2>/dev/null && firewall-cmd --reload 2>/dev/null
                    print_status "info" "firewalld端口已关闭"
                elif command -v ufw &> /dev/null; then
                    ufw delete allow "$port/tcp" 2>/dev/null
                    print_status "info" "ufw端口已关闭"
                else
                    print_status "warning" "请手动关闭防火墙端口 $port"
                fi
            fi
        fi
    fi

    print_status "success" "卸载完成"

    # 询问是否删除Deno
    echo
    read -p "是否同时卸载Deno? (y/N): " remove_deno
    if [[ "$remove_deno" =~ ^[Yy]$ ]]; then
        # 删除Deno安装
        rm -rf /usr/local/deno
        rm -f /usr/local/bin/deno
        rm -rf ~/.deno
        print_status "success" "Deno已卸载"
    fi

    echo
    print_status "title" "感谢使用 CIAO-CORS！"
    print_status "info" "项目地址: https://github.com/bestZwei/ciao-cors"
    print_status "info" "如有问题或建议，请提交Issue或Pull Request"
    exit $EXIT_SUCCESS
}

# ==================== 主菜单和交互 ====================

# 显示主菜单
show_main_menu() {
    clear
    print_separator
    print_status "title" "   🚀 CIAO-CORS 一键部署管理脚本 v$SCRIPT_VERSION"
    print_status "title" "   📦 项目地址: https://github.com/bestZwei/ciao-cors"
    print_separator
    echo
    
    # 检查安装状态
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            print_status "success" "服务状态: 运行中 ✅"
        else
            print_status "warning" "服务状态: 已停止 ⏹️"
        fi
        
        if [[ -f "$CONFIG_FILE" ]]; then
            local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2)
            print_status "info" "服务端口: $port"
        fi
        echo
        
        print_status "cyan" "📋 服务管理"
        echo "  1) 启动服务"
        echo "  2) 停止服务"
        echo "  3) 重启服务"
        echo "  4) 查看状态"
        echo "  5) 查看日志"
        echo
        
        print_status "cyan" "⚙️  配置管理"
        echo "  6) 修改配置"
        echo "  7) 查看配置"
        echo "  8) 备份配置"
        echo
        
        print_status "cyan" "📊 监控维护"
        echo "  9) 健康检查"
        echo " 10) 服务诊断"
        echo " 11) 性能监控"
        echo " 12) 测试统计功能"
        echo " 13) 更新服务"
        echo " 14) 系统优化"
        echo

        print_status "cyan" "🗑️  其他操作"
        echo " 15) 检查更新（脚本 + 服务）"
        echo " 16) 完全卸载"
        echo "  0) 退出脚本"
        
    else
        print_status "warning" "服务状态: 未安装 ❌"
        echo
        
        print_status "cyan" "📦 安装选项"
        echo "  1) 全新安装"
        echo "  2) 检查系统要求"
        echo "  3) 仅安装Deno"
        echo "  0) 退出脚本"
    fi
    
    echo
    print_separator
}

# 显示安装菜单
show_install_menu() {
    clear
    print_separator
    print_status "title" "   📦 CIAO-CORS 安装向导"
    print_status "title" "   📦 项目地址: https://github.com/bestZwei/ciao-cors"
    print_separator
    echo
    
    print_status "info" "安装步骤:"
    echo "  1. 检查系统要求"
    echo "  2. 安装/检查 Deno"
    echo "  3. 下载项目文件"
    echo "  4. 创建配置文件"
    echo "  5. 配置防火墙"
    echo "  6. 创建系统服务"
    echo "  7. 启动服务"
    echo
    
    read -p "确定开始安装? (Y/n): " start_install
    
    if [[ ! "$start_install" =~ ^[Nn]$ ]]; then
        # 执行安装步骤
        security_check
        check_requirements || return 1
        
        if ! check_deno_installation; then
            install_deno || return 1
        fi
        
        download_project || return 1
        create_config || return 1
        
        local port=$(grep "^PORT=" "$CONFIG_FILE" | cut -d'=' -f2)
        configure_firewall "$port"
        
        create_systemd_service || return 1
        start_service || return 1
        
        print_status "success" "🎉 安装完成！"
        show_service_info
        
        echo
        read -p "按回车键继续..."
    fi
}

# 处理用户输入
handle_user_input() {
  local choice=$1
  
  if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
    # 已安装状态的菜单处理
    case $choice in
      1) start_service ;;
      2) stop_service ;;
      3) restart_service ;;
      4) service_status ;;
      5) view_logs ;;
      6) modify_config ;;
      7) show_config ;;
      8) backup_config ;;
      9) health_check ;;
      10) service_diagnosis ;;
      11) performance_monitor ;;
      12) test_stats_function ;;
      13) update_service ;;
      14) optimize_system ;;
      15) check_script_update ;;
      16) uninstall_service ;;
      0)
          print_status "info" "再见! 👋"
          exit $EXIT_SUCCESS
          ;;
      *)
          print_status "error" "无效选择，请重试"
          sleep 2
          ;;
    esac
  else
    # 未安装状态的菜单处理
    case $choice in
      1) show_install_menu ;;
      2) check_requirements ;;
      3) 
          if ! check_deno_installation; then
              install_deno
          else
              print_status "info" "Deno已安装"
          fi
          ;;
      0)
          print_status "info" "再见! 👋"
          exit 0
          ;;
      *)
          print_status "error" "无效选择，请重试"
          sleep 2
          ;;
    esac
  fi
}

# ==================== 主函数 ====================

# 清理函数
cleanup() {
    local exit_code=$?

    # 移除锁文件
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi

    # 如果是异常退出，显示错误信息
    if [[ $exit_code -ne 0 ]]; then
        print_status "error" "脚本异常退出 (退出码: $exit_code)"
        print_status "info" "如需帮助，请查看日志文件: $LOG_FILE"
    fi

    exit $exit_code
}

# 信号处理
handle_signal() {
    local signal=$1
    print_status "warning" "收到信号: $signal"
    print_status "info" "正在清理并退出..."
    cleanup
}

# 脚本主入口
main() {
    # 设置错误处理
    set -eE
    trap 'cleanup' EXIT
    trap 'handle_signal SIGINT' INT
    trap 'handle_signal SIGTERM' TERM

    # 检查root权限
    check_root

    # 创建锁文件
    create_lock

    # 显示脚本信息
    print_status "info" "CIAO-CORS 部署脚本 v$SCRIPT_VERSION 启动"
    print_status "info" "项目地址: https://github.com/bestZwei/ciao-cors"
    print_status "info" "PID: $$"

    # 主循环
    while true; do
        # 重置错误处理，避免菜单选择错误导致脚本退出
        set +e

        show_main_menu
        echo

        # 读取用户输入，增加超时
        local choice=""
        read -t 300 -p "请选择操作 [0-16]: " choice 2>/dev/null || {
            echo
            print_status "warning" "输入超时，退出脚本"
            break
        }

        echo

        # 验证输入
        if [[ -z "$choice" ]]; then
            print_status "warning" "未输入任何内容"
            sleep 2
            continue
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            print_status "error" "无效输入，请输入数字"
            sleep 2
            continue
        fi

        # 处理用户输入
        handle_user_input "$choice"
        local result=$?

        # 如果不是退出选择，等待用户确认
        if [[ "$choice" != "0" ]]; then
            echo
            if [[ $result -eq 0 ]]; then
                read -p "操作完成，按回车键返回主菜单..."
            else
                read -p "操作失败，按回车键返回主菜单..."
            fi
        else
            break
        fi

        # 恢复错误处理
        set -eE
    done

    print_status "info" "感谢使用 CIAO-CORS 部署脚本！"
    print_status "info" "项目地址: https://github.com/bestZwei/ciao-cors"
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
