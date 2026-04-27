from flask import Flask, request, jsonify
import lgpio
import time
import json
import threading
import os
from datetime import datetime, timedelta
import cv2
import numpy as np

try:
    import face_recognition
except ImportError:
    print("WARNING: face_recognition module not found. Face verification will be simulated.")
    face_recognition = None

app = Flask(__name__)

# ─── GPIO Setup ───────────────────────────────────────────────────────────────
try:
    h = lgpio.gpiochip_open(0)
except Exception as e:
    print(f"Warning: Could not open GPIO chip: {e}")
    h = None

motor1 = [17, 18, 27, 22]
motor2 = [5,  6,  13, 19]
motor3 = [12, 16, 20, 21]

all_motors = [motor1, motor2, motor3]

if h:
    for motor in all_motors:
        for pin in motor:
            lgpio.gpio_claim_output(h, pin)

# Step sequence (smooth 28BYJ-48 rotation)
sequence = [
    [1,0,0,1],
    [1,0,0,0],
    [1,1,0,0],
    [0,1,0,0],
    [0,1,1,0],
    [0,0,1,0],
    [0,0,1,1],
    [0,0,0,1]
]

# ─── Motor Rotate ─────────────────────────────────────────────────────────────
def rotate_motor(pins, steps=128, delay=0.002):
    if not h:
        print(f"[SIMULATION] Rotating motor on pins {pins}")
        return
    for _ in range(steps):
        for step in sequence:
            for i in range(4):
                lgpio.gpio_write(h, pins[i], step[i])
            time.sleep(delay)
    for pin in pins:
        lgpio.gpio_write(h, pin, 0)  # Turn off after done

def get_motor_pins(motor_num):
    motors = {"1": motor1, "2": motor2, "3": motor3}
    return motors.get(str(motor_num))

# ─── Data Storage ─────────────────────────────────────────────────────────
SCHEDULE_FILE = 'schedules.json'
HISTORY_FILE  = 'history.json'
CONFIG_FILE   = 'config.json'
FACE_IMAGE    = 'reference_face.jpg'

def load_json(file_path, default):
    if os.path.exists(file_path):
        try:
            with open(file_path, 'r') as f:
                return json.load(f)
        except Exception:
            pass
    return default

def save_json(file_path, data):
    with open(file_path, 'w') as f:
        json.dump(data, f, indent=2)

schedules = load_json(SCHEDULE_FILE, {"1": None, "2": None, "3": None})
config    = load_json(CONFIG_FILE, {"time_limit": 30})
dispensed_today = {}  
waiting_queue   = {}  # {"motor_num": {"start": datetime_obj, "limit": 30}}

# ─── Face Recognition Setup ───────────────────────────────────────────────────
reference_encoding = None

def load_reference_face():
    global reference_encoding
    if face_recognition and os.path.exists(FACE_IMAGE):
        try:
            image = face_recognition.load_image_file(FACE_IMAGE)
            encodings = face_recognition.face_encodings(image)
            if encodings:
                reference_encoding = encodings[0]
                print("[FACE] Reference face loaded successfully.")
            else:
                print("[FACE] No face found in reference image.")
        except Exception as e:
            print(f"[FACE] Error loading reference face: {e}")

load_reference_face()

def init_camera():
    # Try multiple camera indices to support whatever is connected
    for i in [0, 1, 2]:
        cap = cv2.VideoCapture(i)
        if cap is not None and cap.isOpened():
            print(f"[CAMERA] Connected to camera index {i}")
            return cap
    print("[CAMERA] WARNING: No camera found!")
    return None

# ─── Background Camera Thread ────────────────────────────────────────────────
# FACE MATCH TOLERANCE: Lower = stricter. 0.45 is strict, 0.6 is default/loose.
FACE_MATCH_TOLERANCE = 0.45
# Require this many consecutive matches before dispensing (prevents false positives)
CONSECUTIVE_MATCHES_REQUIRED = 3

