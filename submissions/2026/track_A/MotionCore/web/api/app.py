import os
import sys
import json
import uuid
import asyncio
import traceback
import importlib
from datetime import datetime
import cv2
import numpy as np
import mediapipe as mp
from fastapi import FastAPI, File, UploadFile, Request
from fastapi.responses import StreamingResponse, JSONResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv

# ★ 加载 .env 文件，确保环境变量可用
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '..', '.env'))

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

app = FastAPI()

H5_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'h5')
app.mount("/static", StaticFiles(directory=H5_DIR), name="static")

OUTPUTS_DIR = os.path.join(ROOT_DIR, "outputs")
os.makedirs(OUTPUTS_DIR, exist_ok=True)
app.mount("/outputs", StaticFiles(directory=OUTPUTS_DIR), name="outputs")

app.mount("/demo", StaticFiles(directory="demo"), name="demo")

mp_pose = mp.solutions.pose
mp_drawing = mp.solutions.drawing_utils

TARGET_WIDTH = 480
MODEL_COMPLEXITY = 1
DETECTION_CONF = 0.6
TRACKING_CONF = 0.6
CENTER_LOCK_THRESHOLD = 0.15
RESET_AFTER_FRAMES = 10

# ========== 根据模型自动选择压缩参数 ==========
_current_provider = os.getenv("LLM_PROVIDER", "openai").lower()
_default_fps = 5 if _current_provider == "gemma4" else 12
_default_coord = 1 if _current_provider == "gemma4" else 2
TARGET_OUTPUT_FPS = int(os.getenv("TARGET_OUTPUT_FPS", str(_default_fps)))
COORD_DECIMALS = int(os.getenv("COORD_DECIMALS", str(_default_coord)))
VISIBILITY_DECIMALS = 1

tasks = {}

def create_pose():
    return mp_pose.Pose(
        static_image_mode=False,
        model_complexity=MODEL_COMPLEXITY,
        smooth_landmarks=False,
        min_detection_confidence=DETECTION_CONF,
        min_tracking_confidence=TRACKING_CONF
    )

def get_pose_center(landmarks):
    if not landmarks:
        return None
    nose = landmarks[0]
    if nose['visibility'] > 0.5:
        return (nose['x'], nose['y'])
    xs, ys = [], []
    for lm in landmarks:
        if lm['visibility'] > 0.5:
            xs.append(lm['x'])
            ys.append(lm['y'])
    return (sum(xs)/len(xs), sum(ys)/len(ys)) if xs else None

def compress_pose_sequence(raw_frames, raw_fps):
    if not raw_frames:
        return [], raw_fps
    step = max(1, round(raw_fps / TARGET_OUTPUT_FPS))
    compressed = []
    for i, frame_data in enumerate(raw_frames):
        if i % step == 0:
            time_sec = frame_data["frame"] / raw_fps if raw_fps > 0 else 0
            new_frame = {"time": round(time_sec, 2), "landmarks": []}
            for lm in frame_data["landmarks"]:
                new_lm = {
                    "x": round(lm["x"], COORD_DECIMALS),
                    "y": round(lm["y"], COORD_DECIMALS),
                    "z": round(lm["z"], COORD_DECIMALS),
                    "visibility": round(lm["visibility"], VISIBILITY_DECIMALS)
                }
                new_frame["landmarks"].append(new_lm)
            compressed.append(new_frame)
    new_fps = raw_fps / step
    max_frames = int(os.getenv("MAX_POSE_FRAMES", "200"))
    if len(compressed) > max_frames:
        step2 = len(compressed) / max_frames
        compressed = [compressed[int(i * step2)] for i in range(max_frames)]
        new_fps = new_fps * (max_frames / len(compressed))
    return compressed, new_fps

def load_prompt(lang: str):
    try:
        if lang == "en":
            module = importlib.import_module("web.api.prompts_en")
        else:
            module = importlib.import_module("web.api.prompts_zh")
        return module.ANALYSIS_PROMPT
    except Exception:
        import web.api.prompts_zh as prompts
        return prompts.ANALYSIS_PROMPT

# ==================== API 端点 ====================

