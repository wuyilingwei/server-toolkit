# Server Toolkit 文档

## 项目概述

Server Toolkit 是一个模块化的服务器管理工具包，提供统一的管理界面和多种服务器维护功能。

## 架构设计

### 目录结构

```
/srv/server-toolkit/              # 主目录
├── menu.sh                       # 交互式菜单主程序
├── config.json                   # 模块和菜单元数据
├── helper.sh                     # 配置和工具函数库
├── cert/                         # 证书同步模块数据目录
│   ├── local/                   # 同步的证书存储目录 (权限 600)
│   ├── sync-config.json         # 证书同步配置文件
│   ├── worker.sh                # 证书同步工作脚本
│   └── sync.log                 # 证书同步日志
├── storage/                      # 持久化任务数据目录
│   ├── ssh-security/            # SSH 安全模块持久化数据
│   └── [其他模块]/              # 其他模块的持久化数据
└── scripts/                      # Git 仓库目录
    ├── ssh-security/            # SSH 安全模块
    │   └── deploy.sh
    ├── cert/                    # 证书同步模块
    │   └── deploy.sh
    ├── system/                  # 系统维护模块
    │   └── swap.sh
    └── [其他模块]/              # 其他模块脚本
```

### 核心组件

#### menu.sh
交互式菜单主程序，提供：
- 系统信息展示（网络、资源、配置）
- 保留操作菜单（0-9）
- 模块操作菜单（10+）
- 工具包自更新功能

#### helper.sh
配置和工具函数库，包含：
- 环境变量管理（/etc/environment）
- 系统信息获取函数
- 版本比较和更新检查
- Vault API 调用封装
- 日志输出函数

#### config.json
模块和菜单的元数据配置：
- 版本信息
- 模块列表和配置
- 菜单 ID 映射
- 模块依赖关系

#### scripts/
Git 克隆的仓库目录，包含所有模块脚本：
- 从远程仓库自动克隆
- 支持自动更新
- 模块脚本按功能分类

#### storage/
持久化任务数据目录：
- 每个需要持久化的模块有独立子目录
- 存储模块运行时生成的数据
- 存储定时任务脚本和日志
- 独立于 Git 仓库，不受更新影响

## 部署方式

### 一键部署

```bash
curl -sSL https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/wuyilingwei/server-toolkit/main/deploy.sh | sudo bash
```

### 部署流程

1. **检测并安装依赖**
   - curl
   - jq
   - git
   - procps

2. **克隆仓库**
   - 克隆完整仓库到 `/srv/server-toolkit/scripts`
   - 强制克隆（如果目录存在则删除重新克隆）

3. **复制核心文件**
   - 从 scripts/ 复制核心文件到主目录
   - menu.sh
   - config.json
   - helper.sh

4. **创建目录结构**
   - 创建 `/srv/server-toolkit/storage` 目录
   - 创建各模块的持久化子目录

5. **配置环境变量**
   - SYS_TOOLKIT_DIR: `/srv/server-toolkit`
   - SYS_TOOLKIT_REPO: 仓库 URL
   - SYS_VAULT_URL: Vault API 地址
   - SYS_DEVICE_UUID: 设备认证 UUID

6. **创建系统命令**
   - 创建 `/usr/local/bin/server-toolkit` 命令
   - 设置执行权限

## 菜单系统

### 保留操作（0-9）

| 编号 | 功能 | 说明 |
|------|------|------|
| 0 | 退出 | 退出工具包 |
| 1 | 配置 Vault URL | 设置 Vault API 地址 |
| 2 | 配置设备 UUID | 设置设备认证令牌 |
| 3 | 工具包自更新 | 更新核心组件和模块 |
| 4 | 更新模块 | 查看和更新已安装模块 |
| 5 | 显示当前配置 | 显示系统配置和已安装模块 |
| 6-9 | 保留待用 | 预留给未来功能 |

### 模块操作（10+）

| 编号 | 模块 | 功能 |
|------|------|------|
| 10 | SSH 安全防护 | 基于 Vault 白名单的 SSH 防护系统 |
| 11 | 证书同步 | 从 Vault 同步 SSL 证书 |
| 12 | 系统 Swap 管理 | 创建和调整 Swap 交换区 |

## 功能模块

### SSH 安全防护模块

**功能特性：**
- 基于 IPSET 的白名单防护
- 从 Vault API 动态获取白名单
- 熔断保护机制（API 失败时自动解除拦截）
- 定时同步（每 10 分钟）
- 多层级防护策略

**持久化数据：**
- 路径：`/srv/server-toolkit/storage/ssh-security/`
- 内容：同步脚本、日志文件

**使用方法：**
```bash
sudo server-toolkit
# 选择 [10] SSH 安全防护部署
```

### 证书同步模块

