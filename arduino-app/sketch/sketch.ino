// Runs on the UNO Q's microcontroller (STM32).
// - Two LEDs = two lamps that can be dimmed. Python calls set_lamp(id, 0..100).
//   Lamp 1 -> pin D9, lamp 2 -> pin D5 (both PWM).
//   On the UNO Q, do NOT call pinMode() on PWM pins: analogWrite() sets them up.
// - LED matrix: an eye. Open while the glasses' AI sees this board (the hand
//   controls are armed), closed otherwise. Python calls set_eye(1 / 0).
#include <Arduino_RouterBridge.h>
#include <Arduino_LED_Matrix.h>

Arduino_LED_Matrix matrix;

const int LAMP1_PIN = 9;
const int LAMP2_PIN = 5;

const int ROWS = 8;
const int COLS = 13;
uint8_t frame[ROWS * COLS];

const char* EYE_OPEN[ROWS] = {
  ".............",
  "....#####....",
  "..##.....##..",
  ".#...###...#.",
  ".#...###...#.",
  "..##.....##..",
  "....#####....",
  ".............",
};

const char* EYE_CLOSED[ROWS] = {
  ".............",
  ".............",
  ".............",
  ".#.........#.",
  "..##.....##..",
  "....#####....",
  ".............",
  ".............",
};

void drawPattern(const char* rows[]) {
  for (int r = 0; r < ROWS; r++) {
    for (int c = 0; c < COLS; c++) {
      frame[r * COLS + c] = rows[r][c] == '#' ? 1 : 0;
    }
  }
  matrix.draw(frame);
}

void set_eye(int on) { drawPattern(on ? EYE_OPEN : EYE_CLOSED); }

// level 0..100 -> PWM 0..255
void set_lamp(int id, int level) {
  level = constrain(level, 0, 100);
  int pwm = map(level, 0, 100, 0, 255);
  if (id == 1) analogWrite(LAMP1_PIN, pwm);
  if (id == 2) analogWrite(LAMP2_PIN, pwm);
}

void setup() {
  matrix.begin();
  matrix.setGrayscaleBits(1);  // each pixel is just on (1) or off (0)
  Bridge.begin();
  Bridge.provide("set_eye", set_eye);
  Bridge.provide("set_lamp", set_lamp);
  set_eye(0);
  analogWrite(LAMP1_PIN, 0);
  analogWrite(LAMP2_PIN, 0);
}

void loop() {
  delay(10);
}
