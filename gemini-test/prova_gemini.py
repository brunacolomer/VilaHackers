"""
Prova de la API de Gemini: classifica què està fent la persona que porta les
ulleres (vista en primera persona).

Ús:
  python3 prova_gemini.py --llista            # mostra els models disponibles
  python3 prova_gemini.py                     # classifica totes les fotos de ./fotos
  python3 prova_gemini.py foto1.jpg foto2.png # classifica fotos concretes
  python3 prova_gemini.py --video clip.mp4    # classifica un vídeo curt (<20 MB)
  python3 prova_gemini.py --sequencia         # fotos en ordre, com un stream, amb context

Cal la clau a la variable GEMINI_API_KEY. Model per defecte: gemini-3.5-flash-lite
(es pot canviar amb GEMINI_MODEL=nom-del-model).
"""
import enum
import logging
import warnings

# Hide noisy library warnings (old Python 3.9 / "thought_signature" parts).
warnings.filterwarnings("ignore")
logging.getLogger("google_genai").setLevel(logging.ERROR)
logging.getLogger("google_genai.types").setLevel(logging.ERROR)
import json
import os
import sys
import time
from pathlib import Path

from google import genai
from google.genai import types
from pydantic import BaseModel

MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash-lite")

# ── ESCENARIS ────────────────────────────────────────────────────────────────
# Per afegir, treure o canviar un escenari, només cal editar aquesta llista.
# Clau = el que respon el model (sense espais). Valor = com es reconeix.
ESCENARIS = {
    "estudiant": "at a desk with a laptop/computer and books, notes or paper; studying or working",
    "cuinant": "in a kitchen preparing food: cutting, stirring, pans, stove, ingredients",
    "llegint": "holding or looking at a book, e-reader or printed text up close",
    "brainrot": "scrolling a phone: short videos, social media feeds (TikTok, Instagram, Reels...)",
    "social": "with other people chatting or hanging out, faces in front of them (not working together, not mainly eating)",
    "treball_en_equip": "2+ people working together on one laptop, screen, whiteboard or paper (working, not just chatting)",
    "distraccio_portatil": "a laptop/computer screen showing YouTube, Netflix, social media, memes or a game (not study or work material)",
    "menjant": "eating: food, pizza, snacks or a plate in front of them or in their hand",
    "cafe": "a coffee break: holding a coffee cup or mug, not working (a quick sip while studying is not a break)",
    "descansant": "resting: lying or slouched on a sofa, beanbag or chair, looking at the ceiling or around, no screens",
    "xerrada": "attending a talk or workshop: audience, stage, speaker, projector or big screen in front",
    "caminant": "walking: corridor, stairs, street or floor ahead, moving between places",
    "altres": "none of the above",
}

PROMPT = (
    "You see input from smart glasses worn by a person (first-person view).\n"
    "Decide which SCENARIO the wearer is in right now, looking at the whole scene "
    "(objects, place, what their hands are doing), not just a single object.\n"
    "Scenarios:\n"
    + "\n".join(f"- {k}: {v}" for k, v in ESCENARIS.items())
    + "\nIf two could fit, pick the one that best describes what the wearer is actively doing."
    "\nAlso give a short reason in Catalan describing what you see."
)

Activitat = enum.Enum("Activitat", {k: k for k in ESCENARIS}, type=str)


class Resposta(BaseModel):
    activitat: Activitat
    breu_interrupcio: bool
    motiu: str


# How many frames IN A ROW must show a new scenario before we really switch.
# A quick glance at someone is 1 frame, so it never reaches this number.
CANVIS_NECESSARIS = 2

MIME = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
        ".webp": "image/webp", ".heic": "image/heic", ".mp4": "video/mp4", ".mov": "video/quicktime"}


