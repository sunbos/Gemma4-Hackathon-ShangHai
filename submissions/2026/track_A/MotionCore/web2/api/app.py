import os
import json
import uuid
import asyncio
import traceback
import importlib
from datetime import datetime
import cv2
import numpy as np
from fastapi import FastAPI, File, UploadFile, Request
from fastapi.responses import StreamingResponse, JSONResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

from .processor import FootballProcessor
from .client import analyze_football_stream, analyze_football_agent_stream

app = FastAPI()

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
H5_DIR = os.path.join(CURRENT_DIR, '..', 'h5')
app.mount("/static", StaticFiles(directory=H5_DIR), name="static")

os.makedirs("outputs", exist_ok=True)

app.mount("/demo", StaticFiles(directory="demo"), name="demo")

football_tasks = {}

def load_prompt(lang: str):
    try:
        if lang == "en":
            module = importlib.import_module("web2.api.prompts_en")
        else:
            module = importlib.import_module("web2.api.prompts_zh")
        return module.FOOTBALL_ANALYSIS_PROMPT
    except Exception:
        from .prompts_zh import FOOTBALL_ANALYSIS_PROMPT
        return FOOTBALL_ANALYSIS_PROMPT

# ==================== 端点 ====================

@app.post("/upload")
async def upload_video(file: UploadFile = File(...)):
    task_id = str(uuid.uuid4())
    video_path = os.path.join("outputs", f"fb_{task_id}.mp4")
    with open(video_path, "wb") as f:
        f.write(await file.read())

    cap = cv2.VideoCapture(video_path)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total_frames <= 0:
        cap.set(cv2.CAP_PROP_POS_AVI_RATIO, 1)
        total_frames = int(cap.get(cv2.CAP_PROP_POS_FRAMES)) + 1
    cap.release()

    football_tasks[task_id] = {
        "task_id": task_id,
        "video_path": video_path,
        "status": "processing",
        "total_frames": total_frames,
        "current_frame": 0,
        "json_path": None,
        "video_filename": file.filename
    }
    return {"task_id": task_id, "total_frames": total_frames}

@app.get("/stream/{task_id}")
async def stream(task_id: str):
    task = football_tasks.get(task_id)
    if not task:
        return HTMLResponse(content="任务不存在", status_code=404)

    processor = FootballProcessor()

    def generate():
        try:
            for frame_idx, jpeg_bytes in processor.process(task["video_path"], task):
                yield (b'--frame\r\n'
                       b'Content-Type: image/jpeg\r\n\r\n' + jpeg_bytes + b'\r\n\r\n')
            task["status"] = "completed"
        except Exception as e:
            print(f"❌ 视频流处理出错: {e}")
            traceback.print_exc()
            error_frame = np.zeros((480, 640, 3), dtype=np.uint8)
            cv2.putText(error_frame, f"Error: {str(e)}", (50, 240),
                        cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 255), 2)
            _, jpeg = cv2.imencode('.jpg', error_frame)
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n\r\n')

    return StreamingResponse(generate(), media_type="multipart/x-mixed-replace; boundary=frame")

@app.get("/progress/{task_id}")
async def progress(task_id: str):
    t = football_tasks.get(task_id)
    if not t:
        return JSONResponse(content={"error": "任务不存在"}, status_code=404)
    return {
        "status": t["status"],
        "total_frames": t["total_frames"],
        "current_frame": t["current_frame"]
    }

@app.get("/status/{task_id}")
async def status(task_id: str):
    t = football_tasks.get(task_id)
    if not t:
        return JSONResponse(content={"error": "任务不存在"}, status_code=404)
    resp = {"task_id": task_id, "status": t["status"]}
    if t["status"] == "completed":
        resp["json_url"] = f"/download/{task_id}"
    return resp

@app.get("/download/{task_id}")
async def download(task_id: str):
    t = football_tasks.get(task_id)
    if not t or t["status"] != "completed":
        return JSONResponse(content={"error": "JSON未就绪"}, status_code=404)
    json_path = t["json_path"]
    if not os.path.exists(json_path):
        return JSONResponse(content={"error": "文件不存在"}, status_code=404)
    with open(json_path, 'r', encoding='utf-8') as f:
        return JSONResponse(content=json.load(f))

@app.get("/")
async def index():
    html_path = os.path.join(H5_DIR, "index.html")
    with open(html_path, "r", encoding="utf-8") as f:
        return HTMLResponse(content=f.read())

@app.post("/analyze/stream")
async def analyze_stream(request: Request):
    data = await request.json()
    task_id = data.get("task_id", "")
    user_text = data.get("user_text", "")
    lang = data.get("lang", "zh")

    task = football_tasks.get(task_id)
    if not task or task["status"] != "completed":
        return JSONResponse({"error": "视频尚未处理完成"}, status_code=400)

    with open(task["json_path"], "r", encoding="utf-8") as f:
        match_data = json.load(f)

    match_data["task_id"] = task_id

    FOOTBALL_ANALYSIS_PROMPT = load_prompt(lang)

    async def event_generator():
        provider = os.getenv("LLM_PROVIDER", "openai").lower()
        if provider == "gemma4":
            gen, log_lines = analyze_football_agent_stream(
                match_data, user_text, FOOTBALL_ANALYSIS_PROMPT, lang=lang
            )
            try:
                for chunk in gen:
                    if await request.is_disconnected():
                        break
                    yield f"data: {json.dumps({'text': chunk})}\n\n"
                yield "data: [DONE]\n\n"
            except Exception as e:
                traceback.print_exc()
                yield f"data: {json.dumps({'text': f'分析失败：{str(e)}'})}\n\n"
                yield "data: [DONE]\n\n"
            finally:
                try:
                    log_path = os.path.join("outputs", f"agent_log_{task_id}.txt")
                    with open(log_path, "w", encoding="utf-8") as f:
                        f.write("\n".join(log_lines))
                except:
                    pass
        else:
            prompt = FOOTBALL_ANALYSIS_PROMPT.replace(
                '{match_data}', json.dumps(match_data, ensure_ascii=False, separators=(',', ':'))
            ).replace('{user_text}', user_text)

            async def save_prompt():
                filename = f"对话_{task_id}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
                filepath = os.path.join("outputs", filename)
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(prompt)
            asyncio.create_task(save_prompt())

            try:
                for chunk in analyze_football_stream(
                    match_data, user_text, FOOTBALL_ANALYSIS_PROMPT, lang=lang
                ):
                    if await request.is_disconnected():
                        break
                    yield f"data: {json.dumps({'text': chunk})}\n\n"
                yield "data: [DONE]\n\n"
            except Exception as e:
                traceback.print_exc()
                yield f"data: {json.dumps({'text': f'分析失败：{str(e)}'})}\n\n"
                yield "data: [DONE]\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")