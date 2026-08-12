# Local Analytics + RAG Notebooks

Environment dan model lokal disiapkan dengan:

```zsh
./scripts/setup_analysis_llm.zsh
```

Setup bersifat idempotent. Default model adalah `qwen3:14b` dan
`qwen3-embedding:0.6b`; kernel Jupyter bernama `foodcourt-analysis`.

## Urutan penggunaan

1. Buka kedua notebook dengan `./scripts/open_analysis_notebooks.zsh`.
2. Jalankan **Run All** pada `01_trajectory_explanatory_analysis.ipynb`.
   Notebook otomatis memilih job lengkap terbaru. Override opsional:
   `FOODCOURT_JOB_ID=<jobId>` sebelum membuka Jupyter.
3. Jika pertanyaan meja perlu didukung, gunakan canvas yang **embedded di notebook**:
   klik floorplan untuk setiap titik sudut (minimal tiga), lalu tekan
   **Tambah meja** dan **Simpan & rebuild**. Tanpa annotation, analysis lain
   tetap selesai.
4. Jalankan **Run All** pada `02_local_llm_retrieval.ipynb`, lalu gunakan widget
   **Ask Qwen3**.

Notebook pertama memperbarui `notebooks/output/latest.json`; notebook kedua
membaca pointer tersebut otomatis. Output analysis berada di
`notebooks/output/<jobId>/explanatory-v2/`, sedangkan setiap pertanyaan tersimpan
di `notebooks/output/<jobId>/llm-rag-v2/runs/<runId>/`.

Qwen3 menghasilkan `QueryPlan` terstruktur yang langsung dipakai executor untuk
menghitung seluruh populasi kandidat dan menetapkan `areaId`. Planner memakai
mode adaptif: attempt pertama compact tanpa raw thinking; deep thinking hanya
aktif otomatis bila plan awal invalid. Override tersedia melalui
`FOODCOURT_PLANNER_THINKING_MODE=always|adaptive|off` (default `adaptive`).
Geometry dan floorplan overlay selalu diambil dan dirender oleh post-processor
dari package analysis, bukan dibuat model. Run causal baru berada di
`llm-rag-v2/`; run `llm-rag-v1/` tetap terbaca sebagai legacy.
