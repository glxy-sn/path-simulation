# Legacy Tanya Data

Server chat terpisah pada port `8766` sudah dihentikan.

Tanya Data sekarang memakai satu pipeline backend pada port `8765`:

- planner dan narrator: `qwen3:14b`;
- evidence retrieval: `qwen3-embedding:0.6b`;
- geometry dan ranking: executor explanatory backend;
- sesi chat: tersimpan per `jobId` dan per `sessionId`.

Setup runtime berada di backend `be/path-simulation/scripts/setup_runtime.zsh`.
