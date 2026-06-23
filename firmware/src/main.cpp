#include <Arduino.h>
#include <ArduinoJson.h>
#include <Adafruit_NeoPixel.h>
#include <Preferences.h>
#include <SPI.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>

namespace {

constexpr uint32_t kBaud = 115200;
constexpr uint32_t kStaleMs = 90000;
constexpr size_t kMaxLine = 32768;
constexpr size_t kMaxDays = 62;
constexpr size_t kMaxHourlyPoints = 168;
constexpr size_t kMaxWeeklyPoints = 16;
constexpr size_t kMaxSeriesPoints = 32;
constexpr int16_t kUiW = 320;
constexpr int16_t kUiH = 240;
constexpr uint8_t kWaitingMatrixColumns = 18;
constexpr int16_t kWaitingMatrixTop = 138;
constexpr int16_t kWaitingMatrixBottom = 236;
constexpr uint32_t kWaitingMatrixFrameMs = 220;
constexpr uint8_t kPanelRotation = 2;
constexpr bool kMirrorY = false;
constexpr int16_t kTouchMin = 200;
constexpr int16_t kTouchMax = 3900;

constexpr int kTouchCs = 33;
constexpr int kTouchIrq = 36;
constexpr int kTouchMosi = 32;
constexpr int kTouchMiso = 39;
constexpr int kTouchClk = 25;
constexpr int kStatusLedPin = 4;
constexpr uint8_t kStatusLedCount = 1;
constexpr uint8_t kStatusLedBrightness = 48;
constexpr int kBacklightChannel = 0;
constexpr int kBacklightBrightness = 80;
constexpr int16_t kTimeZoneStepMinutes = 60;
constexpr int16_t kMinTimeZoneMinutes = -720;
constexpr int16_t kMaxTimeZoneMinutes = 840;
constexpr int16_t kDefaultTimeZoneMinutes = -300;
constexpr uint8_t kVisibleTimeZoneItems = 4;
constexpr int16_t kHeaderButtonY = 12;
constexpr int16_t kHeaderButtonH = 24;
constexpr int16_t kDayTabX = 148;
constexpr int16_t kDayTabW = 42;
constexpr int16_t kWeekTabX = 194;
constexpr int16_t kWeekTabW = 44;
constexpr int16_t kMonthTabX = 242;
constexpr int16_t kMonthTabW = 48;
constexpr int16_t kAlertIconX = 294;
constexpr int16_t kAlertIconW = 18;
constexpr uint16_t kAlertStep = 5;
constexpr uint32_t kTouchPrefsMagic = 0x54434831;
constexpr int16_t kCalLeftX = 24;
constexpr int16_t kCalRightX = 296;
constexpr int16_t kCalTopY = 28;
constexpr int16_t kCalBottomY = 212;

TFT_eSPI tft;
TFT_eSPI &ui = tft;
SPIClass touchSpi(VSPI);
XPT2046_Touchscreen touch(kTouchCs, kTouchIrq);
Preferences prefs;
Adafruit_NeoPixel statusLed(kStatusLedCount, kStatusLedPin, NEO_GRB + NEO_KHZ800);

enum PeriodMode : uint8_t { ModeDay = 0, ModeWeek, ModeMonth };

enum ScreenView : uint8_t { ViewDashboard = 0, ViewAlerts };

enum AlertLevel : uint8_t { AlertLow = 0, AlertMedium, AlertHigh };

enum UiMode : uint8_t { UiCalibration = 0, UiDashboard };

enum TouchTransform : uint8_t {
  TouchXY = 0,
  TouchXYFlipX,
  TouchXYFlipY,
  TouchXYFlipXY,
  TouchYX,
  TouchYXFlipX,
  TouchYXFlipY,
  TouchYXFlipXY,
  TouchTransformCount
};

enum TouchAction : uint8_t {
  TouchNone = 0,
  TouchSelectDay,
  TouchSelectWeek,
  TouchSelectMonth,
  TouchToggleAlerts,
  TouchPrevRange,
  TouchNextRange,
  TouchTimeZoneToggle,
  TouchTimeZoneDown,
  TouchTimeZoneUp,
  TouchTimeZonePick0,
  TouchTimeZonePick1,
  TouchTimeZonePick2,
  TouchTimeZonePick3,
  TouchLowDown,
  TouchLowUp,
  TouchMediumDown,
  TouchMediumUp,
  TouchStartCalibration
};

struct TouchCandidate {
  TouchAction action = TouchNone;
  TouchTransform transform = TouchXY;
  int16_t x = 0;
  int16_t y = 0;
  int16_t score = 32767;
};

struct TouchCalibration {
  bool valid = false;
  bool swapAxes = false;
  bool flipX = false;
  bool flipY = false;
  int16_t minX = kTouchMin;
  int16_t maxX = kTouchMax;
  int16_t minY = kTouchMin;
  int16_t maxY = kTouchMax;
};

struct RawTouchPoint {
  int32_t x = 0;
  int32_t y = 0;
};

struct DayPoint {
  char date[11] = "";
  uint32_t saved = 0;
  uint32_t input = 0;
  float usd = 0.0f;
  float cost = 0.0f;
};

struct ChartPoint {
  char timestamp[25] = "";
  uint32_t input = 0;
  float usd = 0.0f;
  float cost = 0.0f;
};

struct ViewPoint {
  char label[12] = "";
  uint32_t saved = 0;
  uint32_t input = 0;
  float usd = 0.0f;
  float cost = 0.0f;
};

struct ViewStats {
  char title[16] = "";
  uint32_t saved = 0;
  uint32_t input = 0;
  float usd = 0.0f;
  float cost = 0.0f;
  float avgPct = 0.0f;
  size_t pointCount = 0;
  ViewPoint points[kMaxSeriesPoints];
};

struct WaitingMatrixColumn {
  int16_t x = 0;
  int16_t headY = 0;
  uint8_t speed = 8;
  uint8_t length = 8;
  uint16_t seed = 0;
};

struct Aggregate {
  uint32_t saved = 0;
  uint32_t input = 0;
  float usd = 0.0f;
  float cost = 0.0f;
};

struct SessionStats {
  uint32_t requests = 0;
  uint32_t saved = 0;
  uint32_t input = 0;
  float usd = 0.0f;
  float pct = 0.0f;
  char last[25] = "";
};

struct LiveStats {
  uint32_t rtkCommands = 0;
  uint32_t rtkSaved = 0;
  float rtkPct = 0.0f;
  uint32_t uptime = 0;
  bool ok = false;
  char proxy[16] = "unknown";
  char timestamp[25] = "";
};

DayPoint days[kMaxDays];
ChartPoint hourlyPoints[kMaxHourlyPoints];
ChartPoint weeklyPoints[kMaxWeeklyPoints];
ViewStats rangeViews[3];
SessionStats sessionStats;
LiveStats liveStats;
size_t dayCount = 0;
size_t hourlyCount = 0;
size_t weeklyCount = 0;
size_t selectedEnd = 0;
PeriodMode periodMode = ModeDay;
ScreenView screenView = ViewDashboard;
UiMode uiMode = UiDashboard;
uint32_t lastFrameMs = 0;
uint32_t lastTouchMs = 0;
TouchTransform activeTouchTransform = TouchXY;
bool touchTransformLocked = false;
uint16_t alertLowMax = 50;
uint16_t alertMediumMax = 100;
int16_t timeZoneOffsetMinutes = kDefaultTimeZoneMinutes;
uint8_t timeZoneMenuStartIndex = 0;
bool timeZoneMenuOpen = false;
AlertLevel lastAlertLevel = AlertLow;
bool alertOutputInitialized = false;
bool alertPulseVisible = true;
uint32_t lastAlertPulseMs = 0;
WaitingMatrixColumn waitingMatrix[kWaitingMatrixColumns];
bool waitingMatrixInitialized = false;
uint32_t lastWaitingMatrixMs = 0;
uint16_t waitingMatrixFrame = 0;
TouchCalibration touchCalibration;
RawTouchPoint calibrationPoints[4];
uint8_t calibrationStep = 0;
bool hasDashboardData = false;
uint32_t lastBridgeReadyBeaconMs = 0;
uint8_t currentFrameVersion = 0;
char lineBuffer[kMaxLine];
size_t lineLen = 0;
bool needsRender = true;
char lastError[48] = "waiting for HRM2";

uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return tft.color565(r, g, b);
}

int16_t panelY(int16_t y, int16_t h) {
  return kMirrorY ? kUiH - y - h : y;
}

void copyString(char *dest, size_t len, const char *src) {
  if (len == 0) return;
  if (src == nullptr) {
    dest[0] = '\0';
    return;
  }
  strlcpy(dest, src, len);
}

uint32_t asUInt(JsonVariantConst value) {
  return value.isNull() ? 0 : value.as<uint32_t>();
}

float asFloat(JsonVariantConst value) {
  return value.isNull() ? 0.0f : value.as<float>();
}

size_t parseChartArray(JsonArrayConst points, ChartPoint *target, size_t maxCount) {
  size_t count = 0;
  for (JsonObjectConst point : points) {
    if (count >= maxCount) break;
    const char *timestamp = point["t"] | "";
    if (timestamp[0] == '\0') timestamp = point["timestamp"] | "";
    copyString(target[count].timestamp, sizeof(target[count].timestamp), timestamp);
    target[count].input = asUInt(point["input"]);
    target[count].usd = asFloat(point["usd"]);
    target[count].cost = asFloat(point["cost"]);
    ++count;
  }
  return count;
}

ViewStats &viewForMode(PeriodMode mode) {
  return rangeViews[static_cast<size_t>(mode)];
}

const ViewStats &currentView() {
  return rangeViews[static_cast<size_t>(periodMode)];
}

const char *defaultChartTitle(PeriodMode mode) {
  if (mode == ModeDay) return "USD by hour";
  if (mode == ModeWeek) return "USD by day";
  return "USD by week";
}

void clearView(ViewStats &view) {
  memset(&view, 0, sizeof(view));
}

bool viewHasData(const ViewStats &view) {
  return view.pointCount > 0 || view.saved > 0 || view.input > 0 || view.usd > 0.0f || view.cost > 0.0f;
}

float computeAvgPct(float savedUsd, float consumedUsd) {
  if (consumedUsd <= 0.0f) return 0.0f;
  return (savedUsd / consumedUsd) * 100.0f;
}

Aggregate aggregateFromView(const ViewStats &view) {
  Aggregate agg;
  agg.saved = view.saved;
  agg.input = view.input;
  agg.usd = view.usd;
  agg.cost = view.cost;
  return agg;
}