@app.post("/upload")
async def upload_video(file: UploadFile = File(...)):
    task_id = str(uuid.uuid4())
    video_path = os.path.join(OUTPUTS_DIR, f"{task_id}.mp4")
    with open(video_path, "wb") as f:
        f.write(await file.read())
    cap = cv2.VideoCapture(video_path)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total_frames <= 0:
        cap.set(cv2.CAP_PROP_POS_AVI_RATIO, 1)
        total_frames = int(cap.get(cv2.CAP_PROP_POS_FRAMES)) + 1
    fps = cap.get(cv2.CAP_PROP_FPS)
    cap.release()
    tasks[task_id] = {
        "video_path": video_path,
        "status": "processing",
        "json_path": None,
        "keypoints_data": [],
        "total_frames": max(0, total_frames),
        "current_frame": 0,
        "fps": fps,
        "target_center": None,
        "lost_frames": 0,
        "video_filename": file.filename,
        "task_id": task_id
    }
    return {"task_id": task_id, "total_frames": max(0, total_frames)}

@app.get("/stream/{task_id}")
async def stream(task_id: str):
    if task_id not in tasks:
        return HTMLResponse(content="任务不存在", status_code=404)
    video_path = tasks[task_id]["video_path"]
    cap = cv2.VideoCapture(video_path)

    def generate():
        pose = create_pose()
        task = tasks[task_id]
        frame_idx = 0
        try:
            while cap.isOpened():
                ret, frame = cap.read()
                if not ret:
                    break
                h, w = frame.shape[:2]
                scale = TARGET_WIDTH / w
                frame = cv2.resize(frame, (TARGET_WIDTH, int(h * scale)))
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                results = pose.process(rgb)
                curr_raw = []
                if results.pose_landmarks:
                    for lm in results.pose_landmarks.landmark:
                        curr_raw.append({"x": lm.x, "y": lm.y, "z": lm.z, "visibility": lm.visibility})
                accepted = False
                if curr_raw:
                    curr_center = get_pose_center(curr_raw)
                    if task["target_center"] is None:
                        task["target_center"] = curr_center
                        task["lost_frames"] = 0
                        accepted = True
                    else:
                        dx = curr_center[0] - task["target_center"][0]
                        dy = curr_center[1] - task["target_center"][1]
                        dist = np.sqrt(dx*dx + dy*dy)
                        if dist < CENTER_LOCK_THRESHOLD:
                            accepted = True
                            task["lost_frames"] = 0
                            task["target_center"] = (
                                task["target_center"][0] * 0.9 + curr_center[0] * 0.1,
                                task["target_center"][1] * 0.9 + curr_center[1] * 0.1
                            )
                        else:
                            task["lost_frames"] += 1
                else:
                    task["lost_frames"] += 1
                if task["lost_frames"] >= RESET_AFTER_FRAMES:
                    task["target_center"] = None
                    task["lost_frames"] = 0
                if not accepted:
                    curr_raw = []
                if accepted and results.pose_landmarks:
                    mp_drawing.draw_landmarks(
                        frame, results.pose_landmarks, mp_pose.POSE_CONNECTIONS,
                        landmark_drawing_spec=mp_drawing.DrawingSpec(color=(0,255,0), thickness=2, circle_radius=2),
                        connection_drawing_spec=mp_drawing.DrawingSpec(color=(0,0,255), thickness=2)
                    )
                task["keypoints_data"].append({"frame": frame_idx, "landmarks": curr_raw if curr_raw else []})
                task["current_frame"] = frame_idx + 1
                ret, jpeg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                if ret:
                    yield (b'--frame\r\n'
                           b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n\r\n')
                frame_idx += 1
        finally:
            cap.release()
            if task["status"] == "processing":
                raw_fps = task["fps"]
                raw_data = task["keypoints_data"]
                compressed_sequence, new_fps = compress_pose_sequence(raw_data, raw_fps)
                task["keypoints_data"] = compressed_sequence
                json_path = os.path.join(OUTPUTS_DIR, f"{task_id}.json")
                with open(json_path, 'w') as f:
                    json.dump({
                        "task_id": task_id,
                        "fps": new_fps,
                        "original_fps": raw_fps,
                        "video_filename": task["video_filename"],
                        "pose_sequence": compressed_sequence
                    }, f, indent=2)
                task["status"] = "completed"
                task["json_path"] = json_path

    return StreamingResponse(generate(), media_type="multipart/x-mixed-replace; boundary=frame")

@app.get("/progress/{task_id}")
async def progress(task_id: str):
    if task_id not in tasks:
        return JSONResponse(content={"error": "任务不存在"}, status_code=404)
    t = tasks[task_id]
    return {"status": t["status"], "total_frames": t["total_frames"], "current_frame": t["current_frame"]}

@app.get("/status/{task_id}")
async def status(task_id: str):
    if task_id not in tasks:
        return JSONResponse(content={"error": "任务不存在"}, status_code=404)
    t = tasks[task_id]
    resp = {"task_id": task_id, "status": t["status"]}
    if t["status"] == "completed":
        resp["json_url"] = f"/download/{task_id}"
    return resp

@app.get("/download/{task_id}")
async def download(task_id: str):
    if task_id not in tasks or tasks[task_id]["status"] != "completed":
        return JSONResponse(content={"error": "JSON未就绪"}, status_code=404)
    json_path = tasks[task_id]["json_path"]
    if not os.path.exists(json_path):
        return JSONResponse(content={"error": "文件不存在"}, status_code=404)
    with open(json_path, 'r') as f:
        return JSONResponse(content=json.load(f))

@app.get("/")
async def index():
    html_path = os.path.join(H5_DIR, "index.html")
    with open(html_path, "r", encoding="utf-8") as f:
        return HTMLResponse(content=f.read())

@app.post("/analyze/stream")
async def analyze_stream(request: Request):
    data = await request.json()
    task_id1 = data.get("task_id1", "")
    task_id2 = data.get("task_id2", "")
    user_text = data.get("user_text", "")
    lang = data.get("lang", "zh")

    if not task_id1 or task_id1 not in tasks:
        return JSONResponse({"error": "至少需要一个有效的任务ID"}, status_code=400)

    ANALYSIS_PROMPT = load_prompt(lang)

    def build_compact_json(task):
        return json.dumps({
            "video_filename": task.get("video_filename", "未知"),
            "fps": task.get("fps", 0),
            "original_fps": task.get("fps", 0),
            "pose_sequence": task.get("keypoints_data", [])
        }, ensure_ascii=False, separators=(',', ':'))

    async def generate():
        provider = os.getenv("LLM_PROVIDER", "openai").lower()
        if provider == "gemma4":
            from web.api.client import analyze_agent_stream
            task1 = tasks[task_id1]
            task2 = tasks[task_id2] if task_id2 and task_id2 in tasks else {
                "video_filename": "无", "keypoints_data": [], "fps": 0, "task_id": "none"
            }
            gen, log_lines = analyze_agent_stream(task1, task2, ANALYSIS_PROMPT, user_text=user_text, lang=lang)
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
                    log_path = os.path.join(OUTPUTS_DIR, f"agent_log_{task_id1}.txt")
                    with open(log_path, "w", encoding="utf-8") as f:
                        f.write("\n".join(log_lines))
                except:
                    pass
        else:
            from web.api.client import analyze_videos_stream
            json1 = build_compact_json(tasks[task_id1])
            json2 = build_compact_json(tasks[task_id2]) if task_id2 and task_id2 in tasks else "[]"
            prompt = ANALYSIS_PROMPT.replace('{video1_json}', json1).replace('{video2_json}', json2).replace('{user_text}', user_text)

            async def save_prompt():
                filename = f"对话_{task_id1}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
                filepath = os.path.join(OUTPUTS_DIR, filename)
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(prompt)
            asyncio.create_task(save_prompt())

            try:
                for chunk in analyze_videos_stream(json1, json2, ANALYSIS_PROMPT, user_text=user_text, lang=lang):
                    if await request.is_disconnected():
                        break
                    yield f"data: {json.dumps({'text': chunk})}\n\n"
                yield "data: [DONE]\n\n"
            except Exception as e:
                traceback.print_exc()
                yield f"data: {json.dumps({'text': f'分析失败：{str(e)}'})}\n\n"
                yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")

@app.get("/audio-offset")
async def audio_offset(task_id1: str, task_id2: str):
    from moviepy import VideoFileClip
    import numpy as np

    path1 = os.path.join(OUTPUTS_DIR, f"{task_id1}.mp4")
    path2 = os.path.join(OUTPUTS_DIR, f"{task_id2}.mp4")
    if not os.path.exists(path1) or not os.path.exists(path2):
        return JSONResponse(status_code=404, content={"error": "视频文件不存在"})

    try:
        clip1 = VideoFileClip(path1).subclipped(0, 10)
        y1 = clip1.audio.to_soundarray(fps=22050, nbytes=2, quantize=True)[:, 0]
        clip1.close()

        clip2 = VideoFileClip(path2).subclipped(0, 10)
        y2 = clip2.audio.to_soundarray(fps=22050, nbytes=2, quantize=True)[:, 0]
        clip2.close()

        correlation = np.correlate(y1.astype(np.float64), y2.astype(np.float64), mode='full')
        lag = np.argmax(correlation) - (len(y2) - 1)
        offset = lag / 22050

        return {"offset": round(offset, 3)}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": str(e), "offset": 0})