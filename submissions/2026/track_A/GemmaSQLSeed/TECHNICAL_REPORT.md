# GemmaSQLSeed 技术报告

## 1. 项目概述

GemmaSQLSeed 是一款基于 Gemma 4 大模型的智能 SQLite 测试数据生成工具。通过 MCP（Model Context Protocol）协议和 Gemma 4 原生函数调用（Native Function Calling），AI Agent 可以直接与数据库交互，实现 schema 自动分析、数据配置智能生成和批量数据填充。开发者只需一行命令即可让 Gemma 4 为任意 SQLite 数据库生成高质量测试数据。

## 2. 模型选型理由

### 为什么选择 Gemma 4？

1. **原生函数调用（Native Function Calling）能力**：Gemma 4 支持原生函数调用，我们定义了 `analyze_schema` 和 `generate_column_values` 两个函数接口，Gemma 4 可以直接以结构化参数返回 schema 分析结果，而非简单的文本生成。这确保了输出的结构化可靠性，是本项目的核心技术基础。

2. **多规格适配**：Gemma 4 提供 2B/4B/26B MoE/31B Dense 多种规格：
   - **4B (Edge)**：本地部署（LM Studio/Ollama），schema 分析等结构化任务，推理速度约 20-130 秒/次
   - **26B MoE (Recommended)**：Google AI Studio 云端部署，复杂自纠正流程，推理速度约 10-30 秒/次
   - **31B Dense**：最强推理能力，用于复杂 schema 分析

3. **端侧部署**：轻量规格（4B）可在 LM Studio/Ollama 本地运行，使数据生成工具可在完全离线环境运行，保护数据库 schema 隐私，无需任何云端 API。

4. **开源与合规**：Gemma 4 开源许可允许深度集成，无需担心 API 调用限制和成本。

### 模型使用方式

- **SchemaAnalyzer**：使用 Gemma 4 原生函数调用（GEMMA_TOOLS），输入数据库 schema 信息，输出结构化列映射建议
- **AiConfigRefiner**：利用 Gemma 4 推理能力，对生成配置验证和修正，最多3轮自纠正
- **MCP Tool Calling**：通过 MCP 协议将 Gemma 4 能力暴露为标准化工具接口

## 3. 架构设计

### 整体架构

```
AI Agent Layer (Any MCP-compatible Agent)
    | MCP Protocol
MCP Server Layer
    |- inspect_schema | generate_yaml_config | fill_table
    |- sqlseed_gemma4_analyze | sqlseed_gemma4_agent_fill
    |- sqlseed_list_gemma_models
    |
Gemma 4 Layer (Native Function Calling)
    |- GEMMA_TOOLS: analyze_schema, generate_column_values
    |- SchemaAnalyzer | AiConfigRefiner
    |
Core Engine Layer
    |- Orchestrator | Mapper(9-level) | SchemaInferrer
    |- ColumnDAG | RelationResolver | ExpressionEngine
    |- ConstraintSolver
    |
Generator Layer
    |- Base | Faker | Mimesis (31 generators)
    |
Database Layer
    |- SQLite-Utils Adapter | Raw SQLite Adapter
```

### Gemma 4 原生函数调用实现

本项目通过 OpenAI 兼容 API 调用 Gemma 4 的原生函数调用能力，定义了两个核心函数：

1. **analyze_schema**：分析数据库表结构，返回结构化的列映射建议
2. **generate_column_values**：为特定列生成模板值

调用流程：
1. 发送 `tools=GEMMA_TOOLS, tool_choice="auto"` 给 Gemma 4
2. Gemma 4 选择调用 `analyze_schema` 函数，返回结构化参数
3. 从 `tool_call.function.arguments` 中提取 JSON 结果
4. 若 tool calling 不可用，优雅降级到 JSON mode -> 纯文本模式

### 多后端部署架构

```
AIConfig (统一配置)
    +-- Google AI Studio (base_url: generativelanguage.googleapis.com)
    |   +-- gemma-4-26b-it (推荐，云端推理)
    +-- LM Studio (base_url: 127.0.0.1:1234)
    |   +-- google/gemma-4-e4b (本地 GUI，Edge 部署)
    +-- Ollama (base_url: localhost:11434)
    |   +-- gemma-4-4b-it (本地 CLI，Edge 部署)
    +-- OpenAI Compatible (自定义端点)
```

