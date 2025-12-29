# Server Toolkit

服务器管理工具包，提供模块化的服务器维护工具和统一的管理界面。

## 功能特性

- 🖥️ **系统信息展示**：自动获取网络、资源、设备信息
- 🔐 **SSH 安全防护**：基于 Vault 白名单的智能防护系统
- 🔄 **系统更新管理**：自动化系统更新和维护
- ☁️ **云端集成**：从 Vault API 动态获取配置
- 🎨 **友好界面**：彩色终端输出，交互式操作菜单
- 🔧 **模块化架构**：支持独立模块的安装和更新
- 🔄 **自动更新**：工具包和模块的自动更新检查

## 架构设计

### 仓库结构（云端）

```
server-toolkit/
├── config.sh              # 配置和工具函数库
├── config.json            # 模块和菜单元数据
├── deploy.sh              # 部署脚本（安装到服务器）
├── menu.sh                # 交互式菜单主程序
├── ssh-security/          # SSH 安全模块
│   └── deploy.sh
└── system/                # 系统维护模块
    └── update.sh
```

### 本地结构（/srv/server-toolkit）

部署后，工具包安装在 `/srv/server-toolkit/`，包含：
- 所有仓库文件的副本
- 本地 `config.json`（跟踪已安装模块）
- 模块持久化数据目录
- Git 仓库（用于自动更新）

## 快速开始

### 一键部署

直接运行远程脚本即可完成部署：

```bash
curl -sSL https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash
```

部署脚本会自动：
- 检测并安装缺失的系统依赖（curl、jq、git 等）
- 从远程仓库拉取主模块
- 将工具包部署到 `/srv/server-toolkit/`
- 创建 `server-toolkit` 系统命令
- 配置环境变量（Vault URL、设备 UUID 等）
- 初始化 Git 仓库用于自动更新

子模块由主模块统一管理和引用。

### 启动工具包

部署完成后，使用以下命令启动：

```bash
sudo server-toolkit
```

## 菜单系统

工具包使用编号菜单系统：

### 保留操作（0-9）

- **[0]** 退出
- **[1]** 配置 Vault URL
- **[2]** 配置设备 UUID
- **[3]** 工具包自更新
- **[4]** 更新模块
- **[5]** 显示当前配置
- **[6-9]** 保留待用

### 模块操作（10+）

- **[10]** SSH 安全防护部署
- **[11]** 系统更新
- **[12+]** 其他模块...

## 配置管理

### 环境变量

工具包使用 `/etc/environment` 存储配置：

```bash
# 设备 UUID（用于 Vault API 认证）
SYS_DEVICE_UUID="your-device-uuid-here"

# Vault API URL
SYS_VAULT_URL="https://vault.wuyilingwei.com/api/data"

# 工具包安装目录
SYS_TOOLKIT_DIR="/srv/server-toolkit"

# 工具包仓库 URL
SYS_TOOLKIT_REPO="https://github.com/wuyilingwei/server-toolkit"
```

### 配置方式

1. **部署时配置**：`deploy.sh` 会交互式配置必要变量
2. **菜单配置**：使用菜单选项 [1] 和 [2] 修改配置
3. **手动配置**：编辑 `/etc/environment` 后重新登录

## 模块开发

### 模块结构

每个模块是一个独立的目录，包含：
- `deploy.sh` - 模块部署/执行脚本
- 其他必要的文件和子脚本

### 注册模块

在 `config.json` 中添加模块信息：

```json
{
  "id": "module-id",
  "name": "模块名称",
  "description": "模块描述",
  "script": "module-dir/deploy.sh",
  "min_config_version": "1.0.0",
  "menu_id": 12,
  "enabled": true
}
```

### 版本兼容性

模块应声明所需的最低 `config.sh` 版本：

```json
"min_config_version": "1.0.0"
```

工具包会在执行前检查版本兼容性。

## 功能模块

### 1. SSH 安全防护部署 [10]

基于 Vault API 的白名单防护系统：

- ✅ 自动从云端同步 IP 白名单
- ✅ 使用 IPSET 高性能匹配
- ✅ 熔断保护机制（API 失败时自动解除 DROP 规则）
- ✅ 定时同步（每 10 分钟）
- ✅ 层级防护策略

**使用方法**：

```bash
sudo server-toolkit
# 选择 [10] SSH 安全防护部署
```

### 2. 系统更新 [11]

自动化系统软件包更新和清理：

- 更新软件包列表
- 升级已安装软件包
- 清理不需要的依赖

**使用方法**：

```bash
sudo server-toolkit
# 选择 [11] 系统更新
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

## 使用示例

### 主界面

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

[配置信息]
  设备 UUID: abc123-def456-ghi789
  Vault URL: https://vault.wuyilingwei.com/api/data
  安装目录: /srv/server-toolkit
  配置版本: v1.0.0

==================== 操作菜单 ====================
[1] 配置 Vault URL
[2] 配置设备 UUID
[3] 工具包自更新
[4] 更新模块
[5] 显示当前配置

[10] SSH 安全防护部署
[11] 系统更新

[0] 退出
==================================================
请输入操作编号:
```

### 自动更新

工具包启动时会自动检查更新：

```
[警告] 发现新版本可用！请使用选项 [3] 进行更新
```

选择 [3] 执行自更新：

```
==================== 工具包自更新 ====================
[INFO] 拉取最新代码...
[成功] 更新成功！
[INFO] 重新加载配置...
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
4. 使用菜单 [5] 查看当前配置

### 自动更新失败

1. 确保有 Git 访问权限
2. 检查 `/srv/server-toolkit/.git` 是否存在
3. 手动运行：`cd /srv/server-toolkit && git pull`

### server-toolkit 命令不可用

1. 检查 `/usr/local/bin/server-toolkit` 是否存在
2. 重新运行 `deploy.sh`
3. 确保 `/usr/local/bin` 在 PATH 中

### SSH 安全部署失败

1. 确认以 root 权限运行
2. 检查依赖：`curl`, `jq`, `ipset`, `iptables`
3. 查看同步日志：`/var/log/ssh_security.log`

### 系统信息显示 N/A

网络信息获取失败，可能原因：
- 服务器无公网 IP
- 防火墙阻止出站连接
- API 服务不可用

## 版本历史

### v1.0.0 (2024)

- ✨ 初始版本发布
- ✨ 模块化架构设计
- ✨ 自动更新机制
- ✨ 保留菜单系统（0-9）
- ✨ 模块版本兼容性检查
- ✨ 配置管理界面
- ✨ SSH 安全防护模块
- ✨ 系统更新模块
- ✨ server-toolkit 系统命令
