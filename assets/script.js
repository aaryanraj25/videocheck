// --- Local MediaPipe drawing utilities (copied for guaranteed availability) ---
const POSE_CONNECTIONS = [
  [0,1],[1,2],[2,3],[3,7],[0,4],[4,5],[5,6],[6,8],
  [9,10],[11,12],[11,13],[13,15],[15,17],[15,19],[15,21],[17,19],[12,14],[14,16],[16,18],[16,20],[16,22],[18,20],
  [11,23],[12,24],[23,24],[23,25],[24,26],[25,27],[26,28],[27,29],[28,30],[29,31],[30,32]
];
function drawConnectors(ctx, landmarks, connections, style) {
  style = style || {color: '#00FF00', lineWidth: 4};
  for (const [i, j] of connections) {
    const a = landmarks[i], b = landmarks[j];
    if (a && b && a.visibility > 0.1 && b.visibility > 0.1) {
      ctx.beginPath();
      ctx.moveTo(a.x * ctx.canvas.width, a.y * ctx.canvas.height);
      ctx.lineTo(b.x * ctx.canvas.width, b.y * ctx.canvas.height);
      ctx.strokeStyle = style.color;
      ctx.lineWidth = style.lineWidth;
      ctx.stroke();
    }
  }
}
function drawLandmarks(ctx, landmarks, style) {
  style = style || {color: '#FF0000', lineWidth: 2};
  for (const lm of landmarks) {
    if (lm && lm.visibility > 0.1) {
      ctx.beginPath();
      ctx.arc(lm.x * ctx.canvas.width, lm.y * ctx.canvas.height, style.lineWidth + 1, 0, 2 * Math.PI);
      ctx.fillStyle = style.color;
      ctx.fill();
    }
  }
}
// --- Patch global scope for MediaPipe drawing utilities (for all CDN versions) ---
if (!window.drawConnectors && window.drawingUtils && window.drawingUtils.drawConnectors) {
  window.drawConnectors = window.drawingUtils.drawConnectors;
}
if (!window.drawLandmarks && window.drawingUtils && window.drawingUtils.drawLandmarks) {
  window.drawLandmarks = window.drawingUtils.drawLandmarks;
}
if (!window.POSE_CONNECTIONS && window.Pose && window.Pose.POSE_CONNECTIONS) {
  window.POSE_CONNECTIONS = window.Pose.POSE_CONNECTIONS;
}

// ========== JS Version of Core Logic from Python Child's Pose Detection ==========

function calculateAngle(a, b, c) {
  const radians = Math.atan2(c.y - b.y, c.x - b.x) - Math.atan2(a.y - b.y, a.x - b.x);
  let angle = Math.abs(radians * 180.0 / Math.PI);
  return angle > 180 ? 360 - angle : angle;
}

function calculateDistance(a, b) {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return Math.sqrt(dx * dx + dy * dy);
}

function midpoint(p1, p2) {
  return {
    x: (p1.x + p2.x) / 2,
    y: (p1.y + p2.y) / 2,
  };
}

function calculateSpineCurvature(nose, shoulderCenter, hipCenter) {
  return calculateAngle(nose, shoulderCenter, hipCenter);
}

function checkTorsoThighContact(shoulderCenter, knees) {
  const avgKnee = midpoint(knees[0], knees[1]);
  return calculateDistance(shoulderCenter, avgKnee);
}