**功能特性：**
- 从 Vault API 列出所有可用证书密钥
- 支持选择性同步生产证书（cert, fullchain, privkey）
- 支持选择性同步 CloudFlare Origin 证书（cf-cert, cf-privkey）
- 定时自动同步（每小时）
- 证书目录权限自动管理（可选设置为 600）
- 保持原有证书命名

**持久化数据：**
- 路径：`/srv/server-toolkit/cert/`
- 内容：同步配置、工作脚本、日志文件
- 证书存储：`/srv/server-toolkit/cert/local/`
- 目录权限：建议 600（仅所有者可读写）

**使用方法：**
```bash
sudo server-toolkit
# 选择 [11] 证书同步管理
```

### 系统 Swap 管理模块

**功能特性：**
- 创建和调整 Swap 交换区
- 配置 Swappiness 参数
- 自动持久化到 /etc/fstab
- 交互式配置引导

**使用方法：**
```bash
sudo server-toolkit
# 选择 [12] 系统 Swap 管理
```

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

1. **部署时配置**：deploy.sh 会交互式配置必要变量
2. **菜单配置**：使用菜单选项 [1] 和 [2] 修改配置
3. **手动配置**：编辑 `/etc/environment` 后重新登录或 source

### 配置函数

在 helper.sh 中提供的配置函数：
- `get_config_value(key, default)` - 获取配置值
- `set_config_value(key, value)` - 设置配置值
- `get_device_uuid()` - 获取设备 UUID
- `get_vault_url()` - 获取 Vault URL
- `get_install_dir()` - 获取安装目录
- `get_remote_repo()` - 获取远程仓库 URL

## 模块开发

### 模块结构

每个模块是一个独立的目录，位于 `scripts/` 下：

```
scripts/module-name/
├── deploy.sh              # 主部署脚本（必需）
├── worker.sh             # 持久化任务脚本（可选）
└── [其他文件]            # 模块所需的其他文件
```

### 注册模块

在 `config.json` 中添加模块信息：

```json
{
  "id": "module-id",
  "name": "模块名称",
  "description": "模块描述",
  "script": "module-dir/deploy.sh",
  "min_config_version": "1.0.0",
  "menu_id": 13,
  "enabled": true,
  "needs_persistence": true,
  "version": "1.0.0"
}
```

### 模块脚本要求

1. **工作目录保护**
   每个模块脚本必须包含工作目录保护代码：
   ```bash
   WORKDIR="/srv/server-toolkit"
   mkdir -p "$WORKDIR"
   if ! cd "$WORKDIR" 2>/dev/null; then
       chmod 755 "$WORKDIR" 2>/dev/null || mkdir -p "$WORKDIR"
       cd "$WORKDIR" || { echo "错误: 无法访问工作目录 $WORKDIR"; exit 1; }
   fi
   ```

2. **使用 storage 目录**
   持久化数据应存储在 `storage/[module-id]/` 目录：
   ```bash
   STORAGE_DIR="/srv/server-toolkit/storage/module-id"
   mkdir -p "$STORAGE_DIR"
   ```

3. **环境变量**
   加载系统环境变量：
   ```bash
   source /etc/environment
   ```

4. **日志记录**
   使用统一的日志格式：
   ```bash
   log() {
       echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
   }
   ```

### 持久化任务管理

对于需要定时执行的任务：

1. **创建 worker 脚本**
   在 storage 目录下创建持久化脚本：
   ```bash
   WORKER_SCRIPT="$STORAGE_DIR/worker.sh"
   cat > "$WORKER_SCRIPT" << 'EOF'
   #!/bin/bash
   # Worker script content
   EOF
   chmod +x "$WORKER_SCRIPT"
   ```

2. **配置 Crontab**
   使用标签管理 cron 任务：
   ```bash
   TAG="#st-module-id"
   CRON_CMD="*/10 * * * * $WORKER_SCRIPT >> $LOG_FILE 2>&1 $TAG"
   crontab -l 2>/dev/null | grep -v "$TAG" > /tmp/cron.tmp
   echo "$CRON_CMD" >> /tmp/cron.tmp
   crontab /tmp/cron.tmp
   rm /tmp/cron.tmp
   ```

3. **清理旧任务**
   使用唯一标签避免重复任务：
   ```bash
   crontab -l 2>/dev/null | grep -v "$TAG" > /tmp/cron.tmp
   ```

## Vault API 集成

### API 端点

默认端点：`https://vault.wuyilingwei.com/api/data`

可通过 `SYS_VAULT_URL` 环境变量自定义。

### 认证方式

使用 Bearer Token 认证，Token 从 `SYS_DEVICE_UUID` 环境变量读取。

### 请求格式

```bash
curl -X POST "$VAULT_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "ops": [{
      "id": "operation_id",
      "type": "read|write|list",
      "module": "module_name",
      "key": "key_name"
    }]
  }'
```

