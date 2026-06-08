import json

def get_team_summary(task_dict):
    """获取比赛队伍摘要（双方球员数、足球轨迹点、控球信息）"""
    players = task_dict.get("players", [])
    ball = task_dict.get("ball_trajectory", [])
    possession = task_dict.get("possession_log", [])

    team0_count = sum(1 for p in players if p.get("team") == 0)
    team1_count = sum(1 for p in players if p.get("team") == 1)
    referee_count = sum(1 for p in players if p.get("team") == "referee" or p.get("team") is None)

    possession_info = "无控球数据"
    if possession:
        last_entry = possession[-1]
        pid = last_entry.get("player_id")
        if pid is not None:
            possession_info = f"最后一帧控球球员 ID: {pid}"
        else:
            possession_info = "最后一帧无人控球"

    summary = {
        "team0_players": team0_count,
        "team1_players": team1_count,
        "referee_or_unknown": referee_count,
        "ball_trajectory_points": len(ball),
        "possession_last_frame": possession_info,
        "total_frames": task_dict.get("total_frames", 0)
    }
    return json.dumps(summary, ensure_ascii=False)

def get_player_trajectory_summary(task_dict, player_id):
    """获取指定球员的轨迹摘要（起止位置、跑动距离）"""
    for p in task_dict.get("players", []):
        if p.get("id") == player_id:
            traj = p.get("trajectory", [])
            if not traj:
                return json.dumps({"error": "该球员无轨迹数据"}, ensure_ascii=False)
            start = traj[0]
            end = traj[-1]
            total_dist = sum(
                ((traj[i][0]-traj[i-1][0])**2 + (traj[i][1]-traj[i-1][1])**2)**0.5
                for i in range(1, len(traj))
            )
            return json.dumps({
                "player_id": player_id,
                "team": p.get("team"),
                "trajectory_length": len(traj),
                "start_position": start,
                "end_position": end,
                "total_distance": round(total_dist, 2)
            }, ensure_ascii=False)
    return json.dumps({"error": f"球员 {player_id} 不存在"}, ensure_ascii=False)