/**
 * CIAO-CORS - 高性能CORS代理服务
 * 支持环境变量配置、请求限制、黑白名单、统计等功能
 * 版本: v1.3.0
 * 作者: bestZwei
 * 项目: https://github.com/bestZwei/ciao-cors
 */

// ==================== 配置管理模块 ====================
interface Config {
  port: number;
  allowedOrigins: string[];
  blockedIPs: string[];
  blockedDomains: string[];
  allowedDomains: string[];
  rateLimit: number;
  rateLimitWindow: number;
  concurrentLimit: number;
  totalConcurrentLimit: number;
  apiKey?: string;
  enableStats: boolean;
  enableLogging: boolean;
  logWebhook?: string;
  maxUrlLength: number;
  timeout: number;
  requireHeaders: boolean;
}

/**
 * 加载和解析环境变量配置
 * 支持JSON格式的复杂配置和简单的字符串配置
 */
function loadConfig(): Config {
  const parseArray = (str?: string): string[] => {
    if (!str) return [];
    try {
      const parsed = JSON.parse(str);
      // 验证解析结果是数组且所有元素都是字符串
      if (Array.isArray(parsed) && parsed.every(item => typeof item === 'string')) {
        return parsed.filter(Boolean);
      } else {
        console.warn(`Invalid JSON array format: ${str}, falling back to comma-separated parsing`);
        return str.split(',').map(s => s.trim()).filter(Boolean);
      }
    } catch {
      return str.split(',').map(s => s.trim()).filter(Boolean);
    }
  };

  // 验证和清理配置值
  const validatePort = (port: number): number => {
    if (isNaN(port) || port < 1 || port > 65535) {
      console.warn(`Invalid port ${port}, using default 3000`);
      return 3000;
    }
    return port;
  };

  const validatePositiveInt = (value: number, defaultValue: number, name: string): number => {
    if (isNaN(value) || value < 0) {
      console.warn(`Invalid ${name} ${value}, using default ${defaultValue}`);
      return defaultValue;
    }
    return value;
  };

  const config = {
    port: validatePort(parseInt(Deno.env.get('PORT') || '3000')),
    allowedOrigins: parseArray(Deno.env.get('ALLOWED_ORIGINS')),
    blockedIPs: parseArray(Deno.env.get('BLOCKED_IPS')),
    blockedDomains: parseArray(Deno.env.get('BLOCKED_DOMAINS')),
    allowedDomains: parseArray(Deno.env.get('ALLOWED_DOMAINS')),
    rateLimit: validatePositiveInt(parseInt(Deno.env.get('RATE_LIMIT') || '2500'), 2500, 'RATE_LIMIT'),
    rateLimitWindow: validatePositiveInt(parseInt(Deno.env.get('RATE_LIMIT_WINDOW') || '60000'), 60000, 'RATE_LIMIT_WINDOW'),
    concurrentLimit: validatePositiveInt(parseInt(Deno.env.get('CONCURRENT_LIMIT') || '10'), 10, 'CONCURRENT_LIMIT'),
    totalConcurrentLimit: validatePositiveInt(parseInt(Deno.env.get('TOTAL_CONCURRENT_LIMIT') || '1000'), 1000, 'TOTAL_CONCURRENT_LIMIT'),
    apiKey: Deno.env.get('API_KEY')?.trim() || undefined,
    enableStats: Deno.env.get('ENABLE_STATS') !== 'false',
    enableLogging: Deno.env.get('ENABLE_LOGGING') !== 'false',
    logWebhook: Deno.env.get('LOG_WEBHOOK')?.trim() || undefined,
    maxUrlLength: validatePositiveInt(parseInt(Deno.env.get('MAX_URL_LENGTH') || '2048'), 2048, 'MAX_URL_LENGTH'),
    timeout: validatePositiveInt(parseInt(Deno.env.get('TIMEOUT') || '30000'), 30000, 'TIMEOUT'),
    requireHeaders: Deno.env.get('REQUIRE_HEADERS') !== 'false'
  };

  // 验证数组配置的有效性
  const validateArrayConfig = (arr: string[], name: string) => {
    if (arr.some(item => typeof item !== 'string' || item.trim() === '')) {
      console.warn(`Warning: ${name} contains invalid entries, filtering out empty values`);
      return arr.filter(item => typeof item === 'string' && item.trim() !== '');
    }
    return arr;
  };

  config.allowedOrigins = validateArrayConfig(config.allowedOrigins, 'ALLOWED_ORIGINS');
  config.blockedIPs = validateArrayConfig(config.blockedIPs, 'BLOCKED_IPS');
  config.blockedDomains = validateArrayConfig(config.blockedDomains, 'BLOCKED_DOMAINS');
  config.allowedDomains = validateArrayConfig(config.allowedDomains, 'ALLOWED_DOMAINS');

  return config;
}

// ==================== 限制和安全模块 ====================
class RateLimiter {
  private requests: Map<string, number[]> = new Map();
  private windowMs: number;
  private maxRequests: number;
  private cleanupTimer: number | null = null;
  private isDestroyed: boolean = false;

  constructor(windowMs: number, maxRequests: number) {
    this.windowMs = windowMs;
    this.maxRequests = maxRequests;

    // 定期清理过期记录，确保不会超过1分钟间隔
    const cleanupInterval = Math.min(windowMs, 60000);
    this.cleanupTimer = setInterval(() => {
      if (!this.isDestroyed) {
        this.cleanup();
      }
    }, cleanupInterval) as unknown as number;
  }

  checkLimit(ip: string): boolean {
    const now = Date.now();
    const requests = this.requests.get(ip) || [];
    
    // 移除过期的请求记录
    const validRequests = requests.filter(time => now - time < this.windowMs);
    
    if (validRequests.length >= this.maxRequests) {
      return false;
    }
    
    validRequests.push(now);
    this.requests.set(ip, validRequests);
    return true;
  }

  cleanup(): void {
    const now = Date.now();
    for (const [ip, requests] of this.requests.entries()) {
      const validRequests = requests.filter(time => now - time < this.windowMs);
      if (validRequests.length === 0) {
        this.requests.delete(ip);
      } else {
        this.requests.set(ip, validRequests);
      }
    }
  }

  // 清理资源
  destroy(): void {
    this.isDestroyed = true;
    if (this.cleanupTimer !== null) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
    this.requests.clear();
  }

  getStats(): { totalIPs: number; totalRequests: number } {
    return {
      totalIPs: this.requests.size,
      totalRequests: Array.from(this.requests.values()).reduce((sum, reqs) => sum + reqs.length, 0)
    };
  }
}