def camera_loop():
    global waiting_queue, dispensed_today
    print("[CAMERA THREAD] Started.")
    print(f"[CAMERA THREAD] Face tolerance: {FACE_MATCH_TOLERANCE} (lower=stricter)")
    print(f"[CAMERA THREAD] Consecutive matches required: {CONSECUTIVE_MATCHES_REQUIRED}")
    
    cap = init_camera()
    consecutive_match_count = 0
    
    while True:
        if not waiting_queue:
            consecutive_match_count = 0  # Reset when no pills pending
            time.sleep(2)
            continue
            
        # ── Guard: face_recognition library must be installed ──
        if not face_recognition:
            print("[FACE] ERROR: face_recognition library NOT installed! Cannot verify face.")
            print("[FACE] Install it with: pip install face_recognition")
            print("[FACE] Pills will NOT dispense until face_recognition is installed.")
            time.sleep(30)
            continue

        # ── Guard: reference face must be registered ──
        if reference_encoding is None:
            print("[FACE] WARNING: No reference face registered! Register via the app first.")
            print("[FACE] Pills will NOT dispense until a face is registered.")
            time.sleep(10)
            continue
            
        if cap is None or not cap.isOpened():
            # Try to reconnect
            cap = init_camera()
            if cap is None:
                time.sleep(5)
                continue

        ret, frame = cap.read()
        if not ret:
            time.sleep(1)
            continue
            
        # Optimization: resize frame for faster face detection
        small_frame = cv2.resize(frame, (0, 0), fx=0.25, fy=0.25)
        rgb_small_frame = cv2.cvtColor(small_frame, cv2.COLOR_BGR2RGB)

        match_found = False
        face_locations = face_recognition.face_locations(rgb_small_frame)
        
        if not face_locations:
            consecutive_match_count = 0  # Reset on no face detected
            time.sleep(0.5)
            continue
            
        face_encodings = face_recognition.face_encodings(rgb_small_frame, face_locations)
        
        for face_encoding in face_encodings:
            # Calculate face distance (lower = more similar, 0.0 = identical)
            face_distance = face_recognition.face_distance([reference_encoding], face_encoding)[0]
            is_match = face_distance <= FACE_MATCH_TOLERANCE
            confidence = round((1.0 - face_distance) * 100, 1)
            
            if is_match:
                print(f"[FACE] ✅ Match! Distance: {face_distance:.3f} | Confidence: {confidence}% | Threshold: {FACE_MATCH_TOLERANCE}")
                match_found = True
                break
            else:
                print(f"[FACE] ❌ No match. Distance: {face_distance:.3f} | Confidence: {confidence}% | Threshold: {FACE_MATCH_TOLERANCE}")
                consecutive_match_count = 0  # Reset on non-match
        
        if match_found:
            consecutive_match_count += 1
            print(f"[FACE] Consecutive matches: {consecutive_match_count}/{CONSECUTIVE_MATCHES_REQUIRED}")
            
            if consecutive_match_count < CONSECUTIVE_MATCHES_REQUIRED:
                time.sleep(0.5)  # Brief pause between verification frames
                continue
            
            # ── VERIFIED: Enough consecutive matches — dispense! ──
            consecutive_match_count = 0
            print(f"[FACE] ✅✅✅ IDENTITY CONFIRMED after {CONSECUTIVE_MATCHES_REQUIRED} consecutive matches!")
            print("[FACE] Dispensing pending pills...")
            motors_to_dispense = list(waiting_queue.keys())
            today = datetime.now().strftime("%Y-%m-%d")
            history = load_json(HISTORY_FILE, [])
            
            for motor_num in motors_to_dispense:
                pins = get_motor_pins(motor_num)
                if pins:
                    print(f"       -> Dispensing motor {motor_num}")
                    rotate_motor(pins)
                    
                    # Mark dispensed
                    sched_time = schedules.get(motor_num)
                    key = f"{motor_num}_{today}_{sched_time}"
                    dispensed_today[key] = True
                    
                    history.append({
                        "motor": motor_num,
                        "time": datetime.now().strftime("%H:%M"),
                        "date": today,
                        "mode": "auto_verified"
                    })
            
            save_json(HISTORY_FILE, history)
            waiting_queue.clear()
            
            # Avoid re-triggering immediately
            time.sleep(10)
        
        time.sleep(0.5)  # Don't hog CPU

