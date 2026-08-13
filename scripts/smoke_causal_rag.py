#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from explanatory_analysis.rag import LocalRAG


def main() -> None:
    parser = argparse.ArgumentParser(description="Live smoke test untuk general retrieval + Qwen3-8B reasoning.")
    parser.add_argument("question", nargs="?", default="meja mana yang paling ramai dan apa dasar datanya?")
    args = parser.parse_args()
    rag = LocalRAG()
    result = rag.ask(args.question, show=False)
    payload = {
        "interpretation": result["interpretation"],
        "reasoningMode": result["grounding"]["mode"],
        "selectedAreaId": result["selectedAreaId"],
        "dataGrounding": result["dataGrounding"],
        "supportLevel": result["supportLevel"],
        "answer": result["answer"],
        "modelCallCount": result["usage"]["generation"]["modelCallCount"],
        "thinkingAvailable": result["usage"]["generation"]["thinkingAvailable"],
        "runId": result["artifacts"]["runId"],
        "overlay": result["artifacts"]["floorplanOverlay"],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
