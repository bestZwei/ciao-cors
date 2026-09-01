#!/bin/bash

# CIAO-CORS 版本更新脚本
# 用于统一更新所有文件中的版本号

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    local type=$1
    local message=$2
    case $type in
        "info")    echo -e "${BLUE}[INFO]${NC} $message" ;;
        "success") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "warning") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        "error")   echo -e "${RED}[ERROR]${NC} $message" ;;
    esac
}

# 获取当前版本
get_current_version() {
    local version=""

    # 首先尝试从 version: '1.3.1' 格式中提取
    version=$(grep -o "version: '[0-9]\+\.[0-9]\+\.[0-9]\+'" server.ts | head -1 | sed "s/version: '//;s/'//")

    # 如果没找到，尝试从 "version": "1.3.1" 格式中提取
    if [[ -z "$version" ]]; then
        version=$(grep -o '"version": "[0-9]\+\.[0-9]\+\.[0-9]\+"' server.ts | head -1 | sed 's/"version": "//;s/"//')
    fi

    # 如果还没找到，尝试从 v1.3.1 格式中提取
    if [[ -z "$version" ]]; then
        version=$(grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' server.ts | head -1 | sed 's/v//')
    fi

    # 最后尝试任何版本号格式
    if [[ -z "$version" ]]; then
        version=$(grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' server.ts | head -1)
    fi

    echo "$version"
}

# 验证版本格式
validate_version() {
    local version=$1
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    return 0
}

# 更新文件中的版本号
update_file_version() {
    local file=$1
    local old_version=$2
    local new_version=$3

    if [[ ! -f "$file" ]]; then
        print_status "warning" "文件不存在: $file"
        return 1
    fi

    # 创建备份
    cp "$file" "${file}.backup"

    # 根据文件类型使用不同的更新策略
    case "$file" in
        "server.ts")
            # 更新 TypeScript 文件中的版本号
            sed -i "s/version: '[0-9]\+\.[0-9]\+\.[0-9]\+'/version: '$new_version'/g" "$file"
            sed -i "s/\"version\": \"[0-9]\+\.[0-9]\+\.[0-9]\+\"/\"version\": \"$new_version\"/g" "$file"
            ;;
        "package.json"|"deno.json")
            # 更新 JSON 文件中的版本号
            sed -i "s/\"version\": \"[0-9]\+\.[0-9]\+\.[0-9]\+\"/\"version\": \"$new_version\"/g" "$file"
            ;;
        *)
            # 通用版本号更新
            sed -i "s/${old_version}/${new_version}/g" "$file"
            ;;
    esac

    # 检查是否有更改
    if diff -q "$file" "${file}.backup" > /dev/null; then
        print_status "info" "文件无需更新: $file"
        rm "${file}.backup"
    else
        print_status "success" "已更新: $file"
        rm "${file}.backup"
    fi
}

# 主函数
main() {
    echo -e "${BLUE}CIAO-CORS 版本更新工具${NC}"
    echo "=================================="
    
    # 获取当前版本
    local current_version=$(get_current_version)
    if [[ -z "$current_version" ]]; then
        print_status "error" "无法获取当前版本号"
        exit 1
    fi
    
    print_status "info" "当前版本: $current_version"
    
    # 获取新版本号
    read -p "请输入新版本号 (格式: x.y.z): " new_version
    
    if [[ -z "$new_version" ]]; then
        print_status "error" "版本号不能为空"
        exit 1
    fi
    
    if ! validate_version "$new_version"; then
        print_status "error" "版本号格式无效，请使用 x.y.z 格式"
        exit 1
    fi
    
    if [[ "$current_version" == "$new_version" ]]; then
        print_status "warning" "新版本号与当前版本相同"
        exit 0
    fi
    
    print_status "info" "将版本从 $current_version 更新到 $new_version"
    
    # 确认更新
    read -p "确认更新? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "info" "取消更新"
        exit 0
    fi
    
    # 更新各个文件
    local files=(
        "server.ts"
        "deploy.sh"
        "diagnose.sh"
        "test-stats.sh"
        "security-check.sh"
        "README.md"
    )
    
    print_status "info" "开始更新文件..."
    
    for file in "${files[@]}"; do
        update_file_version "$file" "$current_version" "$new_version"
    done
    
    # 特殊处理：更新package.json如果存在
    if [[ -f "package.json" ]]; then
        print_status "info" "更新 package.json"
        sed -i "s/\"version\": \"$current_version\"/\"version\": \"$new_version\"/" package.json
    fi
    
    # 特殊处理：更新deno.json如果存在
    if [[ -f "deno.json" ]]; then
        print_status "info" "更新 deno.json"
        sed -i "s/\"version\": \"$current_version\"/\"version\": \"$new_version\"/" deno.json
    fi
    
    print_status "success" "版本更新完成！"
    print_status "info" "请检查更新后的文件并提交更改"
    
    # 显示git状态
    if command -v git &> /dev/null && [[ -d .git ]]; then
        echo
        print_status "info" "Git状态:"
        git status --porcelain
        echo
        print_status "info" "建议的git命令:"
        echo "  git add ."
        echo "  git commit -m \"chore: bump version to v$new_version\""
        echo "  git tag v$new_version"
        echo "  git push origin main --tags"
    fi
}

# 检查是否在项目根目录
if [[ ! -f "server.ts" ]]; then
    print_status "error" "请在项目根目录运行此脚本"
    exit 1
fi

# 运行主函数
main "$@"
