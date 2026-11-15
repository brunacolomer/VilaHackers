# Runs on the UNO Q's Linux side.
# The iPhone app sends requests over Wi-Fi and we forward them to the sketch
# through the Router Bridge.
#
#   GET /device?name=lamp1&value=60   -> LED on pin D9 at 60 %
#   GET /device?name=lamp2&value=60   -> LED on pin D5 at 60 %
#   GET /device?name=eye&value=1      -> matrix eye open (1) / closed (0)
#   GET /device                       -> current state of everything
from arduino.app_utils import App, Bridge
from arduino.app_bricks.web_ui import WebUI

state = {"lamp1": 0, "lamp2": 0, "eye": 0}
ui = WebUI()


def apply(name: str, value: int):
    if name == "lamp1":
        Bridge.call("set_lamp", 1, value)
    elif name == "lamp2":
        Bridge.call("set_lamp", 2, value)
    elif name == "eye":
        value = 1 if value else 0
        Bridge.call("set_eye", value)
    else:
        return False
    state[name] = value
    print(f"{name} -> {value}")
    return True


def device(name: str = "", value: int = -1):
    if name and 0 <= value <= 100:
        if not apply(name, value):
            return {"error": f"unknown device '{name}'", "state": state}
    return state


ui.expose_api("GET", "/device", device)

App.run()
