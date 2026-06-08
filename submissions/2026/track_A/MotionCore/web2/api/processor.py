import torch
import cv2
from ultralytics import YOLO
from collections import defaultdict, deque
import numpy as np
import json
import os

# ====================== 预设颜色与常量 ======================
GRAY_COLOR = (128, 128, 128)

PRESET_COLORS = {
    "红": (0, 0, 255),
    "橙": (0, 165, 255),
    "黄": (0, 255, 255),
    "绿": (0, 255, 0),
    "蓝": (255, 0, 0),
    "紫": (255, 0, 128),
}

# ====================== 辅助函数 ======================
def get_hue(bgr):
    hsv = cv2.cvtColor(np.uint8([[bgr]]), cv2.COLOR_BGR2HSV)[0, 0]
    return int(hsv[0])

def map_to_preset_color(bgr):
    h = get_hue(bgr)
    if h <= 10 or h >= 170:
        return PRESET_COLORS["红"]
    elif h <= 25:
        return PRESET_COLORS["橙"]
    elif h <= 35:
        return PRESET_COLORS["黄"]
    elif h <= 85:
        return PRESET_COLORS["绿"]
    elif h <= 125:
        return PRESET_COLORS["蓝"]
    else:
        return PRESET_COLORS["紫"]

def get_green_mask(frame):
    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    lower_green = np.array([30, 40, 40])
    upper_green = np.array([90, 255, 255])
    mask = cv2.inRange(hsv, lower_green, upper_green)
    kernel = np.ones((7, 7), np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    return mask

def grass_ratio(mask, bbox):
    x1, y1, x2, y2 = map(int, bbox)
    h, w = mask.shape
    x1 = max(0, x1)
    y1 = max(0, y1)
    x2 = min(w - 1, x2)
    y2 = min(h - 1, y2)
    body_y1 = int(y1 + (y2 - y1) * 0.6)
    crop = mask[body_y1:y2, x1:x2]
    if crop.size == 0:
        return 0
    green_pixels = np.sum(crop > 0)
    return green_pixels / crop.size

def dynamic_grass_threshold(frame_width, x_center):
    if x_center < frame_width * 0.18:
        return 0.15
    if x_center > frame_width * 0.82:
        return 0.15
    return 0.35

def is_on_pitch(bbox, frame_shape, green_mask):
    h, w = frame_shape[:2]
    x1, y1, x2, y2 = bbox
    bw, bh = x2 - x1, y2 - y1
    if bw <= 0 or bh <= 0 or bh / bw > 3.5:
        return False
    if bh < 40:
        return False
    if x1 < 20 or x2 > w - 20:
        return False
    if y1 < 5 or y2 > h - 5:
        return False
    center_x = (x1 + x2) / 2
    threshold = dynamic_grass_threshold(w, center_x)
    ratio = grass_ratio(green_mask, [x1, y1, x2, y2])
    if ratio < threshold:
        return False
    return True

def get_region_color_lab(frame, bbox, green_mask, expand=0.2):
    x1, y1, x2, y2 = bbox
    h, w = frame.shape[:2]
    bw, bh = x2 - x1, y2 - y1
    dx = int(bw * expand)
    dy = int(bh * expand)
    x1 = max(0, x1 - dx)
    y1 = max(0, y1 - dy)
    x2 = min(w, x2 + dx)
    y2 = min(h, y2 + dy)
    roi = frame[y1:y2, x1:x2]
    mask_roi = green_mask[y1:y2, x1:x2]

    non_green = roi[mask_roi == 0]
    if non_green.size < 15:
        return None
    lab = cv2.cvtColor(non_green.reshape(-1, 1, 3), cv2.COLOR_BGR2Lab)
    mean_color = np.mean(lab.reshape(-1, 3), axis=0)
    return mean_color

def get_upper_body_color(frame, bbox, green_mask):
    x1, y1, x2, y2 = bbox
    bh = y2 - y1
    top = int(y1 + 0.05 * bh)
    bottom = int(y1 + 0.45 * bh)
    left, right = max(x1, 0), min(x2, frame.shape[1])
    roi = frame[top:bottom, left:right]
    mask_roi = green_mask[top:bottom, left:right]

    non_green = roi[mask_roi == 0]
    if non_green.size < 50:
        return None

    lab = cv2.cvtColor(non_green.reshape(-1, 1, 3), cv2.COLOR_BGR2Lab)
    mean_color = np.mean(lab.reshape(-1, 3), axis=0)
    return mean_color

def lab_to_bgr(lab_color_255):
    lab = np.clip(lab_color_255, 0, 255).astype(np.uint8).reshape(1, 1, 3)
    bgr = cv2.cvtColor(lab, cv2.COLOR_Lab2BGR)[0, 0]
    return tuple(int(v) for v in bgr)

def initialize_teams(features):
    if len(features) == 0:
        return None, None
    data = np.float32(features)
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 1.0)
    _, _, centers = cv2.kmeans(data, 2, None, criteria, 10, cv2.KMEANS_RANDOM_CENTERS)

    order = np.argsort(centers[:, 0])
    centers = centers[order]

    raw_bgr_colors = [lab_to_bgr(centers[0]), lab_to_bgr(centers[1])]
    preset_colors = [map_to_preset_color(c) for c in raw_bgr_colors]

    if preset_colors[0] == preset_colors[1]:
        if preset_colors[0] == PRESET_COLORS["蓝"]:
            preset_colors[1] = PRESET_COLORS["红"]
        else:
            preset_colors[1] = PRESET_COLORS["蓝"]

    return centers, preset_colors