# ─── Background Auto-Dispenser Scheduler ─────────────────────────────────────
def scheduler_loop():
    global dispensed_today, waiting_queue
    print("[SCHEDULER] Background scheduler started.")
    while True:
        now          = datetime.now()
        current_time = now.strftime("%H:%M")
        today        = now.strftime("%Y-%m-%d")

        # 1. Check if any motor needs to be added to waiting queue
        for motor_num, sched_time in list(schedules.items()):
            if sched_time is None:
                continue
            
            key = f"{motor_num}_{today}_{sched_time}"
            if current_time == sched_time and key not in dispensed_today and motor_num not in waiting_queue:
                print(f"[SCHEDULER] Time reached for Motor {motor_num}. Entering Waiting Queue...")
                waiting_queue[motor_num] = {
                    "start": now,
                    "limit": config.get("time_limit", 30)
                }

        # 2. Check for expired wait items
        expired_motors = []
        for motor_num, data in list(waiting_queue.items()):
            time_passed = (now - data["start"]).total_seconds() / 60.0
            if time_passed > data["limit"]:
                print(f"[SCHEDULER] Motor {motor_num} collection time limit expired ({data['limit']} mins). Cancelled.")
                expired_motors.append(motor_num)
                
                # Mark as handled today so it doesn't queue up again until tomorrow or if time changes
                sched_time = schedules.get(motor_num)
                key = f"{motor_num}_{today}_{sched_time}"
                dispensed_today[key] = True 
                
                history = load_json(HISTORY_FILE, [])
                history.append({
                    "motor": motor_num,
                    "time": now.strftime("%H:%M"),
                    "date": today,
                    "mode": "missed_time_limit"
                })
                save_json(HISTORY_FILE, history)

        for m in expired_motors:
            del waiting_queue[m]

        time.sleep(20)

threading.Thread(target=scheduler_loop, daemon=True).start()
threading.Thread(target=camera_loop, daemon=True).start()

# ─── API Routes ───────────────────────────────────────────────────────────────
@app.route('/')
def home():
    return jsonify({
        "status": "running",
        "message": "Raspberry Pi Pill Dispenser API (Face Verified)",
        "schedules": schedules,
        "waiting": list(waiting_queue.keys())
    })

@app.route('/run', methods=['GET', 'POST'])
def run_motor_api():
    motor = request.args.get("motor") or (request.get_json(silent=True) or {}).get("motor")
    pins  = get_motor_pins(motor)
    if not pins:
        return jsonify({"error": "Invalid motor. Use 1, 2, or 3"}), 400

    rotate_motor(pins)

    now     = datetime.now()
    history = load_json(HISTORY_FILE, [])
    history.append({
        "motor": str(motor),
        "time": now.strftime("%H:%M"),
        "date": now.strftime("%Y-%m-%d"),
        "mode": "manual"
    })
    save_json(HISTORY_FILE, history)

    return jsonify({"success": True, "message": f"Motor {motor} executed"})

@app.route('/set_schedule', methods=['POST'])
def set_schedule():
    global dispensed_today
    data      = request.get_json(silent=True) or {}
    motor     = str(data.get("motor", ""))
    time_str  = data.get("time", "")

    if motor not in ["1", "2", "3"] or len(time_str) != 5:
        return jsonify({"error": "Invalid input"}), 400

    schedules[motor] = time_str
    save_json(SCHEDULE_FILE, schedules)

    today = datetime.now().strftime("%Y-%m-%d")
    keys_to_remove = [k for k in dispensed_today if k.startswith(f"{motor}_{today}_")]
    for k in keys_to_remove:
        del dispensed_today[k]
        
    if motor in waiting_queue:
        del waiting_queue[motor]

    return jsonify({"success": True, "motor": motor, "scheduled_time": time_str})