### 核心模块

1. **DataOrchestrator**：中央协调器，管理数据生成完整生命周期。采用上下文管理器模式。

2. **ColumnMapper**：9级列映射策略链：
   - Level 1: Autoincrement PK 检测
   - Level 2: 用户配置覆盖
   - Level 3: 精确名称匹配（74条规则）
   - Level 4: 默认值检测
   - Level 5: 模式匹配（26条正则规则）
   - Level 6: 可空字段处理
   - Level 7: 类型回退
   - Level 8-9: AI 辅助映射（Gemma 4 驱动）

3. **SchemaInferrer**：自动读取 SQLite schema，解析 CREATE TABLE SQL，检测 autoincrement。

4. **RelationResolver + SharedPool**：跨表外键完整性保障。通过名称匹配自动发现隐式关联。

5. **ColumnDAG**：基于拓扑排序的列依赖解析，处理 derive_from 表达式依赖。

6. **ExpressionEngine**：基于 simpleeval 的安全表达式引擎，5秒超时保护，21个白名单函数。

7. **ConstraintSolver**：UNIQUE 约束求解器，支持回溯重试和概率模式（>100K行自动切换SHA256哈希）。

### AI 集成架构

**SchemaAnalyzer** 利用 Gemma 4 原生函数调用：
- 识别列语义（email、phone、address 等）
- 推荐数据生成策略和参数
- 处理特殊约束（UNIQUE、CHECK 等）
- 优先使用 Native Function Calling，不可用时优雅降级

**AiConfigRefiner** 自纠正流程：
1. Gemma 4 生成初始配置
2. 系统验证配置（类型检查、约束验证、依赖完整性）
3. 如有错误，将错误信息反馈给 Gemma 4
4. Gemma 4 修正配置
5. 最多3轮自纠正

**MCP Server Gemma 4 工具**：
1. `sqlseed_gemma4_analyze`：Gemma 4 分析 schema
2. `sqlseed_gemma4_agent_fill`：端到端 Agent 工作流
3. `sqlseed_list_gemma_models`：列出可用模型和后端

## 4. 数据生成流水线

```
Schema Inference -> Column Mapping -> DAG Sort -> Batch Generation -> Constraint Check -> DB Insert
SchemaInferrer     ColumnMapper     ColumnDAG   DataStream         ConstraintSolver   DatabaseAdapter
                  (9-level)        (TopoSort)  (Iterator)         (UNIQUE/Backtrack) (Batch Insert)
```

## 5. 性能设计

- **流式生成**：DataStream 实现 Iterator 模式，100万行数据与1000行内存占用相同
- **批量写入**：默认1000行/批次，PRAGMA 优化（journal_mode=WAL, synchronous=OFF）
- **约束求解**：小数据量回溯重试，>100K行自动切换概率模式（SHA256哈希）
- **Provider 降级**：mimesis -> faker -> base 自动降级，确保核心功能始终可用
- **本地推理优化**：LM Studio/Ollama 后端自动减少 few-shot 示例数量

## 6. 创新点总结

1. **Gemma 4 Native Function Calling**：通过 GEMMA_TOOLS 定义函数接口，Gemma 4 以结构化参数返回分析结果
2. **自纠正流程（AiConfigRefiner）**：Gemma 4 生成配置后自动验证并修正
3. **MCP 标准化接口**：任何兼容 MCP 的 AI Agent 可零代码接入
4. **多后端部署**：Google AI Studio / LM Studio / Ollama 三种部署方式
5. **9级列映射策略链**：从自动增量到 AI 辅助，覆盖所有场景
6. **DAG 依赖排序**：确保 derive_from 列表达式的正确计算顺序
7. **跨表外键完整性**：SharedPool + RelationResolver 自动维护引用完整性

## 7. 未来规划

- 端侧部署 Gemma 4 2B/4B，实现完全离线数据生成
- 支持更多数据库（PostgreSQL、MySQL）
- 可视化配置编辑器
- 数据质量评估报告
