#!/bin/bash

# CIAO-CORS 完整测试套件
# 测试所有功能和安全特性


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 测试配置
TEST_PORT=3001
TEST_API_KEY="test-api-key-$(date +%s)"
TEST_CONFIG_FILE="/tmp/ciao-cors-test.env"
TEST_LOG_FILE="/tmp/ciao-cors-test.log"

# 测试计数器
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

print_status() {
    local type=$1
    local message=$2
    local timestamp=$(date '+%H:%M:%S')
    case $type in
        "info")    echo -e "${BLUE}[INFO]${NC} [$timestamp] $message" ;;
        "pass")    echo -e "${GREEN}[PASS]${NC} [$timestamp] $message"; ((TESTS_PASSED++)) ;;
        "fail")    echo -e "${RED}[FAIL]${NC} [$timestamp] $message"; ((TESTS_FAILED++)) ;;
        "warn")    echo -e "${YELLOW}[WARN]${NC} [$timestamp] $message" ;;
    esac
    ((TESTS_TOTAL++))
}

print_separator() {
    echo -e "${BLUE}=====================================================${NC}"
}

# 创建测试配置
create_test_config() {
    cat > "$TEST_CONFIG_FILE" << EOF
PORT=$TEST_PORT
API_KEY=$TEST_API_KEY
RATE_LIMIT=100
RATE_LIMIT_WINDOW=60000
CONCURRENT_LIMIT=20
TOTAL_CONCURRENT_LIMIT=500
ENABLE_STATS=true
ENABLE_LOGGING=true
TIMEOUT=10000
MAX_URL_LENGTH=2048
MAX_BODY_SIZE=1048576
BLOCKED_IPS=192.168.1.100,10.0.0.1
ALLOWED_DOMAINS=httpbin.org,jsonplaceholder.typicode.com
BLOCKED_DOMAINS=malicious.com,spam.net
EOF
}

# 启动测试服务器
start_test_server() {
    print_status "info" "启动测试服务器..."
    
    # 设置环境变量
    export $(cat "$TEST_CONFIG_FILE" | xargs)
    
    # 启动服务器
    deno run --allow-net --allow-env --allow-read server.ts > "$TEST_LOG_FILE" 2>&1 &
    local server_pid=$!
    
    # 等待服务器启动
    local max_wait=30
    local wait_count=0
    
    while [[ $wait_count -lt $max_wait ]]; do
        if curl -s "http://localhost:$TEST_PORT/health" > /dev/null 2>&1; then
            print_status "pass" "测试服务器启动成功 (PID: $server_pid)"
            echo "$server_pid" > /tmp/test-server.pid
            return 0
        fi
        sleep 1
        ((wait_count++))
    done
    
    print_status "fail" "测试服务器启动失败"
    return 1
}

# 停止测试服务器
stop_test_server() {
    if [[ -f /tmp/test-server.pid ]]; then
        local server_pid=$(cat /tmp/test-server.pid)
        if kill "$server_pid" 2>/dev/null; then
            print_status "info" "测试服务器已停止"
        fi
        rm -f /tmp/test-server.pid
    fi
}

# 测试基础功能
test_basic_functionality() {
    print_separator
    print_status "info" "测试基础功能"
    print_separator
    
    # 测试健康检查
    local health_response=$(curl -s "http://localhost:$TEST_PORT/health")
    if echo "$health_response" | grep -q '"status":"healthy"'; then
        print_status "pass" "健康检查正常"
    else
        print_status "fail" "健康检查失败"
    fi
    
    # 测试CORS代理
    local proxy_response=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:$TEST_PORT/httpbin.org/get")
    if [[ "$proxy_response" == "200" ]]; then
        print_status "pass" "CORS代理功能正常"
    else
        print_status "fail" "CORS代理功能异常 (HTTP $proxy_response)"
    fi
    
    # 测试POST请求
    local post_response=$(curl -s -w "%{http_code}" -o /dev/null -X POST \
        -H "Content-Type: application/json" \
        -d '{"test": "data"}' \
        "http://localhost:$TEST_PORT/httpbin.org/post")
    if [[ "$post_response" == "200" ]]; then
        print_status "pass" "POST请求代理正常"
    else
        print_status "fail" "POST请求代理异常 (HTTP $post_response)"
    fi
}

# 测试安全功能
test_security_features() {
    print_separator
    print_status "info" "测试安全功能"
    print_separator
    
    # 测试域名黑名单
    local blocked_response=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:$TEST_PORT/malicious.com/test")
    if [[ "$blocked_response" == "403" ]]; then
        print_status "pass" "域名黑名单功能正常"
    else
        print_status "fail" "域名黑名单功能异常 (HTTP $blocked_response)"
    fi
    
    # 测试恶意URL检测
    local malicious_url="http://localhost:$TEST_PORT/httpbin.org/../../../etc/passwd"
    local malicious_response=$(curl -s -w "%{http_code}" -o /dev/null "$malicious_url")
    if [[ "$malicious_response" == "400" ]]; then
        print_status "pass" "恶意URL检测正常"
    else
        print_status "fail" "恶意URL检测异常 (HTTP $malicious_response)"
    fi
    
    # 测试超长URL拒绝
    local long_url="http://localhost:$TEST_PORT/httpbin.org/get?$(printf 'a%.0s' {1..3000})"
    local long_url_response=$(curl -s -w "%{http_code}" -o /dev/null "$long_url")
    if [[ "$long_url_response" == "400" ]]; then
        print_status "pass" "超长URL拒绝正常"
    else
        print_status "fail" "超长URL拒绝异常 (HTTP $long_url_response)"
    fi
}