class ConcurrencyLimiter {
  private perIpCount: Map<string, number> = new Map();
  private totalCount = 0;
  private perIpLimit: number;
  private totalLimit: number;
  private mutex: Promise<void> = Promise.resolve();

  constructor(perIpLimit: number, totalLimit: number) {
    this.perIpLimit = perIpLimit;
    this.totalLimit = totalLimit;
  }

  async acquire(ip: string): Promise<boolean> {
    return new Promise((resolve) => {
      this.mutex = this.mutex.then(() => {
        const currentPerIp = this.perIpCount.get(ip) || 0;

        if (currentPerIp >= this.perIpLimit || this.totalCount >= this.totalLimit) {
          resolve(false);
          return;
        }

        this.perIpCount.set(ip, currentPerIp + 1);
        this.totalCount++;
        resolve(true);
      });
    });
  }

  async release(ip: string): Promise<void> {
    return new Promise((resolve) => {
      this.mutex = this.mutex.then(() => {
        const currentPerIp = this.perIpCount.get(ip) || 0;
        if (currentPerIp > 0) {
          this.perIpCount.set(ip, currentPerIp - 1);
          this.totalCount = Math.max(0, this.totalCount - 1);

          if (this.perIpCount.get(ip) === 0) {
            this.perIpCount.delete(ip);
          }
        }
        resolve();
      });
    });
  }

  getStats(): { perIpCount: Map<string, number>; totalCount: number } {
    return {
      perIpCount: new Map(this.perIpCount),
      totalCount: this.totalCount
    };
  }
}

/**
 * 校验目标URL自身的安全性：协议白名单、控制字符、内网地址、受限端口等
 * 初始请求和每一跳重定向都会调用，防止通过重定向绕过SSRF防护
 */
function validateTargetUrl(rawUrl: string): { valid: boolean; reason?: string; targetUrl?: URL } {
  let targetUrl: URL;
  try {
    targetUrl = new URL(fixUrl(rawUrl));
  } catch {
    return { valid: false, reason: 'Invalid URL' };
  }

  // 只允许http/https协议（同时拦截javascript:/data:/file:等危险协议）
  if (targetUrl.protocol !== 'http:' && targetUrl.protocol !== 'https:') {
    return { valid: false, reason: 'Unsupported URL protocol' };
  }

  // 检查是否包含控制字符
  if (/[\u0000-\u001F\u007F-\u009F]/.test(rawUrl)) {
    return { valid: false, reason: 'URL contains control characters' };
  }

  // 去掉IPv6地址的方括号，便于匹配私网规则
  const hostname = targetUrl.hostname.toLowerCase().replace(/^\[/, '').replace(/\]$/, '');

  // 检查私有IP地址范围（IPv4）
  const privateIPv4Patterns = [
    /^127\./,           // 127.0.0.0/8 (localhost)
    /^10\./,            // 10.0.0.0/8
    /^172\.(1[6-9]|2[0-9]|3[0-1])\./,  // 172.16.0.0/12
    /^192\.168\./,      // 192.168.0.0/16
    /^169\.254\./,      // 169.254.0.0/16 (link-local)
    /^0\./,             // 0.0.0.0/8
    /^224\./,           // 224.0.0.0/4 (multicast)
    /^240\./,           // 240.0.0.0/4 (reserved)
    /^255\.255\.255\.255$/, // broadcast
    /^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\./  // 100.64.0.0/10 (carrier-grade NAT)
  ];

  // 检查IPv6私有地址
  const privateIPv6Patterns = [
    /^::1$/,            // IPv6 localhost
    /^::/,              // IPv6 unspecified
    /^fe80:/,           // IPv6 link-local
    /^fc00:/,           // IPv6 unique local
    /^fd00:/,           // IPv6 unique local
    /^ff00:/            // IPv6 multicast
  ];

  // 检查特殊域名和元数据服务
  const restrictedDomains = [
    'localhost',
    'metadata.google.internal',
    'metadata.goog',
    '169.254.169.254',  // AWS/GCP metadata service
    'metadata',
    'instance-data',
    'consul',
    'vault.service.consul'
  ];

  // 检查是否为IP地址
  const isIPv4 = /^(\d{1,3}\.){3}\d{1,3}$/.test(hostname);
  const isIPv6 = hostname.includes(':') && !hostname.includes('.');

  if (isIPv4 && privateIPv4Patterns.some(pattern => pattern.test(hostname))) {
    return { valid: false, reason: 'Access to private IPv4 addresses is not allowed' };
  }

  if (isIPv6 && privateIPv6Patterns.some(pattern => pattern.test(hostname))) {
    return { valid: false, reason: 'Access to private IPv6 addresses is not allowed' };
  }

  if (restrictedDomains.some(domain => hostname === domain || hostname.endsWith('.' + domain))) {
    return { valid: false, reason: 'Access to restricted domains is not allowed' };
  }

  // 检查端口是否为敏感端口
  const port = targetUrl.port;
  if (port) {
    const portNum = parseInt(port);
    const restrictedPorts = [22, 23, 25, 53, 135, 139, 445, 993, 995, 1433, 1521, 3306, 3389, 5432, 5984, 6379, 9200, 11211, 27017];
    if (restrictedPorts.includes(portNum)) {
      return { valid: false, reason: 'Access to restricted ports is not allowed' };
    }
  }

  return { valid: true, targetUrl };
}

/**
 * 安全检查：验证目标URL和请求来源
 */
function validateRequest(url: string, ip: string, config: Config, origin?: string | null): { valid: boolean; reason?: string } {
  // 检查IP黑名单
  if (config.blockedIPs.length > 0 && config.blockedIPs.includes(ip)) {
    return { valid: false, reason: 'IP blocked' };
  }

  // 检查URL长度
  if (url.length > config.maxUrlLength) {
    return { valid: false, reason: 'URL too long' };
  }

  // 校验目标URL安全性（协议、控制字符、内网地址、受限端口）
  const check = validateTargetUrl(url);
  if (!check.valid || !check.targetUrl) {
    return { valid: false, reason: check.reason };
  }

  const targetDomain = check.targetUrl.hostname.toLowerCase();

  // 检查域名黑名单
  if (config.blockedDomains.length > 0) {
    const isBlocked = config.blockedDomains.some(blocked =>
      targetDomain === blocked || targetDomain.endsWith('.' + blocked)
    );
    if (isBlocked) {
      return { valid: false, reason: 'Domain blocked' };
    }
  }

  // 检查域名白名单
  if (config.allowedDomains.length > 0) {
    const isAllowed = config.allowedDomains.some(allowed =>
      targetDomain === allowed || targetDomain.endsWith('.' + allowed)
    );
    if (!isAllowed) {
      return { valid: false, reason: 'Domain not allowed' };
    }
  }

  // 检查来源白名单
  if (config.allowedOrigins.length > 0 && origin) {
    if (!config.allowedOrigins.includes('*') && !config.allowedOrigins.includes(origin)) {
      return { valid: false, reason: 'Origin not allowed' };
    }
  }

  return { valid: true };
}

