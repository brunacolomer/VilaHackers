import json
from transformers import pipeline
from pathlib import Path

# 1. Identify the model we want to use
MODEL_ID = "HuggingFaceTB/SmolVLM2-500M-Video-Instruct"

print("Loading SmolVLM2...")

# 2. Load the model using the CPU
vlm = pipeline(
    "image-text-to-text",
    model=MODEL_ID,
    device=-1
)

print("Model loaded successfully!")

# 3. Prepare the image and our question
IMAGE_PATH = Path("images/test_cases/03_living_room.jpeg")
messages = [
    {
        "role": "user",
        "content": [
            {
                "type": "image",
                "path": str(IMAGE_PATH)
            },
            {
                "type": "text",
                "text": """
                
                Analyze this first-person image captured by smart glasses.

                Return exactly ONE JSON object with exactly these 3 fields:

                {
                    "environment": "value",
                    "activity": "value",
                    "lighting": "value"
                }

                Rules:
                - environment: Identify the type of place. Use a short description.
                - activity: Describe the visible activity. If unclear, use "unknown".
                - lighting: Use ONLY natural, artificial, mixed, dark, or unknown.
                - Do not describe objects.
                - Do not infer emotions or intentions.
                - Do not add, remove, or rename fields.
                - Do not repeat fields or generate multiple JSON objects.
                - No explanations, introductions or Markdown.

                Return the JSON object immediately.
                """
            }
        ]
    }
]

# 4. Ask the model to analyse the image
print("\nAnalysing image...")

result = vlm(
    text=messages,
    max_new_tokens=100
)

# 5. Extract the model's response
generated = result[0]["generated_text"]

if isinstance(generated, list):
    response = None

    for message in reversed(generated):
        if message.get("role") == "assistant":
            response = message["content"]
            break
else:
    response = generated

print("\nSmolVLM2 response:")
print(response)

# 6. Convert the response into JSON and save it


try:
    response = response.replace("```json", "").replace("```", "").strip()

    data = json.loads(response)

    # Normalize lighting output

    lighting = data["lighting"].strip().lower()

    LIGHTING_MAP = {
        "natural": "natural",
        "natural lighting": "natural",
        "artificial": "artificial",
        "artificial lighting": "artificial",
        "mixed": "mixed",
        "mixed lighting": "mixed",
        "dark": "dark",
        "dark lighting": "dark",
        "unknown": "unknown"
    }

    data["lighting"] = LIGHTING_MAP.get(lighting, "unknown")


    EXPECTED_KEYS = {"environment", "activity", "lighting"}

    if not isinstance(data, dict):
        raise ValueError("Output must be a JSON object")

    if set(data.keys()) != EXPECTED_KEYS:
        raise ValueError(f"Unexpected fields: {data.keys()}")

    if data["lighting"] not in {
        "natural", "artificial", "mixed", "dark", "unknown"
    }:
        raise ValueError("Invalid lighting value")

    if not all(isinstance(value, str) for value in data.values()):
        raise ValueError("All fields must contain strings")

    output_path = Path("results") / f"{IMAGE_PATH.stem}_analysis.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w", encoding="utf-8") as file:
        json.dump(data, file, indent=4, ensure_ascii=False)

    print(f"\nJSON file saved: {output_path}")

except (json.JSONDecodeError, TypeError, AttributeError, ValueError) as error:

    with open("analysis_raw.txt", "w", encoding="utf-8") as file:
        file.write(str(response))

    print("\nInvalid response. Saved raw output.")
    print(error)