def context_text(estat, frames):
    """Extra instructions telling the model what the wearer was doing before."""
    if estat is None:
        return "\nThere is no previous context. Set breu_interrupcio=false."
    return (
        f"\nCONTEXT: for the last {frames} frames the wearer has been in scenario '{estat}'. "
        "Rules:\n"
        "1. A brief, harmless glance away is NOT a change: looking at someone who walks by or says hi, "
        f"looking out of the window, taking a sip of water. In that case set breu_interrupcio=true "
        f"and activitat='{estat}'.\n"
        "2. A distraction is never a brief interruption. If the wearer is holding or looking at a "
        "phone screen (scrolling, videos, social media, chats), answer activitat='brainrot'; if a "
        "laptop shows YouTube, Netflix, social media or a game, answer 'distraccio_portatil'. In both "
        "cases breu_interrupcio=false, even if they were studying before. Detecting these "
        "distractions is the main goal.\n"
        "3. Otherwise set breu_interrupcio=false and answer the scenario you really see, if the scene "
        "clearly shows a different activity (they left the desk, are cooking, sat down with a group)."
    )


def pregunta(client, path: Path, extra: str = ""):
    """Sends one image/video to Gemini. Returns (answer dict, seconds)."""
    mime = MIME[path.suffix.lower()]
    inici = time.time()
    resp = client.models.generate_content(
        model=MODEL,
        contents=[types.Part.from_bytes(data=path.read_bytes(), mime_type=mime), PROMPT + extra],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=Resposta,
            temperature=0,
        ),
    )
    segons = time.time() - inici
    # Join only the text parts (ignores the hidden "thought_signature" part).
    parts = resp.candidates[0].content.parts or []
    text = "".join(p.text for p in parts if getattr(p, "text", None))
    return json.loads(text), segons


def mode_solt(client, fitxers):
    """Each photo on its own, no memory."""
    for f in fitxers:
        try:
            r, segons = pregunta(client, f, context_text(None, 0))
            print(f"{f.name:30} → {r['activitat']:20} ({segons:.1f} s)  {r['motiu']}")
        except Exception as e:
            print(f"{f.name:30} → ERROR: {e}")


def mode_sequencia(client, fitxers):
    """Photos in order, like a live stream: the model knows the current scenario,
    and the scenario only changes after CANVIS_NECESSARIS frames in a row."""
    estat, frames = None, 0          # current (stable) scenario and how long it lasts
    candidat, compte = None, 0       # possible new scenario and how many times in a row
    print(f"{'foto':30}   {'model diu':28} → {'ESTAT':20}  motiu")
    for f in fitxers:
        try:
            r, segons = pregunta(client, f, context_text(estat, frames))
        except Exception as e:
            print(f"{f.name:30} → ERROR: {e}")
            continue
        vist = r["activitat"]
        # A distraction (phone or laptop) is never "brief": it always counts as a real change.
        breu = r["breu_interrupcio"] and vist not in ("brainrot", "distraccio_portatil")

        if estat is None:
            estat, frames = vist, 1
        elif breu or vist == estat:
            frames += 1
            candidat, compte = None, 0
        else:
            if vist == candidat:
                compte += 1
            else:
                candidat, compte = vist, 1
            if compte >= CANVIS_NECESSARIS:
                estat, frames = candidat, compte
                candidat, compte = None, 0
            else:
                frames += 1

        diu = vist + (" (breu)" if breu else "")
        if candidat:
            diu += f" [{compte}/{CANVIS_NECESSARIS}]"
        print(f"{f.name:30}   {diu:28} → {estat:20}  ({segons:.1f} s) {r['motiu']}")


def main():
    if not os.environ.get("GEMINI_API_KEY"):
        sys.exit("Falta la clau: executa  export GEMINI_API_KEY='la-teva-clau'  i torna-ho a provar.")
    client = genai.Client()
    args = sys.argv[1:]

    if args[:1] == ["--llista"]:
        for m in client.models.list():
            print(m.name)
        return

    sequencia = "--sequencia" in args
    args = [a for a in args if a not in ("--sequencia", "--video")]

    if args:
        fitxers = [Path(a) for a in args]
    else:
        carpeta = Path(__file__).parent / "fotos"
        fitxers = sorted(p for p in carpeta.iterdir() if p.suffix.lower() in MIME)
        if not fitxers:
            sys.exit(f"No hi ha fotos a {carpeta}. Posa-n'hi algunes i torna-ho a provar.")
    fitxers = [f for f in fitxers if f.suffix.lower() in MIME]

    print(f"Model: {MODEL}   Mode: {'seqüència (amb context)' if sequencia else 'fotos soltes'}\n")
    if sequencia:
        mode_sequencia(client, fitxers)
    else:
        mode_solt(client, fitxers)


if __name__ == "__main__":
    main()
