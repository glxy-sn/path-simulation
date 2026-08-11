#!/usr/bin/env python3
"""Layanan tanya-jawab untuk aplikasi Foodcourt.

    GET  /health                 -> {"status", "model", "riwayat"}
    GET  /riwayat                -> {"riwayat": [nama, ...]}
    POST /chat  {nama, pertanyaan, riwayat?}  -> {"jawaban"}

BERDIRI SENDIRI di port 8766, terpisah dari engine analisis di 8765. Dua alasan:
engine itu milik orang lain dan tidak perlu diubah, dan chatbot yang mati tidak
boleh ikut mematikan analisis.

Pustaka standar saja — tidak menambah dependensi ke proyek. Yang perlu dipasang
cuma Ollama beserta modelnya, dan itu di luar Python.

Jalankan:
    python3 llm/chat_server.py
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import konteks as K

HOST, PORT = "127.0.0.1", 8766


class Handler(BaseHTTPRequestHandler):
    server_version = "FoodcourtChat/1.0"

    def log_message(self, fmt, *args):
        pass

    def _kirim(self, kode: int, isi: dict):
        raw = json.dumps(isi).encode()
        self.send_response(kode)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self):
        ruas = [r for r in urllib.parse.urlparse(self.path).path.split("/") if r]
        if ruas == ["health"]:
            return self._kirim(200, {"status": "ok", "model": K.MODEL,
                                     "riwayat": len(K.daftar_riwayat())})
        if ruas == ["riwayat"]:
            return self._kirim(200, {"riwayat": K.daftar_riwayat()})
        self._kirim(404, {"error": "rute tidak dikenal"})

    def do_POST(self):
        ruas = [r for r in urllib.parse.urlparse(self.path).path.split("/") if r]
        if ruas != ["chat"]:
            return self._kirim(404, {"error": "rute tidak dikenal"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError) as e:
            return self._kirim(400, {"error": f"body bukan JSON yang sah: {e}"})

        tanya = (req.get("pertanyaan") or "").strip()
        if not tanya:
            return self._kirim(400, {"error": "pertanyaan kosong"})

        # Nama riwayat datang dari luar; dicocokkan ke daftar yang ADA supaya
        # "../.." tidak bisa dipakai membaca berkas di luar folder riwayat.
        nama = req.get("nama") or ""
        tersedia = K.daftar_riwayat()
        if nama not in tersedia:
            return self._kirim(404, {
                "error": ("Belum ada analisis tersimpan. Jalankan satu analisis "
                          "dulu di aplikasi." if not tersedia
                          else f"Riwayat '{nama}' tidak ditemukan.")})

        try:
            ctx = K.susun_konteks(nama)
            jawab = K.tanya(tanya, ctx, req.get("riwayat") or [])
        except urllib.error.URLError:
            # Satu-satunya kegagalan yang bisa diperbaiki sendiri oleh pemakai,
            # jadi pesannya harus menyebut caranya — bukan "koneksi ditolak".
            return self._kirim(503, {"error": "Ollama belum jalan. Buka Terminal, "
                                              "jalankan: ollama serve"})
        except Exception as e:                                   # noqa: BLE001
            pesan = str(e)
            if "model" in pesan and "not found" in pesan:
                return self._kirim(503, {
                    "error": f"Model {K.MODEL} belum diunduh. Jalankan: "
                             f"ollama pull {K.MODEL}"})
            return self._kirim(500, {"error": f"chat gagal: {e}"})
        return self._kirim(200, {"jawaban": jawab})


def main():
    d = K.folder_riwayat()
    print(f"chat  : http://{HOST}:{PORT}")
    print(f"model : {K.MODEL}")
    print(f"riwayat: {d}")
    n = len(K.daftar_riwayat())
    if n == 0:
        print("PERINGATAN: belum ada analisis tersimpan — chatbot belum punya "
              "bahan. Jalankan satu analisis di aplikasi dulu.")
    else:
        print(f"         {n} analisis siap ditanyai")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
