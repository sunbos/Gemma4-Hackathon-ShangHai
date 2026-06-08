# Build And Test

## 环境要求

- macOS 15 或更高版本。
- Xcode 或 Command Line Tools。
- Swift 6 工具链。
- Python 3.10-3.12，推荐 Python 3.11。
- Apple Silicon Mac 是默认本地 ASR runtime 的主要目标环境；Intel Mac 可以构建 App，但 MLX ASR 推理可能不可用。

检查命令：

```bash
sw_vers
xcodebuild -version
swift --version
python3 --version
```

## 构建 App

在提交包根目录运行：

```bash
cd source/MeetingTruthMacApp
swift build -c release --product MeetingTruth
```

运行 App：

```bash
.build/release/MeetingTruth
```

如果要生成并打开 macOS `.app`：

```bash
./script/build_app.sh --verify
```

如果只想做语法和构建验证，不需要提前下载 ASR 模型。

## LM Studio / Gemma 4 配置

MeetingTruth 使用 OpenAI-compatible `/v1/chat/completions` 接口。

推荐配置：

- Base URL：`http://127.0.0.1:1234/v1/chat/completions`
- API Key：本地 LM Studio 通常可留空。
- 推荐模型：`google/gemma-4-12b`
- 轻量备用：`google/gemma-4-e4b`

建议在 LM Studio 中关闭 thinking / reasoning 模式，避免输出额外推理文本影响 JSON 和 tool calling 解析。需要确认当前 endpoint 支持 `tools/tool_calls`；如果不支持，App 仍会通过 Swift `autoPipeline` 和 `localRule` 展示可审计流程，但这不等同于完整 native function calling 演示。

## 不下载 ASR 模型也能测试

本地 ASR 模型不随提交包附带。新机器首次测试时，可以先不下载模型：

1. 构建并打开 App。
2. 进入「会议整理」。
3. 点击「加载示例」。
4. 配置 Gemma 4 endpoint。
5. 测试冲突检测、多模态复核、function calling、人工确认和成果生成。

App 内置示例数据包含候选转写、会议通知、手写稿和图片材料；`sample-data/` 只放提交包外部说明。

## ASR 模型准备

需要本地 ASR 时，打开 App 的「模型准备」，点击「一键准备」。App 会检查 Python、venv、pip、Apple Silicon、macOS、磁盘空间、缓存目录写入权限、下载源可达性和部分下载文件。

默认三路 ASR：

- Qwen3-ASR 1.7B：时间戳锚点。
- GLM-ASR-Nano-2512：辅助参考。
- MiMo-V2.5-ASR MLX 4-bit：主底稿。

如果系统里有多个 Python，可在启动 App 前指定：

```bash
export LOCAL_ASR_PYTHON311=/opt/homebrew/bin/python3.11
```

## Hugging Face / 镜像

网络访问 Hugging Face 不稳定时，可在启动 App 前设置：

```bash
export HF_ENDPOINT=https://hf-mirror.com
export LOCAL_ASR_HF_ENDPOINTS=https://huggingface.co,https://hf-mirror.com
```

pip 下载慢或失败时，可设置：

```bash
export LOCAL_ASR_PIP_INDEX_URLS=https://pypi.org/simple,https://pypi.tuna.tsinghua.edu.cn/simple,https://mirrors.aliyun.com/pypi/simple
```

提交包和打包脚本不会包含已下载模型权重、虚拟环境、缓存或用户导入资料。默认缓存位于 `~/Library/Application Support/MeetingTruthClean`，可在设置页改到更大的磁盘。

## 常见问题

- Python 版本不合适：安装 Python 3.11，或设置 `LOCAL_ASR_PYTHON311`。
- Hugging Face 无法访问：设置 `HF_ENDPOINT` 或 `LOCAL_ASR_HF_ENDPOINTS`。
- pip 依赖安装失败：设置 `LOCAL_ASR_PIP_INDEX_URLS`，删除失败的 runtime 目录后重试。
- 磁盘空间不足：至少预留模型标称大小 1.15 倍空间，或更换模型缓存目录。
- 模型文件损坏：删除对应模型目录或 `.part` 文件后重试。
- endpoint 没有 tool_calls：检查 LM Studio 是否启用兼容 tools 的模型服务，并关闭 thinking / reasoning。
- Gatekeeper 提示：当前提交以源码构建为主，没有 Developer ID 时不能替代正式签名和公证。

## 打包测试

在提交包根目录运行：

```bash
./package-clean-submission.sh
```

zip 会输出到上一级 `release-output/`，不会混入源码目录。脚本会排除 staging、dist、旧 zip、`.build`、DerivedData、venv、模型权重、缓存和用户隐私数据。

## 签名说明

没有 Apple Developer ID 时，不能生成可在任意 Mac 上无提示打开的正式签名/公证 App。评审或测试推荐从源码构建运行。若未来需要正式分发，应使用 Developer ID 签名、notarization 和 stapling。
