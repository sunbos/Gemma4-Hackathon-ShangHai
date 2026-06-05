import json

def get_pose_summary(task_dict):
    """获取姿态数据摘要（用于 Agent 工具调用）"""
    kp = task_dict.get("keypoints_data", [])
    if not kp:
        return json.dumps({"error": "无姿态数据"}, ensure_ascii=False)
    summary = {
        "total_frames": len(kp),
        "fps": task_dict.get("fps", 12),
        "duration_seconds": round(len(kp) / task_dict.get("fps", 12), 2) if task_dict.get("fps", 12) > 0 else 0,
        "landmark_count": len(kp[0].get("landmarks", [])) if kp else 0
    }
    return json.dumps(summary, ensure_ascii=False)

def compare_videos(task1, task2):
    """对比两个视频的基本信息"""
    return json.dumps({
        "video1_frames": len(task1.get("keypoints_data", [])),
        "video2_frames": len(task2.get("keypoints_data", [])),
        "video1_name": task1.get("video_filename", "未知"),
        "video2_name": task2.get("video_filename", "未知")
    }, ensure_ascii=False)