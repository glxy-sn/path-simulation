# LLM Evaluation Report

Generated: `2026-08-13T07:21:57.208265Z`
Model: `Qwen3-8B-Q4_K_M`
Package/job: `72ebb6668052`

## Summary

- Schema validity: **0/2 (0%)**
- Selected entity accuracy: **0/2 (0%)**
- Unexpected area selections on no-area cases: **0**
- Cold-start end-to-end latency: **4070.032 ms**
- Warm end-to-end latency p50: **1867.309 ms**
- Warm end-to-end latency p95: **1867.309 ms**
- Internal pipeline latency p50/p95: **n/a / n/a**

## Visualizations

- [Open HTML report](report.html)

![Quality metrics](charts/quality.svg)

![Latency by case](charts/latency.svg)

![Case outcomes](charts/case_outcomes.svg)

## Per-case Results

| caseId | expectedArea | actualArea | schema | wallMs | pipelineMs | status |
|---|---|---|---:|---:|---:|---|
| flow-high-01 | flow-01 | none | no | 4070.032 | n/a | error |
| flow-high-02 | flow-01 | none | no | 1867.309 | n/a | error |

## Failures and Diagnostics

- `flow-high-01`: schema=runtime_error; entity_expected='flow-01',entity_actual=None; error=RuntimeError: Qwen3-8B gagal dimuat oleh llama.cpp: Failed to create llama_context
- `flow-high-02`: schema=runtime_error; entity_expected='flow-01',entity_actual=None; error=RuntimeError: Qwen3-8B gagal dimuat oleh llama.cpp: Failed to create llama_context
