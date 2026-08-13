# Local Analytics + RAG Notebooks

Environment dan model lokal disiapkan dengan:

```zsh
./scripts/setup_analysis_llm.zsh
```

Setup bersifat idempotent. Default model adalah GGUF resmi
`Qwen3-8B-Q4_K_M` yang dijalankan langsung melalui llama.cpp; kernel Jupyter
bernama `foodcourt-analysis`. Model diunduh otomatis ke Application Support
pada penggunaan pertama dan tidak disimpan di repository.

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

Resolver deterministik memilih evidence, metrik, dan `areaId` langsung dari
package analysis. Qwen dipanggil satu kali dalam mode non-thinking hanya untuk
merangkai penjelasan teks. Geometry dan floorplan overlay selalu diambil dan
dirender oleh post-processor, bukan dibuat model. Run baru berada di
`llm-rag-v2/`; run lama tetap dapat dibaca sebagai legacy.
