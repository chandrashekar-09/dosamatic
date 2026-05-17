#include <WiFi.h>
#include <ArduinoJson.h>
#include <FastAccelStepper.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <ctype.h>
#include <math.h>
#include <FS.h>
#include <LittleFS.h>
#include <GCodeParser.h>
#if defined(ARDUINO_ARCH_ESP32)
#include <esp32-hal-ledc.h>
#endif

#include "OtaService.h"

const char* ssid = "IIIT-Guest";
const char* password = "f6s68VHJ89mC";

// const char* ssid = "MADHU";
// const char* password = "6303852931";

const int CURRENT_VERSION = 9;
const char* versionUrl = "https://raw.githubusercontent.com/chandrashekar-09/dosamatic/main/var.txt";
const char* firmwareUrl = "https://raw.githubusercontent.com/chandrashekar-09/dosamatic/main/firmware.bin";
const char* deviceId = "test-006";

// Firebase Realtime Database endpoint (write-once at boot)
// Example: https://<project-id>-default-rtdb.<region>.firebasedatabase.app/boot_ack
// Device data will be written to: <base>/<device_id>.json
const char* firebaseBootAckBaseUrl = nullptr;
// Optional database secret/token if your DB rules require auth.
// Leave empty string if your rules allow write for this specific path.
const char* firebaseAuthToken = "";

const OtaConfig otaConfig = {
	CURRENT_VERSION,
	versionUrl,
	firmwareUrl,
	deviceId,
	firebaseBootAckBaseUrl,
	firebaseAuthToken,
};

#define STEP1_PIN 32
#define DIR1_PIN  33
#define LIM1_PIN  16 // change to 16 after testing 

#define STEP2_PIN 25
#define DIR2_PIN  26
#define LIM2_PIN  17

#define STEP3_PIN 27
#define DIR3_PIN  14
#define LIM3_PIN  19

#define DC_PWM_PIN 12
#define DC_DIR_PIN 13

FastAccelStepperEngine engine = FastAccelStepperEngine();
FastAccelStepper* stepper1 = nullptr;
FastAccelStepper* stepper2 = nullptr;
FastAccelStepper* stepper3 = nullptr;

WebServer server(80);

enum SystemState { HOMING, WAITING, READY, MOVING };
SystemState currentState = HOMING;

enum HomingPhase { HOMING_SEEK, HOMING_BACKOFF, HOMING_DONE };

const long HOMING_TARGET = -1000000;
const long HOMING_BACKOFF_STEPS = 400;
const long HOMING_SEEK_SPEED = 300;
const unsigned long HOMING_SWITCH_DEBOUNCE_MS = 20;
const unsigned long WAIT_DELAY_MS = 3000;
const unsigned long WIFI_CONNECT_TIMEOUT_MS = 15000;
const unsigned long WIFI_RECONNECT_INTERVAL_MS = 5000;
const unsigned long PLANNER_INTERVAL_US = 1000;

const long MIN_LIMIT_STEPS = 100;
const long MAX_LIMIT_STEPS = 250000;
const long MIN_FEED_STEPS_PER_SEC = 100;
const long MAX_FEED_STEPS_PER_SEC = 12000;
const float MIN_SEGMENT_EXEC_STEPS = 0.25f;
const float MIN_LOOKAHEAD_SEGMENT_STEPS = 2.0f;
const float MIN_CORNER_SPEED = 250.0f;
const float MIN_JUNCTION_DEV = 0.001f;
const float MAX_JUNCTION_DEV = 20.0f;
const float ARC_CHORD_ERROR_STEPS = 0.25f;
const float ARC_MAX_SEG_LEN = 120.0f;
const int ARC_MAX_SEGMENTS = 720;
const int MAX_GCODE_LINE = 240;
const size_t MAX_UPLOAD_BYTES = 300000;
const float INCH_TO_MM = 25.4f;

long maxLimit1 = 14000;
long maxLimit2 = 15000;
long maxLimit3 = 15000;

long maxSpeed1 = 12000;
long maxSpeed2 = 12000;
long maxSpeed3 = 12000;
long axisAcceleration = 45000;
float pathAcceleration = 18000.0f;
float junctionDeviation = 1.20f;

const int DC_PWM_FREQ = 20000;
const int DC_PWM_RES = 8;
const int DC_PWM_CH = 0;
int dcPwm = 0;
int dcDirection = 1;

bool s1Homed = false;
bool s2Homed = false;
bool s3Homed = false;
HomingPhase s1Phase = HOMING_SEEK;
HomingPhase s2Phase = HOMING_SEEK;
HomingPhase s3Phase = HOMING_SEEK;
unsigned long s1DebounceStart = 0;
unsigned long s2DebounceStart = 0;
unsigned long s3DebounceStart = 0;
unsigned long waitStartTime = 0;
bool plannerCommandInitialized = false;
long lastPlannerTargetX = 0;
long lastPlannerTargetY = 0;
long lastPlannerTargetZ = 0;
bool axisProfileInitialized = false;
float lastAxisSpeed1 = 0.0f;
float lastAxisSpeed2 = 0.0f;
float lastAxisSpeed3 = 0.0f;

unsigned long lastPlannerUs = 0;
unsigned long lastWiFiReconnectAttempt = 0;
bool mdnsStarted = false;
bool gcodeAbsoluteMode = true;
long gcodeModalFeed = 1200;
bool spindleEnabled = false;
unsigned long gcodeAcceptedLines = 0;
unsigned long dwellUntilMs = 0;
bool gcodeMetricUnits = true;
float gcodeUnitsScale = 1.0f;
unsigned long pendingDwellMs = 0;
bool dwellPending = false;

GCodeParser gcodeParser;

File gcodeFile;
String gcodeLine;
bool fileRunning = false;
String runningFile;
String fileError;
bool lastUploadOk = true;
String lastUploadError;
File uploadFile;
size_t uploadBytes = 0;
String uploadName;
bool storageMounted = false;

void stopFileRunner(bool clearError);

struct Waypoint {
	long x;
	long y;
	long z;
	long feed;
};

const int MAX_WAYPOINTS = 180;
Waypoint queueBuffer[MAX_WAYPOINTS];
int queueHead = 0;
int queueTail = 0;
int queueCount = 0;

struct ActiveSegment {
	bool active;
	float sx;
	float sy;
	float sz;
	float ex;
	float ey;
	float ez;
	float dx;
	float dy;
	float dz;
	float length;
	float progress;
	float feed;
};

