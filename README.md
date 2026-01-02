# Server Toolkit

服务器管理工具包，提供模块化的服务器维护工具和统一的管理界面。

> 📖 **完整文档**: 请查看 [docs.md](docs.md) 获取详细的开发指南和使用说明

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
├── helper.sh              # 配置和工具函数库
├── config.json            # 模块和菜单元数据
├── deploy.sh              # 部署脚本（安装到服务器）
├── menu.sh                # 交互式菜单主程序
├── docs.md                # 详细文档
├── ssh-security/          # SSH 安全模块
│   └── deploy.sh
├── cert/                  # 证书同步模块
│   └── deploy.sh
└── system/                # 系统维护模块
    └── swap.sh
```

### 本地结构（/srv/server-toolkit）

部署后，工具包安装在 `/srv/server-toolkit/`，包含：

```
/srv/server-toolkit/
├── menu.sh                # 交互式菜单主程序
├── config.json            # 模块和菜单元数据
├── helper.sh              # 配置和工具函数库
├── scripts/               # Git 克隆的仓库目录
│   ├── ssh-security/     # SSH 安全模块
│   ├── cert/             # 证书同步模块
│   ├── system/           # 系统维护模块
│   └── [其他模块]        # 其他模块脚本
└── storage/               # 持久化任务数据目录
    ├── ssh-security/     # SSH 安全模块数据
    ├── cert/             # 证书同步模块数据
    └── [其他模块]        # 其他模块的持久化数据
```

**核心文件**：
- `menu.sh` - 交互式菜单主程序
- `config.json` - 模块和菜单元数据
- `helper.sh` - 配置和工具函数库

**scripts 目录**：
- Git 克隆的完整仓库
- 包含所有模块脚本
- 支持自动更新

**storage 目录**：
- 持久化任务数据
- 每个模块有独立子目录
- 存储定时任务脚本和日志
- 独立于 Git 仓库，不受更新影响

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
- 检测并安装缺失的系统依赖（curl、jq、git、procps 等）
- 克隆完整仓库到 `/srv/server-toolkit/scripts/`
- 复制核心组件（config.json、helper.sh、menu.sh）到主目录
- 创建 `/srv/server-toolkit/storage/` 持久化数据目录
- 创建 `server-toolkit` 系统命令
- 配置环境变量（Vault URL、设备 UUID 等）

模块脚本从本地 scripts 目录执行，持久化数据保存在 storage 目录。

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
[INFO] 正在检查核心组件更新...
[INFO] 当前版本: v1.0.0
[INFO] 最新版本: v1.1.0
[INFO] 正在更新核心文件...
[成功] 核心组件更新成功！
[INFO] 重新加载配置...
```

## 日志

### SSH 安全同步日志

位置：`/srv/server-toolkit/storage/ssh-security/sync.log`

查看日志：

```bash
tail -f /srv/server-toolkit/storage/ssh-security/sync.log
```

### 证书同步日志

位置：`/srv/server-toolkit/cert/sync.log`

查看日志：

```bash
tail -f /srv/server-toolkit/cert/sync.log
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

1. 检查网络连接到 GitHub
2. 验证可以访问仓库 URL
3. 检查 `/srv/server-toolkit/scripts/` 目录权限
4. 手动执行 `cd /srv/server-toolkit/scripts && git pull`

### server-toolkit 命令不可用

1. 检查 `/usr/local/bin/server-toolkit` 是否存在
2. 重新运行 `deploy.sh`
3. 确保 `/usr/local/bin` 在 PATH 中

### SSH 安全部署失败

1. 确认以 root 权限运行
2. 检查依赖：`curl`, `jq`, `ipset`, `iptables`
3. 查看同步日志：`/srv/server-toolkit/storage/ssh-security/sync.log`

### 系统信息显示 N/A

网络信息获取失败，可能原因：
- 服务器无公网 IP
- 防火墙阻止出站连接
- API 服务不可用

## 版本历史

### v1.1.0 (2024)

- ✨ 重构目录结构
- ✨ 使用 Git 克隆方式部署
- ✨ 引入 storage 目录管理持久化数据
- ✨ 重命名 config.sh 为 helper.sh
- ✨ 改进模块管理机制
- ✨ 创建 docs.md 详细文档

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
