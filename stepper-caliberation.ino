#include <WiFi.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <AccelStepper.h>
#include <ESPmDNS.h>
#include <ctype.h>

#include "OtaService.h"

const char* ssid = "IIIT-Guest";
const char* password = "f6s68VHJ89mC";

// const char* ssid = "MADHU";
// const char* password = "6303852931";

const int CURRENT_VERSION = 6;
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

AccelStepper stepper1(1, STEP1_PIN, DIR1_PIN);
AccelStepper stepper2(1, STEP2_PIN, DIR2_PIN);
AccelStepper stepper3(1, STEP3_PIN, DIR3_PIN);

WebServer server(80);

enum SystemState { HOMING, WAITING, READY, MOVING };
SystemState currentState = HOMING;

const long HOMING_TARGET = -1000000;
const long HOMING_BACKOFF_STEPS = 400;
const unsigned long WAIT_DELAY_MS = 3000;
const unsigned long WIFI_CONNECT_TIMEOUT_MS = 15000;
const unsigned long WIFI_RECONNECT_INTERVAL_MS = 5000;
const unsigned long PLANNER_INTERVAL_US = 4000;

const long MIN_LIMIT_STEPS = 100;
const long MAX_LIMIT_STEPS = 250000;
const long MIN_FEED_STEPS_PER_SEC = 100;
const long MAX_FEED_STEPS_PER_SEC = 12000;
const float MIN_SEGMENT_EXEC_STEPS = 0.5f;
const float MIN_LOOKAHEAD_SEGMENT_STEPS = 5.0f;
const float MIN_CORNER_SPEED = 120.0f;

long maxLimit1 = 14000;
long maxLimit2 = 15000;
long maxLimit3 = 15000;

long maxSpeed1 = 7000;
long maxSpeed2 = 7000;
long maxSpeed3 = 7000;
long axisAcceleration = 22000;
float pathAcceleration = 5000.0f;

bool s1Homed = false;
bool s2Homed = false;
bool s3Homed = false;
unsigned long waitStartTime = 0;

unsigned long lastPlannerUs = 0;
unsigned long lastWiFiReconnectAttempt = 0;
bool mdnsStarted = false;
bool gcodeAbsoluteMode = true;
long gcodeModalFeed = 1200;
bool spindleEnabled = false;
unsigned long gcodeAcceptedLines = 0;

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

