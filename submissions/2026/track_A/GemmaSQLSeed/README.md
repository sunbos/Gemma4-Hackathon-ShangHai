# GemmaSQLSeed
基于 Gemma 4 大模型的智能 SQLite 测试数据生成工具。
## 项目简介
GemmaSQLSeed 是一款基于 Gemma 4 大模型的智能 SQLite 测试数据生成工具。通过 MCP（Model Context Protocol）协议和 Gemma 4 原生函数调用（Native Function Calling），AI Agent 可以直接与数据库交互，实现 schema 自动分析、数据配置智能生成和批量数据填充。
## 核心创新点
1. **Gemma 4 原生函数调用（Native Function Calling）**：SchemaAnalyzer 通过 GEMMA_TOOLS 定义 `analyze_schema` 和 `generate_column_values` 两个函数调用接口，Gemma 4 直接以结构化参数返回分析结果
2. **自纠正流程（AiConfigRefiner）**：Gemma 4 生成配置后自动验证并修正，最多3轮自纠正
3. **多后端支持**：Google AI Studio（云端）、LM Studio（本地 GUI）、Ollama（本地 CLI）三种部署方式
4. **MCP Server 标准化工具接口**：支持任何兼容 MCP 的 AI Agent 零代码接入
5. **9级列映射策略链 + 31种数据生成器 + DAG依赖排序**：确保跨表外键完整性
## 技术架构
- **核心引擎**：Python 3.10+，声明式数据生成框架
- **AI 集成**：Gemma 4 模型驱动 Schema 分析与配置生成（支持 Native Function Calling）
- **MCP 协议**：FastMCP 实现标准化工具接口
- **数据生成**：9级列映射策略链，31种生成器，DAG 依赖排序
- **数据库适配**：SQLite（支持 sqlite-utils 和原生适配器）
## 一键启动

跨平台一键启动脚本（Linux / macOS / Windows 通用）：

```bash
# 克隆仓库
git clone https://github.com/sunbos/sqlseed.git
cd sqlseed

# 一键启动（自动创建虚拟环境、安装依赖、创建测试数据库、填充数据、AI 分析）
python scripts/quickstart.py

# 指定后端
python scripts/quickstart.py --backend lm_studio    # LM Studio 本地（默认）
python scripts/quickstart.py --backend ollama        # Ollama 本地
python scripts/quickstart.py --backend google        # Google AI Studio 云端

# 指定模型
python scripts/quickstart.py --backend ollama --model gemma-4-4b-it

# 跳过安装（使用当前 Python 环境）
python scripts/quickstart.py --skip-install
```

### PyPI 安装

无需克隆仓库，直接从 PyPI 安装：

```bash
pip install "sqlseed[faker,mimesis]" "sqlseed-ai"
```

### 手动安装

```bash
# 创建虚拟环境
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\Activate.ps1

# 安装核心包
pip install -e ".[dev,all]"

# 安装 AI 插件（含 Gemma 4 支持）
pip install -e "./plugins/sqlseed-ai"

# 安装 MCP Server
pip install -e "./plugins/mcp-server-sqlseed"
```
## 配置 Gemma 4 后端
```bash
# 方式1: Google AI Studio（云端，推荐）
export GOOGLE_API_KEY=your-key

# 方式2: LM Studio（本地，隐私优先）
export SQLSEED_AI_BACKEND=lm_studio
export SQLSEED_AI_MODEL=google/gemma-4-e4b

# 方式3: Ollama（本地 CLI）
export SQLSEED_AI_BACKEND=ollama
export SQLSEED_AI_MODEL=gemma-4-4b-it
```
## 使用方式
### 命令行
```bash
# 零配置填充 10000 行数据
sqlseed fill app.db -t users -n 10000

# 预览生成数据
sqlseed preview app.db -t users -n 5

# 查看列映射策略
sqlseed inspect app.db --table users --show-mapping

# AI 驱动的智能配置生成（Gemma 4）
sqlseed ai-suggest app.db --table users
```
### Python API
```python
import sqlseed

# 一行代码生成数据
result = sqlseed.fill("test.db", table="users", count=100_000)
print(result)

# 使用配置文件
sqlseed.fill_from_config("config.yaml")

# 预览模式
preview = sqlseed.preview("test.db", table="users", count=5)
```
### MCP Server
```bash
# 启动 MCP Server
mcp-server-sqlseed
```

AI Agent 可通过 MCP 协议调用以下工具：
- `inspect_schema`：分析数据库 schema
- `generate_yaml_config`：AI 生成数据配置
- `fill_table`：批量填充数据
- `sqlseed_gemma4_analyze`：Gemma 4 原生函数调用分析 schema
- `sqlseed_gemma4_agent_fill`：端到端 Agent 工作流（分析-配置-填充）
- `sqlseed_list_gemma_models`：列出可用 Gemma 4 模型
## 项目结构
```
sqlseed/
├── src/sqlseed/          # 主包
│   ├── core/             # 编排器、映射器、Schema推断、约束求解、DAG
│   ├── generators/       # 数据提供者：base, faker, mimesis
│   ├── database/         # SQLite 适配器
│   ├── plugins/          # 插件系统
│   ├── config/           # Pydantic 配置模型
│   ├── cli/              # Click 命令行
│   └── _utils/           # 内部工具
├── plugins/
│   ├── sqlseed-ai/       # Gemma 4 驱动的 AI 插件
│   └── mcp-server-sqlseed/  # MCP Server
├── scripts/              # 一键启动脚本
│   └── quickstart.py     # 跨平台一键启动
├── tests/                # 测试套件
└── docs/                 # 文档
```
## Gemma 4 模型使用说明
本项目深度利用 Gemma 4 的**原生函数调用（Native Function Calling）**能力：
1. **SchemaAnalyzer**：通过 GEMMA_TOOLS 定义 `analyze_schema` 和 `generate_column_values` 函数，Gemma 4 以结构化参数返回分析结果
2. **AiConfigRefiner**：自纠正流程，Gemma 4 生成配置后自动验证并修正
3. **MCP Tool Calling**：`sqlseed_gemma4_analyze` 和 `sqlseed_gemma4_agent_fill` 工具暴露 Gemma 4 能力给 AI Agent
4. **多后端部署**：Google AI Studio（云端 26B MoE）、LM Studio（本地 4B Edge）、Ollama（本地 4B）
## Agent Memory 与 Tool Calling 架构
### Tool Calling 流程
```
用户请求 → SchemaAnalyzer → GEMMA_TOOLS(analyze_schema/generate_column_values)
                              ↓
                         Gemma 4 返回结构化参数
                              ↓
                         提取 tool_call.function.arguments
                              ↓
                         降级链: Tool Calling → JSON mode → 纯文本
```
### Agent Memory（自纠正流程）
```
Gemma 4 生成初始配置 → 验证(类型/约束/依赖)
    ↓ 失败
反馈错误信息 → Gemma 4 修正配置 → 再次验证
    ↓ 最多3轮
最终配置 → 数据填充
```
## 依赖
- Python 3.10+
- pydantic, pluggy, structlog, pyyaml, click, rich, simpleeval, rstr
- 可选：faker, mimesis, sqlite-utils
- AI 插件：openai>=1.0, google-generativeai>=0.8
- MCP Server：mcp>=1.0, fastmcp>=0.1
## 许可证
AGPL-3.0-or-later