# 测试管理API
test_management_api() {
    print_separator
    print_status "info" "测试管理API"
    print_separator
    
    # 测试无API密钥访问
    local no_key_response=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:$TEST_PORT/_api/stats")
    if [[ "$no_key_response" == "401" ]]; then
        print_status "pass" "API密钥验证正常"
    else
        print_status "fail" "API密钥验证异常 (HTTP $no_key_response)"
    fi
    
    # 测试统计API
    local stats_response=$(curl -s "http://localhost:$TEST_PORT/_api/stats?key=$TEST_API_KEY")
    if echo "$stats_response" | grep -q '"totalRequests"'; then
        print_status "pass" "统计API正常"
    else
        print_status "fail" "统计API异常"
    fi
    
    # 测试版本API
    local version_response=$(curl -s "http://localhost:$TEST_PORT/_api/version?key=$TEST_API_KEY")
    if echo "$version_response" | grep -q '"version"'; then
        print_status "pass" "版本API正常"
    else
        print_status "fail" "版本API异常"
    fi
    
    # 测试配置重载
    local reload_response=$(curl -s "http://localhost:$TEST_PORT/_api/reload-config?key=$TEST_API_KEY")
    if echo "$reload_response" | grep -q '"success":true'; then
        print_status "pass" "配置重载正常"
    else
        print_status "fail" "配置重载异常"
    fi
}

# 测试限流功能
test_rate_limiting() {
    print_separator
    print_status "info" "测试限流功能"
    print_separator
    
    # 快速发送多个请求测试限流
    local rate_limit_triggered=false
    for i in {1..10}; do
        local response=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:$TEST_PORT/httpbin.org/get?test=$i")
        if [[ "$response" == "429" ]]; then
            rate_limit_triggered=true
            break
        fi
        sleep 0.1
    done
    
    if [[ "$rate_limit_triggered" == "true" ]]; then
        print_status "pass" "限流功能正常"
    else
        print_status "warn" "限流功能未触发（可能需要更多请求）"
    fi
}

# 测试缓存功能
test_caching() {
    print_separator
    print_status "info" "测试缓存功能"
    print_separator
    
    # 第一次请求
    local start_time=$(date +%s%N)
    curl -s "http://localhost:$TEST_PORT/httpbin.org/delay/1" > /dev/null
    local first_time=$(($(date +%s%N) - start_time))
    
    # 第二次请求（应该从缓存返回）
    start_time=$(date +%s%N)
    curl -s "http://localhost:$TEST_PORT/httpbin.org/delay/1" > /dev/null
    local second_time=$(($(date +%s%N) - start_time))
    
    # 如果第二次请求明显更快，说明缓存工作正常
    if [[ $second_time -lt $((first_time / 2)) ]]; then
        print_status "pass" "缓存功能正常"
    else
        print_status "warn" "缓存功能可能未生效"
    fi
}

# 测试错误处理
test_error_handling() {
    print_separator
    print_status "info" "测试错误处理"
    print_separator
    
    # 测试无效域名
    local invalid_domain_response=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:$TEST_PORT/invalid-domain-12345.com/test")
    if [[ "$invalid_domain_response" == "502" ]] || [[ "$invalid_domain_response" == "500" ]]; then
        print_status "pass" "无效域名错误处理正常"
    else
        print_status "fail" "无效域名错误处理异常 (HTTP $invalid_domain_response)"
    fi
    
    # 测试超时处理
    local timeout_response=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:$TEST_PORT/httpbin.org/delay/15")
    if [[ "$timeout_response" == "504" ]] || [[ "$timeout_response" == "500" ]]; then
        print_status "pass" "超时错误处理正常"
    else
        print_status "fail" "超时错误处理异常 (HTTP $timeout_response)"
    fi
}

# 生成测试报告
generate_test_report() {
    print_separator
    print_status "info" "测试报告"
    print_separator
    
    echo "测试时间: $(date)"
    echo "总测试数: $TESTS_TOTAL"
    echo "通过测试: $TESTS_PASSED"
    echo "失败测试: $TESTS_FAILED"
    echo "成功率: $(( TESTS_PASSED * 100 / TESTS_TOTAL ))%"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        print_status "pass" "所有测试通过！"
        return 0
    else
        print_status "fail" "有 $TESTS_FAILED 个测试失败"
        return 1
    fi
}

# 清理测试环境
cleanup_test_env() {
    print_status "info" "清理测试环境..."
    stop_test_server
    rm -f "$TEST_CONFIG_FILE" "$TEST_LOG_FILE" /tmp/test-server.pid
}

# 主函数
main() {
    clear
    print_separator
    print_status "info" "CIAO-CORS 完整测试套件 v1.3.2"
    print_separator
    
    # 检查依赖
    if ! command -v deno &> /dev/null; then
        print_status "fail" "Deno未安装，无法运行测试"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        print_status "fail" "curl未安装，无法运行测试"
        exit 1
    fi
    
    # 设置清理陷阱
    trap cleanup_test_env EXIT
    
    # 创建测试配置
    create_test_config
    
    # 启动测试服务器
    if ! start_test_server; then
        print_status "fail" "无法启动测试服务器"
        exit 1
    fi
    
    # 等待服务器完全启动
    sleep 2
    
    # 运行测试
    test_basic_functionality
    test_security_features
    test_management_api
    test_rate_limiting
    test_caching
    test_error_handling
    
    # 生成报告
    if generate_test_report; then
        exit 0
    else
        exit 1
    fi
}

# 运行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
