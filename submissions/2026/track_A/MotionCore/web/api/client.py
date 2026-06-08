import os
import json
import datetime
from dotenv import load_dotenv
from openai import OpenAI
import httpx
import time

load_dotenv(os.path.join(os.path.dirname(__file__), '..', '..', '.env'))

def _create_client(api_key, base_url=None, use_proxy=False):
    timeout = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
    proxy_url = os.getenv("HTTPS_PROXY") or os.getenv("https_proxy")
    if use_proxy and proxy_url:
        http_client = httpx.Client(proxy=proxy_url, timeout=timeout)
    else:
        http_client = httpx.Client(timeout=timeout)

    kwargs = {
        "api_key": api_key,
        "timeout": timeout,
        "max_retries": 0,
        "http_client": http_client
    }
    if base_url:
        kwargs["base_url"] = base_url
    return OpenAI(**kwargs)

def _stream_chat(client, model, messages):
    response = client.chat.completions.create(
        model=model,
        messages=messages,
        stream=True,
        max_tokens=4096
    )
    for chunk in response:
        if chunk.choices and chunk.choices[0].delta:
            content = chunk.choices[0].delta.content
            if content:
                yield content

def analyze_videos_stream(video1_json, video2_json, prompt_template, user_text="", lang="zh", model=None):
    prompt = prompt_template.replace('{video1_json}', video1_json).replace('{video2_json}', video2_json).replace('{user_text}', user_text)
    instructions = "你是一位世界顶级的舞蹈导师。" if lang == "zh" else "You are a world-class dance instructor."
    if lang == "en":
        instructions += " You must reply in English. Do not reply in Chinese."

    messages = [
        {"role": "system", "content": instructions},
        {"role": "user", "content": prompt}
    ]

    provider = os.getenv("LLM_PROVIDER", "openai").lower()

    if provider == "deepseek":
        client = _create_client(api_key=os.getenv("DEEPSEEK_API_KEY"), base_url="https://api.deepseek.com")
        model_name = model or os.getenv("DEEPSEEK_MODEL", "deepseek-chat")
    elif provider == "gemma4":
        client = _create_client(api_key=os.getenv("GEMMA_API_KEY"),
                                base_url=os.getenv("GEMMA_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai/"),
                                use_proxy=True)
        model_name = model or os.getenv("GEMMA_MODEL", "gemma-4-31b-it")
    else:
        client = _create_client(api_key=os.getenv("OPENAI_API_KEY"),
                                base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
        model_name = model or os.getenv("OPENAI_MODEL", "gpt-4.1-mini")

    last_error = None
    for attempt in range(3):
        try:
            for chunk in _stream_chat(client, model_name, messages):
                yield chunk
            return
        except Exception as e:
            last_error = e
            if attempt < 2:
                time.sleep(2)
    raise last_error


def analyze_agent_stream(task1, task2, prompt_template, user_text="", lang="zh", model=None):
    """
    Agent 模式：返回 (generator, log_lines)。
    清晰展示多步规划、工具调用、数据整合过程。
    """
    from .agent_tools import get_pose_summary, compare_videos

    os.makedirs("outputs", exist_ok=True)
    log_lines = []
    log_lines.append("=== Gemma 4 Agent 决策日志 ===\n")

    if lang == "zh":
        system_msg = "你是一个运动分析智能体。你可以调用工具来获取数据，然后给出分析报告。请使用中文。"
        user_content = f"请分析两个舞蹈视频。视频A: {task1.get('video_filename','')}，视频B: {task2.get('video_filename','')}。{user_text}"
    else:
        system_msg = "You are a sports analysis agent. You can call tools to get data, then provide an analysis report."
        user_content = f"Analyze two dance videos. Video1: {task1.get('video_filename','')}, Video2: {task2.get('video_filename','')}. {user_text}"

    # 步骤一：记录系统指令和用户请求
    log_lines.append("【步骤一】系统发送指令与用户请求")
    log_lines.append(f"系统指令: {system_msg}")
    log_lines.append(f"用户请求: {user_content}\n")

    messages = [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": user_content}
    ]

    tools = [
        {
            "type": "function",
            "function": {
                "name": "get_pose_summary",
                "description": "获取指定视频的姿态数据摘要（帧数、时长、关键点数等）",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "video_index": {"type": "integer", "enum": [1, 2], "description": "视频序号：1 或 2"}
                    },
                    "required": ["video_index"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "compare_videos",
                "description": "对比两个视频的基本信息",
                "parameters": {"type": "object", "properties": {}}
            }
        }
    ]

    client = _create_client(
        api_key=os.getenv("GEMMA_API_KEY"),
        base_url=os.getenv("GEMMA_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai/"),
        use_proxy=True
    )
    model_name = model or os.getenv("GEMMA_MODEL", "gemma-4-31b-it")

    def _generator():
        nonlocal log_lines, messages

        try:
            # 步骤二：Agent 思考与决策
            log_lines.append("【步骤二】Agent 思考与决策")
            response = client.chat.completions.create(
                model=model_name,
                messages=messages,
                tools=tools,
                tool_choice="auto",
                max_tokens=1024
            )
            first_message = response.choices[0].message
            
            # 提取思考内容
            thought = first_message.content if first_message.content else "(模型未输出思考文本，直接决策)"
            log_lines.append(f"思考过程: {thought}")
            
            if first_message.tool_calls:
                log_lines.append("决策结果: 模型决定调用以下工具")
                for tc in first_message.tool_calls:
                    log_lines.append(f"  - {tc.function.name} (参数: {tc.function.arguments})")
                log_lines.append("")

                # 步骤三：执行工具调用并解释返回结果
                log_lines.append("【步骤三】执行工具调用并解读返回数据")
                tool_summary_lines = []
                
                for tool_call in first_message.tool_calls:
                    func_name = tool_call.function.name
                    args = json.loads(tool_call.function.arguments)
                    
                    if func_name == "get_pose_summary":
                        idx = args.get("video_index", 1)
                        task = task1 if idx == 1 else task2
                        result = get_pose_summary(task)
                        result_obj = json.loads(result)
                        
                        log_lines.append(f"调用工具: get_pose_summary(video_index={idx})")
                        log_lines.append(f"返回 JSON: {result}")
                        log_lines.append("数据解读:")
                        log_lines.append(f"  - total_frames: {result_obj['total_frames']} → 视频总帧数")
                        log_lines.append(f"  - fps: {result_obj['fps']} → 每秒帧率")
                        log_lines.append(f"  - duration_seconds: {result_obj['duration_seconds']} → 视频时长(秒)")
                        log_lines.append(f"  - landmark_count: {result_obj['landmark_count']} → 每帧检测到的关键点数量(MediaPipe 33点)")
                        log_lines.append("")
                        tool_summary_lines.append(f"[{func_name}(video_index={idx})] {result}")
                        
                    elif func_name == "compare_videos":
                        result = compare_videos(task1, task2)
                        result_obj = json.loads(result)
                        
                        log_lines.append("调用工具: compare_videos()")
                        log_lines.append(f"返回 JSON: {result}")
                        log_lines.append("数据解读:")
                        log_lines.append(f"  - video1_frames: {result_obj['video1_frames']} → 视频A总帧数")
                        log_lines.append(f"  - video2_frames: {result_obj['video2_frames']} → 视频B总帧数")
                        log_lines.append(f"  - video1_name: {result_obj['video1_name']} → 视频A文件名")
                        log_lines.append(f"  - video2_name: {result_obj['video2_name']} → 视频B文件名")
                        log_lines.append("")
                        tool_summary_lines.append(f"[{func_name}] {result}")

                # 步骤四：整合数据，生成最终提示词
                log_lines.append("【步骤四】数据整合与提示词构建")
                def build_compact_json(task):
                    return json.dumps({
                        "video_filename": task.get("video_filename", "未知"),
                        "fps": task.get("fps", 0),
                        "original_fps": task.get("fps", 0),
                        "pose_sequence": task.get("keypoints_data", [])
                    }, ensure_ascii=False, separators=(',', ':'))

                video1_full_json = build_compact_json(task1)
                video2_full_json = build_compact_json(task2)

                final_prompt = prompt_template.replace('{video1_json}', video1_full_json)
                final_prompt = final_prompt.replace('{video2_json}', video2_full_json)
                final_prompt = final_prompt.replace('{user_text}', user_text)

                summary_text = "\n".join(tool_summary_lines)
                combined_user_message = f"[Agent 工具调用结果]\n{summary_text}\n\n{final_prompt}"

                messages.append({"role": "user", "content": combined_user_message})
                
                log_lines.append(f"已将工具返回结果和完整姿态数据注入提示词模板")
                log_lines.append(f"最终提示词总长度: {len(final_prompt)} 字符")
                log_lines.append("(完整提示词内容请查看 outputs/对话_*.txt 文件)\n")

                # 保存对话文件
                try:
                    task_id = task1.get("task_id", "unknown")
                    conv_path = os.path.join("outputs", f"对话_{task_id}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.txt")
                    with open(conv_path, "w", encoding="utf-8") as f:
                        f.write(final_prompt)
                    log_lines.append(f"对话文件已保存至: {conv_path}\n")
                except Exception as e:
                    log_lines.append(f"对话文件保存失败: {e}\n")

                # 步骤五：生成分析报告
                log_lines.append("【步骤五】调用 Gemma 4 生成分析报告")
                
                # 流式请求
                response2 = client.chat.completions.create(
                    model=model_name,
                    messages=messages,
                    max_tokens=8192,
                    stream=True
                )
                full_response = ""
                for chunk in response2:
                    if chunk.choices and chunk.choices[0].delta:
                        content = chunk.choices[0].delta.content
                        if content:
                            if not full_response and content.strip().startswith("<thought>"):
                                continue
                            full_response += content
                            yield content

                # 非流式保底
                if not full_response.strip():
                    log_lines.append("流式输出为空，启用非流式保底请求...")
                    response3 = client.chat.completions.create(
                        model=model_name,
                        messages=messages,
                        max_tokens=8192,
                        stream=False
                    )
                    final_msg = response3.choices[0].message
                    if final_msg.content:
                        full_response = final_msg.content
                        yield full_response
                        log_lines.append(f"报告生成成功 (非流式)，长度: {len(full_response)} 字符")
                    else:
                        yield "模型未产生有效回复。"
                        log_lines.append("错误: 模型未产生有效回复")
                else:
                    log_lines.append(f"报告生成成功 (流式)，长度: {len(full_response)} 字符")

            else:
                log_lines.append("模型未调用工具，直接回复")
                if first_message.content:
                    yield first_message.content
                else:
                    yield "模型未产生有效回复。"

        except Exception as e:
            log_lines.append(f"\n错误: {e}")
            yield f"分析失败：{str(e)}"

    gen = _generator()
    return gen, log_lines