### 响应格式

```json
[{
  "status": 200,
  "data": {
    "content": [...]
  }
}]
```

### 使用 helper 函数

在 helper.sh 中提供的 API 调用函数：

```bash
source /srv/server-toolkit/helper.sh
vault_api_call '{"ops": [...]}'
```

## 更新机制

### 工具包自更新

菜单选项 [3] 触发自更新：

1. 检查远程版本
2. 比较本地版本
3. 拉取最新代码（git pull）
4. 复制核心文件到主目录
5. 重新加载配置

### 模块更新

模块随工具包一起更新：
- Git 仓库更新会同时更新所有模块脚本
- 持久化数据保存在 storage/ 目录，不受更新影响
- 重新执行模块会应用最新脚本

### 版本兼容性

模块声明所需的最低 helper.sh 版本：

```json
"min_config_version": "1.0.0"
```

工具包在执行前检查版本兼容性。

## 安全注意事项

1. **保护敏感信息**
   - 妥善保管 `SYS_DEVICE_UUID`
   - 不要在日志中输出完整 UUID
   - 使用 HTTPS 连接 Vault API

2. **权限管理**
   - 工具包需要 root 权限运行
   - 证书文件权限设置为 600
   - Storage 目录权限适当限制

3. **SSH 安全**
   - 部署前确保有备用管理入口
   - 熔断机制避免锁死服务器
   - 定期备份白名单配置

4. **备份建议**
   - 定期备份 `/etc/environment`
   - 备份 `/srv/server-toolkit/storage/` 持久化数据
   - 记录重要的配置变更

## 故障排查

### 无法连接 Vault API

1. 检查网络连接
2. 验证 `SYS_DEVICE_UUID` 是否正确
3. 检查 `SYS_VAULT_URL` 配置
4. 使用菜单 [5] 查看当前配置

### 工具包更新失败

1. 检查网络连接到 GitHub
2. 验证可以访问仓库 URL
3. 检查 `/srv/server-toolkit/scripts/` 目录权限
4. 手动执行 `cd /srv/server-toolkit/scripts && git pull`

### server-toolkit 命令不可用

1. 检查 `/usr/local/bin/server-toolkit` 是否存在
2. 检查文件执行权限
3. 确保 `/usr/local/bin` 在 PATH 中
4. 重新运行 deploy.sh

### 模块执行失败

1. 确认以 root 权限运行
2. 检查模块所需依赖是否安装
3. 查看 storage 目录下的日志文件
4. 使用菜单 [5] 检查配置

### 持久化任务未运行

1. 检查 crontab 配置：`crontab -l`
2. 查看系统日志：`grep CRON /var/log/syslog`
3. 验证 worker 脚本执行权限
4. 手动执行 worker 脚本测试

## 日志文件

### SSH 安全同步日志
- 位置：`/srv/server-toolkit/storage/ssh-security/sync.log`
- 查看：`tail -f /srv/server-toolkit/storage/ssh-security/sync.log`

### 证书同步日志
- 位置：`/srv/server-toolkit/cert/sync.log`
- 查看：`tail -f /srv/server-toolkit/cert/sync.log`

### 系统日志
- Cron 日志：`/var/log/syslog` 或 `/var/log/cron`
- 查看：`grep server-toolkit /var/log/syslog`

## 版本历史

### v1.1.0 (当前)
- ✨ 重构目录结构
- ✨ 使用 Git 克隆方式部署
- ✨ 引入 storage 目录管理持久化数据
- ✨ 重命名 config.sh 为 helper.sh
- ✨ 改进模块管理机制

### v1.0.0
- ✨ 初始版本发布
- ✨ 模块化架构设计
- ✨ 自动更新机制
- ✨ SSH 安全防护模块
- ✨ 证书同步模块
- ✨ 系统 Swap 管理模块

## 贡献指南

### 提交模块

1. Fork 仓库
2. 在 `scripts/` 下创建模块目录
3. 编写模块脚本（遵循规范）
4. 在 `config.json` 中注册模块
5. 测试模块功能
6. 提交 Pull Request

### 代码规范

1. Shell 脚本使用 Bash
2. 缩进使用 4 空格
3. 变量命名使用大写字母和下划线
4. 函数命名使用小写字母和下划线
5. 添加必要的注释说明

### 测试要求

1. 在干净的系统上测试部署
2. 测试模块的所有功能
3. 验证持久化数据正确保存
4. 确保错误处理正确
5. 检查日志输出格式

## 许可证

本项目采用 MIT 许可证。详见 LICENSE 文件。

## 联系方式

- 仓库：https://github.com/wuyilingwei/server-toolkit
- 问题反馈：https://github.com/wuyilingwei/server-toolkit/issues