// --- Improved analyzeChildPose: returns feedback, bodyPartStatus, and landmark-to-body-part mapping ---
function analyzeChildPose(landmarks, canvasHeight) {
  const get = idx => landmarks[idx];

  // Indices as per MediaPipe Pose
  const LEFT_HIP = get(23), RIGHT_HIP = get(24);
  const LEFT_KNEE = get(25), RIGHT_KNEE = get(26);
  const LEFT_ANKLE = get(27), RIGHT_ANKLE = get(28);
  const LEFT_HEEL = get(29), RIGHT_HEEL = get(30);
  const LEFT_SHOULDER = get(11), RIGHT_SHOULDER = get(12);
  const LEFT_ELBOW = get(13), RIGHT_ELBOW = get(14);
  const LEFT_WRIST = get(15), RIGHT_WRIST = get(16);
  const LEFT_EAR = get(7), RIGHT_EAR = get(8);
  const NOSE = get(0);

  const hipCenter = midpoint(LEFT_HIP, RIGHT_HIP);
  const heelCenter = midpoint(LEFT_HEEL, RIGHT_HEEL);
  const shoulderCenter = midpoint(LEFT_SHOULDER, RIGHT_SHOULDER);
  const kneePositions = [LEFT_KNEE, RIGHT_KNEE];

  // Ideal ranges (pixel distances are normalized to [0,1] for canvas)
  const IDEAL = {
    knee_flexion: [10, 35],
    hip_heel_distance: 0.12, // normalized (was 120px for 1000px image)
    torso_thigh_contact: 0.15,
    spine_curvature: [40, 120],
    shoulder_relaxation: 0.06, // normalized
    arm_relaxation: 0.2 // normalized
  };
  // Tolerances (normalized for distances, degrees for angles)
  const TOLERANCE = {
    knee_flexion: 15, // degrees
    hip_heel_distance: 0.06, // normalized (60px)
    torso_thigh_contact: 0.08, // normalized (80px)
    spine_curvature: 25, // degrees
    shoulder_relaxation: 0.04, // normalized (40px)
    arm_relaxation: 0.08 // normalized (80px)
  };

  // Map body parts to landmark indices
  const bodyPartLandmarks = {
    knee_flexion: [23, 25, 27, 24, 26, 28],
    hip_heel_contact: [23, 24, 29, 30],
    torso_fold: [0, 11, 12, 23, 24],
    head_position: [0, 7, 8],
    spine_curve: [0, 11, 12, 23, 24],
    shoulder_relaxation: [11, 12],
    arm_position: [11, 13, 15, 12, 14, 16]
  };

  // Status for each body part
  const bodyPartStatus = {};
  const feedback = [];

  // 1. Knee Flexion
  const leftKneeAngle = calculateAngle(LEFT_HIP, LEFT_KNEE, LEFT_ANKLE);
  const rightKneeAngle = calculateAngle(RIGHT_HIP, RIGHT_KNEE, RIGHT_ANKLE);
  const avgKneeAngle = (leftKneeAngle + rightKneeAngle) / 2;
  bodyPartStatus.knee_flexion = (avgKneeAngle >= IDEAL.knee_flexion[0] && avgKneeAngle <= IDEAL.knee_flexion[1]);
  // Feedback only if outside ideal+tolerance
  if (avgKneeAngle < IDEAL.knee_flexion[0] - TOLERANCE.knee_flexion || avgKneeAngle > IDEAL.knee_flexion[1] + TOLERANCE.knee_flexion) {
    feedback.push("Sit deeper on your heels. Knee angle too open.");
  }

  // 2. Hip-Heel Contact
  const hipHeelDistance = calculateDistance(hipCenter, heelCenter);
  bodyPartStatus.hip_heel_contact = (hipHeelDistance <= IDEAL.hip_heel_distance);
  if (hipHeelDistance > IDEAL.hip_heel_distance + TOLERANCE.hip_heel_distance) {
    feedback.push("Bring your hips closer to your heels.");
  }

  // 3. Torso-Thigh Contact
  const torsoThighDistance = checkTorsoThighContact(shoulderCenter, kneePositions);
  bodyPartStatus.torso_fold = (torsoThighDistance <= IDEAL.torso_thigh_contact);
  if (torsoThighDistance > IDEAL.torso_thigh_contact + TOLERANCE.torso_thigh_contact) {
    feedback.push("Fold your torso more onto your thighs.");
  }

  // 4. Head Position (no tolerance, binary)
  const headBelowHips = NOSE.y > hipCenter.y;
  bodyPartStatus.head_position = headBelowHips;
  if (!bodyPartStatus.head_position) {
    feedback.push("Lower your head below your hips.");
  }

  // 5. Spine Curvature
  const spineCurve = calculateSpineCurvature(NOSE, shoulderCenter, hipCenter);
  bodyPartStatus.spine_curve = (spineCurve >= IDEAL.spine_curvature[0] && spineCurve <= IDEAL.spine_curvature[1]);
  if (spineCurve < IDEAL.spine_curvature[0] - TOLERANCE.spine_curvature || spineCurve > IDEAL.spine_curvature[1] + TOLERANCE.spine_curvature) {
    feedback.push("Relax your spine more. Allow natural curve.");
  }

  // 6. Shoulder Relaxation
  const shoulderDiff = Math.abs(LEFT_SHOULDER.y - RIGHT_SHOULDER.y);
  bodyPartStatus.shoulder_relaxation = (shoulderDiff <= IDEAL.shoulder_relaxation);
  if (shoulderDiff > IDEAL.shoulder_relaxation + TOLERANCE.shoulder_relaxation) {
    feedback.push("Relax and level your shoulders.");
  }

  // 7. Arm Position
  const leftArm = calculateDistance(LEFT_SHOULDER, LEFT_WRIST);
  const rightArm = calculateDistance(RIGHT_SHOULDER, RIGHT_WRIST);
  const armRelaxation = (leftArm + rightArm) / 2;
  bodyPartStatus.arm_position = (armRelaxation <= IDEAL.arm_relaxation);
  if (armRelaxation > IDEAL.arm_relaxation + TOLERANCE.arm_relaxation) {
    feedback.push("Let your arms relax alongside your body.");
  }

  // Map each landmark index to its body part(s)
  const landmarkToBodyPart = {};
  for (const [part, indices] of Object.entries(bodyPartLandmarks)) {
    for (const idx of indices) {
      if (!landmarkToBodyPart[idx]) landmarkToBodyPart[idx] = [];
      landmarkToBodyPart[idx].push(part);
    }
  }

  return { feedback, bodyPartStatus, landmarkToBodyPart };
}