ActiveSegment segment = {false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
float plannerX = 0;
float plannerY = 0;
float plannerZ = 0;
float pathSpeed = 0;
void setDcPwm(int pwm) {
	int clamped = pwm;
	if (clamped < 0) clamped = 0;
	if (clamped > 255) clamped = 255;
	dcPwm = clamped;
	digitalWrite(DC_DIR_PIN, dcDirection > 0 ? HIGH : LOW);

#ifndef ESP_ARDUINO_VERSION_MAJOR
#define ESP_ARDUINO_VERSION_MAJOR 2
#endif
#if ESP_ARDUINO_VERSION_MAJOR >= 3
	ledcWriteChannel(DC_PWM_CH, dcPwm);
#else
	ledcWrite(DC_PWM_CH, dcPwm);
#endif
}

void setDcMotor(int speed) {
	int clamped = speed;
	if (clamped < -255) clamped = -255;
	if (clamped > 255) clamped = 255;
	dcDirection = clamped >= 0 ? 1 : -1;
	setDcPwm(abs(clamped));
}

void initDcPwm() {
#ifndef ESP_ARDUINO_VERSION_MAJOR
#define ESP_ARDUINO_VERSION_MAJOR 2
#endif
	pinMode(DC_DIR_PIN, OUTPUT);
	digitalWrite(DC_DIR_PIN, HIGH);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
	ledcAttachChannel(DC_PWM_PIN, DC_PWM_FREQ, DC_PWM_RES, DC_PWM_CH);
#else
	ledcSetup(DC_PWM_CH, DC_PWM_FREQ, DC_PWM_RES);
	ledcAttachPin(DC_PWM_PIN, DC_PWM_CH);
#endif
}

String sanitizeFilename(const String& name) {
	String base = name;
	int slash = base.lastIndexOf('/');
	if (slash >= 0) base = base.substring(slash + 1);
	slash = base.lastIndexOf('\\');
	if (slash >= 0) base = base.substring(slash + 1);
	base.trim();

	String clean = "";
	for (int i = 0; i < base.length() && clean.length() < 48; i++) {
		char c = base[i];
		bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
				  (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
		if (ok) {
			clean += c;
		} else if (c == ' ') {
			clean += '_';
		}
	}

	clean.replace("..", ".");
	if (clean.length() == 0 || clean == "." || clean == "..") {
		clean = "job.gco";
	}
	if (clean.indexOf('.') < 0) {
		clean += ".gco";
	}
	if (!clean.startsWith("/")) clean = "/" + clean;
	return clean;
}

bool mountStorage(bool formatOnFail) {
	if (storageMounted) return true;
	if (LittleFS.begin(false)) {
		storageMounted = true;
		return true;
	}

	Serial.println("LittleFS mount failed");
	if (!formatOnFail) {
		return false;
	}

	Serial.println("Formatting LittleFS...");
	LittleFS.end();
	if (!LittleFS.format()) {
		Serial.println("LittleFS format failed");
		storageMounted = false;
		return false;
	}
	if (!LittleFS.begin(false)) {
		Serial.println("LittleFS remount failed after format");
		storageMounted = false;
		return false;
	}
	storageMounted = true;
	Serial.println("LittleFS ready after format");
	return true;
}

bool ensureStorageReady() {
	return storageMounted || mountStorage(false);
}

bool formatStorage() {
	stopFileRunner(true);
	if (uploadFile) uploadFile.close();
	storageMounted = false;
	LittleFS.end();
	if (!LittleFS.format()) {
		return false;
	}
	return mountStorage(false);
}


float clampf(float value, float low, float high) {
	if (value < low) return low;
	if (value > high) return high;
	return value;
}

long clampTarget(long value, long limit) {
	if (value < 0) return 0;
	if (value > limit) return limit;
	return value;
}

float applyGcodeUnits(float value) {
	return value * gcodeUnitsScale;
}

void updateGcodeUnits(bool metric) {
	gcodeMetricUnits = metric;
	gcodeUnitsScale = metric ? 1.0f : INCH_TO_MM;
}

const char* stateToString(SystemState state) {
	switch (state) {
		case HOMING: return "HOMING";
		case WAITING: return "WAITING";
		case READY: return "READY";
		case MOVING: return "MOVING";
		default: return "UNKNOWN";
	}
}

void clearQueue() {
	queueHead = 0;
	queueTail = 0;
	queueCount = 0;
}

bool enqueueWaypoint(const Waypoint& point) {
	if (queueCount >= MAX_WAYPOINTS) return false;
	queueBuffer[queueTail] = point;
	queueTail = (queueTail + 1) % MAX_WAYPOINTS;
	queueCount++;
	return true;
}

bool dequeueWaypoint(Waypoint& point) {
	if (queueCount <= 0) return false;
	point = queueBuffer[queueHead];
	queueHead = (queueHead + 1) % MAX_WAYPOINTS;
	queueCount--;
	return true;
}

bool peekWaypoint(Waypoint& point) {
	if (queueCount <= 0) return false;
	point = queueBuffer[queueHead];
	return true;
}

bool isValidLimit(long value) {
	return value >= MIN_LIMIT_STEPS && value <= MAX_LIMIT_STEPS;
}

bool isValidFeed(long value) {
	return value >= MIN_FEED_STEPS_PER_SEC && value <= MAX_FEED_STEPS_PER_SEC;
}


String stripGcodeComments(const String& input) {
	String line = input;
	int semicolon = line.indexOf(';');
	if (semicolon >= 0) {
		line = line.substring(0, semicolon);
	}

	while (true) {
		int start = line.indexOf('(');
		if (start < 0) break;
		int end = line.indexOf(')', start);
		if (end < 0) {
			line = line.substring(0, start);
			break;
		}
		line.remove(start, end - start + 1);
	}

	line.trim();
	line.toUpperCase();
	return line;
}

bool extractWordValue(const String& line, char code, float& outValue) {
	int idx = line.indexOf(code);
	if (idx < 0 || idx + 1 >= line.length()) return false;

	int start = idx + 1;
	int end = start;
	while (end < line.length()) {
		char c = line[end];
		bool part = (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.';
		if (!part) break;
		end++;
	}

	if (end == start) return false;
	String token = line.substring(start, end);
	outValue = token.toFloat();
	return true;
}

void getPlannerReferencePosition(float& x, float& y, float& z) {
	if (queueCount > 0) {
		int lastIndex = (queueTail - 1 + MAX_WAYPOINTS) % MAX_WAYPOINTS;
		x = queueBuffer[lastIndex].x;
		y = queueBuffer[lastIndex].y;
		z = queueBuffer[lastIndex].z;
		return;
	}

	if (segment.active) {
		x = segment.ex;
		y = segment.ey;
		z = segment.ez;
		return;
	}

	x = plannerX;
	y = plannerY;
	z = plannerZ;
}

int computeArcSegments(float radius, float sweep) {
	float absSweep = fabsf(sweep);
	if (radius <= 0.0f || absSweep <= 0.0f) return 1;

	float maxAngle = 2.0f * acosf(fmaxf(0.0f, 1.0f - (ARC_CHORD_ERROR_STEPS / radius)));
	float maxAngleByLen = ARC_MAX_SEG_LEN / radius;
	float stepAngle = fminf(maxAngle, maxAngleByLen);
	if (stepAngle < 0.001f || !isfinite(stepAngle)) stepAngle = 0.001f;

	int segs = (int)ceilf(absSweep / stepAngle);
	if (segs < 1) segs = 1;
	if (segs > ARC_MAX_SEGMENTS) segs = ARC_MAX_SEGMENTS;
	return segs;
}

float computeArcSweep(float startAngle, float endAngle, bool clockwise) {
	float sweep = endAngle - startAngle;
	if (clockwise) {
		if (sweep >= 0.0f) sweep -= 2.0f * (float)PI;
	} else {
		if (sweep <= 0.0f) sweep += 2.0f * (float)PI;
	}
	return sweep;
}

bool computeCenterFromR(float startX, float startY,
						float endX, float endY,
						float radius,
						bool clockwise,
						bool largeArc,
						float& outCx, float& outCy) {
	float dx = endX - startX;
	float dy = endY - startY;
	float chord = hypotf(dx, dy);
	if (chord < 0.0001f) return false;
	float r = fabsf(radius);
	if (chord > 2.0f * r) return false;

	float mx = (startX + endX) * 0.5f;
	float my = (startY + endY) * 0.5f;
	float h = sqrtf(fmaxf(0.0f, r * r - (chord * 0.5f) * (chord * 0.5f)));
	float ux = -dy / chord;
	float uy = dx / chord;

	float cx1 = mx + ux * h;
	float cy1 = my + uy * h;
	float cx2 = mx - ux * h;
	float cy2 = my - uy * h;

	float a1s = atan2f(startY - cy1, startX - cx1);
	float a1e = atan2f(endY - cy1, endX - cx1);
	float sweep1 = computeArcSweep(a1s, a1e, clockwise);
	bool large1 = fabsf(sweep1) > (float)PI;

	float a2s = atan2f(startY - cy2, startX - cx2);
	float a2e = atan2f(endY - cy2, endX - cx2);
	float sweep2 = computeArcSweep(a2s, a2e, clockwise);
	bool large2 = fabsf(sweep2) > (float)PI;

	if (large1 == largeArc) {
		outCx = cx1;
		outCy = cy1;
		return true;
	}
	if (large2 == largeArc) {
		outCx = cx2;
		outCy = cy2;
		return true;
	}

	outCx = cx1;
	outCy = cy1;
	return true;
}

bool enqueueArc(bool clockwise,
				float startX, float startY, float startZ,
				float endX, float endY, float endZ,
				float centerX, float centerY,
				long feed,
				String& error) {
	float radius = hypotf(startX - centerX, startY - centerY);
	if (radius <= 0.001f) {
		error = "arc_radius_small";
		return false;
	}

	float startAngle = atan2f(startY - centerY, startX - centerX);
	float endAngle = atan2f(endY - centerY, endX - centerX);
	float sweep = computeArcSweep(startAngle, endAngle, clockwise);

	int segs = computeArcSegments(radius, sweep);
	int available = MAX_WAYPOINTS - queueCount;
	if (available <= 0) {
		error = "queue_full";
		return false;
	}
	if (segs > available) segs = available;
	for (int i = 1; i <= segs; i++) {
		float t = (float)i / (float)segs;
		float angle = startAngle + sweep * t;
		float x = centerX + radius * cosf(angle);
		float y = centerY + radius * sinf(angle);
		float z = startZ + (endZ - startZ) * t;

		Waypoint point;
		point.x = clampTarget(lroundf(x), maxLimit1);
		point.y = clampTarget(lroundf(y), maxLimit2);
		point.z = clampTarget(lroundf(z), maxLimit3);
		point.feed = feed;

		if (!enqueueWaypoint(point)) {
			error = "queue_full";
			return false;
		}
	}

	return true;
}

bool parseAndQueueGcodeLine(const String& rawLine, String& error) {
	if (rawLine.length() > MAX_GCODE_LINE) {
		error = "line_too_long";
		return false;
	}
	String trimmed = rawLine;
	trimmed.trim();
	if (trimmed.length() == 0) {
		return true;
	}
	char buf[MAX_GCODE_LINE + 2];
	trimmed.toCharArray(buf, sizeof(buf));
	gcodeParser.ParseLine(buf);
	if (gcodeParser.NoWords()) {
		return true;
	}

	if (gcodeParser.HasWord('G')) {
		int g_cmd = (int)gcodeParser.GetWordValue('G');
		switch (g_cmd) {
			case 90: gcodeAbsoluteMode = true; break;
			case 91: gcodeAbsoluteMode = false; break;
			case 20: updateGcodeUnits(false); break;
			case 21: updateGcodeUnits(true); break;
			case 4: // G4 P<ms>
				if (gcodeParser.HasWord('P')) {
					pendingDwellMs = (unsigned long)lroundf(gcodeParser.GetWordValue('P'));
					dwellPending = pendingDwellMs > 0;
				}
				return true;
		}
	}

	if (gcodeParser.HasWord('M')) {
		int m_cmd = (int)gcodeParser.GetWordValue('M');
		if (m_cmd == 3 || m_cmd == 30) {
			spindleEnabled = true;
			if (gcodeParser.HasWord('S')) {
				setDcPwm((int)lroundf(gcodeParser.GetWordValue('S')));
			}
		} else if (m_cmd == 5 || m_cmd == 50) {
			spindleEnabled = false;
			setDcPwm(0);
		}
	}

	bool hasLinearWord = gcodeParser.HasWord('G') && (gcodeParser.GetWordValue('G') == 0 || gcodeParser.GetWordValue('G') == 1);
	bool hasArcWord = gcodeParser.HasWord('G') && (gcodeParser.GetWordValue('G') == 2 || gcodeParser.GetWordValue('G') == 3);

	if (!hasLinearWord && !hasArcWord) {
		if (gcodeParser.HasWord('F')) {
			long parsedFeed = lroundf(applyGcodeUnits(gcodeParser.GetWordValue('F')));
			if (!isValidFeed(parsedFeed)) {
				error = "feed_out_of_range";
				return false;
			}
			gcodeModalFeed = parsedFeed;
		}
		// Allow feed-only lines and non-motion modal commands.
		if (gcodeParser.HasWord('F')) return true;
		if (gcodeParser.HasWord('G') || gcodeParser.HasWord('M')) return true;
		error = "unsupported_command";
		return false;
	}

	bool hasX = gcodeParser.HasWord('X');
	bool hasY = gcodeParser.HasWord('Y');
	bool hasZ = gcodeParser.HasWord('Z');
	bool hasF = gcodeParser.HasWord('F');
	bool hasI = gcodeParser.HasWord('I');
	bool hasJ = gcodeParser.HasWord('J');
	bool hasR = gcodeParser.HasWord('R');

	float fx = hasX ? (float)gcodeParser.GetWordValue('X') : 0.0f;
	float fy = hasY ? (float)gcodeParser.GetWordValue('Y') : 0.0f;
	float fz = hasZ ? (float)gcodeParser.GetWordValue('Z') : 0.0f;
	float ff = hasF ? (float)gcodeParser.GetWordValue('F') : 0.0f;
	float fi = hasI ? (float)gcodeParser.GetWordValue('I') : 0.0f;
	float fj = hasJ ? (float)gcodeParser.GetWordValue('J') : 0.0f;
	float fr = hasR ? (float)gcodeParser.GetWordValue('R') : 0.0f;

	if (hasF) {
		long parsedFeed = lroundf(applyGcodeUnits(ff));
		if (!isValidFeed(parsedFeed)) {
			error = "feed_out_of_range";
			return false;
		}
		gcodeModalFeed = parsedFeed;
	}

	if (!hasX && !hasY && !hasZ && !hasArcWord) {
		return true;
	}

	float refX = 0;
	float refY = 0;
	float refZ = 0;
	getPlannerReferencePosition(refX, refY, refZ);

	float targetX = refX;
	float targetY = refY;
	float targetZ = refZ;

	if (gcodeAbsoluteMode) {
		if (hasX) targetX = applyGcodeUnits(fx);
		if (hasY) targetY = applyGcodeUnits(fy);
		if (hasZ) targetZ = applyGcodeUnits(fz);
	} else {
		if (hasX) targetX = refX + applyGcodeUnits(fx);
		if (hasY) targetY = refY + applyGcodeUnits(fy);
		if (hasZ) targetZ = refZ + applyGcodeUnits(fz);
	}

	if (hasArcWord) {
		if (!hasI && !hasJ && !hasR) {
			error = "arc_center_missing";
			return false;
		}
		bool clockwise = gcodeParser.GetWordValue('G') == 2;
		float centerX = 0.0f;
		float centerY = 0.0f;
		if (hasI || hasJ) {
			centerX = refX + applyGcodeUnits(hasI ? fi : 0.0f);
			centerY = refY + applyGcodeUnits(hasJ ? fj : 0.0f);
		} else {
			bool largeArc = fr < 0.0f;
			float radius = applyGcodeUnits(fr);
			if (!computeCenterFromR(refX, refY, targetX, targetY, radius, clockwise, largeArc, centerX, centerY)) {
				error = "arc_radius_invalid";
				return false;
			}
		}
		if (!enqueueArc(clockwise, refX, refY, refZ, targetX, targetY, targetZ, centerX, centerY, gcodeModalFeed, error)) {
			return false;
		}
		gcodeAcceptedLines++;
		return true;
	}

	Waypoint point;
	point.x = clampTarget(lroundf(targetX), maxLimit1);
	point.y = clampTarget(lroundf(targetY), maxLimit2);
	point.z = clampTarget(lroundf(targetZ), maxLimit3);
	point.feed = gcodeModalFeed;

	if (!enqueueWaypoint(point)) {
		error = "queue_full";
		return false;
	}

	gcodeAcceptedLines++;
	return true;
}

void stopFileRunner(bool clearError = false) {
	fileRunning = false;
	if (gcodeFile) gcodeFile.close();
	runningFile = "";
	gcodeLine = "";
	if (clearError) fileError = "";
}

void startFileRunner(const String& filename) {
	if (!ensureStorageReady()) {
		fileError = "storage_unavailable";
		fileRunning = false;
		return;
	}
	String clean = sanitizeFilename(filename);
	if (gcodeFile) gcodeFile.close();
	gcodeFile = LittleFS.open(clean, "r");
	if (!gcodeFile) {
		fileError = "file_open_failed";
		fileRunning = false;
		return;
	}
	runningFile = clean;
	fileError = "";
	gcodeLine = "";
	gcodeAcceptedLines = 0;
	fileRunning = true;
}

void updateDwellState() {
	if (dwellUntilMs > 0) {
		if (millis() >= dwellUntilMs) {
			dwellUntilMs = 0;
		}
		return;
	}
	if (dwellPending && !segment.active && queueCount == 0) {
		dwellUntilMs = millis() + pendingDwellMs;
		dwellPending = false;
	}
}

void serviceFileRunner() {
	if (!fileRunning) return;
	updateDwellState();
	if (dwellPending) return;
	if (dwellUntilMs > millis()) return;
	if (!gcodeFile) {
		stopFileRunner();
		return;
	}

	int targetFree = MAX_WAYPOINTS - 10;
	while (queueCount < targetFree && gcodeFile.available()) {
		int c = gcodeFile.read();
		if (c < 0) break;
		if (c == '\r') continue;
		if (c == '\n') {
			if (gcodeLine.length() > 0) {
				String error;
				if (!parseAndQueueGcodeLine(gcodeLine, error)) {
					if (error == "queue_full") break;
					if (error.length() == 0) error = "parse_error";
					Serial.printf("FILE: reject line: %s | err=%s\n", gcodeLine.c_str(), error.c_str());
					fileError = error;
					stopFileRunner();
					return;
				}
				if (dwellPending) break;
				gcodeLine = "";
			}
			continue;
		}
		if (gcodeLine.length() >= MAX_GCODE_LINE) {
			fileError = "line_too_long";
			stopFileRunner();
			return;
		}
		gcodeLine += (char)c;
	}

	if (!gcodeFile.available() && gcodeLine.length() > 0) {
		String error;
		if (!parseAndQueueGcodeLine(gcodeLine, error)) {
			if (error != "queue_full") {
				if (error.length() == 0) error = "parse_error";
				Serial.printf("FILE: reject line: %s | err=%s\n", gcodeLine.c_str(), error.c_str());
				fileError = error;
				stopFileRunner();
				return;
			}
		} else {
			gcodeLine = "";
		}
	}

	if (!gcodeFile.available() && gcodeLine.length() == 0) {
		stopFileRunner();
	}
}

void applyAxisProfile(float requestedFeed) {
	float f1 = clampf(requestedFeed, MIN_FEED_STEPS_PER_SEC, maxSpeed1);
	float f2 = clampf(requestedFeed, MIN_FEED_STEPS_PER_SEC, maxSpeed2);
	float f3 = clampf(requestedFeed, MIN_FEED_STEPS_PER_SEC, maxSpeed3);
	if (stepper1 && (!axisProfileInitialized || fabsf(f1 - lastAxisSpeed1) >= 0.5f)) {
		stepper1->setSpeedInHz(f1);
		lastAxisSpeed1 = f1;
	}
	if (stepper2 && (!axisProfileInitialized || fabsf(f2 - lastAxisSpeed2) >= 0.5f)) {
		stepper2->setSpeedInHz(f2);
		lastAxisSpeed2 = f2;
	}
	if (stepper3 && (!axisProfileInitialized || fabsf(f3 - lastAxisSpeed3) >= 0.5f)) {
		stepper3->setSpeedInHz(f3);
		lastAxisSpeed3 = f3;
	}
	axisProfileInitialized = true;
}

void commandPlannerPosition() {
	long targetX = lroundf(plannerX);
	long targetY = lroundf(plannerY);
	long targetZ = lroundf(plannerZ);

	if (stepper1 && (!plannerCommandInitialized || targetX != lastPlannerTargetX)) {
		stepper1->moveTo(targetX);
	}
	if (stepper2 && (!plannerCommandInitialized || targetY != lastPlannerTargetY)) {
		stepper2->moveTo(targetY);
	}
	if (stepper3 && (!plannerCommandInitialized || targetZ != lastPlannerTargetZ)) {
		stepper3->moveTo(targetZ);
	}

	lastPlannerTargetX = targetX;
	lastPlannerTargetY = targetY;
	lastPlannerTargetZ = targetZ;
	plannerCommandInitialized = true;
}

float computeJunctionSpeed(const ActiveSegment& current, const Waypoint& nextPoint) {
	float n1x = current.dx / current.length;
	float n1y = current.dy / current.length;
	float n1z = current.dz / current.length;

	float nx = (float)clampTarget(nextPoint.x, maxLimit1) - current.ex;
	float ny = (float)clampTarget(nextPoint.y, maxLimit2) - current.ey;
	float nz = (float)clampTarget(nextPoint.z, maxLimit3) - current.ez;
	float n2len = sqrtf(nx * nx + ny * ny + nz * nz);

	if (n2len < MIN_LOOKAHEAD_SEGMENT_STEPS) return MIN_CORNER_SPEED;

	float n2x = nx / n2len;
	float n2y = ny / n2len;
	float n2z = nz / n2len;

	float dot = n1x * n2x + n1y * n2y + n1z * n2z;
	dot = clampf(dot, -1.0f, 1.0f);

	float maxJunction = min((float)current.feed, (float)nextPoint.feed);
	float sinHalf = sqrtf(0.5f * (1.0f + dot));
	if (sinHalf > 0.999f) {
		return maxJunction;
	}
	if (sinHalf < 0.0001f) {
		return MIN_CORNER_SPEED;
	}

	float v = sqrtf((pathAcceleration * junctionDeviation * sinHalf) / (1.0f - sinHalf));
	return clampf(v, MIN_CORNER_SPEED, maxJunction);
}

bool startNextSegment() {
	Waypoint next;
	while (dequeueWaypoint(next)) {
		float ex = (float)clampTarget(next.x, maxLimit1);
		float ey = (float)clampTarget(next.y, maxLimit2);
		float ez = (float)clampTarget(next.z, maxLimit3);

		float dx = ex - plannerX;
		float dy = ey - plannerY;
		float dz = ez - plannerZ;
		float len = sqrtf(dx * dx + dy * dy + dz * dz);

		if (len < MIN_SEGMENT_EXEC_STEPS) {
			plannerX = ex;
			plannerY = ey;
			plannerZ = ez;
			commandPlannerPosition();
			continue;
		}

		segment.active = true;
		segment.sx = plannerX;
		segment.sy = plannerY;
		segment.sz = plannerZ;
		segment.ex = ex;
		segment.ey = ey;
		segment.ez = ez;
		segment.dx = dx;
		segment.dy = dy;
		segment.dz = dz;
		segment.length = len;
		segment.progress = 0.0f;
		segment.feed = clampf((float)next.feed, MIN_FEED_STEPS_PER_SEC, MAX_FEED_STEPS_PER_SEC);
		applyAxisProfile(segment.feed);
		return true;
	}

	segment.active = false;
	return false;
}

void stopAllMotion() {
	clearQueue();
	segment.active = false;
	pathSpeed = 0;
	dwellPending = false;
	pendingDwellMs = 0;
	dwellUntilMs = 0;
	if (stepper1) stepper1->stopMove();
	if (stepper2) stepper2->stopMove();
	if (stepper3) stepper3->stopMove();
	plannerX = stepper1 ? stepper1->getCurrentPosition() : 0;
	plannerY = stepper2 ? stepper2->getCurrentPosition() : 0;
	plannerZ = stepper3 ? stepper3->getCurrentPosition() : 0;
	commandPlannerPosition();
	currentState = READY;
}

void plannerTick(float dt) {
	if (dwellUntilMs > millis()) {
		if (!segment.active) {
			return;
		}
	}
	if (dwellUntilMs > 0 && millis() >= dwellUntilMs) {
		dwellUntilMs = 0;
	}
	if (!segment.active) {
		if (startNextSegment()) {
			currentState = MOVING;
		} else if (currentState == MOVING) {
			currentState = READY;
			pathSpeed = 0;
		}
		return;
	}

	Waypoint peek;
	bool hasNext = peekWaypoint(peek);
	float junctionSpeed = 0.0f;
	if (hasNext) {
		junctionSpeed = computeJunctionSpeed(segment, peek);
	}

	float remaining = segment.length * (1.0f - segment.progress);
	float brakingDistance = 0.0f;
	if (pathSpeed > junctionSpeed) {
		brakingDistance = (pathSpeed * pathSpeed - junctionSpeed * junctionSpeed) / (2.0f * pathAcceleration);
	}

	float targetCruise = segment.feed;
	if (brakingDistance >= remaining) {
		pathSpeed -= pathAcceleration * dt;
		if (pathSpeed < junctionSpeed) pathSpeed = junctionSpeed;
	} else {
		pathSpeed += pathAcceleration * dt;
		if (pathSpeed > targetCruise) pathSpeed = targetCruise;
	}

	pathSpeed = clampf(pathSpeed, 0.0f, targetCruise);
	float advance = pathSpeed * dt;

	if (advance >= remaining) {
		plannerX = segment.ex;
		plannerY = segment.ey;
		plannerZ = segment.ez;
		commandPlannerPosition();

		segment.active = false;

		if (!startNextSegment()) {
			pathSpeed = 0;
			currentState = READY;
		}
		return;
	}

	segment.progress += advance / segment.length;
	segment.progress = clampf(segment.progress, 0.0f, 1.0f);

	plannerX = segment.sx + segment.dx * segment.progress;
	plannerY = segment.sy + segment.dy * segment.progress;
	plannerZ = segment.sz + segment.dz * segment.progress;
	commandPlannerPosition();
}

bool limitTriggered(int pin) {
	return digitalRead(pin) == LOW;
}

bool handleAxisHoming(FastAccelStepper* stepper, int limitPin, bool& homed, HomingPhase& phase, unsigned long& debounceStart) {
	if (!stepper) return false;

	switch (phase) {
		case HOMING_SEEK:
			if (limitTriggered(limitPin)) {
				if (debounceStart == 0) debounceStart = millis();
				if (millis() - debounceStart >= HOMING_SWITCH_DEBOUNCE_MS) {
					stepper->stopMove();
					stepper->setCurrentPosition(0);
					stepper->setSpeedInHz(HOMING_SEEK_SPEED);
					stepper->moveTo(HOMING_BACKOFF_STEPS);
					phase = HOMING_BACKOFF;
					debounceStart = 0;
				}
				return false;
			}
			debounceStart = 0;
			if (!stepper->isRunning()) {
				stepper->setSpeedInHz(HOMING_SEEK_SPEED);
				stepper->moveTo(HOMING_TARGET);
			}
			return false;

		case HOMING_BACKOFF:
			if (stepper->isRunning()) return false;
			stepper->setCurrentPosition(0);
			homed = true;
			phase = HOMING_DONE;
			return true;

		case HOMING_DONE:
		default:
			return true;
	}
}

void performHoming() {
	if (!stepper1 || !stepper2 || !stepper3) return;

	if (!s1Homed) {
		handleAxisHoming(stepper1, LIM1_PIN, s1Homed, s1Phase, s1DebounceStart);
	}
	if (!s2Homed) {
		handleAxisHoming(stepper2, LIM2_PIN, s2Homed, s2Phase, s2DebounceStart);
	}
	if (!s3Homed) {
		handleAxisHoming(stepper3, LIM3_PIN, s3Homed, s3Phase, s3DebounceStart);
	}

	if (!s1Homed || !s2Homed || !s3Homed) {
		return;
	}

	plannerX = 0;
	plannerY = 0;
	plannerZ = 0;
	commandPlannerPosition();
	pathSpeed = 0;
	waitStartTime = millis();
	currentState = WAITING;
	Serial.println("Homing complete");
}

void addCorsHeaders() {
	server.sendHeader("Access-Control-Allow-Origin", "*");
	server.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
	server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

void sendJsonResponse(int code, const String& body) {
	addCorsHeaders();
	server.send(code, "application/json", body);
}

void sendEmptyResponse(int code) {
	addCorsHeaders();
	server.send(code);
}

void handleOptions() {
	sendEmptyResponse(204);
}

void handleFileUpload() {
	HTTPUpload& upload = server.upload();
	if (upload.status == UPLOAD_FILE_START) {
		lastUploadOk = true;
		lastUploadError = "";
		uploadBytes = 0;
		uploadName = sanitizeFilename(upload.filename);
		if (!ensureStorageReady()) {
			lastUploadOk = false;
			lastUploadError = "storage_unavailable";
			Serial.println("UPLOAD: storage unavailable");
			return;
		}
		if (upload.totalSize > MAX_UPLOAD_BYTES) {
			lastUploadOk = false;
			lastUploadError = "file_too_large";
			Serial.println("UPLOAD: file too large");
			return;
		}
		if (LittleFS.exists(uploadName)) {
			LittleFS.remove(uploadName);
		}
		uploadFile = LittleFS.open(uploadName, "w");
		if (!uploadFile) {
			lastUploadOk = false;
			lastUploadError = "file_open_failed";
			Serial.println("UPLOAD: file open failed");
			return;
		}
	}

	if (upload.status == UPLOAD_FILE_WRITE) {
		if (!lastUploadOk) return;
		uploadBytes += upload.currentSize;
		if (uploadBytes > MAX_UPLOAD_BYTES) {
			lastUploadOk = false;
			lastUploadError = "file_too_large";
			Serial.println("UPLOAD: exceeded max size");
			if (uploadFile) uploadFile.close();
			if (uploadName.length() > 0) LittleFS.remove(uploadName);
			return;
		}
		if (uploadFile) {
			size_t written = uploadFile.write(upload.buf, upload.currentSize);
			if (written != upload.currentSize) {
				lastUploadOk = false;
				lastUploadError = "write_failed";
				Serial.println("UPLOAD: write failed");
				uploadFile.close();
				if (uploadName.length() > 0) LittleFS.remove(uploadName);
				return;
			}
		}
	}

	if (upload.status == UPLOAD_FILE_END) {
		if (uploadFile) uploadFile.close();
	}
}

void handleListFiles() {
	if (!ensureStorageReady()) {
		sendJsonResponse(503, "{\"mounted\":false,\"error\":\"storage_unavailable\",\"files\":[]}");
		return;
	}

	DynamicJsonDocument doc(4096);
	doc["mounted"] = true;
	doc["total"] = LittleFS.totalBytes();
	doc["used"] = LittleFS.usedBytes();
	JsonArray files = doc["files"].to<JsonArray>();

	File root = LittleFS.open("/");
	if (!root) {
		sendJsonResponse(500, "{\"mounted\":true,\"error\":\"root_open_failed\",\"files\":[]}");
		return;
	}

	File file = root.openNextFile();
	int count = 0;
	while (file && count < 64) {
		if (!file.isDirectory()) {
			JsonObject item = files.add<JsonObject>();
			String n = file.name();
			if (!n.startsWith("/")) n = "/" + n;
			item["name"] = n;
			item["size"] = file.size();
			count++;
		}
		file = root.openNextFile();
	}

	String out;
	serializeJson(doc, out);
	sendJsonResponse(200, out);
}

bool readNameJson(String& outName, const char* key = "name") {
	String body = server.arg("plain");
	StaticJsonDocument<192> doc;
	if (deserializeJson(doc, body) || !doc.is<JsonObject>() || !doc[key].is<const char*>()) {
		return false;
	}
	outName = sanitizeFilename(String(doc[key].as<const char*>()));
	return true;
}

void handleDeleteFile() {
	if (!ensureStorageReady()) {
		sendJsonResponse(503, "{\"error\":\"storage_unavailable\"}");
		return;
	}
	String name;
	if (!readNameJson(name)) {
		sendJsonResponse(400, "{\"error\":\"name_missing\"}");
		return;
	}
	if (runningFile == name) {
		stopFileRunner(true);
	}
	if (!LittleFS.exists(name)) {
		sendJsonResponse(404, "{\"error\":\"file_not_found\"}");
		return;
	}
	if (!LittleFS.remove(name)) {
		sendJsonResponse(500, "{\"error\":\"delete_failed\"}");
		return;
	}
	sendJsonResponse(200, "{\"status\":\"deleted\"}");
}

void handleRenameFile() {
	if (!ensureStorageReady()) {
		sendJsonResponse(503, "{\"error\":\"storage_unavailable\"}");
		return;
	}
	String body = server.arg("plain");
	StaticJsonDocument<256> doc;
	if (deserializeJson(doc, body) || !doc.is<JsonObject>() ||
		!doc["from"].is<const char*>() || !doc["to"].is<const char*>()) {
		sendJsonResponse(400, "{\"error\":\"from_to_missing\"}");
		return;
	}
	String from = sanitizeFilename(String(doc["from"].as<const char*>()));
	String to = sanitizeFilename(String(doc["to"].as<const char*>()));
	if (from == to) {
		sendJsonResponse(200, "{\"status\":\"unchanged\"}");
		return;
	}
	if (runningFile == from) {
		sendJsonResponse(409, "{\"error\":\"file_running\"}");
		return;
	}
	if (!LittleFS.exists(from)) {
		sendJsonResponse(404, "{\"error\":\"file_not_found\"}");
		return;
	}
	if (LittleFS.exists(to)) {
		sendJsonResponse(409, "{\"error\":\"target_exists\"}");
		return;
	}
	if (!LittleFS.rename(from, to)) {
		sendJsonResponse(500, "{\"error\":\"rename_failed\"}");
		return;
	}
	sendJsonResponse(200, "{\"status\":\"renamed\"}");
}

void handleFormatStorage() {
	if (!formatStorage()) {
		sendJsonResponse(500, "{\"status\":\"failed\",\"mounted\":false}");
		return;
	}
	sendJsonResponse(200, "{\"status\":\"formatted\",\"mounted\":true}");
}

void setupWebServer() {
	server.on("/api/status", HTTP_OPTIONS, handleOptions);
	server.on("/api/status", HTTP_GET, []() {
		StaticJsonDocument<512> doc;
		doc["state"] = stateToString(currentState);
		doc["wifi"] = (WiFi.status() == WL_CONNECTED) ? "CONNECTED" : "DISCONNECTED";
		doc["sta_ip"] = WiFi.localIP().toString();
		doc["m1_pos"] = stepper1 ? stepper1->getCurrentPosition() : 0;
		doc["m2_pos"] = stepper2 ? stepper2->getCurrentPosition() : 0;
		doc["m3_pos"] = stepper3 ? stepper3->getCurrentPosition() : 0;
		doc["queue_depth"] = queueCount + (segment.active ? 1 : 0);
		doc["queue_free"] = MAX_WAYPOINTS - queueCount;
		doc["path_speed"] = (int)pathSpeed;
		doc["path_accel"] = pathAcceleration;
		doc["junction_dev"] = junctionDeviation;
		doc["dc_pwm"] = dcPwm;
		doc["dc_dir"] = dcDirection > 0 ? "forward" : "reverse";
		doc["file_running"] = fileRunning;
		doc["file_name"] = runningFile;
		doc["file_error"] = fileError;
		doc["max1"] = maxLimit1;
		doc["max2"] = maxLimit2;
		doc["max3"] = maxLimit3;
		doc["m1_limit"] = maxLimit1;
		doc["m2_limit"] = maxLimit2;
		doc["m3_limit"] = maxLimit3;
		doc["m1_max_speed"] = maxSpeed1;
		doc["m2_max_speed"] = maxSpeed2;
		doc["m3_max_speed"] = maxSpeed3;
		doc["gcode_mode"] = gcodeAbsoluteMode ? "G90" : "G91";
		doc["gcode_units"] = gcodeMetricUnits ? "G21" : "G20";
		doc["gcode_feed"] = gcodeModalFeed;
		doc["spindle"] = spindleEnabled ? "ON" : "OFF";
		doc["gcode_lines"] = gcodeAcceptedLines;
		doc["storage_mounted"] = storageMounted;
		if (storageMounted) {
			doc["storage_total"] = LittleFS.totalBytes();
			doc["storage_used"] = LittleFS.usedBytes();
		}
		String out;
		serializeJson(doc, out);
		sendJsonResponse(200, out);
	});

	server.on("/api/dc", HTTP_OPTIONS, handleOptions);
	server.on("/api/dc", HTTP_POST, []() {
		String body = server.arg("plain");
		StaticJsonDocument<128> doc;
		if (deserializeJson(doc, body) || !doc.is<JsonObject>()) {
			sendJsonResponse(400, "{\"error\":\"invalid_json_object\"}");
			return;
		}
		if (!doc["speed"].is<long>()) {
			sendJsonResponse(400, "{\"error\":\"speed_type\"}");
			return;
		}
		long speed = doc["speed"].as<long>();
		setDcMotor((int)speed);
		spindleEnabled = speed != 0;
		sendJsonResponse(200, "{\"status\":\"ok\"}");
	});

	server.on("/api/gcode", HTTP_OPTIONS, handleOptions);
	server.on("/api/gcode", HTTP_POST, []() {
		if (currentState == HOMING || currentState == WAITING) {
			sendJsonResponse(409, "{\"error\":\"not_ready\"}");
			return;
		}
		String body = server.arg("plain");
		String programText;
		String trimmed = body;
		trimmed.trim();
		if (trimmed.startsWith("{")) {
			DynamicJsonDocument doc(8192);
			DeserializationError err = deserializeJson(doc, trimmed);
			if (err || !doc.is<JsonObject>() || !doc["program"].is<String>()) {
				sendJsonResponse(400, "{\"error\":\"invalid_gcode_json\"}");
				return;
			}
			programText = doc["program"].as<String>();
		} else {
			programText = trimmed;
		}

		int accepted = 0;
		int processedLines = 0;
		int startIdx = 0;
		while (startIdx <= programText.length()) {
			int endIdx = programText.indexOf('\n', startIdx);
			if (endIdx < 0) endIdx = programText.length();
			String line = programText.substring(startIdx, endIdx);
			line.replace("\r", "");
			processedLines++;

			String error;
			if (!parseAndQueueGcodeLine(line, error)) {
				if (error.length() == 0) error = "parse_error";
				Serial.printf("GCODE: reject line %d: %s | err=%s\n", processedLines, line.c_str(), error.c_str());
				StaticJsonDocument<192> errResp;
				errResp["error"] = error;
				errResp["line"] = processedLines;
				errResp["accepted"] = accepted;
				String out;
				serializeJson(errResp, out);
				int code = (error == "queue_full") ? 409 : 400;
				sendJsonResponse(code, out);
				return;
			}

			if (stripGcodeComments(line).length() > 0) {
				accepted++;
			}

			startIdx = endIdx + 1;
			if (endIdx >= programText.length()) break;
		}

		if (accepted == 0) {
			sendJsonResponse(400, "{\"error\":\"empty_program\"}");
			return;
		}

		if (currentState == READY && !segment.active) {
			currentState = MOVING;
		}

		StaticJsonDocument<128> resp;
		resp["status"] = "queued";
		resp["accepted"] = accepted;
		resp["queue_depth"] = queueCount + (segment.active ? 1 : 0);
		String out;
		serializeJson(resp, out);
		sendJsonResponse(200, out);
	});

	server.on("/api/limits", HTTP_OPTIONS, handleOptions);
	server.on("/api/limits", HTTP_POST, []() {
		String body = server.arg("plain");
		StaticJsonDocument<512> doc;
		if (deserializeJson(doc, body) || !doc.is<JsonObject>()) {
			sendJsonResponse(400, "{\"error\":\"invalid_json_object\"}");
			return;
		}

		long nMax1 = maxLimit1;
		long nMax2 = maxLimit2;
		long nMax3 = maxLimit3;
		long nSpeed1 = maxSpeed1;
		long nSpeed2 = maxSpeed2;
		long nSpeed3 = maxSpeed3;
		float nPathAccel = pathAcceleration;
		float nJunctionDev = junctionDeviation;

		if (doc.containsKey("max1")) {
			if (!doc["max1"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"max1_type\"}");
				return;
			}
			nMax1 = doc["max1"].as<long>();
			if (!isValidLimit(nMax1)) {
				sendJsonResponse(400, "{\"error\":\"max1_range\"}");
				return;
			}
		}
		if (doc.containsKey("max2")) {
			if (!doc["max2"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"max2_type\"}");
				return;
			}
			nMax2 = doc["max2"].as<long>();
			if (!isValidLimit(nMax2)) {
				sendJsonResponse(400, "{\"error\":\"max2_range\"}");
				return;
			}
		}
		if (doc.containsKey("max3")) {
			if (!doc["max3"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"max3_type\"}");
				return;
			}
			nMax3 = doc["max3"].as<long>();
			if (!isValidLimit(nMax3)) {
				sendJsonResponse(400, "{\"error\":\"max3_range\"}");
				return;
			}
		}

		if (doc.containsKey("speed1")) {
			if (!doc["speed1"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"speed1_type\"}");
				return;
			}
			nSpeed1 = doc["speed1"].as<long>();
			if (!isValidFeed(nSpeed1)) {
				sendJsonResponse(400, "{\"error\":\"speed1_range\"}");
				return;
			}
		}
		if (doc.containsKey("speed2")) {
			if (!doc["speed2"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"speed2_type\"}");
				return;
			}
			nSpeed2 = doc["speed2"].as<long>();
			if (!isValidFeed(nSpeed2)) {
				sendJsonResponse(400, "{\"error\":\"speed2_range\"}");
				return;
			}
		}
		if (doc.containsKey("speed3")) {
			if (!doc["speed3"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"speed3_type\"}");
				return;
			}
			nSpeed3 = doc["speed3"].as<long>();
			if (!isValidFeed(nSpeed3)) {
				sendJsonResponse(400, "{\"error\":\"speed3_range\"}");
				return;
			}
		}

		if (doc.containsKey("path_accel")) {
			if (!doc["path_accel"].is<float>() && !doc["path_accel"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"path_accel_type\"}");
				return;
			}
			nPathAccel = doc["path_accel"].as<float>();
			if (nPathAccel < 500.0f || nPathAccel > 30000.0f) {
				sendJsonResponse(400, "{\"error\":\"path_accel_range\"}");
				return;
			}
		}
		if (doc.containsKey("junction_dev")) {
			if (!doc["junction_dev"].is<float>() && !doc["junction_dev"].is<long>()) {
				sendJsonResponse(400, "{\"error\":\"junction_dev_type\"}");
				return;
			}
			nJunctionDev = doc["junction_dev"].as<float>();
			if (nJunctionDev < MIN_JUNCTION_DEV || nJunctionDev > MAX_JUNCTION_DEV) {
				sendJsonResponse(400, "{\"error\":\"junction_dev_range\"}");
				return;
			}
		}

		maxLimit1 = nMax1;
		maxLimit2 = nMax2;
		maxLimit3 = nMax3;
		maxSpeed1 = nSpeed1;
		maxSpeed2 = nSpeed2;
		maxSpeed3 = nSpeed3;
		pathAcceleration = nPathAccel;
		junctionDeviation = nJunctionDev;

		if (segment.active) {
			applyAxisProfile(segment.feed);
		}

		sendJsonResponse(200, "{\"status\":\"updated\"}");
	});

	server.on("/api/files", HTTP_OPTIONS, handleOptions);
	server.on("/api/files", HTTP_GET, handleListFiles);

	server.on("/api/file/delete", HTTP_OPTIONS, handleOptions);
	server.on("/api/file/delete", HTTP_POST, handleDeleteFile);

	server.on("/api/file/rename", HTTP_OPTIONS, handleOptions);
	server.on("/api/file/rename", HTTP_POST, handleRenameFile);

	server.on("/api/storage/format", HTTP_OPTIONS, handleOptions);
	server.on("/api/storage/format", HTTP_POST, handleFormatStorage);

	server.on("/upload", HTTP_OPTIONS, handleOptions);
	server.on("/upload", HTTP_POST, []() {
		if (!lastUploadOk) {
			String out = String("{\"error\":\"") + lastUploadError + "\"}";
			int code = (lastUploadError == "file_too_large") ? 413 : 500;
			sendJsonResponse(code, out);
			return;
		}
		sendJsonResponse(200, "{\"status\":\"uploaded\"}");
	}, handleFileUpload);

	server.on("/run", HTTP_OPTIONS, handleOptions);
	server.on("/run", HTTP_GET, []() {
		if (!server.hasArg("file")) {
			sendJsonResponse(400, "{\"error\":\"file_missing\"}");
			return;
		}
		String filename = server.arg("file");
		startFileRunner(filename);
		if (!fileRunning) {
			sendJsonResponse(404, "{\"error\":\"file_open_failed\"}");
			return;
		}
		sendJsonResponse(200, "{\"status\":\"running\"}");
	});

	server.on("/stop", HTTP_OPTIONS, handleOptions);
	server.on("/stop", HTTP_GET, []() {
		stopFileRunner(true);
		stopAllMotion();
		sendJsonResponse(200, "{\"status\":\"stopped\"}");
	});

	server.on("/homing", HTTP_OPTIONS, handleOptions);
	server.on("/homing", HTTP_GET, []() {
		stopFileRunner(true);
		stopAllMotion();
		s1Homed = false;
		s2Homed = false;
		s3Homed = false;
		s1Phase = HOMING_SEEK;
		s2Phase = HOMING_SEEK;
		s3Phase = HOMING_SEEK;
		s1DebounceStart = 0;
		s2DebounceStart = 0;
		s3DebounceStart = 0;
		currentState = HOMING;
		sendJsonResponse(200, "{\"status\":\"homing\"}");
	});

	server.onNotFound([]() {
		if (server.method() == HTTP_OPTIONS) {
			handleOptions();
			return;
		}
		sendJsonResponse(404, "{\"error\":\"not_found\"}");
	});

	server.begin();
	Serial.println("HTTP server started (sync)");
}

void maintainWiFiConnection() {
	wl_status_t status = WiFi.status();
	if (status == WL_CONNECTED) {
		if (!mdnsStarted && MDNS.begin("dosamatic")) {
			mdnsStarted = true;
			Serial.println("mDNS ready: http://dosamatic.local");
		}
		return;
	}

	if (millis() - lastWiFiReconnectAttempt >= WIFI_RECONNECT_INTERVAL_MS) {
		lastWiFiReconnectAttempt = millis();
		WiFi.disconnect();
		WiFi.begin(ssid, password);
		Serial.println("WiFi reconnect attempt...");
	}
}

void setupWiFi() {
	WiFi.mode(WIFI_STA);
	WiFi.setSleep(false);
	WiFi.begin(ssid, password);

	unsigned long start = millis();
	while (WiFi.status() != WL_CONNECTED && (millis() - start) < WIFI_CONNECT_TIMEOUT_MS) {
		delay(300);
		Serial.print('.');
	}

	if (WiFi.status() == WL_CONNECTED) {
		Serial.println();
		Serial.print("WiFi IP: ");
		Serial.println(WiFi.localIP());
	} else {
		Serial.println();
		Serial.println("WiFi timeout. Continuing in offline mode.");
	}
}

void setup() {
	Serial.begin(115200);

	initDcPwm();
	setDcPwm(0);

	pinMode(LIM1_PIN, INPUT_PULLUP);
	pinMode(LIM2_PIN, INPUT_PULLUP);
	pinMode(LIM3_PIN, INPUT_PULLUP);

	engine.init();
	stepper1 = engine.stepperConnectToPin(STEP1_PIN);
	stepper2 = engine.stepperConnectToPin(STEP2_PIN);
	stepper3 = engine.stepperConnectToPin(STEP3_PIN);
	if (stepper1) {
		stepper1->setDirectionPin(DIR1_PIN);
		stepper1->setAutoEnable(true);
		stepper1->setSpeedInHz(maxSpeed1);
		stepper1->setAcceleration(axisAcceleration);
	}
	if (stepper2) {
		stepper2->setDirectionPin(DIR2_PIN);
		stepper2->setAutoEnable(true);
		stepper2->setSpeedInHz(maxSpeed2);
		stepper2->setAcceleration(axisAcceleration);
	}
	if (stepper3) {
		stepper3->setDirectionPin(DIR3_PIN);
		stepper3->setAutoEnable(true);
		stepper3->setSpeedInHz(maxSpeed3);
		stepper3->setAcceleration(axisAcceleration);
	}

	mountStorage(true);
	setupWiFi();
	check_ota(otaConfig);
	StaticJsonDocument<384> payload;
	payload["device_id"] = deviceId;
	payload["fw_version"] = CURRENT_VERSION;
	payload["local_ip"] = WiFi.localIP().toString();
	payload["ssid"] = WiFi.SSID();
	payload["rssi"] = WiFi.RSSI();
	payload["boot_ms"] = millis();
	payload["state"] = stateToString(currentState);
	payload["gcode_mode"] = gcodeAbsoluteMode ? "G90" : "G91";
	send_ota_ack(otaConfig, payload);
	setupWebServer();

	Serial.println("Boot complete. Starting homing...");
}

void loop() {
	maintainWiFiConnection();
	server.handleClient();
	serviceFileRunner();

	switch (currentState) {
		case HOMING:
			performHoming();
			break;

		case WAITING:
			if (millis() - waitStartTime >= WAIT_DELAY_MS) {
				currentState = READY;
			}
			break;

		case READY:
			if (queueCount > 0 || segment.active) {
				currentState = MOVING;
			}
			break;

		case MOVING: {
			unsigned long nowUs = micros();
			if (lastPlannerUs == 0) lastPlannerUs = nowUs;

			unsigned long elapsedUs = nowUs - lastPlannerUs;
			if (elapsedUs >= PLANNER_INTERVAL_US) {
				float dt = elapsedUs / 1000000.0f;
				if (dt > 0.03f) dt = 0.03f;
				plannerTick(dt);
				lastPlannerUs = nowUs;
			}
			yield();
			break;
		}
	}

}
