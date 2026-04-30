#include <Arduino.h>
#include <U8g2lib.h>
#include <Wire.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Update.h>
#include <WiFiClientSecure.h>

// --- Display Setup for 1.3" SH1106 ---
U8G2_SH1106_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, /* reset=*/ U8X8_PIN_NONE);

// --- OTA Settings ---
const char* ssid = "IIIT-Guest";
const char* password = "f6s68VHJ89mC";
const int CURRENT_VERSION = 2; 
String versionUrl = "https://raw.githubusercontent.com/chandrashekar-09/dosamatic/main/var.txt";
String firmwareUrl = "https://raw.githubusercontent.com/chandrashekar-09/dosamatic/main/firmware.bin";

unsigned long lastOTACheck = 0;
const unsigned long OTA_CHECK_INTERVAL = 5000; 

// Function to print "Hi anna" in a large font
void showGreeting() {
  u8g2.clearBuffer();
  // Using a 24-pixel high bold font
  u8g2.setFont(u8g2_font_logisoso24_tr); 
  u8g2.drawStr(10, 45, "Hi anna!!"); 
  u8g2.sendBuffer();
}

// Function for smaller status updates during OTA
void updateStatus(String status) {
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_ncenB08_tr);
  u8g2.drawStr(0, 35, status.c_str());
  u8g2.sendBuffer();
}

void setup() {
  Serial.begin(115200);
  u8g2.begin();
  
  // Show the big greeting immediately
  showGreeting();
  delay(2000); 

  updateStatus("Connecting WiFi...");
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }

  // Go back to the greeting after connecting
  showGreeting();
}

void loop() {
  // Check for OTA every 5 seconds
  if (millis() - lastOTACheck >= OTA_CHECK_INTERVAL) {
    lastOTACheck = millis();
    checkForOTAUpdate();
  }
}

void checkForOTAUpdate() {
  if (WiFi.status() != WL_CONNECTED) return;

  WiFiClientSecure client;
  client.setInsecure(); 
  HTTPClient http;
  http.begin(client, versionUrl);
  
  if (http.GET() == HTTP_CODE_OK) {
    int latestVersion = http.getString().toInt();
    if (latestVersion > CURRENT_VERSION) {
      updateStatus("Update Found! Updating...");
      performOTA();
    }
  }
  http.end();
}

void performOTA() {
  WiFiClientSecure client;
  client.setInsecure(); 
  HTTPClient http;
  http.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS); 
  http.begin(client, firmwareUrl);
  
  if (http.GET() == HTTP_CODE_OK) {
    int contentLength = http.getSize();
    if (Update.begin(contentLength)) {
      WiFiClient* stream = http.getStreamPtr();
      if (Update.writeStream(*stream) == contentLength) {
        if (Update.end() && Update.isFinished()) {
          updateStatus("Success! Rebooting...");
          delay(1000);
          ESP.restart();
        }
      }
    }
  }
  http.end();
}