@app.route('/clear_schedule', methods=['POST'])
def clear_schedule():
    data  = request.get_json(silent=True) or {}
    motor = str(data.get("motor", ""))
    if motor in schedules:
        schedules[motor] = None
        save_json(SCHEDULE_FILE, schedules)
    if motor in waiting_queue:
        del waiting_queue[motor]
    return jsonify({"success": True, "motor": motor, "scheduled_time": None})

@app.route('/get_schedules', methods=['GET'])
def get_schedules():
    return jsonify(schedules)

@app.route('/history', methods=['GET'])
def get_history():
    return jsonify(load_json(HISTORY_FILE, []))

@app.route('/set_time_limit', methods=['POST'])
def set_time_limit():
    data = request.get_json(silent=True) or {}
    limit = data.get("time_limit")
    if isinstance(limit, int):
        config["time_limit"] = limit
        save_json(CONFIG_FILE, config)
        return jsonify({"success": True, "time_limit": limit})
    return jsonify({"error": "Invalid time limit"}), 400

@app.route('/register_face', methods=['POST'])
def register_face():
    global reference_encoding
    if 'image' not in request.files:
        return jsonify({"error": "No image part"}), 400
    file = request.files['image']
    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400
    
    # Save temporarily to validate
    temp_path = 'temp_face.jpg'
    file.save(temp_path)
    
    # Validate: check if the image actually contains a face
    if face_recognition:
        try:
            image = face_recognition.load_image_file(temp_path)
            encodings = face_recognition.face_encodings(image)
            if not encodings:
                os.remove(temp_path)
                return jsonify({"error": "No face detected in the image. Please try again with a clear face photo."}), 400
            
            # Valid face found — save as reference
            if os.path.exists(FACE_IMAGE):
                os.remove(FACE_IMAGE)
            os.rename(temp_path, FACE_IMAGE)
            reference_encoding = encodings[0]
            print(f"[FACE] ✅ New reference face registered successfully! ({len(encodings)} face(s) detected)")
            return jsonify({"success": True, "message": "Face registered successfully.", "faces_detected": len(encodings)})
        except Exception as e:
            if os.path.exists(temp_path):
                os.remove(temp_path)
            print(f"[FACE] ❌ Error processing face image: {e}")
            return jsonify({"error": f"Failed to process face image: {str(e)}"}), 500
    else:
        # face_recognition not installed — just save the image
        if os.path.exists(FACE_IMAGE):
            os.remove(FACE_IMAGE)
        os.rename(temp_path, FACE_IMAGE)
        print("[FACE] WARNING: face_recognition not installed. Image saved but cannot verify.")
        return jsonify({"success": True, "message": "Image saved (face_recognition not installed — cannot verify)."})

@app.route('/face_status', methods=['GET'])
def face_status():
    """Debug endpoint to check face recognition status"""
    return jsonify({
        "face_recognition_installed": face_recognition is not None,
        "reference_face_registered": reference_encoding is not None,
        "reference_face_file_exists": os.path.exists(FACE_IMAGE),
        "face_match_tolerance": FACE_MATCH_TOLERANCE,
        "consecutive_matches_required": CONSECUTIVE_MATCHES_REQUIRED,
        "waiting_queue": list(waiting_queue.keys()),
        "time_limit_mins": config.get("time_limit", 30)
    })

if __name__ == '__main__':
    print("=" * 50)
    print("  PillBot Flask Server Starting...")
    print(f"  face_recognition installed: {face_recognition is not None}")
    print(f"  Reference face registered: {reference_encoding is not None}")
    print(f"  Face tolerance: {FACE_MATCH_TOLERANCE} (lower=stricter)")
    print(f"  Consecutive matches: {CONSECUTIVE_MATCHES_REQUIRED}")
    print("  Schedules:", schedules)
    print("  Time Limit:", config.get("time_limit", 30), "mins")
    print("=" * 50)
    app.run(host='0.0.0.0', port=5000, debug=False)