// ==================== 请求处理模块 ====================
/**
 * 修复和标准化URL格式
 * 协议判断限定在字符串开头，避免路径或查询串中偶含":/"时被误改写
 */
function fixUrl(url: string): string {
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(url)) {
    return url;
  }
  // 处理 http:/example.com 这类少写一个斜杠的情况
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/(?!\/)/.test(url)) {
    return url.replace(':/', '://');
  }
  // 默认使用HTTPS协议，更安全
  return "https://" + url;
}

/**
 * 构建代理请求的headers
 */
function buildProxyHeaders(originalHeaders: Headers): Record<string, string> {
  const proxyHeaders: Record<string, string> = {};
  const dropHeaders = [
    'content-length', 'host', 'connection', 'keep-alive',
    'proxy-authenticate', 'proxy-authorization', 'te', 'trailers',
    'transfer-encoding', 'upgrade', 'cf-connecting-ip', 'cf-ray',
    'cf-visitor', 'cf-ipcountry'
  ];

  for (const [key, value] of originalHeaders.entries()) {
    const lowerKey = key.toLowerCase();
    if (!dropHeaders.includes(lowerKey)) {
      proxyHeaders[key] = value;
    }
  }

  // 优先保留用户的User-Agent，只在没有时才设置默认值
  // 使用更真实的默认User-Agent，模拟常见浏览器
  if (!proxyHeaders['User-Agent'] && !proxyHeaders['user-agent']) {
    // 使用多个真实的User-Agent轮换，减少被识别为爬虫的风险
    const defaultUserAgents = [
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15',
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    ];

    // 基于时间戳选择User-Agent，确保一定的随机性但又相对稳定
    const index = Math.floor(Date.now() / (1000 * 60 * 10)) % defaultUserAgents.length;
    proxyHeaders['User-Agent'] = defaultUserAgents[index];
  }

  // 增强其他重要请求头的处理，提高请求成功率
  // 如果没有Accept头，添加通用的Accept头
  if (!proxyHeaders['Accept'] && !proxyHeaders['accept']) {
    proxyHeaders['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7';
  }

  // 如果没有Accept-Language头，添加常见的语言设置
  if (!proxyHeaders['Accept-Language'] && !proxyHeaders['accept-language']) {
    proxyHeaders['Accept-Language'] = 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7';
  }

  // 如果没有Accept-Encoding头，添加常见的编码支持
  if (!proxyHeaders['Accept-Encoding'] && !proxyHeaders['accept-encoding']) {
    proxyHeaders['Accept-Encoding'] = 'gzip, deflate, br';
  }

  // 添加DNT头，表明不希望被跟踪（提高隐私性）
  if (!proxyHeaders['DNT'] && !proxyHeaders['dnt']) {
    proxyHeaders['DNT'] = '1';
  }

  // 添加Sec-Fetch-* 头，模拟真实浏览器行为
  if (!proxyHeaders['Sec-Fetch-Dest'] && !proxyHeaders['sec-fetch-dest']) {
    proxyHeaders['Sec-Fetch-Dest'] = 'document';
  }
  if (!proxyHeaders['Sec-Fetch-Mode'] && !proxyHeaders['sec-fetch-mode']) {
    proxyHeaders['Sec-Fetch-Mode'] = 'navigate';
  }
  if (!proxyHeaders['Sec-Fetch-Site'] && !proxyHeaders['sec-fetch-site']) {
    proxyHeaders['Sec-Fetch-Site'] = 'none';
  }

  return proxyHeaders;
}

/**
 * 处理请求body：统一读取为ArrayBuffer
 * 1. 重试时可以安全复用body（字符串/FormData等无法跨请求重用）
 * 2. 原样转发，避免JSON.parse/stringify改变原始payload
 */
async function processRequestBody(request: Request): Promise<ArrayBuffer | undefined> {
  if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(request.method)) {
    return undefined;
  }

  // 从配置获取最大请求体大小，默认10MB
  const maxBodySize = parseInt(Deno.env.get('MAX_BODY_SIZE') || '10485760'); // 10MB
  const contentLength = request.headers.get('content-length');
  if (contentLength && parseInt(contentLength) > maxBodySize) {
    throw new Error(`Request body too large. Maximum size: ${maxBodySize} bytes`);
  }

  try {
    const buffer = await request.arrayBuffer();
    // content-length可能缺失（如chunked传输），读取后兜底检查实际大小
    if (buffer.byteLength > maxBodySize) {
      throw new Error('Request body too large');
    }
    return buffer;
  } catch (e) {
    if (e instanceof Error && e.message.includes('Request body too large')) {
      throw e;
    }
    console.error("Error processing request body:", e);
    return undefined;
  }
}

/**
 * 执行代理请求（带智能重试机制）
 * 重定向手动跟随，并对每一跳重新校验目标地址，防止通过重定向绕过SSRF防护
 */