bool parseAndQueueGcodeLine(const String& rawLine, String& error) {
	String line = stripGcodeComments(rawLine);
	if (line.length() == 0) {
		return true;
	}

	if (line.startsWith("N")) {
		int firstSpace = line.indexOf(' ');
		if (firstSpace > 0) {
			line = line.substring(firstSpace + 1);
			line.trim();
		}
	}

	if (line.indexOf("G90") >= 0) {
		gcodeAbsoluteMode = true;
	}
	if (line.indexOf("G91") >= 0) {
		gcodeAbsoluteMode = false;
	}
	if (line.indexOf("M3") >= 0 || line.indexOf("M03") >= 0) {
		spindleEnabled = true;
	}
	if (line.indexOf("M5") >= 0 || line.indexOf("M05") >= 0) {
		spindleEnabled = false;
	}

	bool hasMotionWord = line.indexOf("G0") >= 0 || line.indexOf("G00") >= 0 || line.indexOf("G1") >= 0 || line.indexOf("G01") >= 0;
	if (!hasMotionWord) {
		if (line.indexOf("G90") >= 0 || line.indexOf("G91") >= 0 || line.indexOf("M3") >= 0 || line.indexOf("M03") >= 0 || line.indexOf("M5") >= 0 || line.indexOf("M05") >= 0 || line.indexOf("F") >= 0) {
			float ffOnly = 0;
			if (extractWordValue(line, 'F', ffOnly)) {
				long parsedFeed = lroundf(ffOnly);
				if (!isValidFeed(parsedFeed)) {
					error = "feed_out_of_range";
					return false;
				}
				gcodeModalFeed = parsedFeed;
			}
			return true;
		}

		error = "unsupported_command";
		return false;
	}

	float fx = 0;
	float fy = 0;
	float fz = 0;
	float ff = 0;
	bool hasX = extractWordValue(line, 'X', fx);
	bool hasY = extractWordValue(line, 'Y', fy);
	bool hasZ = extractWordValue(line, 'Z', fz);
	bool hasF = extractWordValue(line, 'F', ff);

	if (hasF) {
		long parsedFeed = lroundf(ff);
		if (!isValidFeed(parsedFeed)) {
			error = "feed_out_of_range";
			return false;
		}
		gcodeModalFeed = parsedFeed;
	}

	if (!hasX && !hasY && !hasZ) {
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
		if (hasX) targetX = fx;
		if (hasY) targetY = fy;
		if (hasZ) targetZ = fz;
	} else {
		if (hasX) targetX = refX + fx;
		if (hasY) targetY = refY + fy;
		if (hasZ) targetZ = refZ + fz;
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

void applyAxisProfile(float requestedFeed) {
	float f1 = clampf(requestedFeed, MIN_FEED_STEPS_PER_SEC, maxSpeed1);
	float f2 = clampf(requestedFeed, MIN_FEED_STEPS_PER_SEC, maxSpeed2);
	float f3 = clampf(requestedFeed, MIN_FEED_STEPS_PER_SEC, maxSpeed3);
	stepper1.setMaxSpeed(f1);
	stepper2.setMaxSpeed(f2);
	stepper3.setMaxSpeed(f3);
}

void commandPlannerPosition() {
	stepper1.moveTo(lroundf(plannerX));
	stepper2.moveTo(lroundf(plannerY));
	stepper3.moveTo(lroundf(plannerZ));
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

	float straightness = (dot + 1.0f) * 0.5f;
	float maxJunction = min((float)current.feed, (float)nextPoint.feed);
	float blended = MIN_CORNER_SPEED + (maxJunction - MIN_CORNER_SPEED) * straightness * straightness;
	return clampf(blended, MIN_CORNER_SPEED, maxJunction);
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
	plannerX = stepper1.currentPosition();
	plannerY = stepper2.currentPosition();
	plannerZ = stepper3.currentPosition();
	commandPlannerPosition();
	currentState = READY;
}

void plannerTick(float dt) {
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

void performHoming() {
	if (!s1Homed) {
		if (digitalRead(LIM1_PIN) == LOW) {
			stepper1.setCurrentPosition(0);
			stepper1.move(HOMING_BACKOFF_STEPS);
			s1Homed = true;
		} else {
			stepper1.setSpeed(-1000);
			stepper1.runSpeed();
		}
	}

	if (!s2Homed) {
		if (digitalRead(LIM2_PIN) == LOW) {
			stepper2.setCurrentPosition(0);
			stepper2.move(HOMING_BACKOFF_STEPS);
			s2Homed = true;
		} else {
			stepper2.setSpeed(-1000);
			stepper2.runSpeed();
		}
	}

	if (!s3Homed) {
		if (digitalRead(LIM3_PIN) == LOW) {
			stepper3.setCurrentPosition(0);
			stepper3.move(HOMING_BACKOFF_STEPS);
			s3Homed = true;
		} else {
			stepper3.setSpeed(-1000);
			stepper3.runSpeed();
		}
	}

	if (s1Homed && s2Homed && s3Homed) {
		if (stepper1.distanceToGo() == 0 && stepper2.distanceToGo() == 0 && stepper3.distanceToGo() == 0) {
			stepper1.setCurrentPosition(0);
			stepper2.setCurrentPosition(0);
			stepper3.setCurrentPosition(0);
			plannerX = 0;
			plannerY = 0;
			plannerZ = 0;
			commandPlannerPosition();
			pathSpeed = 0;
			waitStartTime = millis();
			currentState = WAITING;
			Serial.println("Homing complete");
		} else {
			stepper1.run();
			stepper2.run();
			stepper3.run();
		}
	}
}

void handleCors() {
	server.sendHeader("Access-Control-Allow-Origin", "*");
	server.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
	server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
	server.send(204);
}

void setupWebServer() {
	server.on("/api/status", HTTP_GET, []() {
		server.sendHeader("Access-Control-Allow-Origin", "*");
		StaticJsonDocument<320> doc;
		doc["state"] = stateToString(currentState);
		doc["wifi"] = (WiFi.status() == WL_CONNECTED) ? "CONNECTED" : "DISCONNECTED";
		doc["m1_pos"] = stepper1.currentPosition();
		doc["m2_pos"] = stepper2.currentPosition();
		doc["m3_pos"] = stepper3.currentPosition();
		doc["queue_depth"] = queueCount + (segment.active ? 1 : 0);
		doc["path_speed"] = (int)pathSpeed;
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
		doc["gcode_feed"] = gcodeModalFeed;
		doc["spindle"] = spindleEnabled ? "ON" : "OFF";
		doc["gcode_lines"] = gcodeAcceptedLines;
		String out;
		serializeJson(doc, out);
		server.send(200, "application/json", out);
	});

	server.on("/api/gcode", HTTP_POST, []() {
		server.sendHeader("Access-Control-Allow-Origin", "*");
		if (!server.hasArg("plain")) {
			return server.send(400, "application/json", "{\"error\":\"body_missing\"}");
		}
		if (currentState == HOMING || currentState == WAITING) {
			return server.send(409, "application/json", "{\"error\":\"not_ready\"}");
		}

		String payload = server.arg("plain");
		String programText;

		String trimmed = payload;
		trimmed.trim();
		if (trimmed.startsWith("{")) {
			DynamicJsonDocument doc(8192);
			DeserializationError err = deserializeJson(doc, trimmed);
			if (err || !doc.is<JsonObject>() || !doc["program"].is<String>()) {
				return server.send(400, "application/json", "{\"error\":\"invalid_gcode_json\"}");
			}
			programText = doc["program"].as<String>();
		} else {
			programText = payload;
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
				StaticJsonDocument<192> errResp;
				errResp["error"] = error;
				errResp["line"] = processedLines;
				errResp["accepted"] = accepted;
				String out;
				serializeJson(errResp, out);
				int code = (error == "queue_full") ? 409 : 400;
				return server.send(code, "application/json", out);
			}

			if (stripGcodeComments(line).length() > 0) {
				accepted++;
			}

			startIdx = endIdx + 1;
			if (endIdx >= programText.length()) break;
		}

		if (accepted == 0) {
			return server.send(400, "application/json", "{\"error\":\"empty_program\"}");
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
		server.send(200, "application/json", out);
	});

	server.on("/api/path", HTTP_POST, []() {
		server.sendHeader("Access-Control-Allow-Origin", "*");
		if (!server.hasArg("plain")) {
			return server.send(400, "application/json", "{\"error\":\"body_missing\"}");
		}
		if (currentState == HOMING || currentState == WAITING) {
			return server.send(409, "application/json", "{\"error\":\"not_ready\"}");
		}

		DynamicJsonDocument doc(8192);
		DeserializationError err = deserializeJson(doc, server.arg("plain"));
		if (err || !doc.is<JsonArray>()) {
			return server.send(400, "application/json", "{\"error\":\"invalid_json_array\"}");
		}

		JsonArray arr = doc.as<JsonArray>();
		if (arr.size() == 0) {
			return server.send(400, "application/json", "{\"error\":\"empty_path\"}");
		}

		int accepted = 0;
		for (JsonObjectConst wp : arr) {
			if (!wp["x"].is<long>() || !wp["y"].is<long>() || !wp["z"].is<long>()) {
				continue;
			}

			Waypoint point;
			point.x = clampTarget(wp["x"].as<long>(), maxLimit1);
			point.y = clampTarget(wp["y"].as<long>(), maxLimit2);
			point.z = clampTarget(wp["z"].as<long>(), maxLimit3);

			long feed = wp.containsKey("speed") && wp["speed"].is<long>() ? wp["speed"].as<long>() : min(maxSpeed1, min(maxSpeed2, maxSpeed3));
			point.feed = isValidFeed(feed) ? feed : min(maxSpeed1, min(maxSpeed2, maxSpeed3));

			if (!enqueueWaypoint(point)) {
				break;
			}
			accepted++;
		}

		if (accepted == 0) {
			return server.send(400, "application/json", "{\"error\":\"no_valid_waypoints\"}");
		}

		if (currentState == READY && !segment.active) {
			currentState = MOVING;
		}

		StaticJsonDocument<96> resp;
		resp["status"] = "queued";
		resp["accepted"] = accepted;
		String out;
		serializeJson(resp, out);
		server.send(200, "application/json", out);
	});

	server.on("/api/stop", HTTP_POST, []() {
		server.sendHeader("Access-Control-Allow-Origin", "*");
		stopAllMotion();
		server.send(200, "application/json", "{\"status\":\"stopped\"}");
	});

	server.on("/api/home", HTTP_POST, []() {
		server.sendHeader("Access-Control-Allow-Origin", "*");
		stopAllMotion();
		s1Homed = false;
		s2Homed = false;
		s3Homed = false;
		stepper1.moveTo(HOMING_TARGET);
		stepper2.moveTo(HOMING_TARGET);
		stepper3.moveTo(HOMING_TARGET);
		currentState = HOMING;
		server.send(200, "application/json", "{\"status\":\"homing\"}");
	});

	server.on("/api/limits", HTTP_POST, []() {
		server.sendHeader("Access-Control-Allow-Origin", "*");
		if (!server.hasArg("plain")) {
			return server.send(400, "application/json", "{\"error\":\"body_missing\"}");
		}

		StaticJsonDocument<512> doc;
		if (deserializeJson(doc, server.arg("plain")) || !doc.is<JsonObject>()) {
			return server.send(400, "application/json", "{\"error\":\"invalid_json_object\"}");
		}

		long nMax1 = maxLimit1;
		long nMax2 = maxLimit2;
		long nMax3 = maxLimit3;
		long nSpeed1 = maxSpeed1;
		long nSpeed2 = maxSpeed2;
		long nSpeed3 = maxSpeed3;
		float nPathAccel = pathAcceleration;

		if (doc.containsKey("max1")) {
			if (!doc["max1"].is<long>()) return server.send(400, "application/json", "{\"error\":\"max1_type\"}");
			nMax1 = doc["max1"].as<long>();
			if (!isValidLimit(nMax1)) return server.send(400, "application/json", "{\"error\":\"max1_range\"}");
		}
		if (doc.containsKey("max2")) {
			if (!doc["max2"].is<long>()) return server.send(400, "application/json", "{\"error\":\"max2_type\"}");
			nMax2 = doc["max2"].as<long>();
			if (!isValidLimit(nMax2)) return server.send(400, "application/json", "{\"error\":\"max2_range\"}");
		}
		if (doc.containsKey("max3")) {
			if (!doc["max3"].is<long>()) return server.send(400, "application/json", "{\"error\":\"max3_type\"}");
			nMax3 = doc["max3"].as<long>();
			if (!isValidLimit(nMax3)) return server.send(400, "application/json", "{\"error\":\"max3_range\"}");
		}

		if (doc.containsKey("speed1")) {
			if (!doc["speed1"].is<long>()) return server.send(400, "application/json", "{\"error\":\"speed1_type\"}");
			nSpeed1 = doc["speed1"].as<long>();
			if (!isValidFeed(nSpeed1)) return server.send(400, "application/json", "{\"error\":\"speed1_range\"}");
		}
		if (doc.containsKey("speed2")) {
			if (!doc["speed2"].is<long>()) return server.send(400, "application/json", "{\"error\":\"speed2_type\"}");
			nSpeed2 = doc["speed2"].as<long>();
			if (!isValidFeed(nSpeed2)) return server.send(400, "application/json", "{\"error\":\"speed2_range\"}");
		}
		if (doc.containsKey("speed3")) {
			if (!doc["speed3"].is<long>()) return server.send(400, "application/json", "{\"error\":\"speed3_type\"}");
			nSpeed3 = doc["speed3"].as<long>();
			if (!isValidFeed(nSpeed3)) return server.send(400, "application/json", "{\"error\":\"speed3_range\"}");
		}

		if (doc.containsKey("path_accel")) {
			if (!doc["path_accel"].is<float>() && !doc["path_accel"].is<long>()) {
				return server.send(400, "application/json", "{\"error\":\"path_accel_type\"}");
			}
			nPathAccel = doc["path_accel"].as<float>();
			if (nPathAccel < 500.0f || nPathAccel > 30000.0f) {
				return server.send(400, "application/json", "{\"error\":\"path_accel_range\"}");
			}
		}

		maxLimit1 = nMax1;
		maxLimit2 = nMax2;
		maxLimit3 = nMax3;
		maxSpeed1 = nSpeed1;
		maxSpeed2 = nSpeed2;
		maxSpeed3 = nSpeed3;
		pathAcceleration = nPathAccel;

		if (segment.active) {
			applyAxisProfile(segment.feed);
		}

		server.send(200, "application/json", "{\"status\":\"updated\"}");
	});

	server.on("/api/status", HTTP_OPTIONS, handleCors);
	server.on("/api/gcode", HTTP_OPTIONS, handleCors);
	server.on("/api/path", HTTP_OPTIONS, handleCors);
	server.on("/api/stop", HTTP_OPTIONS, handleCors);
	server.on("/api/home", HTTP_OPTIONS, handleCors);
	server.on("/api/limits", HTTP_OPTIONS, handleCors);

	server.onNotFound([]() {
		server.sendHeader("Access-Control-Allow-Origin", "*");
		server.send(404, "application/json", "{\"error\":\"not_found\"}");
	});

	server.begin();
	Serial.println("HTTP server started");
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
		Serial.println("WiFi timeout. Continuing offline mode.");
	}
}

void setup() {
	Serial.begin(115200);

	pinMode(LIM1_PIN, INPUT_PULLUP);
	pinMode(LIM2_PIN, INPUT_PULLUP);
	pinMode(LIM3_PIN, INPUT_PULLUP);

	stepper1.setMaxSpeed(maxSpeed1);
	stepper2.setMaxSpeed(maxSpeed2);
	stepper3.setMaxSpeed(maxSpeed3);
	stepper1.setAcceleration(axisAcceleration);
	stepper2.setAcceleration(axisAcceleration);
	stepper3.setAcceleration(axisAcceleration);

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

	stepper1.moveTo(HOMING_TARGET);
	stepper2.moveTo(HOMING_TARGET);
	stepper3.moveTo(HOMING_TARGET);

	Serial.println("Boot complete. Starting homing...");
}

void loop() {
	maintainWiFiConnection();
	server.handleClient();

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
			break;
		}
	}

	stepper1.run();
	stepper2.run();
	stepper3.run();
}