def smooth_points(pts, alpha=0.3):
    if len(pts) < 3:
        return pts
    smoothed = [pts[0]]
    for p in pts[1:]:
        prev = smoothed[-1]
        new_x = alpha * p[0] + (1 - alpha) * prev[0]
        new_y = alpha * p[1] + (1 - alpha) * prev[1]
        smoothed.append((new_x, new_y))
    return smoothed

def compute_iou(box1, box2):
    x1 = max(box1[0], box2[0])
    y1 = max(box1[1], box2[1])
    x2 = min(box1[2], box2[2])
    y2 = min(box1[3], box2[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    area1 = (box1[2] - box1[0]) * (box1[3] - box1[1])
    area2 = (box2[2] - box2[0]) * (box2[3] - box2[1])
    return inter / (area1 + area2 - inter + 1e-6)

# ====================== 背景匹配器 ======================
class AdaptiveBackgroundMatcher:
    def __init__(self, reference_frame):
        self.ref_frame = reference_frame
        self.ref_mask = get_green_mask(reference_frame)
        self.orb = cv2.ORB_create(3000)
        self.matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
        self.kp_ref, self.des_ref = self.detect_background(reference_frame, self.ref_mask, [])
        self.history = deque(maxlen=3)
        self.fail_count = 0
        self.max_fail = 15

    def detect_background(self, frame, mask, exclude_bboxes):
        mask_no_players = mask.copy()
        h, w = mask.shape[:2]
        for bbox in exclude_bboxes:
            x1, y1, x2, y2 = [int(v) for v in bbox]
            border = int((x2 - x1) * 0.15)
            x1 = max(0, x1 - border)
            x2 = min(w, x2 + border)
            y1 = max(0, y1 - border)
            y2 = min(h, y2 + border)
            mask_no_players[y1:y2, x1:x2] = 0
        kp = self.orb.detect(frame, mask=mask_no_players)
        if len(kp) < 30:
            return [], None
        kp, des = self.orb.compute(frame, kp)
        return kp, des

    def match(self, current_frame, exclude_bboxes):
        curr_mask = get_green_mask(current_frame)
        kp_curr, des_curr = self.detect_background(current_frame, curr_mask, exclude_bboxes)
        if des_curr is None or self.des_ref is None:
            self.fail_count += 1
            return None

        matches = self.matcher.match(self.des_ref, des_curr)
        matches = sorted(matches, key=lambda x: x.distance)[:100]
        if len(matches) < 30:
            self.fail_count += 1
            return None

        pts_ref = np.float32([self.kp_ref[m.queryIdx].pt for m in matches]).reshape(-1, 1, 2)
        pts_curr = np.float32([kp_curr[m.trainIdx].pt for m in matches]).reshape(-1, 1, 2)

        M, inliers = cv2.estimateAffinePartial2D(pts_curr, pts_ref, method=cv2.RANSAC, ransacReprojThreshold=3.0)
        if M is None or inliers is None or np.sum(inliers) < 15:
            self.fail_count += 1
            return None

        H = np.eye(3, dtype=np.float64)
        H[:2, :] = M
        self.history.append(H)
        self.fail_count = 0
        return self._get_smoothed_H()

    def update_reference(self, new_frame, exclude_bboxes):
        self.ref_frame = new_frame.copy()
        self.ref_mask = get_green_mask(new_frame)
        kp, des = self.detect_background(new_frame, self.ref_mask, exclude_bboxes)
        if kp and des is not None and len(kp) >= 30:
            self.kp_ref, self.des_ref = kp, des
            self.history.clear()
            self.fail_count = 0
            return True
        else:
            self.fail_count = 0
            return False

    def _get_smoothed_H(self):
        if not self.history:
            return np.eye(3, dtype=np.float64)
        avg_H = np.eye(3, dtype=np.float64)
        avg_H[0, 2] = np.mean([h[0, 2] for h in self.history])
        avg_H[1, 2] = np.mean([h[1, 2] for h in self.history])
        return avg_H

# ====================== 足球处理器 ======================
class FootballProcessor:
    def __init__(self):
        self.device = 'cuda' if torch.cuda.is_available() else 'cpu'
        model_dir = os.path.dirname(os.path.abspath(__file__))
        model_path = os.path.join(model_dir, '..', 'model', 'yolov8n.pt')
        self.model = YOLO(model_path).to(self.device)

        dummy = np.zeros((64, 64, 3), dtype=np.uint8)
        self.model(dummy, classes=[0], conf=0.5, verbose=False, device=self.device)

        self.MIN_TRACK_FRAMES = 4
        self.COLOR_DRIFT_THRESH = 0.7
        self.BALL_COLOR_DIST_THRESH = 25.0
        self.PLAYER_CONF_THRESH = 0.5
        self.BALL_CONF_THRESH = 0.05
        self.IOU_OVERLAP_THRESH = 0.3
        self.TRAJ_SMOOTH_ALPHA = 0.3
        self.POSSESSION_MAX_DIST = 5.0

    def process(self, video_path, task_info):
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise RuntimeError("无法打开视频文件")
        ret, first_frame = cap.read()
        if not ret:
            cap.release()
            raise RuntimeError("无法读取视频第一帧")

        src_pts = np.float32([[0, 0], [first_frame.shape[1], 0],
                              [first_frame.shape[1], first_frame.shape[0]], [0, first_frame.shape[0]]])
        dst_pts = np.float32([[0, 0], [105, 0], [105, 68], [0, 68]])
        M_ref = cv2.getPerspectiveTransform(src_pts, dst_pts)
        M_ref_inv = cv2.getPerspectiveTransform(dst_pts, src_pts)

        bg_matcher = AdaptiveBackgroundMatcher(first_frame)

        trajectories = defaultdict(list)
        ball_trajectory = []
        possession_log = []
        lost_count = defaultdict(int)
        track_lifetime = {}
        smooth_center_x = None
        smooth_center_y = None

        team_centers = None
        team_draw_colors = None
        player_team = {}
        team_color_buffer = defaultdict(list)
        referee_ids = set()
        global_features = []

        frame_idx = 0
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        task_info['total_frames'] = total_frames

        while True:
            ret, frame = cap.read()
            if not ret:
                break

            green_mask = get_green_mask(frame)

            classes_to_detect = [0, 32]
            results_pre = self.model(frame, classes=classes_to_detect, conf=0.1, verbose=False,
                                     device=self.device)
            exclude_bboxes = []
            if results_pre[0].boxes is not None and len(results_pre[0].boxes.xyxy) > 0:
                for i, xyxy in enumerate(results_pre[0].boxes.xyxy.cpu().numpy()):
                    cls = int(results_pre[0].boxes.cls[i])
                    conf = float(results_pre[0].boxes.conf[i])
                    if cls == 0 and conf >= self.PLAYER_CONF_THRESH:
                        exclude_bboxes.append(xyxy.tolist())

            H_curr_to_ref = bg_matcher.match(frame, exclude_bboxes)

            if bg_matcher.fail_count >= bg_matcher.max_fail:
                if bg_matcher.update_reference(frame, exclude_bboxes):
                    trajectories.clear()
                    lost_count.clear()
                    track_lifetime.clear()
                    ball_trajectory.clear()
                    possession_log.clear()
                H_curr_to_ref = None

            use_compensation = H_curr_to_ref is not None

            results = self.model.track(frame, tracker="botsort.yaml", classes=classes_to_detect,
                                       conf=0.1, persist=True, verbose=False, device=self.device)

            current_ids = set()
            tracked_players_minimap = []
            ball_position_world = None
            ball_pixel_center = None
            player_boxes = []

            if results[0].boxes is not None and results[0].boxes.id is not None:
                boxes = results[0].boxes.xyxy.cpu().numpy().astype(int)
                classes = results[0].boxes.cls.cpu().numpy().astype(int) if results[0].boxes.cls is not None else [0]*len(boxes)
                confs = results[0].boxes.conf.cpu().numpy() if results[0].boxes.conf is not None else [1.0]*len(boxes)
                for box, cls, conf in zip(boxes, classes, confs):
                    if cls == 0 and conf >= self.PLAYER_CONF_THRESH:
                        x1, y1, x2, y2 = box.tolist()
                        if is_on_pitch([x1, y1, x2, y2], frame.shape, green_mask):
                            player_boxes.append([x1, y1, x2, y2])

            if results[0].boxes is not None and results[0].boxes.id is not None:
                boxes = results[0].boxes.xyxy.cpu().numpy().astype(int)
                ids = results[0].boxes.id.cpu().numpy().astype(int)
                classes = results[0].boxes.cls.cpu().numpy().astype(int) if results[0].boxes.cls is not None else [0]*len(boxes)
                confs = results[0].boxes.conf.cpu().numpy() if results[0].boxes.conf is not None else [1.0]*len(boxes)

                for box, tid, cls, conf in zip(boxes, ids, classes, confs):
                    x1, y1, x2, y2 = box.tolist()

                    if cls == 32:
                        if conf < self.BALL_CONF_THRESH:
                            continue
                        ball_box = [x1, y1, x2, y2]
                        is_near_player = any(compute_iou(ball_box, pbox) > self.IOU_OVERLAP_THRESH for pbox in player_boxes)
                        if not is_near_player:
                            ball_color_lab = get_region_color_lab(frame, ball_box, green_mask, expand=0.2)
                            if team_centers is not None and ball_color_lab is not None:
                                d0 = np.linalg.norm(ball_color_lab - team_centers[0])
                                d1 = np.linalg.norm(ball_color_lab - team_centers[1])
                                if min(d0, d1) < self.BALL_COLOR_DIST_THRESH:
                                    continue

                        cx_ball = (x1 + x2) / 2
                        cy_ball = (y1 + y2) / 2
                        ball_pixel_center = (cx_ball, cy_ball)
                        cv2.circle(frame, (int(cx_ball), int(cy_ball)), int((x2 - x1) / 2), (0, 255, 255), 2)
                        cv2.putText(frame, "BALL", (x1, y1 - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 2)

                        if use_compensation:
                            foot_curr = np.array([[cx_ball, cy_ball, 1.0]], dtype=np.float64)
                            foot_ref = H_curr_to_ref @ foot_curr.T
                            foot_ref /= foot_ref[2]
                            foot_world = M_ref @ foot_ref
                            foot_world /= foot_world[2]
                            ball_position_world = (float(foot_world[0, 0]), float(foot_world[1, 0]))
                            ball_trajectory.append(ball_position_world)
                        continue

                    if conf < self.PLAYER_CONF_THRESH:
                        continue
                    if not is_on_pitch([x1, y1, x2, y2], frame.shape, green_mask):
                        continue

                    current_ids.add(tid)
                    track_lifetime[tid] = track_lifetime.get(tid, 0) + 1
                    current_color = get_upper_body_color(frame, [x1, y1, x2, y2], green_mask)

                    if (team_centers is not None and
                        tid in player_team and
                        tid not in referee_ids and
                        current_color is not None):

                        assigned_team = player_team[tid]
                        d_own = np.linalg.norm(current_color - team_centers[assigned_team])
                        d_other = np.linalg.norm(current_color - team_centers[1 - assigned_team])
                        if d_other < d_own * self.COLOR_DRIFT_THRESH:
                            del player_team[tid]
                            continue

                    if tid not in player_team and tid not in referee_ids:
                        if current_color is not None:
                            if team_centers is None:
                                global_features.append(current_color)
                                if len(global_features) >= 50:
                                    team_centers, team_draw_colors = initialize_teams(global_features)
                                    global_features = []
                            else:
                                team_color_buffer[tid].append(current_color)
                                if len(team_color_buffer[tid]) >= 5:
                                    avg_color = np.mean(team_color_buffer[tid], axis=0)
                                    d0 = np.linalg.norm(avg_color - team_centers[0])
                                    d1 = np.linalg.norm(avg_color - team_centers[1])
                                    if min(d0, d1) > 40:
                                        referee_ids.add(tid)
                                    else:
                                        assigned_team = 0 if d0 < d1 else 1
                                        player_team[tid] = assigned_team
                                    del team_color_buffer[tid]

                    if tid in referee_ids:
                        team = None
                        color = GRAY_COLOR
                    elif tid in player_team:
                        team = player_team[tid]
                        color = team_draw_colors[team] if team_draw_colors else GRAY_COLOR
                    else:
                        team = None
                        color = GRAY_COLOR

                    if track_lifetime[tid] >= self.MIN_TRACK_FRAMES:
                        tracked_players_minimap.append({
                            "id": tid,
                            "bbox": [x1, y1, x2, y2],
                            "team": team
                        })

                    cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                    cv2.putText(frame, f"ID:{tid}", (x1, y1 - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

                    if use_compensation:
                        foot_curr = np.array([[(x1 + x2) / 2, y2, 1.0]], dtype=np.float64)
                        foot_ref = H_curr_to_ref @ foot_curr.T
                        foot_ref /= foot_ref[2]
                        foot_world = M_ref @ foot_ref
                        foot_world /= foot_world[2]
                        trajectories[tid].append((float(foot_world[0, 0]), float(foot_world[1, 0])))
                    lost_count[tid] = 0

            # 记录控球者
            closest_id = None
            if ball_position_world is not None and tracked_players_minimap:
                bx, by = ball_position_world
                min_dist = self.POSSESSION_MAX_DIST
                for p in tracked_players_minimap:
                    pid = p["id"]
                    if pid in trajectories and len(trajectories[pid]) > 0:
                        px, py = trajectories[pid][-1]
                        dist = np.sqrt((bx - px)**2 + (by - py)**2)
                        if dist < min_dist:
                            min_dist = dist
                            closest_id = pid
            possession_log.append({"frame": frame_idx, "player_id": closest_id})

            # 球权连线
            if ball_pixel_center is not None and tracked_players_minimap:
                bx, by = ball_pixel_center
                min_dist_pix = float('inf')
                closest_pix_id = None
                for p in tracked_players_minimap:
                    x1, y1, x2, y2 = p["bbox"]
                    pcx, pcy = (x1 + x2) / 2, (y1 + y2) / 2
                    dist = np.sqrt((bx - pcx) ** 2 + (by - pcy) ** 2)
                    if dist < min_dist_pix:
                        min_dist_pix = dist
                        closest_pix_id = p["id"]
                if closest_pix_id is not None:
                    for p in tracked_players_minimap:
                        if p["id"] == closest_pix_id:
                            x1, y1, x2, y2 = p["bbox"]
                            pcx, pcy = (x1 + x2) / 2, (y1 + y2) / 2
                            cv2.line(frame, (int(bx), int(by)), (int(pcx), int(pcy)), (255, 255, 255), 2, cv2.LINE_AA)
                            cv2.putText(frame, f"Possession: ID {closest_pix_id}", (30, 80),
                                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
                            break

            for tid in list(lost_count.keys()):
                if tid not in current_ids:
                    lost_count[tid] += 1
                    if lost_count[tid] > 10:
                        trajectories.pop(tid, None)
                        lost_count.pop(tid, None)
                        track_lifetime.pop(tid, None)

            if use_compensation:
                H_ref_to_curr = np.linalg.inv(H_curr_to_ref)
                for tid, pts in trajectories.items():
                    if len(pts) < 2:
                        continue
                    recent = pts[-25:]
                    smoothed = smooth_points(recent, self.TRAJ_SMOOTH_ALPHA)
                    if len(smoothed) < 2:
                        continue
                    world_pts = np.float64([[[p[0], p[1], 1.0]] for p in smoothed])
                    ref_pts = (M_ref_inv @ world_pts.reshape(-1, 3).T).T
                    ref_pts = ref_pts[:, :2] / ref_pts[:, 2:]
                    curr_pts = (H_ref_to_curr @ np.hstack([ref_pts, np.ones((len(ref_pts), 1))]).T).T
                    curr_pts = curr_pts[:, :2] / curr_pts[:, 2:]

                    if tid in referee_ids:
                        color = GRAY_COLOR
                    elif tid in player_team and team_draw_colors:
                        color = team_draw_colors[player_team[tid]]
                    else:
                        color = GRAY_COLOR
                    for i in range(1, len(curr_pts)):
                        pt1 = (int(curr_pts[i - 1, 0]), int(curr_pts[i - 1, 1]))
                        pt2 = (int(curr_pts[i, 0]), int(curr_pts[i, 1]))
                        cv2.line(frame, pt1, pt2, color, 2)

                if len(ball_trajectory) >= 2:
                    continuous_ball = [ball_trajectory[-1]]
                    for i in range(len(ball_trajectory) - 2, -1, -1):
                        p1 = ball_trajectory[i]
                        p2 = continuous_ball[0]
                        dist = np.sqrt((p1[0] - p2[0]) ** 2 + (p1[1] - p2[1]) ** 2)
                        if dist > 10.0:
                            break
                        continuous_ball.insert(0, p1)
                    if len(continuous_ball) >= 2:
                        smoothed_ball = smooth_points(continuous_ball, self.TRAJ_SMOOTH_ALPHA)
                        if len(smoothed_ball) >= 2:
                            world_ball = np.float64([[[p[0], p[1], 1.0]] for p in smoothed_ball])
                            ref_ball = (M_ref_inv @ world_ball.reshape(-1, 3).T).T
                            ref_ball = ref_ball[:, :2] / ref_ball[:, 2:]
                            curr_ball = (H_ref_to_curr @ np.hstack([ref_ball, np.ones((len(ref_ball), 1))]).T).T
                            curr_ball = curr_ball[:, :2] / curr_ball[:, 2:]
                            for i in range(1, len(curr_ball)):
                                pt1 = (int(curr_ball[i - 1, 0]), int(curr_ball[i - 1, 1]))
                                pt2 = (int(curr_ball[i, 0]), int(curr_ball[i, 1]))
                                cv2.line(frame, pt1, pt2, (255, 255, 255), 1, cv2.LINE_AA)

            self._draw_minimap(frame, tracked_players_minimap, team_draw_colors,
                               ball_position_world, smooth_center_x, smooth_center_y)
            if tracked_players_minimap:
                centers = [[(p["bbox"][0]+p["bbox"][2])/2, (p["bbox"][1]+p["bbox"][3])/2] for p in tracked_players_minimap]
                centers = np.array(centers)
                curr_cx = np.mean(centers[:, 0])
                curr_cy = np.mean(centers[:, 1])
                alpha = 0.08
                if smooth_center_x is None:
                    smooth_center_x = curr_cx
                    smooth_center_y = curr_cy
                else:
                    smooth_center_x = alpha * curr_cx + (1 - alpha) * smooth_center_x
                    smooth_center_y = alpha * curr_cy + (1 - alpha) * smooth_center_y

            ret, jpeg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            if ret:
                yield (frame_idx, jpeg.tobytes())
            frame_idx += 1
            task_info['current_frame'] = frame_idx

        cap.release()
        self._save_json(task_info, trajectories, ball_trajectory, player_team, referee_ids, team_draw_colors, possession_log)
        task_info['status'] = 'completed'

    def _draw_minimap(self, frame, tracked_players, team_draw_colors, ball_pos_world,
                      smooth_cx, smooth_cy):
        # 放大 0.5 倍：480x330
        minimap_w, minimap_h = 480, 330
        start_x = frame.shape[1] - minimap_w - 20
        start_y = 20

        overlay = frame.copy()
        cv2.rectangle(overlay, (start_x, start_y), (start_x + minimap_w, start_y + minimap_h), (0, 0, 0), -1)
        cv2.addWeighted(overlay, 0.7, frame, 0.3, 0, frame)
        cv2.rectangle(frame, (start_x, start_y), (start_x + minimap_w, start_y + minimap_h), (255, 255, 255), 2)
        cv2.line(frame, (start_x + minimap_w // 2, start_y), (start_x + minimap_w // 2, start_y + minimap_h), (255, 255, 255), 2)
        cv2.circle(frame, (start_x + minimap_w // 2, start_y + minimap_h // 2), 45, (255, 255, 255), 2)
        cv2.putText(frame, "TEAM SHAPE", (start_x + 25, start_y + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 2)

        if tracked_players and smooth_cx is not None:
            scale = 0.35
            for p in tracked_players:
                x1, y1, x2, y2 = p["bbox"]
                cx = (x1 + x2) / 2
                cy = (y1 + y2) / 2
                rel_x = cx - smooth_cx
                rel_y = cy - smooth_cy
                mx = int(start_x + minimap_w // 2 + rel_x * scale)
                my = int(start_y + minimap_h // 2 + rel_y * scale)
                mx = max(start_x + 10, min(start_x + minimap_w - 10, mx))
                my = max(start_y + 10, min(start_y + minimap_h - 10, my))
                team = p.get("team")
                col = team_draw_colors[team] if team is not None and team_draw_colors else GRAY_COLOR
                cv2.circle(frame, (mx, my), 8, col, -1)

        if ball_pos_world is not None:
            wx, wy = ball_pos_world
            mbx = int(start_x + wx * (minimap_w / 105))
            mby = int(start_y + wy * (minimap_h / 68))
            mbx = max(start_x + 5, min(start_x + minimap_w - 5, mbx))
            mby = max(start_y + 5, min(start_y + minimap_h - 5, mby))
            cv2.circle(frame, (mbx, mby), 6, (255, 255, 255), -1)

    def _save_json(self, task_info, trajectories, ball_trajectory, player_team, referee_ids, team_draw_colors, possession_log):
        def to_py_float_list(pts):
            return [[float(p[0]), float(p[1])] for p in pts]

        clean_possession = []
        for entry in possession_log:
            pid = entry["player_id"]
            if pid is not None:
                pid = int(pid)
            clean_possession.append({"frame": int(entry["frame"]), "player_id": pid})

        data = {
            "video_filename": task_info.get("video_filename", "未知"),
            "total_frames": task_info.get("total_frames", 0),
            "players": [],
            "ball_trajectory": to_py_float_list(ball_trajectory),
            "team_colors": team_draw_colors if team_draw_colors else [],
            "possession_log": clean_possession
        }

        for tid, pts in trajectories.items():
            team = player_team.get(tid)
            if tid in referee_ids:
                team = "referee"
            data["players"].append({
                "id": int(tid),
                "team": team,
                "trajectory": to_py_float_list(pts)
            })

        json_path = os.path.join("outputs", f"{task_info['task_id']}.json")
        with open(json_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
        task_info['json_path'] = json_path