async function performProxy(request: Request, targetUrl: string, config: Config): Promise<Response> {
  const headers = buildProxyHeaders(request.headers);
  const body = await processRequestBody(request);

  // 重试配置
  const maxRetries = 3;
  const retryDelay = [100, 300, 1000]; // 递增延迟：100ms, 300ms, 1000ms
  const maxRedirects = 5;

  // 判断是否应该重试的错误类型
  const shouldRetry = (error: any, attempt: number): boolean => {
    if (attempt >= maxRetries) return false;

    // 网络错误、连接被拒绝、DNS错误等应该重试
    if (error instanceof Error) {
      const message = error.message.toLowerCase();
      return message.includes('network') ||
             message.includes('connection') ||
             message.includes('econnrefused') ||
             message.includes('enotfound') ||
             message.includes('timeout') ||
             message.includes('fetch');
    }
    return false;
  };

  // 判断HTTP状态码是否应该重试
  const shouldRetryStatus = (status: number): boolean => {
    // 5xx服务器错误、429限流、502/503/504网关错误应该重试
    return status >= 500 || status === 429 || status === 502 || status === 503 || status === 504;
  };

  // 校验重定向目标：禁止跳转到内网地址、危险协议或黑名单域名
  const validateRedirectTarget = (location: string, baseUrl: string): string => {
    const resolved = new URL(location, baseUrl);
    const check = validateTargetUrl(resolved.toString());
    if (!check.valid || !check.targetUrl) {
      throw new Error(`Redirect blocked: ${check.reason}`);
    }
    const domain = check.targetUrl.hostname.toLowerCase();
    const domainBlocked = config.blockedDomains.some(blocked =>
      domain === blocked || domain.endsWith('.' + blocked)
    );
    const domainNotAllowed = config.allowedDomains.length > 0 && !config.allowedDomains.some(allowed =>
      domain === allowed || domain.endsWith('.' + allowed)
    );
    if (domainBlocked || domainNotAllowed) {
      throw new Error('Redirect target domain is not allowed');
    }
    return resolved.toString();
  };

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), config.timeout);

    try {
      let currentUrl = targetUrl;
      let method = request.method;
      let currentBody = body;
      let redirectCount = 0;

      while (true) {
        const response = await fetch(currentUrl, {
          method,
          headers,
          body: currentBody,
          signal: controller.signal,
          redirect: 'manual',
          // 增加缓存控制
          cache: request.headers.get('cache-control')?.includes('no-cache') ? 'no-cache' : 'default'
        });

        const location = response.headers.get('location');
        if (response.status >= 300 && response.status < 400 && location) {
          if (redirectCount >= maxRedirects) {
            response.body?.cancel();
            throw new Error('Too many redirects');
          }

          redirectCount++;
          response.body?.cancel();

          // 303以及POST遇到301/302时按浏览器语义转为GET并丢弃body
          if (response.status === 303 ||
              ((response.status === 301 || response.status === 302) && method === 'POST')) {
            method = 'GET';
            currentBody = undefined;
          }

          currentUrl = validateRedirectTarget(location, currentUrl);
          continue;
        }

        // 检查是否需要基于状态码重试
        if (attempt < maxRetries && shouldRetryStatus(response.status)) {
          console.warn(`Attempt ${attempt + 1} failed with status ${response.status}, retrying...`);
          response.body?.cancel();
          await new Promise(resolve => setTimeout(resolve, retryDelay[attempt]));
          break;
        }

        clearTimeout(timeoutId);
        return response;
      }
    } catch (error) {
      clearTimeout(timeoutId);

      if (error instanceof Error && error.name === 'AbortError') {
        if (attempt < maxRetries) {
          console.warn(`Attempt ${attempt + 1} timed out, retrying...`);
          await new Promise(resolve => setTimeout(resolve, retryDelay[attempt]));
          continue;
        }
        throw new Error('Request timeout after retries');
      }

      if (shouldRetry(error, attempt)) {
        console.warn(`Attempt ${attempt + 1} failed: ${error instanceof Error ? error.message : 'Unknown error'}, retrying...`);
        await new Promise(resolve => setTimeout(resolve, retryDelay[attempt]));
        continue;
      }

      throw error;
    }
  }

  throw new Error('Max retries exceeded');
}

// ==================== 统计和日志模块 ====================
interface RequestStats {
  totalRequests: number;
  successfulRequests: number;
  failedRequests: number;
  topDomains: Map<string, number>;
  topIPs: Map<string, number>;
  statusCodes: Map<number, number>;
  averageResponseTime: number;
  startTime: number;
}

class StatsCollector {
  private stats: RequestStats;
  private responseTimes: number[] = [];
  // 添加存储周期性统计的数组
  private hourlyStats: { timestamp: number; requests: number }[] = [];
  private lastHourRequestCount: number = 0;
  private hourlyTimer: number | null = null;
  private isDestroyed: boolean = false;

  constructor() {
    this.stats = {
      totalRequests: 0,
      successfulRequests: 0,
      failedRequests: 0,
      topDomains: new Map(),
      topIPs: new Map(),
      statusCodes: new Map(),
      averageResponseTime: 0,
      startTime: Date.now()
    };

    // 每小时记录一次统计数据
    this.hourlyTimer = setInterval(() => {
      if (!this.isDestroyed) {
        this.recordHourlyStat();
      }
    }, 3600000) as unknown as number;
  }

  recordRequest(ip: string, domain: string, statusCode: number, responseTime: number, success: boolean): void {
    this.stats.totalRequests++;
    
    if (success) {
      this.stats.successfulRequests++;
    } else {
      this.stats.failedRequests++;
    }

    // 记录域名统计
    const domainCount = this.stats.topDomains.get(domain) || 0;
    this.stats.topDomains.set(domain, domainCount + 1);

    // 记录IP统计
    const ipCount = this.stats.topIPs.get(ip) || 0;
    this.stats.topIPs.set(ip, ipCount + 1);

    // 记录状态码统计
    const statusCount = this.stats.statusCodes.get(statusCode) || 0;
    this.stats.statusCodes.set(statusCode, statusCount + 1);

    // 记录响应时间
    this.responseTimes.push(responseTime);
    if (this.responseTimes.length > 1000) {
      this.responseTimes.shift();
    }
    this.stats.averageResponseTime = this.responseTimes.reduce((a, b) => a + b, 0) / this.responseTimes.length;
  }

  // 记录每小时统计数据
  private recordHourlyStat(): void {
    const now = Date.now();
    const currentRequests = this.stats.totalRequests;

    // 计算这一小时的增量请求数
    const hourlyIncrement = currentRequests - this.lastHourRequestCount;

    this.hourlyStats.push({
      timestamp: now,
      requests: Math.max(0, hourlyIncrement) // 确保不为负数
    });

    // 更新上一小时的请求计数
    this.lastHourRequestCount = currentRequests;

    // 保留最近24小时的数据
    if (this.hourlyStats.length > 24) {
      this.hourlyStats.shift();
    }
  }

  getStats(): RequestStats & { hourlyStats?: { timestamp: number; requests: number }[] } {
    const result = {
      ...this.stats,
      topDomains: new Map(Array.from(this.stats.topDomains.entries())
        .sort((a, b) => b[1] - a[1]).slice(0, 10)),
      topIPs: new Map(Array.from(this.stats.topIPs.entries())
        .sort((a, b) => b[1] - a[1]).slice(0, 10)),
      hourlyStats: this.hourlyStats
    };
    return result;
  }