bool parseView(JsonVariantConst node, PeriodMode mode, ViewStats &view) {
  clearView(view);
  JsonObjectConst obj = node.as<JsonObjectConst>();
  if (obj.isNull()) {
    copyString(view.title, sizeof(view.title), defaultChartTitle(mode));
    return false;
  }

  copyString(view.title, sizeof(view.title), obj["title"] | defaultChartTitle(mode));
  view.cost = asFloat(obj["consumed_usd"]);
  view.usd = asFloat(obj["saved_usd"]);
  view.input = asUInt(obj["input_tokens"]);
  view.saved = asUInt(obj["saved_tokens"]);
  view.avgPct = obj["avg_pct"].isNull() ? computeAvgPct(view.usd, view.cost) : asFloat(obj["avg_pct"]);

  JsonArrayConst series = obj["series"].as<JsonArrayConst>();
  size_t count = 0;
  for (JsonObjectConst point : series) {
    if (count >= kMaxSeriesPoints) break;
    const char *label = point["label"].isNull() ? (point["x"] | "") : (point["label"] | "");
    copyString(view.points[count].label, sizeof(view.points[count].label), label);
    view.points[count].cost = asFloat(point["consumed_usd"]);
    view.points[count].usd = asFloat(point["saved_usd"]);
    view.points[count].input = asUInt(point["input_tokens"]);
    view.points[count].saved = asUInt(point["saved_tokens"]);
    ++count;
  }
  view.pointCount = count;
  return viewHasData(view);
}

TouchTransform composeTransform(bool swapAxes, bool flipX, bool flipY) {
  if (!swapAxes) {
    if (!flipX && !flipY) return TouchXY;
    if (flipX && !flipY) return TouchXYFlipX;
    if (!flipX && flipY) return TouchXYFlipY;
    return TouchXYFlipXY;
  }
  if (!flipX && !flipY) return TouchYX;
  if (flipX && !flipY) return TouchYXFlipX;
  if (!flipX && flipY) return TouchYXFlipY;
  return TouchYXFlipXY;
}

void resetTouchCalibration() {
  touchCalibration = TouchCalibration{};
  activeTouchTransform = TouchXY;
  touchTransformLocked = false;
  calibrationStep = 0;
}

void saveTouchCalibration() {
  prefs.begin("touchcfg", false);
  prefs.putUInt("magic", kTouchPrefsMagic);
  prefs.putBool("swap", touchCalibration.swapAxes);
  prefs.putBool("flipX", touchCalibration.flipX);
  prefs.putBool("flipY", touchCalibration.flipY);
  prefs.putShort("minX", touchCalibration.minX);
  prefs.putShort("maxX", touchCalibration.maxX);
  prefs.putShort("minY", touchCalibration.minY);
  prefs.putShort("maxY", touchCalibration.maxY);
  prefs.end();
}

bool loadTouchCalibration() {
  prefs.begin("touchcfg", true);
  const uint32_t magic = prefs.getUInt("magic", 0);
  if (magic != kTouchPrefsMagic) {
    prefs.end();
    return false;
  }

  touchCalibration.valid = true;
  touchCalibration.swapAxes = prefs.getBool("swap", false);
  touchCalibration.flipX = prefs.getBool("flipX", false);
  touchCalibration.flipY = prefs.getBool("flipY", false);
  touchCalibration.minX = prefs.getShort("minX", kTouchMin);
  touchCalibration.maxX = prefs.getShort("maxX", kTouchMax);
  touchCalibration.minY = prefs.getShort("minY", kTouchMin);
  touchCalibration.maxY = prefs.getShort("maxY", kTouchMax);
  prefs.end();

  activeTouchTransform = composeTransform(touchCalibration.swapAxes, touchCalibration.flipX, touchCalibration.flipY);
  touchTransformLocked = true;
  return true;
}

int16_t normalizeTimeZoneOffset(int16_t minutes) {
  minutes = constrain(minutes, kMinTimeZoneMinutes, kMaxTimeZoneMinutes);
  int remainder = minutes % kTimeZoneStepMinutes;
  if (remainder != 0) {
    minutes -= remainder;
  }
  return minutes;
}

int timeZoneOptionCount() {
  return ((kMaxTimeZoneMinutes - kMinTimeZoneMinutes) / kTimeZoneStepMinutes) + 1;
}

int timeZoneOptionIndexFromOffset(int16_t offsetMinutes) {
  return (normalizeTimeZoneOffset(offsetMinutes) - kMinTimeZoneMinutes) / kTimeZoneStepMinutes;
}

int16_t timeZoneOffsetFromOptionIndex(int index) {
  return kMinTimeZoneMinutes + static_cast<int16_t>(index * kTimeZoneStepMinutes);
}

void syncTimeZoneMenuWindow() {
  const int total = timeZoneOptionCount();
  const int currentIndex = timeZoneOptionIndexFromOffset(timeZoneOffsetMinutes);
  int startIndex = currentIndex - static_cast<int>(kVisibleTimeZoneItems / 2);
  if (startIndex < 0) startIndex = 0;
  const int maxStart = max(0, total - static_cast<int>(kVisibleTimeZoneItems));
  if (startIndex > maxStart) startIndex = maxStart;
  timeZoneMenuStartIndex = static_cast<uint8_t>(startIndex);
}

void saveMonitorSettings() {
  prefs.begin("hrm2cfg", false);
  prefs.putUShort("low", alertLowMax);
  prefs.putUShort("medium", alertMediumMax);
  prefs.putShort("tzMin", timeZoneOffsetMinutes);
  prefs.end();
}

void loadMonitorSettings() {
  prefs.begin("hrm2cfg", true);
  alertLowMax = prefs.getUShort("low", 50);
  alertMediumMax = prefs.getUShort("medium", 100);
  timeZoneOffsetMinutes = prefs.getShort("tzMin", kDefaultTimeZoneMinutes);
  prefs.end();

  if (alertLowMax < kAlertStep) alertLowMax = kAlertStep;
  if (alertMediumMax <= alertLowMax) alertMediumMax = alertLowMax + kAlertStep;
  if (alertMediumMax > 995) alertMediumMax = 995;
  if (alertLowMax >= alertMediumMax) alertLowMax = alertMediumMax - kAlertStep;
  timeZoneOffsetMinutes = normalizeTimeZoneOffset(timeZoneOffsetMinutes);
  syncTimeZoneMenuWindow();
}

void formatTimeZoneLabelForOffset(int16_t offsetMinutes, char *out, size_t len) {
  if (len == 0) return;
  const int totalMinutes = offsetMinutes;
  const char sign = totalMinutes < 0 ? '-' : '+';
  const int absMinutes = abs(totalMinutes);
  const int hours = absMinutes / 60;
  const int minutes = absMinutes % 60;
  snprintf(out, len, "UTC%c%02d:%02d", sign, hours, minutes);
}

void formatTimeZoneLabel(char *out, size_t len) {
  formatTimeZoneLabelForOffset(timeZoneOffsetMinutes, out, len);
}

void formatTimeZoneValue(char *out, size_t len) {
  if (len == 0) return;
  const int totalMinutes = timeZoneOffsetMinutes;
  const char sign = totalMinutes < 0 ? '-' : '+';
  const int absMinutes = abs(totalMinutes);
  const int hours = absMinutes / 60;
  const int minutes = absMinutes % 60;
  if (minutes == 0) {
    snprintf(out, len, "%c%d", sign, hours);
  } else {
    snprintf(out, len, "%c%d.%d", sign, hours, (minutes * 10) / 60);
  }
}

void sendBridgeControlState() {
  Serial.printf("HRMC {\"tz_offset_minutes\":%d}\n", static_cast<int>(timeZoneOffsetMinutes));
}

void maybeAnnounceBridgeReady() {
  if (hasDashboardData) return;

  const uint32_t now = millis();
  if ((now - lastBridgeReadyBeaconMs) < 3000u) return;

  lastBridgeReadyBeaconMs = now;
  Serial.println("HEADROOM_MONITOR_READY ili9342-320x240-r2");
  sendBridgeControlState();
}

bool parseFixedInt(const char *text, size_t start, size_t width, int &value) {
  if (text == nullptr) return false;
  int parsed = 0;
  for (size_t i = 0; i < width; ++i) {
    char ch = text[start + i];
    if (ch < '0' || ch > '9') return false;
    parsed = (parsed * 10) + (ch - '0');
  }
  value = parsed;
  return true;
}

bool parseTimestampParts(const char *text, int &year, int &month, int &day,
                         int &hour, int &minute, int &second, bool &hasTime) {
  if (text == nullptr || strlen(text) < 10) return false;
  if (!parseFixedInt(text, 0, 4, year) || !parseFixedInt(text, 5, 2, month) ||
      !parseFixedInt(text, 8, 2, day)) {
    return false;
  }

  hasTime = strlen(text) >= 19;
  hour = 0;
  minute = 0;
  second = 0;
  if (!hasTime) return true;

  return parseFixedInt(text, 11, 2, hour) && parseFixedInt(text, 14, 2, minute) &&
         parseFixedInt(text, 17, 2, second);
}