// Use predefined DOM elements
const videoElement = document.getElementById("input_video");
const canvasElement = document.getElementById("output_canvas");
const canvasCtx = canvasElement.getContext("2d");
const feedbackElement = document.getElementById("feedback");
const toggleSoundBtn = document.getElementById("toggle-sound");

// Ensure canvas is visible and above video
canvasElement.style.display = "block";
canvasElement.style.position = "relative";
canvasElement.style.zIndex = "10";

let soundEnabled = true;
toggleSoundBtn.addEventListener("click", () => {
  soundEnabled = !soundEnabled;
  toggleSoundBtn.textContent = soundEnabled ? "Toggle Sound" : "Sound Off";
});

function speak(text) {
  if (!soundEnabled) return;
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.rate = 1.0;
  speechSynthesis.speak(utterance);
}

async function setupCamera() {
  const stream = await navigator.mediaDevices.getUserMedia({ video: true });
  videoElement.srcObject = stream;
  return new Promise(resolve => {
    videoElement.onloadedmetadata = () => resolve(videoElement);
  });
}

const pose = new Pose({
  locateFile: file => `https://cdn.jsdelivr.net/npm/@mediapipe/pose/${file}`
});

pose.setOptions({
  modelComplexity: 1,
  smoothLandmarks: true,
  enableSegmentation: false,
  minDetectionConfidence: 0.5,
  minTrackingConfidence: 0.5
});

// --- Improved onResults: per-landmark coloring and better TTS ---
let lastTTS = 0;
const TTS_INTERVAL = 5; // seconds
let lastSpokenFeedback = "";
let correctPoseCount = 0;