  // 添加性能分析数据
  getPerformanceData(): {
    requestsPerMinute: number;
    averageResponseTime: number;
    errorRate: number;
    topEndpoints: [string, number][];
  } {
    const now = Date.now();
    const oneMinuteAgo = now - 60000;
    
    // 计算最近一分钟的请求数
    const recentHourlyStats = this.hourlyStats.filter(stat => stat.timestamp > oneMinuteAgo);
    const requestsLastMinute = recentHourlyStats.length > 0 
      ? this.stats.totalRequests - recentHourlyStats[0].requests 
      : 0;
    
    // 计算错误率
    const errorRate = this.stats.totalRequests > 0 
      ? this.stats.failedRequests / this.stats.totalRequests 
      : 0;
    
    // 获取最常访问的目标域名
    const topEndpoints = Array.from(this.stats.topDomains.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5);
    
    return {
      requestsPerMinute: requestsLastMinute,
      averageResponseTime: this.stats.averageResponseTime,
      errorRate: errorRate,
      topEndpoints: topEndpoints
    };
  }

  reset(): void {
    this.stats = {
      totalRequests: 0,
      successfulRequests: 0,
      failedRequests: 0,
      topDomains: new Map(),
      topIPs: new Map(),
      statusCodes: new Map(),
      averageResponseTime: 0,
      startTime: Date.now()
    };
    this.responseTimes = [];
    // 保留历史统计数据
    // this.hourlyStats = [];
  }

  // 清理资源
  destroy(): void {
    this.isDestroyed = true;
    if (this.hourlyTimer !== null) {
      clearInterval(this.hourlyTimer);
      this.hourlyTimer = null;
    }
  }
}

class Logger {
  private enableConsole: boolean;
  private webhookUrl?: string;
  // 添加日志缓冲区，减少I/O操作
  private logBuffer: string[] = [];
  private bufferSize = 10;
  private bufferTimer: number | null = null;
  private isDestroyed: boolean = false;

  constructor(enableConsole: boolean, webhookUrl?: string) {
    this.enableConsole = enableConsole;
    this.webhookUrl = webhookUrl;

    // 定期刷新日志缓冲区
    if (this.webhookUrl) {
      this.bufferTimer = setInterval(() => {
        if (!this.isDestroyed) {
          this.flushLogBuffer();
        }
      }, 30000) as unknown as number;
    }
  }

  logRequest(request: Request, response: Response, proxyUrl?: string, responseTime?: number): void {
    if (!this.enableConsole && !this.webhookUrl) return;

    // 过滤敏感信息
    const sanitizedUrl = this.sanitizeUrl(new URL(request.url).pathname);
    const sanitizedProxyUrl = proxyUrl ? this.sanitizeUrl(proxyUrl) : undefined;
    const sanitizedUserAgent = this.sanitizeUserAgent(request.headers.get('user-agent'));

    const logData = {
      timestamp: new Date().toISOString(),
      method: request.method,
      url: sanitizedUrl,
      proxyUrl: sanitizedProxyUrl,
      statusCode: response.status,
      responseTime,
      userAgent: sanitizedUserAgent,
      referer: request.headers.get('referer'),
      ip: this.getClientIP(request)
    };

    if (this.enableConsole) {
      console.log(`[${logData.timestamp}] ${logData.method} ${logData.url} -> ${logData.proxyUrl} (${logData.statusCode}) ${logData.responseTime}ms`);
    }

    if (this.webhookUrl) {
      // 将日志添加到缓冲区
      this.logBuffer.push(JSON.stringify(logData));
      
      // 如果缓冲区已满，立即发送
      if (this.logBuffer.length >= this.bufferSize) {
        this.flushLogBuffer();
      }
    }
  }

  logError(error: Error, context?: any): void {
    if (!this.enableConsole && !this.webhookUrl) return;

    const logData = {
      timestamp: new Date().toISOString(),
      level: 'ERROR',
      message: error.message,
      stack: error.stack,
      context
    };

    if (this.enableConsole) {
      console.error(`[${logData.timestamp}] ERROR: ${error.message}`, context);
    }

    if (this.webhookUrl) {
      fetch(this.webhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(logData)
      }).catch(() => {});
    }
  }

  // 批量发送日志到webhook
  private flushLogBuffer(): void {
    if (this.webhookUrl && this.logBuffer.length > 0) {
      const logs = this.logBuffer;
      this.logBuffer = [];
      
      fetch(this.webhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ logs })
      }).catch(() => {});
    }
  }

  // 清理资源
  cleanup(): void {
    this.isDestroyed = true;
    if (this.bufferTimer !== null) {
      clearInterval(this.bufferTimer);
      this.bufferTimer = null;
      this.flushLogBuffer();
    }
  }

  private getClientIP(request: Request): string {
    return request.headers.get('cf-connecting-ip') ||
           request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
           request.headers.get('x-real-ip') ||
           'unknown';
  }

  // 清理URL中的敏感信息
  private sanitizeUrl(url: string): string {
    try {
      const urlObj = new URL(url.startsWith('http') ? url : `http://example.com${url}`);
      // 移除查询参数中的敏感信息
      const sensitiveParams = ['key', 'token', 'password', 'secret', 'auth', 'api_key'];
      sensitiveParams.forEach(param => {
        if (urlObj.searchParams.has(param)) {
          urlObj.searchParams.set(param, '***');
        }
      });
      return url.startsWith('http') ? urlObj.toString() : urlObj.pathname + urlObj.search;
    } catch {
      return url;
    }
  }

  // 清理User-Agent中的敏感信息
  private sanitizeUserAgent(userAgent: string | null): string | null {
    if (!userAgent) return null;
    // 移除可能的敏感信息，保留基本的浏览器信息
    return userAgent.replace(/\b[\w-]{32,}\b/g, '***'); // 移除长的token-like字符串
  }
}

// ==================== 主服务模块 ====================
class CiaoCorsServer {
  private config: Config;
  private rateLimiter: RateLimiter;
  private concurrencyLimiter: ConcurrencyLimiter;
  private statsCollector: StatsCollector;
  private logger: Logger;
  // 添加简单缓存
  private responseCache: Map<string, { response: Response, timestamp: number }> = new Map();
  private cacheTTL = 60000; // 1分钟缓存
  private cacheCleanupTimer: number | null = null;
  private isDestroyed: boolean = false;

  constructor() {
    this.config = loadConfig();
    this.rateLimiter = new RateLimiter(this.config.rateLimitWindow, this.config.rateLimit);
    this.concurrencyLimiter = new ConcurrencyLimiter(this.config.concurrentLimit, this.config.totalConcurrentLimit);
    this.statsCollector = new StatsCollector();
    this.logger = new Logger(this.config.enableLogging, this.config.logWebhook);

    // 定期清理缓存
    this.cacheCleanupTimer = setInterval(() => {
      if (!this.isDestroyed) {
        this.cleanupCache();
      }
    }, 30000) as unknown as number;
  }