int32_t daysFromCivil(int year, unsigned month, unsigned day) {
  year -= month <= 2;
  const int era = (year >= 0 ? year : year - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(year - era * 400);
  const unsigned doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + static_cast<int>(doe) - 719468;
}

void civilFromDays(int32_t z, int &year, int &month, int &day) {
  z += 719468;
  const int era = (z >= 0 ? z : z - 146096) / 146097;
  const unsigned doe = static_cast<unsigned>(z - era * 146097);
  const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  year = static_cast<int>(yoe) + era * 400;
  const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const unsigned mp = (5 * doy + 2) / 153;
  day = static_cast<int>(doy - (153 * mp + 2) / 5 + 1);
  month = static_cast<int>(mp + (mp < 10 ? 3 : -9));
  year += month <= 2;
}

void applyTimeZoneOffset(int &year, int &month, int &day, int &hour, int &minute) {
  int totalMinutes = hour * 60 + minute + timeZoneOffsetMinutes;
  int dayOffset = 0;
  while (totalMinutes < 0) {
    totalMinutes += 1440;
    --dayOffset;
  }
  while (totalMinutes >= 1440) {
    totalMinutes -= 1440;
    ++dayOffset;
  }

  if (dayOffset != 0) {
    const int32_t shifted = daysFromCivil(year, static_cast<unsigned>(month), static_cast<unsigned>(day)) + dayOffset;
    civilFromDays(shifted, year, month, day);
  }

  hour = totalMinutes / 60;
  minute = totalMinutes % 60;
}

void updateStatusLed(AlertLevel level) {
  uint8_t r = 0;
  uint8_t g = 0;
  uint8_t b = 0;
  switch (level) {
    case AlertMedium:
      r = 255;
      g = 110;
      break;
    case AlertHigh:
      r = 255;
      break;
    case AlertLow:
    default:
      g = 255;
      break;
  }
  statusLed.setPixelColor(0, statusLed.Color(r, g, b));
  statusLed.show();
}

void resetWaitingMatrixColumn(uint8_t index, bool randomizeY) {
  WaitingMatrixColumn &column = waitingMatrix[index];
  column.x = 10 + index * 17 + random(0, 6);
  column.speed = static_cast<uint8_t>(6 + random(0, 5));
  column.length = static_cast<uint8_t>(6 + random(0, 7));
  column.seed = static_cast<uint16_t>(random(0, 2048));
  column.headY = randomizeY ? random(kWaitingMatrixTop, kWaitingMatrixBottom + 24)
                            : random(kWaitingMatrixTop - 80, kWaitingMatrixTop - 8);
}

void initWaitingMatrix() {
  for (uint8_t i = 0; i < kWaitingMatrixColumns; ++i) {
    resetWaitingMatrixColumn(i, true);
  }
  waitingMatrixInitialized = true;
  lastWaitingMatrixMs = millis();
  waitingMatrixFrame = 0;
}

void advanceWaitingMatrix() {
  if (!waitingMatrixInitialized) initWaitingMatrix();
  ++waitingMatrixFrame;
  for (uint8_t i = 0; i < kWaitingMatrixColumns; ++i) {
    WaitingMatrixColumn &column = waitingMatrix[i];
    column.headY += column.speed;
    if (column.headY - static_cast<int16_t>(column.length * 11) > kWaitingMatrixBottom + 12) {
      resetWaitingMatrixColumn(i, false);
    }
  }
}

void drawWaitingMatrix() {
  if (!waitingMatrixInitialized) initWaitingMatrix();
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(1);
  for (uint8_t i = 0; i < kWaitingMatrixColumns; ++i) {
    const WaitingMatrixColumn &column = waitingMatrix[i];
    for (uint8_t j = 0; j < column.length; ++j) {
      const int16_t y = column.headY - static_cast<int16_t>(j * 11);
      if (y < kWaitingMatrixTop || y > kWaitingMatrixBottom) continue;

      const uint8_t intensity = j == 0 ? 255 : static_cast<uint8_t>(max(45, 180 - j * 22));
      const uint8_t glow = j == 0 ? 120 : static_cast<uint8_t>(max(0, 30 - j * 3));
      ui.setTextColor(rgb(intensity, glow, glow), TFT_BLACK);

      char digit[2];
      digit[0] = ((column.seed + waitingMatrixFrame + j) & 1U) ? '1' : '0';
      digit[1] = '\0';
      ui.drawString(digit, column.x, y);
    }
  }
}

void beginCalibration() {
  uiMode = UiCalibration;
  calibrationStep = 0;
  touchCalibration.valid = false;
  touchTransformLocked = false;
  needsRender = true;
}

int16_t averagePair(int32_t a, int32_t b) {
  return static_cast<int16_t>((a + b) / 2);
}

bool solveAxis(int32_t firstRaw, int32_t secondRaw, int16_t firstScreen, int16_t secondScreen,
               int16_t logicalMax, bool flipped, int16_t &minOut, int16_t &maxOut) {
  if (firstScreen == secondScreen || firstRaw == secondRaw) return false;
  const float screenSpan = static_cast<float>(secondScreen - firstScreen);
  const float maxLogical = static_cast<float>(logicalMax);
  if (!flipped) {
    const float scale = static_cast<float>(secondRaw - firstRaw) / screenSpan;
    const float minValue = static_cast<float>(firstRaw) - scale * static_cast<float>(firstScreen);
    const float maxValue = minValue + scale * maxLogical;
    minOut = static_cast<int16_t>(lroundf(minValue));
    maxOut = static_cast<int16_t>(lroundf(maxValue));
  } else {
    const float scale = static_cast<float>(firstRaw - secondRaw) / screenSpan;
    const float maxValue = static_cast<float>(firstRaw) + scale * static_cast<float>(firstScreen);
    const float minValue = maxValue - scale * maxLogical;
    minOut = static_cast<int16_t>(lroundf(minValue));
    maxOut = static_cast<int16_t>(lroundf(maxValue));
  }
  if (minOut > maxOut) {
    int16_t temp = minOut;
    minOut = maxOut;
    maxOut = temp;
  }
  minOut = constrain(minOut, 0, 4095);
  maxOut = constrain(maxOut, 0, 4095);
  return maxOut - minOut >= 200;
}

bool computeCalibration() {
  float bestError = 1.0e9f;
  TouchCalibration best;

  for (uint8_t swapCandidate = 0; swapCandidate < 2; ++swapCandidate) {
    const bool swapAxes = swapCandidate == 1;
    const int32_t tlX = swapAxes ? calibrationPoints[0].y : calibrationPoints[0].x;
    const int32_t trX = swapAxes ? calibrationPoints[1].y : calibrationPoints[1].x;
    const int32_t brX = swapAxes ? calibrationPoints[2].y : calibrationPoints[2].x;
    const int32_t blX = swapAxes ? calibrationPoints[3].y : calibrationPoints[3].x;
    const int32_t tlY = swapAxes ? calibrationPoints[0].x : calibrationPoints[0].y;
    const int32_t trY = swapAxes ? calibrationPoints[1].x : calibrationPoints[1].y;
    const int32_t brY = swapAxes ? calibrationPoints[2].x : calibrationPoints[2].y;
    const int32_t blY = swapAxes ? calibrationPoints[3].x : calibrationPoints[3].y;

    const int16_t leftX = averagePair(tlX, blX);
    const int16_t rightX = averagePair(trX, brX);
    const int16_t topY = averagePair(tlY, trY);
    const int16_t bottomY = averagePair(blY, brY);
    const bool flipX = leftX > rightX;
    const bool flipY = topY > bottomY;

    TouchCalibration candidate;
    candidate.swapAxes = swapAxes;
    candidate.flipX = flipX;
    candidate.flipY = flipY;
    candidate.valid = true;
    if (!solveAxis(leftX, rightX, kCalLeftX, kCalRightX, kUiW - 1, flipX, candidate.minX, candidate.maxX)) continue;
    if (!solveAxis(topY, bottomY, kCalTopY, kCalBottomY, kUiH - 1, flipY, candidate.minY, candidate.maxY)) continue;

    float error = 0.0f;
    for (uint8_t i = 0; i < 4; ++i) {
      int16_t mappedX = 0;
      int16_t mappedY = 0;
      const TS_Point point = {static_cast<int16_t>(calibrationPoints[i].x), static_cast<int16_t>(calibrationPoints[i].y), 0};
      int32_t rawX = point.x;
      int32_t rawY = point.y;
      if (candidate.swapAxes) {
        int32_t temp = rawX;
        rawX = rawY;
        rawY = temp;
      }
      rawX = constrain(rawX, candidate.minX, candidate.maxX);
      rawY = constrain(rawY, candidate.minY, candidate.maxY);
      mappedX = candidate.flipX ? map(rawX, candidate.maxX, candidate.minX, 0, kUiW - 1)
                                : map(rawX, candidate.minX, candidate.maxX, 0, kUiW - 1);
      mappedY = candidate.flipY ? map(rawY, candidate.maxY, candidate.minY, 0, kUiH - 1)
                                : map(rawY, candidate.minY, candidate.maxY, 0, kUiH - 1);
      const int16_t targetX = (i == 0 || i == 3) ? kCalLeftX : kCalRightX;
      const int16_t targetY = (i < 2) ? kCalTopY : kCalBottomY;
      const float dx = static_cast<float>(mappedX - targetX);
      const float dy = static_cast<float>(mappedY - targetY);
      error += dx * dx + dy * dy;
    }

    if (error < bestError) {
      bestError = error;
      best = candidate;
    }
  }

  if (!best.valid) return false;
  touchCalibration = best;
  activeTouchTransform = composeTransform(best.swapAxes, best.flipX, best.flipY);
  touchTransformLocked = true;
  touchCalibration.valid = true;
  return true;
}

size_t clampIndex(int value) {
  if (dayCount == 0 || value <= 0) return 0;
  if (static_cast<size_t>(value) >= dayCount) return dayCount - 1;
  return static_cast<size_t>(value);
}

bool sameMonth(size_t a, size_t b) {
  return strncmp(days[a].date, days[b].date, 7) == 0;
}

bool sameDatePrefix(const char *timestamp, const char *date) {
  return timestamp != nullptr && date != nullptr && strncmp(timestamp, date, 10) == 0;
}

bool sameMonthPrefix(const char *timestamp, const char *date) {
  return timestamp != nullptr && date != nullptr && strncmp(timestamp, date, 7) == 0;
}

void currentRange(size_t &start, size_t &end) {
  end = clampIndex(static_cast<int>(selectedEnd));
  start = end;
  if (dayCount == 0) return;
  if (periodMode == ModeWeek) {
    start = end > 6 ? end - 6 : 0;
  } else if (periodMode == ModeMonth) {
    while (start > 0 && sameMonth(start - 1, end)) --start;
  }
}

Aggregate aggregateRange(size_t start, size_t end) {
  Aggregate result;
  if (dayCount == 0) return result;
  start = clampIndex(static_cast<int>(start));
  end = clampIndex(static_cast<int>(end));
  if (start > end) {
    size_t tmp = start;
    start = end;
    end = tmp;
  }
  for (size_t i = start; i <= end; ++i) {
    result.saved += days[i].saved;
    result.input += days[i].input;
    result.usd += days[i].usd;
    result.cost += days[i].cost;
    if (i == end) break;
  }
  return result;
}

AlertLevel alertLevelFor(float cost) {
  if (cost < static_cast<float>(alertLowMax)) return AlertLow;
  if (cost < static_cast<float>(alertMediumMax)) return AlertMedium;
  return AlertHigh;
}

uint16_t alertColor(AlertLevel level) {
  switch (level) {
    case AlertMedium: return rgb(255, 165, 0);
    case AlertHigh: return rgb(255, 0, 0);
    case AlertLow:
    default: return rgb(0, 255, 0);
  }
}

const char *alertName(AlertLevel level) {
  switch (level) {
    case AlertMedium: return "MEDIUM";
    case AlertHigh: return "HIGH";
    case AlertLow:
    default: return "LOW";
  }
}

void formatRangeLabel(uint16_t fromValue, const char *toText, char *out, size_t len) {
  snprintf(out, len, "%u-%s", static_cast<unsigned>(fromValue), toText);
}

void changeThreshold(uint16_t &value, int delta, uint16_t minValue, uint16_t maxValue) {
  int next = static_cast<int>(value) + delta * static_cast<int>(kAlertStep);
  if (next < static_cast<int>(minValue)) next = minValue;
  if (next > static_cast<int>(maxValue)) next = maxValue;
  value = static_cast<uint16_t>(next);
}

void applyAlertOutput(AlertLevel level, float cost) {
  if (alertOutputInitialized && level == lastAlertLevel) return;
  lastAlertLevel = level;
  alertOutputInitialized = true;
  updateStatusLed(level);
  Serial.printf("ALERT_LEVEL %s cost=%.2f low=%u medium=%u\n",
                alertName(level), static_cast<double>(cost),
                static_cast<unsigned>(alertLowMax),
                static_cast<unsigned>(alertMediumMax));
}

const char *modeName() {
  switch (periodMode) {
    case ModeWeek: return "WEEK";
    case ModeMonth: return "MONTH";
    case ModeDay:
    default: return "DAY";
  }
}

void formatNumber(uint32_t value, char *out, size_t len) {
  if (value >= 1000000) {
    snprintf(out, len, "%.1fM", static_cast<double>(value) / 1000000.0);
  } else if (value >= 1000) {
    snprintf(out, len, "%.1fk", static_cast<double>(value) / 1000.0);
  } else {
    snprintf(out, len, "%lu", static_cast<unsigned long>(value));
  }
}

void formatMoney(float value, char *out, size_t len) {
  if (value >= 1000.0f) {
    snprintf(out, len, "$%.1fk", static_cast<double>(value) / 1000.0);
  } else {
    snprintf(out, len, "$%.2f", static_cast<double>(value));
  }
}

void formatMetric(float money, uint32_t tokens, char *out, size_t len) {
  char moneyText[18];
  char tokenText[18];
  formatMoney(money, moneyText, sizeof(moneyText));
  formatNumber(tokens, tokenText, sizeof(tokenText));
  snprintf(out, len, "%s/%s", moneyText, tokenText);
}

void drawTextFit(const char *text, int16_t x, int16_t y, int16_t maxW, uint8_t largeFont, uint8_t smallFont, uint16_t color, uint16_t bg) {
  ui.setTextDatum(TL_DATUM);
  ui.setTextColor(color, bg);
  ui.setTextFont(largeFont);
  if (ui.textWidth(text) > maxW) ui.setTextFont(smallFont);
  ui.drawString(text, x, y);
}

void drawMetricValue(float money, uint32_t tokens, int16_t x, int16_t y, int16_t maxW, uint16_t accent) {
  char moneyText[18];
  char tokenText[18];
  char fullText[32];
  formatMoney(money, moneyText, sizeof(moneyText));
  formatNumber(tokens, tokenText, sizeof(tokenText));
  snprintf(fullText, sizeof(fullText), "%s/%s", moneyText, tokenText);

  if (maxW <= 140) {
    drawTextFit(fullText, x, y + 5, maxW, 2, 1, accent, TFT_BLACK);
    return;
  }

  ui.setTextDatum(TL_DATUM);
  ui.setTextColor(accent, TFT_BLACK);
  ui.setTextFont(4);
  int16_t moneyW = ui.textWidth(moneyText);
  ui.setTextFont(2);
  int16_t tokenW = ui.textWidth("/") + ui.textWidth(tokenText);
  if (moneyW + tokenW + 2 > maxW) {
    drawTextFit(fullText, x, y + 4, maxW, 2, 1, accent, TFT_BLACK);
    return;
  }

  ui.setTextFont(4);
  ui.drawString(moneyText, x, y);
  ui.setTextFont(2);
  ui.drawString("/", x + moneyW + 1, y + 12);
  ui.drawString(tokenText, x + moneyW + 8, y + 12);
}

void drawLogo(int16_t yBase) {
  const uint16_t headerRed = rgb(255, 18, 12);
  ui.fillRoundRect(8, yBase + 8, 44, 28, 14, TFT_WHITE);
  ui.fillRoundRect(14, yBase + 14, 32, 16, 8, headerRed);
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(2);
  ui.setTextColor(TFT_WHITE, headerRed);
  ui.drawString("Codex", 62, yBase + 6);
  ui.drawString("Headroom", 62, yBase + 20);
}

void drawTab(int16_t x, int16_t w, const char *label, bool active) {
  uint16_t bg = rgb(190, 0, 0);
  ui.fillRoundRect(x, kHeaderButtonY, w, kHeaderButtonH, 4, bg);
  ui.drawRoundRect(x, kHeaderButtonY, w, kHeaderButtonH, 4, active ? TFT_WHITE : bg);
  ui.setTextDatum(MC_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(TFT_WHITE, bg);
  ui.drawString(label, x + (w / 2), kHeaderButtonY + 11);
}

void drawAlertIconButton(bool active) {
  uint16_t bg = rgb(190, 0, 0);
  ui.fillRoundRect(kAlertIconX, kHeaderButtonY, kAlertIconW, kHeaderButtonH, 4, bg);
  ui.drawRoundRect(kAlertIconX, kHeaderButtonY, kAlertIconW, kHeaderButtonH, 4, active ? TFT_WHITE : bg);

  const int16_t left = kAlertIconX + 4;
  const int16_t top = kHeaderButtonY + 4;
  ui.drawFastVLine(left, top, 14, TFT_WHITE);
  ui.fillCircle(left, top + 4, 2, TFT_WHITE);
  ui.drawFastVLine(left + 5, top, 14, TFT_WHITE);
  ui.fillCircle(left + 5, top + 10, 2, TFT_WHITE);
  ui.drawFastVLine(left + 10, top, 14, TFT_WHITE);
  ui.fillCircle(left + 10, top + 6, 2, TFT_WHITE);
}

void drawHeader() {
  int16_t y = 0;
  ui.fillRect(0, y, kUiW, 48, rgb(255, 18, 12));
  drawLogo(y);
  drawTab(kDayTabX, kDayTabW, "DAY", uiMode == UiDashboard && screenView == ViewDashboard && periodMode == ModeDay);
  drawTab(kWeekTabX, kWeekTabW, "WEEK", uiMode == UiDashboard && screenView == ViewDashboard && periodMode == ModeWeek);
  drawTab(kMonthTabX, kMonthTabW, "MONTH", uiMode == UiDashboard && screenView == ViewDashboard && periodMode == ModeMonth);
  drawAlertIconButton(screenView == ViewAlerts);
}

void drawCard(int16_t x, int16_t y, int16_t w, int16_t h, const char *label, float money, uint32_t tokens, uint16_t accent) {
  ui.drawRect(x, y, w, h, accent);
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(2);
  ui.setTextColor(rgb(145, 145, 145), TFT_BLACK);
  ui.drawString(label, x + 5, y + 4);
  drawMetricValue(money, tokens, x + 5, y + 18, w - 10, accent);
}

void drawAlertIndicator(int16_t x, int16_t y, AlertLevel level) {
  const uint16_t color = alertColor(level);
  ui.fillCircle(x, y, 4, color);
}

size_t buildActiveChart(ChartPoint *buffer, size_t maxCount) {
  if (buffer == nullptr || maxCount == 0) return 0;

  if (periodMode == ModeDay) {
    if (dayCount == 0 || hourlyCount == 0) return 0;
    const char *selectedDate = days[clampIndex(static_cast<int>(selectedEnd))].date;
    size_t count = 0;
    for (size_t i = 0; i < hourlyCount && count < maxCount; ++i) {
      if (!sameDatePrefix(hourlyPoints[i].timestamp, selectedDate)) continue;
      buffer[count++] = hourlyPoints[i];
    }
    if (count == 0) {
      size_t take = hourlyCount < maxCount ? hourlyCount : maxCount;
      size_t startIndex = hourlyCount > take ? hourlyCount - take : 0;
      for (size_t i = startIndex; i < hourlyCount; ++i) buffer[count++] = hourlyPoints[i];
    }
    return count;
  }

  if (periodMode == ModeWeek) {
    if (dayCount == 0) return 0;
    size_t startIndex = 0;
    size_t endIndex = 0;
    currentRange(startIndex, endIndex);
    size_t count = 0;
    for (size_t i = startIndex; i <= endIndex && count < maxCount; ++i) {
      copyString(buffer[count].timestamp, sizeof(buffer[count].timestamp), days[i].date);
      buffer[count].input = days[i].input;
      buffer[count].usd = days[i].usd;
      buffer[count].cost = days[i].cost;
      ++count;
      if (i == endIndex) break;
    }
    return count;
  }

  if (dayCount == 0 || weeklyCount == 0) return 0;
  const char *selectedDate = days[clampIndex(static_cast<int>(selectedEnd))].date;
  size_t count = 0;
  for (size_t i = 0; i < weeklyCount && count < maxCount; ++i) {
    if (!sameMonthPrefix(weeklyPoints[i].timestamp, selectedDate)) continue;
    buffer[count++] = weeklyPoints[i];
  }
  if (count == 0) {
    // ponytail: month view currently reuses proxy weekly buckets by start date.
    size_t take = weeklyCount < maxCount ? weeklyCount : maxCount;
    size_t startIndex = weeklyCount > take ? weeklyCount - take : 0;
    for (size_t i = startIndex; i < weeklyCount; ++i) buffer[count++] = weeklyPoints[i];
  }
  return count;
}

const char *chartTitle() {
  if (periodMode == ModeDay) return "USD by hour";
  if (periodMode == ModeWeek) return "USD by day";
  return "USD by week";
}

float chartTickStep(float maxValue) {
  float rawStep = maxValue / 5.0f;
  if (rawStep <= 5.0f) return 5.0f;

  float magnitude = 1.0f;
  while (rawStep > 50.0f) {
    rawStep /= 10.0f;
    magnitude *= 10.0f;
  }

  if (rawStep <= 10.0f) return 10.0f * magnitude;
  if (rawStep <= 20.0f) return 20.0f * magnitude;
  if (rawStep <= 25.0f) return 25.0f * magnitude;
  return 50.0f * magnitude;
}

float chartTopValue(float maxValue) {
  float step = chartTickStep(maxValue);
  float topValue = ceilf(maxValue / step) * step;
  if (topValue < step) topValue = step;
  return topValue;
}

void formatChartXLabel(const ChartPoint &point, char *label, size_t len) {
  if (len == 0) return;
  label[0] = '\0';
  if (point.timestamp[0] == '\0') return;

  int year = 0;
  int month = 0;
  int day = 0;
  int hour = 0;
  int minute = 0;
  int second = 0;
  bool hasTime = false;
  if (!parseTimestampParts(point.timestamp, year, month, day, hour, minute, second, hasTime)) return;
  if (hasTime) applyTimeZoneOffset(year, month, day, hour, minute);

  if (periodMode == ModeDay) {
    snprintf(label, len, "%02dh", hour);
    return;
  }

  snprintf(label, len, "%02d/%02d", day, month);
}

void drawChart(const ViewStats &view) {
  constexpr int16_t x0 = 40;
  constexpr int16_t y0 = 108;
  constexpr int16_t w = 272;
  constexpr int16_t h = 92;
  if (view.pointCount == 0) return;
  const size_t count = view.pointCount;

  const uint16_t grid = rgb(28, 28, 28);
  const uint16_t axis = rgb(92, 92, 92);
  const uint16_t lineColor = rgb(0, 255, 255);
  const uint16_t fillColor = rgb(0, 255, 0);
  float maxValue = 1.0f;
  for (size_t i = 0; i < count; ++i) {
    if (view.points[i].cost > maxValue) maxValue = view.points[i].cost;
    if (view.points[i].usd > maxValue) maxValue = view.points[i].usd;
  }
  const float topValue = chartTopValue(maxValue);
  const float tickStep = chartTickStep(maxValue);

  ui.setTextDatum(TR_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(rgb(145, 145, 145), TFT_BLACK);
  ui.drawString(view.title[0] ? view.title : defaultChartTitle(periodMode), x0 + w, y0 - 12);

  auto valueToY = [&](float value) -> int16_t {
    float normalized = value / topValue;
    if (normalized < 0.0f) normalized = 0.0f;
    if (normalized > 1.0f) normalized = 1.0f;
    return y0 + h - static_cast<int16_t>(normalized * static_cast<float>(h));
  };

  auto drawAreaSlice = [&](int16_t x, float costValue, float usdValue) {
    const int16_t baseY = y0 + h;
    if (costValue < 0.0f) costValue = 0.0f;
    if (usdValue < 0.0f) usdValue = 0.0f;
    if (usdValue > costValue) usdValue = costValue;

    const int16_t costY = valueToY(costValue);
    const int16_t savingsY = valueToY(usdValue);

    if (savingsY < baseY) {
      ui.drawFastVLine(x, savingsY, baseY - savingsY, fillColor);
    }
    if (costY < savingsY) {
      ui.drawFastVLine(x, costY, savingsY - costY, lineColor);
    } else if (costY < baseY && usdValue <= 0.0f) {
      ui.drawFastVLine(x, costY, baseY - costY, lineColor);
    }
  };

  auto drawAreaSegment = [&](int16_t xA, float costA, float usdA, int16_t xB, float costB, float usdB) {
    if (xB < xA) {
      const int16_t tempX = xA;
      const float tempCost = costA;
      const float tempUsd = usdA;
      xA = xB;
      costA = costB;
      usdA = usdB;
      xB = tempX;
      costB = tempCost;
      usdB = tempUsd;
    }
    const int16_t dx = xB - xA;
    if (dx == 0) {
      drawAreaSlice(xA, costA, usdA);
      return;
    }
    for (int16_t x = xA; x <= xB; ++x) {
      const float t = static_cast<float>(x - xA) / static_cast<float>(dx);
      const float cost = costA + ((costB - costA) * t);
      const float usd = usdA + ((usdB - usdA) * t);
      drawAreaSlice(x, cost, usd);
    }
  };

  if (count == 1) {
    const int16_t centerX = x0 + (w / 2);
    const float savingsValue = view.points[0].usd > view.points[0].cost ? view.points[0].cost : view.points[0].usd;
    const int16_t costY = valueToY(view.points[0].cost);
    const int16_t savingsY = valueToY(savingsValue);
    for (int16_t dx = -2; dx <= 2; ++dx) drawAreaSlice(centerX + dx, view.points[0].cost, view.points[0].usd);
    ui.drawLine(centerX - 2, costY, centerX + 2, costY, lineColor);
    if (savingsValue > 0.0f) {
      ui.drawLine(centerX - 2, savingsY, centerX + 2, savingsY, fillColor);
    }
  } else {
    int16_t lastX = x0;
    int16_t lastY = valueToY(view.points[0].cost);
    float firstSavings = view.points[0].usd > view.points[0].cost ? view.points[0].cost : view.points[0].usd;
    int16_t lastSavingsY = valueToY(firstSavings);
    for (size_t i = 1; i < count; ++i) {
      int16_t x = x0 + static_cast<int16_t>((static_cast<int32_t>(w) * static_cast<int32_t>(i)) / static_cast<int32_t>(count - 1));
      int16_t y = valueToY(view.points[i].cost);
      float savingsValue = view.points[i].usd > view.points[i].cost ? view.points[i].cost : view.points[i].usd;
      int16_t savingsY = valueToY(savingsValue);
      drawAreaSegment(lastX, view.points[i - 1].cost, view.points[i - 1].usd, x, view.points[i].cost, view.points[i].usd);
      ui.drawLine(lastX, lastY, x, y, lineColor);
      ui.drawLine(lastX, lastSavingsY, x, savingsY, fillColor);
      lastX = x;
      lastY = y;
      lastSavingsY = savingsY;
    }
  }

  ui.setTextDatum(TR_DATUM);
  ui.setTextColor(axis, TFT_BLACK);
  for (float tick = 0.0f; tick <= topValue + 0.1f; tick += tickStep) {
    const int16_t y = valueToY(tick);
    ui.drawFastHLine(x0, y, w, tick == 0.0f ? axis : grid);
    char tickLabel[12];
    snprintf(tickLabel, sizeof(tickLabel), "$%.0f", static_cast<double>(tick));
    ui.drawString(tickLabel, x0 - 6, y);
  }
  ui.drawFastVLine(x0, y0, h + 1, axis);
  ui.drawFastHLine(x0, y0 + h, w, axis);

  ui.setTextDatum(TC_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(axis, TFT_BLACK);
  size_t anchorIndexes[3];
  size_t anchorCount = 0;
  auto pushAnchorIndex = [&](size_t idx) {
    for (size_t i = 0; i < anchorCount; ++i) {
      if (anchorIndexes[i] == idx) return;
    }
    anchorIndexes[anchorCount++] = idx;
  };
  pushAnchorIndex(0);
  pushAnchorIndex(count / 2);
  pushAnchorIndex(count - 1);

  for (size_t anchor = 0; anchor < anchorCount; ++anchor) {
    size_t idx = anchorIndexes[anchor];
    int16_t x = count == 1 ? x0 + (w / 2)
                           : x0 + static_cast<int16_t>((static_cast<int32_t>(w) * static_cast<int32_t>(idx)) / static_cast<int32_t>(count - 1));
    const char *label = view.points[idx].label;
    if (anchor == 0) {
      ui.setTextDatum(TL_DATUM);
      ui.drawString(label, x + 12, y0 + h + 6);
    } else if (anchor == anchorCount - 1) {
      ui.setTextDatum(TR_DATUM);
      ui.drawString(label, x - 2, y0 + h + 6);
    } else {
      ui.setTextDatum(TC_DATUM);
      ui.drawString(label, x, y0 + h + 6);
    }
  }
}

void drawFooter(const ViewStats &view, AlertLevel level) {
  int16_t y = 218;
  const uint16_t footerBg = rgb(5, 5, 5);
  ui.fillRect(0, y, kUiW, 22, footerBg);
  ui.fillRect(kUiW - 80, y, 80, 22, TFT_BLACK);
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(TFT_WHITE, footerBg);
  ui.drawString("Made with", 5, y + 6);
  ui.setTextColor(rgb(255, 0, 0), footerBg);
  ui.drawString("love", 61, y + 6);
  ui.setTextColor(TFT_WHITE, footerBg);
  ui.drawString("by", 88, y + 6);
  ui.setTextColor(rgb(255, 0, 0), footerBg);
  ui.drawString("Joel Gangini", 102, y + 6);

  char avg[16];
  snprintf(avg, sizeof(avg), "AVG %.1f%%", static_cast<double>(view.avgPct));
  ui.fillRect(kUiW - 80, y, 80, 22, TFT_BLACK);
  drawAlertIndicator(kUiW - 74, y + 11, level);
  ui.setTextDatum(MC_DATUM);
  ui.setTextColor(rgb(255, 220, 0), TFT_BLACK);
  ui.drawString(avg, kUiW - 34, y + 11);
}

void buildLegacyViewsFromState() {
  const PeriodMode previousMode = periodMode;
  for (uint8_t modeIndex = 0; modeIndex < 3; ++modeIndex) {
    PeriodMode legacyMode = static_cast<PeriodMode>(modeIndex);
    ViewStats &view = viewForMode(legacyMode);
    clearView(view);
    copyString(view.title, sizeof(view.title), defaultChartTitle(legacyMode));
    periodMode = legacyMode;

    size_t start = 0;
    size_t end = 0;
    currentRange(start, end);
    Aggregate agg = aggregateRange(start, end);
    view.saved = agg.saved;
    view.input = agg.input;
    view.usd = agg.usd;
    view.cost = agg.cost;
    view.avgPct = computeAvgPct(view.usd, view.cost);

    ChartPoint chartPoints[kMaxSeriesPoints];
    const size_t count = buildActiveChart(chartPoints, kMaxSeriesPoints);
    for (size_t i = 0; i < count; ++i) {
      char label[12];
      formatChartXLabel(chartPoints[i], label, sizeof(label));
      copyString(view.points[i].label, sizeof(view.points[i].label), label);
      view.points[i].saved = 0;
      view.points[i].input = chartPoints[i].input;
      view.points[i].usd = chartPoints[i].usd;
      view.points[i].cost = chartPoints[i].cost;
    }
    view.pointCount = count;
  }

  periodMode = previousMode;
  hasDashboardData = viewHasData(viewForMode(ModeDay)) ||
                     viewHasData(viewForMode(ModeWeek)) ||
                     viewHasData(viewForMode(ModeMonth));
}

void drawCalibrationTarget(int16_t x, int16_t y, uint16_t color) {
  ui.drawFastHLine(x - 10, y, 21, color);
  ui.drawFastVLine(x, y - 10, 21, color);
  ui.drawCircle(x, y, 12, color);
  ui.fillCircle(x, y, 2, color);
}

void drawCalibrationScreen() {
  static const char *kSteps[4] = {
      "Tap top-left",
      "Tap top-right",
      "Tap bottom-right",
      "Tap bottom-left",
  };
  ui.fillScreen(TFT_BLACK);
  ui.setTextDatum(TC_DATUM);
  ui.setTextColor(TFT_WHITE, TFT_BLACK);
  ui.setTextFont(2);
  ui.drawString("Touch calibration", kUiW / 2, 8);
  ui.setTextFont(1);
  ui.setTextColor(rgb(190, 190, 190), TFT_BLACK);
  ui.drawString("Use the stylus and press each target once", kUiW / 2, 28);
  ui.setTextColor(rgb(255, 220, 0), TFT_BLACK);
  ui.drawString(kSteps[calibrationStep < 4 ? calibrationStep : 3], kUiW / 2, 42);

  const int16_t targetsX[4] = {kCalLeftX, kCalRightX, kCalRightX, kCalLeftX};
  const int16_t targetsY[4] = {kCalTopY, kCalTopY, kCalBottomY, kCalBottomY};
  for (uint8_t i = 0; i < 4; ++i) {
    drawCalibrationTarget(targetsX[i], targetsY[i], i == calibrationStep ? rgb(0, 255, 255) : rgb(70, 70, 70));
  }

  char progress[16];
  snprintf(progress, sizeof(progress), "%u / 4", static_cast<unsigned>(calibrationStep + 1));
  ui.setTextColor(TFT_WHITE, TFT_BLACK);
  ui.drawString(progress, kUiW / 2, 226);
}

void drawStepperButton(int16_t x, int16_t y, bool plus) {
  ui.drawRoundRect(x, y, 18, 18, 4, TFT_WHITE);
  ui.drawFastHLine(x + 5, y + 9, 8, TFT_WHITE);
  if (plus) ui.drawFastVLine(x + 9, y + 5, 8, TFT_WHITE);
}

void drawTimeZoneCombo(int16_t y) {
  constexpr int16_t comboX = 170;
  constexpr int16_t comboW = 134;
  constexpr uint16_t comboBg = 0x1082;
  char tzText[16];
  formatTimeZoneLabel(tzText, sizeof(tzText));

  ui.fillRoundRect(8, y, 304, 24, 4, TFT_BLACK);
  ui.drawRoundRect(8, y, 304, 24, 4, rgb(0, 255, 255));
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(2);
  ui.setTextColor(rgb(0, 255, 255), TFT_BLACK);
  ui.drawString("Timezone", 14, y + 4);

  ui.fillRoundRect(comboX, y + 3, comboW, 18, 4, comboBg);
  ui.drawRoundRect(comboX, y + 3, comboW, 18, 4, TFT_WHITE);
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(TFT_WHITE, comboBg);
  ui.drawString(tzText, comboX + 6, y + 7);
  ui.drawFastHLine(comboX + comboW - 20, y + 9, 8, TFT_WHITE);
  ui.drawLine(comboX + comboW - 18, y + 11, comboX + comboW - 16, y + 13, TFT_WHITE);
  ui.drawLine(comboX + comboW - 10, y + 11, comboX + comboW - 12, y + 13, TFT_WHITE);
}

void drawTimeZoneMenuOverlay() {
  constexpr int16_t panelX = 8;
  constexpr int16_t panelY = 94;
  constexpr int16_t panelW = 304;
  constexpr int16_t panelH = 128;
  constexpr int16_t listX = 14;
  constexpr int16_t listY = 112;
  constexpr int16_t listW = 292;
  constexpr int16_t menuRowH = 18;
  constexpr uint16_t panelBg = 0x0000;
  constexpr uint16_t menuBg = 0x0841;

  ui.fillRoundRect(panelX, panelY, panelW, panelH, 4, panelBg);
  ui.drawRoundRect(panelX, panelY, panelW, panelH, 4, TFT_WHITE);
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(rgb(145, 145, 145), panelBg);
  ui.drawString("Select timezone", panelX + 8, panelY + 6);

  auto drawMenuLabel = [&](int16_t rowY, const char *text, uint16_t borderColor, uint16_t textColor, uint16_t fillColor) {
    ui.fillRect(listX, rowY, listW, menuRowH, fillColor);
    ui.drawRect(listX, rowY, listW, menuRowH, borderColor);
    ui.setTextDatum(MC_DATUM);
    ui.setTextFont(1);
    ui.setTextColor(textColor, fillColor);
    ui.drawString(text, listX + (listW / 2), rowY + (menuRowH / 2));
  };

  drawMenuLabel(listY, "PREV", rgb(145, 145, 145), rgb(145, 145, 145), menuBg);
  const int selectedIndex = timeZoneOptionIndexFromOffset(timeZoneOffsetMinutes);
  for (uint8_t i = 0; i < kVisibleTimeZoneItems; ++i) {
    const int optionIndex = timeZoneMenuStartIndex + static_cast<int>(i);
    const int16_t rowY = listY + menuRowH * (i + 1);
    if (optionIndex >= timeZoneOptionCount()) {
      ui.fillRect(listX, rowY, listW, menuRowH, menuBg);
      ui.drawRect(listX, rowY, listW, menuRowH, rgb(40, 40, 40));
      continue;
    }
    char optionText[16];
    formatTimeZoneLabelForOffset(timeZoneOffsetFromOptionIndex(optionIndex), optionText, sizeof(optionText));
    const uint16_t border = optionIndex == selectedIndex ? rgb(0, 255, 255) : rgb(55, 55, 55);
    const uint16_t textColor = optionIndex == selectedIndex ? rgb(0, 255, 255) : TFT_WHITE;
    drawMenuLabel(rowY, optionText, border, textColor, optionIndex == selectedIndex ? rgb(18, 28, 28) : menuBg);
  }
  drawMenuLabel(listY + menuRowH * 5, "NEXT", rgb(145, 145, 145), rgb(145, 145, 145), menuBg);
}

void drawThresholdRow(int16_t y, const char *label, uint16_t fromValue, const char *toText,
                      uint16_t accent, bool editable, uint16_t value) {
  ui.drawRoundRect(8, y, 304, 24, 4, accent);
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(2);
  ui.setTextColor(accent, TFT_BLACK);
  ui.drawString(label, 14, y + 4);

  char rangeText[18];
  formatRangeLabel(fromValue, toText, rangeText, sizeof(rangeText));
  ui.setTextFont(1);
  ui.setTextColor(TFT_WHITE, TFT_BLACK);
  ui.drawString(rangeText, 70, y + 8);

  if (editable) {
    drawStepperButton(238, y + 3, false);
    ui.drawRoundRect(260, y + 3, 28, 18, 4, TFT_WHITE);
    ui.setTextDatum(MC_DATUM);
    ui.setTextFont(1);
    char valueText[8];
    snprintf(valueText, sizeof(valueText), "%u", static_cast<unsigned>(value));
    ui.drawString(valueText, 274, y + 12);
    drawStepperButton(292, y + 3, true);
  } else {
    ui.drawRoundRect(252, y + 3, 52, 18, 4, TFT_WHITE);
    ui.setTextDatum(MC_DATUM);
    ui.setTextFont(1);
    ui.drawString("AUTO", 278, y + 12);
  }
}

void drawAlertsConfig(const Aggregate &agg) {
  char lowTo[8];
  char mediumTo[8];
  snprintf(lowTo, sizeof(lowTo), "%u", static_cast<unsigned>(alertLowMax));
  snprintf(mediumTo, sizeof(mediumTo), "%u", static_cast<unsigned>(alertMediumMax));

  ui.fillRect(0, 56, kUiW, 184, TFT_BLACK);
  drawTimeZoneCombo(64);
  if (timeZoneMenuOpen) {
    drawTimeZoneMenuOverlay();
    return;
  }
  ui.setTextFont(1);
  ui.setTextColor(rgb(145, 145, 145), TFT_BLACK);
  ui.setTextDatum(TL_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(rgb(145, 145, 145), TFT_BLACK);
  ui.drawString("Alert ranges", 8, 98);
  drawThresholdRow(108, "Low", 0, lowTo, rgb(0, 255, 0), true, alertLowMax);
  drawThresholdRow(136, "Medium", alertLowMax, mediumTo, rgb(255, 165, 0), true, alertMediumMax);
  drawThresholdRow(164, "High", alertMediumMax, "MAX", rgb(255, 0, 0), false, 0);

  ui.drawRoundRect(8, 206, 304, 16, 4, TFT_WHITE);
  ui.setTextDatum(MC_DATUM);
  ui.setTextFont(1);
  ui.setTextColor(TFT_WHITE, TFT_BLACK);
  ui.drawString("CALIBRATE TOUCH", 160, 214);
}

void pushUi() {
  tft.setRotation(kPanelRotation);
}

void renderWaitingScreen(bool fullRefresh) {
  tft.setRotation(kPanelRotation);
  if (fullRefresh) {
    ui.fillScreen(TFT_BLACK);
    drawHeader();
  } else {
    ui.fillRect(0, 48, kUiW, kUiH - 48, TFT_BLACK);
  }
  drawWaitingMatrix();
  ui.setTextDatum(MC_DATUM);
  ui.setTextFont(4);
  ui.setTextColor(TFT_WHITE, TFT_BLACK);
  ui.drawString("Waiting", kUiW / 2, panelY(96, 24));
  pushUi();
}

void renderScreen() {
  tft.setRotation(kPanelRotation);
  if (uiMode == UiCalibration) {
    drawCalibrationScreen();
    pushUi();
    return;
  }

  if (!hasDashboardData) {
    renderWaitingScreen(true);
    return;
  }

  ui.fillScreen(TFT_BLACK);
  const ViewStats &view = currentView();
  Aggregate agg = aggregateFromView(view);
  const AlertLevel level = alertLevelFor(agg.cost);
  applyAlertOutput(level, agg.cost);

  drawHeader();
  if (screenView == ViewAlerts) {
    drawAlertsConfig(agg);
  } else {
    drawCard(8, 54, 148, 32, "Consumed", agg.cost, agg.input, rgb(0, 255, 255));
    drawCard(164, 54, 148, 32, "Savings", agg.usd, agg.saved, rgb(0, 255, 0));
    drawChart(view);
    drawFooter(view, level);
  }
  pushUi();
}

void clearDisplayMemory() {
  for (uint8_t rotation = 0; rotation < 4; ++rotation) {
    tft.setRotation(rotation);
    tft.fillScreen(TFT_BLACK);
  }
  tft.setRotation(kPanelRotation);
  tft.fillScreen(TFT_BLACK);
}

void selectMode(PeriodMode mode) {
  periodMode = mode;
  if (dayCount > 0) selectedEnd = dayCount - 1;
}

void cycleMode() {
  if (periodMode == ModeDay) {
    selectMode(ModeWeek);
  } else if (periodMode == ModeWeek) {
    selectMode(ModeMonth);
  } else {
    selectMode(ModeDay);
  }
}

void movePeriod(int delta) {
  if (dayCount == 0 || delta == 0) return;
  if (periodMode == ModeWeek) {
    selectedEnd = clampIndex(static_cast<int>(selectedEnd) + delta * 7);
  } else if (periodMode == ModeMonth) {
    size_t i = selectedEnd;
    if (delta < 0) {
      while (i > 0 && sameMonth(i, selectedEnd)) --i;
      selectedEnd = i;
    } else {
      while (i + 1 < dayCount && sameMonth(i + 1, selectedEnd)) ++i;
      if (i + 1 < dayCount) {
        size_t next = i + 1;
        while (next + 1 < dayCount && sameMonth(next + 1, next)) ++next;
        selectedEnd = next;
      } else {
        selectedEnd = dayCount - 1;
      }
    }
  } else {
    selectedEnd = clampIndex(static_cast<int>(selectedEnd) + delta);
  }
}

bool parseFrame(const char *line) {
  if (strncmp(line, "HRM2 ", 5) != 0) return false;
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, line + 5);
  if (err) {
    copyString(lastError, sizeof(lastError), err.c_str());
    return false;
  }

  JsonObject root = doc.as<JsonObject>();
  JsonObject session = root["session"];
  JsonObject live = root["live"];

  sessionStats.requests = asUInt(session["req"]);
  sessionStats.saved = asUInt(session["saved"]);
  sessionStats.input = asUInt(session["input"]);
  sessionStats.usd = asFloat(session["usd"]);
  sessionStats.pct = asFloat(session["pct"]);
  copyString(sessionStats.last, sizeof(sessionStats.last), session["last"] | "");

  liveStats.ok = root["ok"] | false;
  liveStats.rtkCommands = asUInt(live["rtkCmd"]);
  liveStats.rtkSaved = asUInt(live["rtkSaved"]);
  liveStats.rtkPct = asFloat(live["rtkPct"]);
  liveStats.uptime = asUInt(live["uptime"]);
  copyString(liveStats.proxy, sizeof(liveStats.proxy), live["proxy"] | "unknown");
  copyString(liveStats.timestamp, sizeof(liveStats.timestamp), root["ts"] | "");

  currentFrameVersion = root["v"] | 0;
  JsonObjectConst views = root["views"].as<JsonObjectConst>();
  if (!views.isNull()) {
    parseView(views["day"], ModeDay, viewForMode(ModeDay));
    parseView(views["week"], ModeWeek, viewForMode(ModeWeek));
    parseView(views["month"], ModeMonth, viewForMode(ModeMonth));
    hasDashboardData = viewHasData(viewForMode(ModeDay)) ||
                       viewHasData(viewForMode(ModeWeek)) ||
                       viewHasData(viewForMode(ModeMonth));
    dayCount = 0;
    hourlyCount = 0;
    weeklyCount = 0;
    lastFrameMs = millis();
    copyString(lastError, sizeof(lastError), "ok");
    return hasDashboardData;
  }

  JsonArray newDays = root["days"].as<JsonArray>();
  JsonObject chart = root["chart"];
  JsonArray hourly = chart["hourly"].as<JsonArray>();
  JsonArray weekly = chart["weekly"].as<JsonArray>();
  char previousDate[11] = "";
  if (dayCount > 0 && selectedEnd < dayCount) {
    copyString(previousDate, sizeof(previousDate), days[selectedEnd].date);
  }

  size_t i = 0;
  for (JsonObject day : newDays) {
    if (i >= kMaxDays) break;
    copyString(days[i].date, sizeof(days[i].date), day["d"] | "");
    days[i].saved = asUInt(day["saved"]);
    days[i].input = asUInt(day["input"]);
    days[i].usd = asFloat(day["usd"]);
    days[i].cost = asFloat(day["cost"]);
    ++i;
  }

  dayCount = i;
  if (dayCount > 0) {
    size_t matched = dayCount - 1;
    bool found = false;
    if (previousDate[0] != '\0') {
      for (size_t j = 0; j < dayCount; ++j) {
        if (strncmp(days[j].date, previousDate, sizeof(days[j].date) - 1) == 0) {
          matched = j;
          found = true;
          break;
        }
      }
    }
    selectedEnd = found ? matched : dayCount - 1;
  }
  hourlyCount = parseChartArray(hourly, hourlyPoints, kMaxHourlyPoints);
  weeklyCount = parseChartArray(weekly, weeklyPoints, kMaxWeeklyPoints);
  buildLegacyViewsFromState();
  lastFrameMs = millis();
  copyString(lastError, sizeof(lastError), "ok");
  return hasDashboardData;
}

void handleCommand(const char *line) {
  if (strcmp(line, "NEXT") == 0) {
    movePeriod(1);
    needsRender = true;
  } else if (strcmp(line, "PREV") == 0) {
    movePeriod(-1);
    needsRender = true;
  } else if (strcmp(line, "DAY") == 0) {
    selectMode(ModeDay);
    screenView = ViewDashboard;
    needsRender = true;
  } else if (strcmp(line, "WEEK") == 0) {
    selectMode(ModeWeek);
    screenView = ViewDashboard;
    needsRender = true;
  } else if (strcmp(line, "MONTH") == 0) {
    selectMode(ModeMonth);
    screenView = ViewDashboard;
    needsRender = true;
  } else if (strcmp(line, "ALERTS") == 0) {
    screenView = ViewAlerts;
    needsRender = true;
  } else if (strcmp(line, "DASHBOARD") == 0) {
    screenView = ViewDashboard;
    needsRender = true;
  } else if (strcmp(line, "CALIBRATE") == 0) {
    beginCalibration();
  } else if (strcmp(line, "HRMQ TZ") == 0 || strcmp(line, "HRMQ STATE") == 0) {
    sendBridgeControlState();
  } else if (strcmp(line, "PING") == 0) {
    Serial.println("HEADROOM_MONITOR_READY");
  } else if (parseFrame(line)) {
    needsRender = true;
  }
}

void readSerial() {
  while (Serial.available() > 0) {
    char c = static_cast<char>(Serial.read());
    if (c == '\r') continue;
    if (c == '\n') {
      lineBuffer[lineLen] = '\0';
      if (lineLen > 0) handleCommand(lineBuffer);
      lineLen = 0;
      continue;
    }
    if (lineLen + 1 < kMaxLine) {
      lineBuffer[lineLen++] = c;
    } else {
      lineLen = 0;
      copyString(lastError, sizeof(lastError), "serial line too long");
      needsRender = true;
    }
  }
}

int16_t mapTouchAxis(int32_t raw, int16_t minValue, int16_t maxValue, bool flipped, int16_t outMax) {
  raw = constrain(raw, minValue, maxValue);
  return flipped ? map(raw, maxValue, minValue, 0, outMax)
                 : map(raw, minValue, maxValue, 0, outMax);
}

void applyTouchTransform(const TS_Point &point, TouchTransform transform, int16_t &x, int16_t &y) {
  int32_t rawX = point.x;
  int32_t rawY = point.y;
  bool swapAxes = transform >= TouchYX;
  bool flipX = transform == TouchXYFlipX || transform == TouchXYFlipXY ||
               transform == TouchYXFlipX || transform == TouchYXFlipXY;
  bool flipY = transform == TouchXYFlipY || transform == TouchXYFlipXY ||
               transform == TouchYXFlipY || transform == TouchYXFlipXY;

  if (swapAxes) {
    int32_t temp = rawX;
    rawX = rawY;
    rawY = temp;
  }

  x = mapTouchAxis(rawX, kTouchMin, kTouchMax, flipX, kUiW - 1);
  y = mapTouchAxis(rawY, kTouchMin, kTouchMax, flipY, kUiH - 1);
}

void mapCalibratedTouch(const TS_Point &point, int16_t &x, int16_t &y) {
  int32_t rawX = point.x;
  int32_t rawY = point.y;
  if (touchCalibration.swapAxes) {
    int32_t temp = rawX;
    rawX = rawY;
    rawY = temp;
  }
  x = mapTouchAxis(rawX, touchCalibration.minX, touchCalibration.maxX, touchCalibration.flipX, kUiW - 1);
  y = mapTouchAxis(rawY, touchCalibration.minY, touchCalibration.maxY, touchCalibration.flipY, kUiH - 1);
}

TouchAction actionForPoint(int16_t x, int16_t y, int16_t &score) {
  if (y >= 6 && y <= 42) {
    if (x >= kDayTabX && x <= kDayTabX + kDayTabW) {
      score = abs(x - (kDayTabX + (kDayTabW / 2))) + abs(y - 24);
      return TouchSelectDay;
    }
    if (x >= kWeekTabX && x <= kWeekTabX + kWeekTabW) {
      score = abs(x - (kWeekTabX + (kWeekTabW / 2))) + abs(y - 24);
      return TouchSelectWeek;
    }
    if (x >= kMonthTabX && x <= kMonthTabX + kMonthTabW) {
      score = abs(x - (kMonthTabX + (kMonthTabW / 2))) + abs(y - 24);
      return TouchSelectMonth;
    }
    if (x >= kAlertIconX && x <= kAlertIconX + kAlertIconW) {
      score = abs(x - (kAlertIconX + (kAlertIconW / 2))) + abs(y - 24);
      return TouchToggleAlerts;
    }
  }

  if (screenView == ViewAlerts) {
    if (timeZoneMenuOpen) {
      if (x >= 170 && x <= 304 && y >= 67 && y <= 85) {
        score = abs(x - 237) + abs(y - 76);
        return TouchTimeZoneToggle;
      }
      if (x >= 14 && x <= 306 && y >= 112 && y <= 219) {
        const int row = (y - 112) / 18;
        score = abs(x - 160) + abs(y - (121 + row * 18));
        switch (row) {
          case 0:
            return TouchTimeZoneDown;
          case 1:
            return TouchTimeZonePick0;
          case 2:
            return TouchTimeZonePick1;
          case 3:
            return TouchTimeZonePick2;
          case 4:
            return TouchTimeZonePick3;
          default:
            return TouchTimeZoneUp;
        }
      }
      score = 0;
      return TouchTimeZoneToggle;
    }
    if (x >= 170 && x <= 304 && y >= 67 && y <= 85) {
      score = abs(x - 237) + abs(y - 76);
      return TouchTimeZoneToggle;
    }
    if (y >= 111 && y <= 129) {
      if (x >= 238 && x <= 256) {
        score = abs(x - 247) + abs(y - 120);
        return TouchLowDown;
      }
      if (x >= 292 && x <= 310) {
        score = abs(x - 301) + abs(y - 120);
        return TouchLowUp;
      }
    }
    if (y >= 139 && y <= 157) {
      if (x >= 238 && x <= 256) {
        score = abs(x - 247) + abs(y - 148);
        return TouchMediumDown;
      }
      if (x >= 292 && x <= 310) {
        score = abs(x - 301) + abs(y - 148);
        return TouchMediumUp;
      }
    }
    if (y >= 206 && y <= 222 && x >= 8 && x <= 312) {
      score = abs(x - 160) + abs(y - 214);
      return TouchStartCalibration;
    }
    score = 32767;
    return TouchNone;
  }

  if (x < kUiW / 5) {
    score = x;
    return TouchPrevRange;
  }
  if (x > (kUiW * 4) / 5) {
    score = (kUiW - 1) - x;
    return TouchNextRange;
  }

  score = 32767;
  return TouchNone;
}

bool isHeaderAction(TouchAction action) {
  return action == TouchSelectDay || action == TouchSelectWeek ||
         action == TouchSelectMonth || action == TouchToggleAlerts;
}

TouchCandidate findBestTouchCandidate(const TS_Point &point, bool headerOnly) {
  TouchCandidate best;
  for (uint8_t i = 0; i < TouchTransformCount; ++i) {
    TouchTransform transform = static_cast<TouchTransform>(i);
    int16_t x = 0;
    int16_t y = 0;
    int16_t score = 32767;
    applyTouchTransform(point, transform, x, y);
    TouchAction action = actionForPoint(x, y, score);
    if (action == TouchNone) continue;
    if (headerOnly && !isHeaderAction(action)) continue;
    if (best.action == TouchNone || score < best.score) {
      best.action = action;
      best.transform = transform;
      best.x = x;
      best.y = y;
      best.score = score;
    }
  }
  return best;
}

TouchCandidate resolveTouchCandidate(const TS_Point &point) {
  TouchCandidate current;
  if (touchCalibration.valid) {
    mapCalibratedTouch(point, current.x, current.y);
    current.transform = activeTouchTransform;
    current.action = actionForPoint(current.x, current.y, current.score);
    return current;
  }

  applyTouchTransform(point, activeTouchTransform, current.x, current.y);
  current.transform = activeTouchTransform;
  current.action = actionForPoint(current.x, current.y, current.score);

  if (touchTransformLocked && current.action != TouchNone) {
    return current;
  }

  TouchCandidate header = findBestTouchCandidate(point, true);
  if (header.action != TouchNone) return header;

  if (!touchTransformLocked && current.action != TouchNone) return current;
  if (touchTransformLocked) return current;
  return findBestTouchCandidate(point, false);
}

void runTouchAction(TouchAction action) {
  switch (action) {
    case TouchSelectDay:
      selectMode(ModeDay);
      screenView = ViewDashboard;
      timeZoneMenuOpen = false;
      break;
    case TouchSelectWeek:
      selectMode(ModeWeek);
      screenView = ViewDashboard;
      timeZoneMenuOpen = false;
      break;
    case TouchSelectMonth:
      selectMode(ModeMonth);
      screenView = ViewDashboard;
      timeZoneMenuOpen = false;
      break;
    case TouchPrevRange:
      if (screenView == ViewDashboard) movePeriod(-1);
      break;
    case TouchNextRange:
      if (screenView == ViewDashboard) movePeriod(1);
      break;
    case TouchToggleAlerts:
      screenView = screenView == ViewAlerts ? ViewDashboard : ViewAlerts;
      timeZoneMenuOpen = false;
      break;
    case TouchTimeZoneToggle:
      timeZoneMenuOpen = !timeZoneMenuOpen;
      if (timeZoneMenuOpen) syncTimeZoneMenuWindow();
      break;
    case TouchTimeZoneDown:
      if (timeZoneMenuStartIndex > 0) {
        --timeZoneMenuStartIndex;
      }
      break;
    case TouchTimeZoneUp:
      if (timeZoneMenuStartIndex + kVisibleTimeZoneItems < timeZoneOptionCount()) {
        ++timeZoneMenuStartIndex;
      }
      break;
    case TouchTimeZonePick0:
    case TouchTimeZonePick1:
    case TouchTimeZonePick2:
    case TouchTimeZonePick3: {
      const uint8_t visibleIndex = static_cast<uint8_t>(action - TouchTimeZonePick0);
      const int optionIndex = timeZoneMenuStartIndex + static_cast<int>(visibleIndex);
      if (optionIndex < timeZoneOptionCount()) {
        timeZoneOffsetMinutes = timeZoneOffsetFromOptionIndex(optionIndex);
        saveMonitorSettings();
        sendBridgeControlState();
      }
      timeZoneMenuOpen = false;
      break;
    }
    case TouchLowDown:
      changeThreshold(alertLowMax, -1, 5, alertMediumMax > kAlertStep ? alertMediumMax - kAlertStep : 5);
      saveMonitorSettings();
      break;
    case TouchLowUp:
      changeThreshold(alertLowMax, 1, 5, alertMediumMax > kAlertStep ? alertMediumMax - kAlertStep : 5);
      saveMonitorSettings();
      break;
    case TouchMediumDown:
      changeThreshold(alertMediumMax, -1, alertLowMax + kAlertStep, 995);
      saveMonitorSettings();
      break;
    case TouchMediumUp:
      changeThreshold(alertMediumMax, 1, alertLowMax + kAlertStep, 995);
      saveMonitorSettings();
      break;
    case TouchStartCalibration:
      beginCalibration();
      return;
    case TouchNone:
    default:
      return;
  }
  needsRender = true;
}

TS_Point sampleTouchPoint() {
  int32_t sumX = 0;
  int32_t sumY = 0;
  int samples = 0;
  for (int i = 0; i < 8; ++i) {
    TS_Point point = touch.getPoint();
    sumX += point.x;
    sumY += point.y;
    ++samples;
    delay(6);
    if (!touch.touched()) break;
  }
  TS_Point result;
  result.x = static_cast<int16_t>(sumX / samples);
  result.y = static_cast<int16_t>(sumY / samples);
  result.z = 0;
  return result;
}

void handleCalibrationTouch() {
  if (!touch.touched() || millis() - lastTouchMs < 350) return;
  const TS_Point point = sampleTouchPoint();
  lastTouchMs = millis();
  calibrationPoints[calibrationStep].x = point.x;
  calibrationPoints[calibrationStep].y = point.y;
  while (touch.touched()) delay(10);

  if (calibrationStep < 3) {
    ++calibrationStep;
    needsRender = true;
    return;
  }

  if (computeCalibration()) {
    saveTouchCalibration();
    uiMode = UiDashboard;
    screenView = ViewDashboard;
    Serial.printf("TOUCH_CAL saved swap=%u flipX=%u flipY=%u x=%d..%d y=%d..%d\n",
                  touchCalibration.swapAxes ? 1 : 0, touchCalibration.flipX ? 1 : 0,
                  touchCalibration.flipY ? 1 : 0, touchCalibration.minX, touchCalibration.maxX,
                  touchCalibration.minY, touchCalibration.maxY);
    copyString(lastError, sizeof(lastError), "ok");
  } else {
    resetTouchCalibration();
    copyString(lastError, sizeof(lastError), "touch calibration failed");
    uiMode = UiCalibration;
  }
  needsRender = true;
}

void handleTouch() {
  if (!touch.touched() || millis() - lastTouchMs < 300) return;
  TS_Point point = touch.getPoint();
  lastTouchMs = millis();

  TouchCandidate candidate = resolveTouchCandidate(point);
  if (candidate.action == TouchNone) return;

  if (!touchCalibration.valid) {
    activeTouchTransform = candidate.transform;
    touchTransformLocked = true;
    Serial.printf("TOUCH_LOCK t=%u raw=%d,%d ui=%d,%d action=%u\n",
                  static_cast<unsigned>(candidate.transform), point.x, point.y,
                  candidate.x, candidate.y, static_cast<unsigned>(candidate.action));
  }
  runTouchAction(candidate.action);
}

} // namespace

void setup() {
  Serial.begin(kBaud);
  delay(100);
  randomSeed(micros());
  statusLed.begin();
  statusLed.setBrightness(kStatusLedBrightness);
  statusLed.clear();
  statusLed.show();
  loadMonitorSettings();
  pinMode(TFT_BL, OUTPUT);
  ledcSetup(kBacklightChannel, 5000, 8);
  ledcAttachPin(TFT_BL, kBacklightChannel);
  ledcWrite(kBacklightChannel, kBacklightBrightness);

  tft.init();
  clearDisplayMemory();

  touchSpi.begin(kTouchClk, kTouchMiso, kTouchMosi, kTouchCs);
  touch.begin(touchSpi);
  touch.setRotation(0);

  if (!loadTouchCalibration()) {
    beginCalibration();
  }

  lastAlertPulseMs = millis();
  alertPulseVisible = true;
  lastBridgeReadyBeaconMs = 0;
  maybeAnnounceBridgeReady();
  renderScreen();
}

void loop() {
  readSerial();
  if (uiMode == UiCalibration) handleCalibrationTouch();
  else handleTouch();

  if (uiMode != UiCalibration && !hasDashboardData) {
    maybeAnnounceBridgeReady();
    if (millis() - lastWaitingMatrixMs > kWaitingMatrixFrameMs) {
      lastWaitingMatrixMs = millis();
      advanceWaitingMatrix();
      renderWaitingScreen(false);
    }
  }

  alertPulseVisible = true;

  static uint32_t lastStaleCheck = 0;
  if (millis() - lastStaleCheck > 1000) {
    lastStaleCheck = millis();
    if (lastFrameMs != 0 && millis() - lastFrameMs > kStaleMs) needsRender = true;
  }

  if (needsRender) {
    needsRender = false;
    renderScreen();
  }
}