pose.onResults(results => {
  canvasCtx.save();
  canvasCtx.clearRect(0, 0, canvasElement.width, canvasElement.height);
  // Mirror horizontally
  canvasCtx.translate(canvasElement.width, 0);
  canvasCtx.scale(-1, 1);
  canvasCtx.drawImage(results.image, 0, 0, canvasElement.width, canvasElement.height);

  if (results.poseLandmarks) {
    // Analyze pose for feedback and per-body-part status
    const { feedback, bodyPartStatus, landmarkToBodyPart } = analyzeChildPose(results.poseLandmarks, canvasElement.height);

    // Draw connectors as before
    drawConnectors(canvasCtx, results.poseLandmarks, POSE_CONNECTIONS, {
      color: "#ffffff", lineWidth: 2
    });

    // Draw landmarks with per-body-part coloring using tolerance logic
    for (let i = 0; i < results.poseLandmarks.length; ++i) {
      const lm = results.poseLandmarks[i];
      if (!lm || lm.visibility <= 0.1) continue;
      let color = "#00ff00";
      if (landmarkToBodyPart[i]) {
        for (const part of landmarkToBodyPart[i]) {
          // Use the same tolerance logic as feedback
          let outOfTolerance = false;
          if (part === 'knee_flexion') {
            const leftKneeAngle = calculateAngle(results.poseLandmarks[23], results.poseLandmarks[25], results.poseLandmarks[27]);
            const rightKneeAngle = calculateAngle(results.poseLandmarks[24], results.poseLandmarks[26], results.poseLandmarks[28]);
            const avgKneeAngle = (leftKneeAngle + rightKneeAngle) / 2;
            if (avgKneeAngle < 10 - 15 || avgKneeAngle > 35 + 15) outOfTolerance = true;
          } else if (part === 'hip_heel_contact') {
            const hipCenter = midpoint(results.poseLandmarks[23], results.poseLandmarks[24]);
            const heelCenter = midpoint(results.poseLandmarks[29], results.poseLandmarks[30]);
            const hipHeelDistance = calculateDistance(hipCenter, heelCenter);
            if (hipHeelDistance > 0.12 + 0.06) outOfTolerance = true;
          } else if (part === 'torso_fold') {
            const shoulderCenter = midpoint(results.poseLandmarks[11], results.poseLandmarks[12]);
            const kneePositions = [results.poseLandmarks[25], results.poseLandmarks[26]];
            const torsoThighDistance = checkTorsoThighContact(shoulderCenter, kneePositions);
            if (torsoThighDistance > 0.15 + 0.08) outOfTolerance = true;
          } else if (part === 'head_position') {
            const NOSE = results.poseLandmarks[0];
            const hipCenter = midpoint(results.poseLandmarks[23], results.poseLandmarks[24]);
            if (!(NOSE.y > hipCenter.y)) outOfTolerance = true;
          } else if (part === 'spine_curve') {
            const NOSE = results.poseLandmarks[0];
            const shoulderCenter = midpoint(results.poseLandmarks[11], results.poseLandmarks[12]);
            const hipCenter = midpoint(results.poseLandmarks[23], results.poseLandmarks[24]);
            const spineCurve = calculateSpineCurvature(NOSE, shoulderCenter, hipCenter);
            if (spineCurve < 40 - 25 || spineCurve > 120 + 25) outOfTolerance = true;
          } else if (part === 'shoulder_relaxation') {
            const shoulderDiff = Math.abs(results.poseLandmarks[11].y - results.poseLandmarks[12].y);
            if (shoulderDiff > 0.06 + 0.04) outOfTolerance = true;
          } else if (part === 'arm_position') {
            const leftArm = calculateDistance(results.poseLandmarks[11], results.poseLandmarks[15]);
            const rightArm = calculateDistance(results.poseLandmarks[12], results.poseLandmarks[16]);
            const armRelaxation = (leftArm + rightArm) / 2;
            if (armRelaxation > 0.2 + 0.08) outOfTolerance = true;
          }
          if (outOfTolerance) {
            color = "#ff0000";
            break;
          }
        }
      }
      canvasCtx.beginPath();
      canvasCtx.arc(lm.x * canvasElement.width, lm.y * canvasElement.height, 4, 0, 2 * Math.PI);
      canvasCtx.fillStyle = color;
      canvasCtx.fill();
      canvasCtx.lineWidth = 2;
      canvasCtx.strokeStyle = "#fff";
      canvasCtx.stroke();
    }

    // Show feedback
    if (feedback.length > 0) {
      feedbackElement.innerHTML = feedback.join("<br>");
      // Speak only if enough time has passed and feedback changed
      const now = Date.now() / 1000;
      if (soundEnabled && (now - lastTTS > TTS_INTERVAL) && feedback[0] !== lastSpokenFeedback) {
        speak(feedback[0]);
        lastTTS = now;
        lastSpokenFeedback = feedback[0];
      }
    } else {
      // Progressive positive feedback
      correctPoseCount = (lastSpokenFeedback && lastSpokenFeedback.startsWith('Good pose')) || lastSpokenFeedback === "You're doing great!" || lastSpokenFeedback === "Excellent! Keep going." ? correctPoseCount + 1 : 1;
      let goodMsg = "Good pose!";
      if (correctPoseCount >= 3 && correctPoseCount < 6) {
        goodMsg = "You're doing great!";
      } else if (correctPoseCount >= 6) {
        goodMsg = "Excellent! Keep going.";
      }
      const breathMsg = "Now take slow, deep breaths. Inhale through your nose, exhale gently, and relax your body in this posture.";
      feedbackElement.innerHTML = goodMsg + "<br>" + breathMsg;
      // Speak both messages together if enough time has passed or the message changed
      const now = Date.now() / 1000;
      if (soundEnabled && (now - lastTTS > TTS_INTERVAL) && lastSpokenFeedback !== goodMsg) {
        speak(goodMsg + ' ' + breathMsg);
        lastTTS = now;
        lastSpokenFeedback = goodMsg;
      }
    }
  } else {
    feedbackElement.innerText = "No person detected.";
    lastSpokenFeedback = "";
    correctPoseCount = 0;
  }
  canvasCtx.restore();
});


// Ensure video and canvas are the same size
videoElement.width = 480;
videoElement.height = 360;
canvasElement.width = 480;
canvasElement.height = 360;

let lastFeedback = "";

async function detectionLoop() {
  if (videoElement.readyState >= 2) {
    await pose.send({ image: videoElement });
  }
  requestAnimationFrame(detectionLoop);
}

setupCamera().then(() => {
  videoElement.play();
  detectionLoop();
}).catch(err => {
  feedbackElement.innerText = "Webcam access denied or not available.";
});
