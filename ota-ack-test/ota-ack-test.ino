#include <WiFi.h>

#include "OtaService.h"

// const char* ssid = "IIIT-Guest";
// const char* password = "f6s68VHJ89mC";

const char* ssid = "IIIT-Guest";
const char* password = "f6s68VHJ89mC";

const int CURRENT_VERSION = 7;
const char* versionUrl = "https://raw.githubusercontent.com/chandrashekar-09/dosamatic/main/var.txt";
const char* firmwareUrl = "https://raw.githubusercontent.com/chandrashekar-09/dosamatic/main/firmware.bin";
const char* deviceId = "tes-001";

const char* firebaseBootAckBaseUrl = nullptr;
const char* firebaseAuthToken = "";

const OtaConfig otaConfig = {
		CURRENT_VERSION,
		versionUrl,
		firmwareUrl,
		deviceId,
		firebaseBootAckBaseUrl,
		firebaseAuthToken,
};

void setupWiFi() {
	WiFi.mode(WIFI_STA);
	WiFi.begin(ssid, password);

	unsigned long start = millis();
	while (WiFi.status() != WL_CONNECTED && (millis() - start) < 15000) {
		delay(300);
		Serial.print('.');
	}

	if (WiFi.status() == WL_CONNECTED) {
		Serial.println();
		Serial.print("WiFi IP: ");
		Serial.println(WiFi.localIP());
	} else {
		Serial.println();
		Serial.println("WiFi timeout. Continuing offline.");
	}
}

void setup() {
	Serial.begin(115200);
	setupWiFi();
	StaticJsonDocument<256> payload;
	payload["device_id"] = deviceId;
	payload["fw_version"] = CURRENT_VERSION;
	payload["local_ip"] = WiFi.localIP().toString();
	payload["ssid"] = WiFi.SSID();
	payload["rssi"] = WiFi.RSSI();
	payload["boot_state"] = "BOOT";
	send_ota_ack(otaConfig, payload);
}

void loop() {}
