#include <WiFi.h>

#include "OtaService.h"  // OTA Service


// ------------OTA and Wi-Fi Config----------------------//

 
const char* ssid = "IIIT-Guest";
const char* password = "f6s68VHJ89mC";

const int CURRENT_VERSION = 6;
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

	Serial.print("connecting to wifi: ");
	Serial.print(ssid);

	while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    }
	
	Serial.println(WiFi.localIP());

}

void setup() {
	Serial.begin(115200);
	setupWiFi();

	check_ota(otaConfig); //check for updates and apply if available

	StaticJsonDocument<256> payload;
	payload["device_id"] = deviceId;
	payload["fw_version"] = CURRENT_VERSION;
	payload["local_ip"] = WiFi.localIP().toString();
	payload["ssid"] = WiFi.SSID();
	payload["rssi"] = WiFi.RSSI();
	payload["state"] = "BOOT";

	send_ota_ack(otaConfig, payload); //send boot ack with device info
}

void loop() {}