  async handleRequest(request: Request): Promise<Response> {
    // 增加请求ID用于日志追踪
    const requestId = crypto.randomUUID ? crypto.randomUUID() : `req-${Date.now()}-${Math.random().toString(36).substring(2, 11)}`;
    const startTime = Date.now();
    const clientIP = this.getClientIP(request);
    const origin = request.headers.get('origin');

    try {
      // 处理OPTIONS预检请求
      if (request.method === 'OPTIONS') {
        return this.handlePreflight(request);
      }

      // 解析目标URL（必须带上查询字符串，否则GET参数会全部丢失）
      const url = new URL(request.url);
      let targetPath: string;
      try {
        targetPath = decodeURIComponent(url.pathname.substring(1)) + url.search;
      } catch {
        return this.createErrorResponse(400, 'Invalid URL encoding');
      }

      // 处理管理API
      if (targetPath.startsWith('_api/')) {
        return this.handleManagementApi(request, targetPath);
      }

      // 添加健康检查路径
      if (targetPath === 'health' || targetPath === '_health') {
        return new Response(JSON.stringify({
          status: 'ok',
          timestamp: new Date().toISOString(),
          version: '1.3.0'
        }), {
          headers: { 'Content-Type': 'application/json' }
        });
      }

      // 验证基本URL格式
      if (targetPath.length < 3 || !targetPath.includes('.') ||
          targetPath === 'favicon.ico' || targetPath === 'robots.txt') {
        return this.createErrorResponse(400, 'Invalid URL format', {
          usage: 'https://your-domain.com/{target-url}',
          example: 'https://your-domain.com/httpbin.org/get'
        });
      }

      // 添加必需头部验证（类似 cors-anywhere.com）
      if (this.config.requireHeaders) {
        const hasOrigin = request.headers.has('origin');
        const hasXRequestedWith = request.headers.has('x-requested-with');

        if (!hasOrigin && !hasXRequestedWith) {
          return this.createErrorResponse(403, 'Missing required request header. Must specify one of: origin,x-requested-with', {
            usage: 'Add "Origin" or "X-Requested-With" header to your request',
            example: 'fetch(url, { headers: { "X-Requested-With": "XMLHttpRequest" } })'
          });
        }
      }

      // 检查请求频率限制
      if (!this.rateLimiter.checkLimit(clientIP)) {
        return this.createErrorResponse(429, 'Rate limit exceeded', {
          retryAfter: Math.ceil(this.config.rateLimitWindow / 1000)
        });
      }

      // 检查并发限制
      if (!(await this.concurrencyLimiter.acquire(clientIP))) {
        return this.createErrorResponse(503, 'Concurrency limit exceeded', {
          retryAfter: 5
        });
      }

      let response: Response;
      let success = false;

      try {
        // 安全验证
        const validation = validateRequest(targetPath, clientIP, this.config, origin || undefined);
        if (!validation.valid) {
          return this.createErrorResponse(403, validation.reason || 'Request blocked');
        }

        // 执行代理请求
        const targetUrl = fixUrl(targetPath);

        // 检查GET请求的缓存（包含关键请求头以避免冲突）
        const cacheKey = await this.generateCacheKey(request, targetUrl);
        const cachedResponse = request.method === 'GET' ? this.responseCache.get(cacheKey) : undefined;

        if (cachedResponse && (Date.now() - cachedResponse.timestamp < this.cacheTTL)) {
          // 返回缓存的响应副本
          const cachedBody = await cachedResponse.response.clone().arrayBuffer();
          const cachedHeaders = new Headers(cachedResponse.response.headers);

          response = new Response(cachedBody, {
            status: cachedResponse.response.status,
            statusText: cachedResponse.response.statusText,
            headers: this.buildCorsHeaders(cachedHeaders, origin || undefined)
          });

          success = response.status < 400;
        } else {
          try {
            // 执行新请求
            const proxyResponse = await performProxy(request, targetUrl, this.config);

            // 构建响应
            response = new Response(proxyResponse.body, {
              status: proxyResponse.status,
              statusText: proxyResponse.statusText,
              headers: this.buildCorsHeaders(proxyResponse.headers, origin || undefined)
            });

            success = proxyResponse.status < 400;

            // 缓存GET请求的成功响应
            if (request.method === 'GET' && success) {
              this.responseCache.set(cacheKey, {
                response: response.clone(),
                timestamp: Date.now()
              });
            }
          } catch (proxyError) {
            // 处理代理请求错误
            if (proxyError instanceof Error && proxyError.message.includes('Request body too large')) {
              return this.createErrorResponse(413, 'Request body too large');
            }
            throw proxyError; // 重新抛出其他错误
          }
        }
        
        // 记录统计
        if (this.config.enableStats) {
          const domain = new URL(targetUrl).hostname;
          const responseTime = Date.now() - startTime;
          this.statsCollector.recordRequest(clientIP, domain, response.status, responseTime, success);
        }

        // 记录日志
        this.logger.logRequest(request, response, targetUrl, Date.now() - startTime);
        
        return response;
        
      } finally {
        await this.concurrencyLimiter.release(clientIP);
      }

    } catch (error) {
      // 并发限制由内层 finally 统一释放，这里不能重复释放（否则计数会漂移）

      // 改进错误处理和日志
      this.logger.logError(error as Error, {
        url: request.url,
        ip: clientIP,
        requestId: requestId,
        timestamp: new Date().toISOString()
      });

      if (this.config.enableStats) {
        this.statsCollector.recordRequest(clientIP, 'error', 500, Date.now() - startTime, false);
      }

      // 避免泄露敏感错误信息
      const sanitizedMessage = error instanceof Error
        ? (error.message.includes('ENOTFOUND') ? 'Target host not found' :
           error.message.includes('ECONNREFUSED') ? 'Connection refused' :
           error.message.includes('timeout') ? 'Request timeout' :
           'Proxy error')
        : 'Unknown error';

      return this.createErrorResponse(500, 'Proxy error', {
        message: sanitizedMessage
      });
    }
  }

  // 清理过期缓存
  private cleanupCache(): void {
    const now = Date.now();
    for (const [key, cached] of this.responseCache.entries()) {
      if (now - cached.timestamp > this.cacheTTL) {
        this.responseCache.delete(key);
      }
    }
  }

  handlePreflight(request: Request): Response {
    const origin = request.headers.get('origin');
    const headers = this.buildCorsHeaders(new Headers(), origin || undefined);
    
    // 添加请求的自定义头
    const requestHeaders = request.headers.get('access-control-request-headers');
    if (requestHeaders) {
      headers.set('Access-Control-Allow-Headers', 
        `${headers.get('Access-Control-Allow-Headers')}, ${requestHeaders}`);
    }
    
    return new Response(null, {
      status: 204,
      headers
    });
  }

