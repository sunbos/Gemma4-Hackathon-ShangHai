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

# ==================== 标准流式分析（所有模型通用） ====================

def analyze_football_stream(json_data: dict, user_text: str, prompt_template: str, lang="zh", model=None):
    json_str = json.dumps(json_data, ensure_ascii=False, separators=(',', ':'))
    prompt = prompt_template.replace('{match_data}', json_str).replace('{user_text}', user_text)

    if lang == "en":
        instructions = "You are a senior football tactical analyst, skilled at identifying formations, transitions, and key players from data. You must reply in English."
    else:
        instructions = "你是一位资深足球战术分析师，擅长从数据中洞察阵型、攻防转换和关键球员。"

    messages = [
        {"role": "system", "content": instructions},
        {"role": "user", "content": prompt}
    ]

    provider = os.getenv("LLM_PROVIDER", "openai").lower()
    client = None
    model_name = None

    if provider == "deepseek":
        client = _create_client(api_key=os.getenv("DEEPSEEK_API_KEY"), base_url="https://api.deepseek.com")
        model_name = model or os.getenv("DEEPSEEK_MODEL", "deepseek-chat")
    elif provider == "gemma4":
        client = _create_client(
            api_key=os.getenv("GEMMA_API_KEY"),
            base_url=os.getenv("GEMMA_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai/"),
            use_proxy=True
        )
        model_name = model or os.getenv("GEMMA_MODEL", "gemma-4-31b-it")
    else:
        openai_key = os.getenv("OPENAI_API_KEY")
        if not openai_key:
            raise ValueError("OPENAI_API_KEY 未设置")
        base_url = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
        client = _create_client(api_key=openai_key, base_url=base_url)
        model_name = model or os.getenv("OPENAI_MODEL", "gpt-4.1-mini")

    if not client or not model_name:
        raise RuntimeError("无法创建 LLM 客户端，请检查 .env 配置。")

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

# ==================== Agent 流式分析（Gemma 4 专用） ====================

def analyze_football_agent_stream(task_dict, user_text, prompt_template, lang="zh", model=None):
    from .agent_tools import get_team_summary, get_player_trajectory_summary

    os.makedirs("outputs", exist_ok=True)
    log_lines = []
    log_lines.append("=== 足球 Agent 决策日志 ===\n")

    if lang == "zh":
        system_msg = "你是一个足球战术分析智能体。你可以调用工具来获取比赛数据，然后给出战术分析报告。请使用中文。"
        user_content = f"请分析以下足球比赛数据。{user_text}"
    else:
        system_msg = "You are a football tactical analysis agent. You can call tools to obtain match data, then provide a tactical report. Please reply in English."
        user_content = f"Analyze the following football match data. {user_text}"

    log_lines.append("【步骤一】系统指令与用户请求")
    log_lines.append(f"系统: {system_msg}")
    log_lines.append(f"用户: {user_content}\n")

    messages = [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": user_content}
    ]

    tools = [
        {
            "type": "function",
            "function": {
                "name": "get_team_summary",
                "description": "获取比赛队伍摘要（双方球员数量、足球轨迹点数、控球信息等）",
                "parameters": {"type": "object", "properties": {}}
            }
        },
        {
            "type": "function",
            "function": {
                "name": "get_player_trajectory_summary",
                "description": "获取指定球员的轨迹摘要（起止位置、跑动距离等）",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "player_id": {"type": "integer", "description": "球员 ID"}
                    },
                    "required": ["player_id"]
                }
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
            log_lines.append("【步骤二】Agent 思考与决策")
            response = client.chat.completions.create(
                model=model_name,
                messages=messages,
                tools=tools,
                tool_choice="auto",
                max_tokens=1024
            )
            first_message = response.choices[0].message
            thought = first_message.content if first_message.content else "(模型未输出思考文本，直接决策)"
            log_lines.append(f"思考: {thought}")

            if first_message.tool_calls:
                log_lines.append("决策: 模型决定调用以下工具")
                for tc in first_message.tool_calls:
                    log_lines.append(f"  - {tc.function.name}({tc.function.arguments})")
                log_lines.append("")

                messages.append(first_message)

                log_lines.append("【步骤三】执行工具调用并解读返回数据")
                for tool_call in first_message.tool_calls:
                    func_name = tool_call.function.name
                    args = json.loads(tool_call.function.arguments)
                    if func_name == "get_team_summary":
                        result = get_team_summary(task_dict)
                        result_obj = json.loads(result)
                        log_lines.append(f"调用: get_team_summary()")
                        log_lines.append(f"返回: {result}")
                        log_lines.append(f"解读: 队伍0人数={result_obj['team0_players']}, 队伍1人数={result_obj['team1_players']}, 足球轨迹点数={result_obj['ball_trajectory_points']}, 控球={result_obj['possession_last_frame']}")
                        log_lines.append("")
                        messages.append({
                            "role": "tool",
                            "tool_call_id": tool_call.id,
                            "name": func_name,
                            "content": result
                        })
                    elif func_name == "get_player_trajectory_summary":
                        pid = args.get("player_id")
                        result = get_player_trajectory_summary(task_dict, pid)
                        log_lines.append(f"调用: get_player_trajectory_summary(player_id={pid})")
                        log_lines.append(f"返回: {result[:200]}...")
                        log_lines.append("")
                        messages.append({
                            "role": "tool",
                            "tool_call_id": tool_call.id,
                            "name": func_name,
                            "content": result
                        })

                log_lines.append("【步骤四】注入完整比赛数据与提示词")
                full_json_str = json.dumps(task_dict, ensure_ascii=False, separators=(',', ':'))
                final_prompt = prompt_template.replace('{match_data}', full_json_str).replace('{user_text}', user_text)
                messages.append({"role": "user", "content": final_prompt})
                log_lines.append(f"完整提示词已生成，长度: {len(final_prompt)} 字符")
                log_lines.append("(完整内容请查看 outputs/对话_*.txt)\n")

                # 保存对话文件
                try:
                    task_id = task_dict.get("task_id", "unknown")
                    conv_path = os.path.join("outputs", f"对话_{task_id}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.txt")
                    with open(conv_path, "w", encoding="utf-8") as f:
                        f.write(final_prompt)
                    log_lines.append(f"对话文件已保存: {conv_path}\n")
                except Exception as e:
                    log_lines.append(f"对话文件保存失败: {e}\n")

                log_lines.append("【步骤五】调用 Gemma 4 生成战术分析报告")
                response2 = client.chat.completions.create(
                    model=model_name,
                    messages=messages,
                    tools=tools,
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

                if not full_response.strip():
                    log_lines.append("流式输出为空，启用非流式保底...")
                    response3 = client.chat.completions.create(
                        model=model_name, messages=messages, tools=tools, max_tokens=8192, stream=False
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