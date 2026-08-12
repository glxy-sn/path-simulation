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
    parser = argparse.ArgumentParser(description="Live smoke test untuk causal QueryPlan RAG.")
    parser.add_argument("question", nargs="?", default="area mana yang paling sepi atau yang jarang dilewati")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    rag = LocalRAG()
    if args.plan_only:
        plan, thinking, audit, _ = rag.plan_question(args.question)
        payload = {"queryPlan": plan.model_dump(), "thinkingChars": len(thinking), "thinkingAudit": audit}
    else:
        result = rag.ask(args.question, show=False)
        payload = {
            "interpretation": result["interpretation"],
            "assumption": result["assumption"],
            "queryPlan": result["queryPlan"],
            "selectedAreaId": result["selectedAreaId"],
            "dataGrounding": result["dataGrounding"],
            "supportLevel": result["supportLevel"],
            "answer": result["answer"],
            "thinkingStatus": result["thinkingAudit"]["status"],
            "runId": result["artifacts"]["runId"],
            "overlay": result["artifacts"]["floorplanOverlay"],
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