  handleManagementApi(request: Request, path: string): Response {
    // API密钥验证（防时序攻击）
    if (this.config.apiKey) {
      const authHeader = request.headers.get('authorization');
      const providedKey = authHeader?.replace('Bearer ', '') ||
                         new URL(request.url).searchParams.get('key');

      if (!providedKey || !this.constantTimeCompare(providedKey, this.config.apiKey)) {
        return this.createErrorResponse(401, 'Invalid API key');
      }
    }

    const apiPath = path.substring(5); // 移除 '_api/' 前缀

    switch (apiPath) {
      case 'stats':
        if (!this.config.enableStats) {
          return this.createErrorResponse(404, 'Stats disabled');
        }
        const stats = this.statsCollector.getStats();
        const rateLimiterStats = this.rateLimiter.getStats();
        const concurrencyStats = this.concurrencyLimiter.getStats();
        
        return new Response(JSON.stringify({
          stats: {
            ...stats,
            topDomains: Object.fromEntries(stats.topDomains),
            topIPs: Object.fromEntries(stats.topIPs),
            statusCodes: Object.fromEntries(stats.statusCodes),
            hourlyStats: stats.hourlyStats
          },
          rateLimiter: rateLimiterStats,
          concurrency: {
            totalCount: concurrencyStats.totalCount,
            activeIPs: concurrencyStats.perIpCount.size
          },
          cache: {
            size: this.responseCache.size
          },
          uptime: Date.now() - stats.startTime,
          version: '1.3.0'
        }, null, 2), {
          headers: { 'Content-Type': 'application/json' }
        });

      case 'health':
        return new Response(JSON.stringify({
          status: 'healthy',
          timestamp: new Date().toISOString(),
          version: '1.3.0',
          memory: Deno.memoryUsage ? {
            rss: Deno.memoryUsage().rss,
            heapTotal: Deno.memoryUsage().heapTotal,
            heapUsed: Deno.memoryUsage().heapUsed
          } : undefined
        }), {
          headers: { 'Content-Type': 'application/json' }
        });

      case 'config':
        // 返回脱敏的配置信息
        const safeConfig = { ...this.config };
        if (safeConfig.apiKey) safeConfig.apiKey = '***';
        if (safeConfig.logWebhook) safeConfig.logWebhook = '***';
        
        return new Response(JSON.stringify(safeConfig, null, 2), {
          headers: { 'Content-Type': 'application/json' }
        });

      case 'reset-stats':
        if (!this.config.enableStats) {
          return this.createErrorResponse(404, 'Stats disabled');
        }
        this.statsCollector.reset();
        return new Response(JSON.stringify({
          success: true,
          message: 'Statistics reset successfully'
        }), {
          headers: { 'Content-Type': 'application/json' }
        });

      case 'clear-cache':
        const cacheSize = this.responseCache.size;
        this.responseCache.clear();
        return new Response(JSON.stringify({
          success: true,
          message: `Cache cleared successfully (${cacheSize} entries)`
        }), {
          headers: { 'Content-Type': 'application/json' }
        });

      case 'reload-config':
        try {
          const newConfig = loadConfig();

          // 验证新配置的有效性
          if (newConfig.port < 1 || newConfig.port > 65535) {
            throw new Error(`Invalid port: ${newConfig.port}`);
          }
          if (newConfig.rateLimit < 0 || newConfig.concurrentLimit < 0) {
            throw new Error('Rate limit and concurrent limit must be non-negative');
          }

          // 清理旧的资源
          this.logger.cleanup();
          this.rateLimiter.destroy();

          // 更新配置
          this.config = newConfig;

          // 重新初始化所有组件
          this.rateLimiter = new RateLimiter(newConfig.rateLimitWindow, newConfig.rateLimit);
          this.concurrencyLimiter = new ConcurrencyLimiter(newConfig.concurrentLimit, newConfig.totalConcurrentLimit);
          this.logger = new Logger(newConfig.enableLogging, newConfig.logWebhook);

          return new Response(JSON.stringify({
            success: true,
            message: 'Configuration reloaded successfully',
            timestamp: new Date().toISOString(),
            config: {
              port: newConfig.port,
              enableStats: newConfig.enableStats,
              enableLogging: newConfig.enableLogging,
              rateLimit: newConfig.rateLimit,
              concurrentLimit: newConfig.concurrentLimit,
              totalConcurrentLimit: newConfig.totalConcurrentLimit,
              maxUrlLength: newConfig.maxUrlLength,
              timeout: newConfig.timeout,
              logWebhook: newConfig.logWebhook ? '***' : undefined,
              allowedOrigins: newConfig.allowedOrigins.length,
              allowedDomains: newConfig.allowedDomains.length,
              blockedIPs: newConfig.blockedIPs.length,
              blockedDomains: newConfig.blockedDomains.length
            }
          }), {
            headers: { 'Content-Type': 'application/json' }
          });
        } catch (error) {
          return new Response(JSON.stringify({
            success: false,
            error: 'Failed to reload configuration',
            message: error instanceof Error ? error.message : 'Unknown error',
            timestamp: new Date().toISOString()
          }), {
            status: 500,
            headers: { 'Content-Type': 'application/json' }
          });
        }

      case 'performance':
        if (!this.config.enableStats) {
          return this.createErrorResponse(404, 'Stats disabled');
        }
        const performanceData = this.statsCollector.getPerformanceData();
        return new Response(JSON.stringify(performanceData, null, 2), {
          headers: { 'Content-Type': 'application/json' }
        });

      case 'version':
        return new Response(JSON.stringify({
          version: '1.3.0',
          runtime: `Deno ${Deno.version.deno}`,
          typescript: Deno.version.typescript,
          v8: Deno.version.v8
        }), {
          headers: { 'Content-Type': 'application/json' }
        });

      default:
        return this.createErrorResponse(404, 'API endpoint not found');
    }
  }

