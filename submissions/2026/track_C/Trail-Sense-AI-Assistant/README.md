# Trail Sense AI Assistant

赛道：C - Edge AI

项目仓库：https://github.com/jiantao88/Trail-Sense/tree/feature/ai-assistant

当前提交版本：以 `feature/ai-assistant` 分支最新 HEAD 为准。

## 项目简介

Trail Sense AI Assistant 是一个面向户外徒步、露营和应急场景的端侧 AI 助手。项目基于开源 Android 应用 Trail Sense，在原有离线导航、天气、天文、生存指南和手机传感器工具之上，集成 Gemma 4 + LiteRT-LM 本地推理能力，让用户可以用自然语言询问“我现在该用哪个工具”“这个读数代表什么”“如何发出求救信号”等问题。

AI 模型只在首次设置时下载；推理、工具调用、传感器上下文读取和聊天记录都在设备本地完成，适合无网络或弱网络的户外环境。

## 核心功能

- Gemma 4 端侧推理：使用 LiteRT-LM Android Runtime 加载 Gemma-4-E2B-it，支持 Gemma-4-E4B-it 作为可选模型。
- Native Function Calling：AI Assistant 注册 Trail Sense 工具能力，模型可以调用天气、导航、云识别、闪光灯、哨子、路径、信标等工具读取上下文或准备行动卡片。
- 户外工具推荐：根据用户问题匹配 Trail Sense 内置工具，并解释工具入口、使用步骤和读数含义。
- 多模态入口：聊天界面支持附加图片，为云识别和户外视觉问答预留本地多模态工作流。
- 隐私优先：位置、路径、气压、天气和聊天数据默认保留在本机；没有云端 AI 请求。

## Gemma 4 相关代码

- 模型管理与下载：`app/src/main/java/com/kylecorry/trail_sense/tools/ai_assistant/infrastructure/ModelManager.kt`
- LiteRT-LM 推理封装：`app/src/main/java/com/kylecorry/trail_sense/tools/ai_assistant/infrastructure/AiInferenceSubsystem.kt`
- Native Function Calling 注册：`app/src/main/java/com/kylecorry/trail_sense/tools/ai_assistant/infrastructure/AiAssistantTools.kt`
- Trail Sense 工具执行器：`app/src/main/java/com/kylecorry/trail_sense/tools/ai_assistant/infrastructure/TrailSenseAiToolRunner.kt`
- Prompt 与工具知识：`app/src/main/java/com/kylecorry/trail_sense/tools/ai_assistant/domain/AiPromptBuilder.kt`
- App 内工具知识库：`app/src/main/res/raw/ai_tool_knowledge.md`
- App 内工具技能库：`app/src/main/res/raw/ai_tool_skills.md`
- AI 助手界面：`app/src/main/java/com/kylecorry/trail_sense/tools/ai_assistant/ui/AiAssistantFragment.kt`

## 环境与运行

### 环境

- Android Studio Narwhal 或更新版本
- JDK 21
- Android SDK / Gradle Android Plugin 对应版本
- Android 设备或模拟器
- 首次下载 Gemma 4 模型需要网络连接

### 构建

```bash
./gradlew :app:assembleDebug
```

Debug APK 输出：

```text
app/build/outputs/apk/debug/app-debug.apk
```

### 测试

```bash
./gradlew :app:testDebugUnitTest
```

当前本地验证结果：

- `./gradlew :app:testDebugUnitTest`：通过
- `./gradlew :app:assembleDebug`：通过

## Demo 建议

5 分钟内演示建议：

1. 打开 Trail Sense，进入 AI Assistant。
2. 展示 AI 设置页下载/选择 Gemma 4 模型。
3. 输入“我迷路了，手机没信号怎么办？”展示工具推荐和安全提醒。
4. 输入“打开 SOS 手电筒”或“用哨子求救”展示 Native Function Calling 生成行动卡片。
5. 输入“天气读数怎么看？”展示 AI 读取 Trail Sense 天气/气压上下文并解释。
6. 强调模型端侧运行、位置和聊天数据不上传云端。

Demo 视频链接：待补充

在线 Demo / APK 下载链接：待补充

## 提交说明

推荐官方提交路径：

```text
submissions/2026/C/Trail-Sense-AI-Assistant/
```

PR 标题格式：

```text
[赛道C] Trail Sense AI Assistant - 队伍名
```
