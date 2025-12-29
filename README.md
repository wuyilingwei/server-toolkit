# Server Toolkit

服务器管理工具包，提供统一的脚本入口和多种服务器维护工具。

## 功能特性

- 🖥️ **系统信息展示**：自动获取网络、资源、设备信息
- 🔐 **SSH 安全防护**：基于 Vault 白名单的智能防护系统
- 🔄 **系统更新管理**：自动化系统更新和维护
- ☁️ **云端集成**：从 Vault API 动态获取操作列表
- 🎨 **友好界面**：彩色终端输出，交互式操作菜单

## 快速开始

### 安装依赖

```bash
sudo apt update
sudo apt install -y curl jq
```

### 运行主脚本

```bash
sudo bash main.sh
```

## 配置

### 环境变量配置

在 `/etc/environment` 中配置以下变量：

```bash
# 设备 UUID（用于 Vault API 认证）
SYS_DEVICE_UUID="your-device-uuid-here"

# Vault API URL（可选，默认为 https://vault.wuyilingwei.com/api/data）
SYS_VAULT_URL="https://vault.wuyilingwei.com/api/data"
```

### 配置方式

1. **自动配置**：首次运行 SSH 安全部署时会交互式配置
2. **手动配置**：直接编辑 `/etc/environment` 文件

```bash
sudo nano /etc/environment
```

添加配置后，重新登录或执行：

```bash
source /etc/environment
```

## 项目结构

```
server-toolkit/
├── main.sh                    # 主入口脚本
├── README.md                  # 项目文档
├── ssh-security/              # SSH 安全模块
│   └── deploy.sh             # SSH 安全部署脚本
└── system/                    # 系统维护模块
    └── update.sh             # 系统更新脚本
```

## 功能模块

### 1. SSH 安全防护部署

基于 Vault API 的白名单防护系统，特性包括：

- ✅ 自动从云端同步 IP 白名单
- ✅ 使用 IPSET 高性能匹配
- ✅ 熔断保护机制（API 失败时自动解除 DROP 规则）
- ✅ 定时同步（每 10 分钟）
- ✅ 层级防护策略

**使用方法**：

```bash
sudo bash main.sh
# 选择 [1] SSH 安全防护部署
```

### 2. 系统更新

自动化系统软件包更新和清理：

- 更新软件包列表
- 升级已安装软件包
- 清理不需要的依赖

**使用方法**：

```bash
sudo bash main.sh
# 选择 [2] 系统更新
```

## Vault API 集成

### API 端点

默认使用：`https://vault.wuyilingwei.com/api/data`

可通过 `SYS_VAULT_URL` 环境变量自定义。

### 认证方式

使用 Bearer Token 认证，Token 从 `SYS_DEVICE_UUID` 环境变量读取。

### 请求示例

获取操作列表：

```bash
curl -X POST "https://vault.wuyilingwei.com/api/data" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_DEVICE_UUID" \
  -d '{
    "ops": [{
      "id": "get_operations",
      "type": "read",
      "module": "toolkit",
      "key": "operations"
    }]
  }'
```

### 响应格式

```json
[{
  "data": {
    "content": [
      {"id": 1, "name": "SSH 安全防护部署", "script": "ssh-security/deploy.sh"},
      {"id": 2, "name": "系统更新", "script": "system/update.sh"}
    ]
  }
}]
```

## 主界面示例

```
==================================================
           Server Toolkit v1.0.0
==================================================
[网络信息]
  公网 IPv4: 203.0.113.42
  公网 IPv6: 2001:db8::1

[系统资源]
  内存使用: 2.1GB / 8.0GB (26%)
  存储使用: 45.2GB / 100.0GB (45%)

[设备信息]
  设备 UUID: abc123-def456-ghi789
  脚本版本: v1.0.0

[Vault 配置]
  Vault URL: https://vault.wuyilingwei.com/api/data

==================== 操作菜单 ====================
[1] SSH 安全防护部署
[2] 系统更新
[0] 退出
==================================================
请输入操作编号:
```

## 日志

### SSH 安全同步日志

位置：`/var/log/ssh_security.log`

查看日志：

```bash
tail -f /var/log/ssh_security.log
```

## 安全注意事项

1. 🔒 请妥善保管 `SYS_DEVICE_UUID`，不要泄露
2. 🔒 建议使用 HTTPS 连接 Vault API
3. 🔒 SSH 安全部署需要 root 权限
4. 🔒 部署前请确保至少有一个备用管理入口
5. 🔒 定期备份 `/etc/environment` 配置

## 故障排查

### 无法连接 Vault API

1. 检查网络连接
2. 验证 `SYS_DEVICE_UUID` 是否正确
3. 检查 `SYS_VAULT_URL` 配置
4. 查看错误信息：`curl -v` 测试 API 连接

### SSH 安全部署失败

1. 确认以 root 权限运行
2. 检查依赖：`curl`, `jq`, `ipset`, `iptables`
3. 查看同步日志：`/var/log/ssh_security.log`

### 系统信息显示 N/A

网络信息获取失败，可能原因：
- 服务器无公网 IP
- 防火墙阻止出站连接
- API 服务不可用

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

详见 [LICENSE](LICENSE) 文件。

## 版本历史

### v1.0.0 (2024)

- ✨ 初始版本发布
- ✨ 支持系统信息展示
- ✨ 集成 Vault API
- ✨ SSH 安全防护部署
- ✨ 系统更新功能
- ✨ 可配置 Vault URL

## 联系方式

如有问题或建议，请通过 GitHub Issues 联系。