  private buildCorsHeaders(originalHeaders: Headers, origin?: string): Headers {
    const headers = new Headers();

    // 复制原始响应头（除了一些需要过滤的）
    const skipHeaders = ['access-control-allow-origin', 'access-control-allow-methods', 
                        'access-control-allow-headers', 'access-control-expose-headers'];
    
    for (const [key, value] of originalHeaders.entries()) {
      if (!skipHeaders.includes(key.toLowerCase())) {
        headers.set(key, value);
      }
    }

    // 设置CORS头
    if (this.config.allowedOrigins.length > 0) {
      if (this.config.allowedOrigins.includes('*')) {
        headers.set('Access-Control-Allow-Origin', '*');
      } else if (origin && this.config.allowedOrigins.includes(origin)) {
        headers.set('Access-Control-Allow-Origin', origin);
        headers.set('Vary', 'Origin');
      }
    } else {
      headers.set('Access-Control-Allow-Origin', '*');
    }

    headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
    headers.set('Access-Control-Allow-Headers', 
      'Accept, Authorization, Cache-Control, Content-Type, DNT, If-Modified-Since, Keep-Alive, Origin, User-Agent, X-Requested-With, Token, x-access-token');
    headers.set('Access-Control-Expose-Headers', '*');
    headers.set('Access-Control-Max-Age', '86400');

    return headers;
  }

  createErrorResponse(code: number, message: string, details?: any): Response {
    const body = {
      error: true,
      code,
      message,
      timestamp: new Date().toISOString(),
      ...details
    };

    return new Response(JSON.stringify(body, null, 2), {
      status: code,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        ...(details?.retryAfter ? { 'Retry-After': String(details.retryAfter) } : {})
      }
    });
  }

  private getClientIP(request: Request): string {
    return request.headers.get('cf-connecting-ip') ||
           request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
           request.headers.get('x-real-ip') ||
           'unknown';
  }

  // 常量时间字符串比较，防止时序攻击
  private constantTimeCompare(a: string, b: string): boolean {
    if (a.length !== b.length) {
      return false;
    }

    let result = 0;
    for (let i = 0; i < a.length; i++) {
      result |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }

    return result === 0;
  }

  // 生成缓存键，包含关键请求头以避免冲突
  private async generateCacheKey(request: Request, targetUrl: string): Promise<string> {
    const method = request.method;
    const userAgent = request.headers.get('user-agent') || '';
    const accept = request.headers.get('accept') || '';
    const acceptLanguage = request.headers.get('accept-language') || '';

    const keyData = `${method}:${targetUrl}:${userAgent}:${accept}:${acceptLanguage}`;

    // 使用SHA-256避免哈希冲突（自研哈希在用户可控输入下可被碰撞，导致返回错误目标的缓存）
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(keyData));
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
  }
  
  // 重载配置
  reloadConfig(): void {
    try {
      const newConfig = loadConfig();

      // 验证新配置
      if (newConfig.port < 1 || newConfig.port > 65535) {
        throw new Error(`Invalid port: ${newConfig.port}`);
      }

      // 清理旧资源
      this.logger.cleanup();
      this.rateLimiter.destroy();

      // 更新配置
      this.config = newConfig;

      // 重新初始化组件
      this.rateLimiter = new RateLimiter(newConfig.rateLimitWindow, newConfig.rateLimit);
      this.concurrencyLimiter = new ConcurrencyLimiter(newConfig.concurrentLimit, newConfig.totalConcurrentLimit);
      this.logger = new Logger(newConfig.enableLogging, newConfig.logWebhook);

      console.log("✅ Configuration reloaded successfully");
    } catch (error) {
      console.error("❌ Failed to reload configuration:", error);
      throw error;
    }
  }

  // 清理资源
  cleanup(): void {
    this.isDestroyed = true;
    this.logger.cleanup();
    this.rateLimiter.destroy();
    this.statsCollector.destroy();
    if (this.cacheCleanupTimer !== null) {
      clearInterval(this.cacheCleanupTimer);
      this.cacheCleanupTimer = null;
    }
    this.responseCache.clear();
  }
}

// ==================== 服务启动模块 ====================
/**
 * 主函数：启动服务
 * 支持Deno Deploy和本地运行
 */
async function main() {
  const config = loadConfig();
  const server = new CiaoCorsServer();

  console.log(`
====================================================
  🚀 CIAO-CORS Server v1.3.0
====================================================
  📌 Port: ${config.port}
  📊 Stats: ${config.enableStats ? 'enabled' : 'disabled'}
  📝 Logging: ${config.enableLogging ? 'enabled' : 'disabled'}
  ⏱️ Rate limit: ${config.rateLimit} requests per ${config.rateLimitWindow / 1000}s
  🔄 Concurrent limit: ${config.concurrentLimit} per IP, ${config.totalConcurrentLimit} total
  🔒 API key: ${config.apiKey ? 'configured' : 'not set'}
  🛡️ Header validation: ${config.requireHeaders ? 'enabled' : 'disabled'}
====================================================
  `);
  
  if (config.allowedDomains.length > 0) {
    console.log(`🔒 Domain whitelist: ${config.allowedDomains.length} domains`);
  }
  if (config.blockedDomains.length > 0) {
    console.log(`🚫 Domain blacklist: ${config.blockedDomains.length} domains`);
  }

  // 捕获退出信号
  const handleShutdown = () => {
    console.log("💤 Shutting down gracefully...");
    server.cleanup();
    Deno.exit(0);
  };

  // 处理退出信号
  if (Deno.addSignalListener) {
    try {
      Deno.addSignalListener("SIGINT", handleShutdown);
      Deno.addSignalListener("SIGTERM", handleShutdown);
      // 添加HUP信号处理（用于配置重载）
      Deno.addSignalListener("SIGHUP", () => {
        console.log("🔄 Received SIGHUP, reloading configuration...");
        try {
          server.reloadConfig();
        } catch (error) {
          console.error("❌ Failed to reload configuration:", error);
        }
      });
    } catch (e) {
      console.warn("无法注册信号处理程序:", e);
    }
  }

  const handler = (request: Request) => server.handleRequest(request);

  // 启动HTTP服务器
  try {
    console.log(`🌐 Starting server on port ${config.port}...`);
    await Deno.serve({
      port: config.port,
      onError: (error) => {
        console.error('Server error:', error);
        return new Response('Internal Server Error', { status: 500 });
      }
    }, handler);
  } catch (error) {
    console.error('Failed to start server:', error);
    if (error instanceof Error && error.message.includes('Address already in use')) {
      console.error(`Port ${config.port} is already in use. Please check if another service is running on this port.`);
    }
    Deno.exit(1);
  }
}

/**
 * Deno Deploy兼容的默认导出
 * 使用模块级单例，确保限流、统计、缓存在请求之间共享
 * （环境变量在Deno Deploy中直接通过Deno.env读取，无需逐请求注入）
 */
let deployServer: CiaoCorsServer | null = null;

export default {
  fetch(request: Request): Promise<Response> {
    if (!deployServer) {
      deployServer = new CiaoCorsServer();
    }
    return deployServer.handleRequest(request);
  }
};

// 如果直接运行，启动服务
if (import.meta.main) {
  main();
}
