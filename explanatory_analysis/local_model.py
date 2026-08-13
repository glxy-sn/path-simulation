from __future__ import annotations

import os
import re
import shutil
import threading
import uuid
from pathlib import Path
from typing import Any, Callable


MODEL_REPO = "Qwen/Qwen3-8B-GGUF"
MODEL_FILENAME = "Qwen3-8B-Q4_K_M.gguf"
MODEL_DISPLAY_NAME = "Qwen3-8B-Q4_K_M"
DEFAULT_MODEL_DIR = Path.home() / "Library/Application Support/Foodcourt/models"


def _default_download(repo_id: str, filename: str, cache_dir: Path) -> Path:
    from huggingface_hub import hf_hub_download

    return Path(
        hf_hub_download(
            repo_id=repo_id,
            filename=filename,
            cache_dir=cache_dir,
        )
    )


class LocalModelRuntime:
    """Own the downloaded GGUF and the single in-process llama.cpp runtime."""

    def __init__(
        self,
        model_path: str | Path | None = None,
        download: Callable[[str, str, Path], Path] | None = None,
        minimum_model_bytes: int | None = None,
    ) -> None:
        configured = model_path or os.getenv("FOODCOURT_LLM_MODEL_PATH")
        self.model_path = (
            Path(configured).expanduser().resolve()
            if configured
            else (DEFAULT_MODEL_DIR / MODEL_FILENAME).resolve()
        )
        self.repo_id = os.getenv("FOODCOURT_LLM_MODEL_REPO", MODEL_REPO)
        self.filename = os.getenv("FOODCOURT_LLM_MODEL_FILE", MODEL_FILENAME)
        self.minimum_model_bytes = minimum_model_bytes or int(
            os.getenv("FOODCOURT_LLM_MIN_MODEL_BYTES", "4500000000")
        )
        self._download = download or _default_download
        self._llm: Any | None = None
        self._lock = threading.RLock()
        self._state = "not_downloaded"
        self._error: str | None = None

    def _is_valid_model(self, path: Path) -> bool:
        try:
            return path.is_file() and path.stat().st_size >= self.minimum_model_bytes
        except OSError:
            return False

    def ensure_model(self) -> Path:
        with self._lock:
            if self._is_valid_model(self.model_path):
                return self.model_path

            self.model_path.parent.mkdir(parents=True, exist_ok=True)
            self._state = "downloading"
            self._error = None
            download_cache = self.model_path.parent / ".download-cache"
            temporary = self.model_path.with_name(
                f".{self.model_path.name}.{uuid.uuid4().hex}.partial"
            )
            try:
                downloaded = self._download(self.repo_id, self.filename, download_cache).resolve()
                if not self._is_valid_model(downloaded):
                    raise RuntimeError("Berkas Qwen3-8B yang diunduh tidak lengkap.")
                try:
                    os.link(downloaded, temporary)
                except OSError:
                    shutil.copyfile(downloaded, temporary)
                if not self._is_valid_model(temporary):
                    raise RuntimeError("Salinan sementara Qwen3-8B tidak lengkap.")
                os.replace(temporary, self.model_path)
                shutil.rmtree(download_cache, ignore_errors=True)
                self._state = "downloaded"
                return self.model_path
            except Exception as error:
                temporary.unlink(missing_ok=True)
                self._state = "error"
                self._error = str(error)
                raise

    def ensure_ready(self) -> None:
        with self._lock:
            if self._llm is not None:
                return
            model_path = self.ensure_model()
            self._state = "loading"
            try:
                from llama_cpp import Llama

                self._llm = Llama(
                    model_path=str(model_path),
                    n_ctx=int(os.getenv("FOODCOURT_LLM_NUM_CTX", "12288")),
                    n_gpu_layers=int(os.getenv("FOODCOURT_LLM_GPU_LAYERS", "-1")),
                    verbose=False,
                )
                self._state = "ready"
                self._error = None
            except Exception as error:
                self._state = "error"
                self._error = str(error)
                raise RuntimeError(f"Qwen3-8B gagal dimuat oleh llama.cpp: {error}") from error

    @staticmethod
    def _split_thinking(text: str, explicit: str = "") -> tuple[str, str]:
        thinking = explicit.strip()
        if re.search(r"<think>", text, flags=re.I) and not re.search(r"</think>", text, flags=re.I):
            unfinished = re.split(r"<think>", text, maxsplit=1, flags=re.I)[-1].strip()
            return "", thinking or unfinished
        blocks = re.findall(r"<think>(.*?)</think>", text, flags=re.I | re.S)
        if blocks and not thinking:
            thinking = "\n\n".join(block.strip() for block in blocks if block.strip())
        answer = re.sub(r"<think>.*?</think>", "", text, flags=re.I | re.S)
        answer = re.sub(r"^\s*</?think>\s*", "", answer, flags=re.I)
        return answer.strip(), thinking

    def generate(self, messages: list[dict[str, str]], max_tokens: int = 256) -> dict[str, Any]:
        self.ensure_ready()
        with self._lock:
            started_state = self._state
            response = self._llm.create_chat_completion(
                messages=messages,
                max_tokens=max_tokens,
                temperature=0.2,
                top_p=0.8,
            )
            choice = (response.get("choices") or [{}])[0]
            message = choice.get("message") or {}
            content, thinking = self._split_thinking(
                str(message.get("content") or ""),
                str(message.get("reasoning_content") or ""),
            )
            if not content:
                raise RuntimeError("Qwen3-8B tidak menghasilkan jawaban teks.")
            usage = response.get("usage") or {}
            return {
                "text": content,
                "thinking": thinking,
                "promptTokens": usage.get("prompt_tokens"),
                "completionTokens": usage.get("completion_tokens"),
                "finishReason": choice.get("finish_reason"),
                "runtimeState": started_state,
            }

    def status(self) -> dict[str, Any]:
        with self._lock:
            return {
                "runtime": "llama.cpp",
                "chatModel": MODEL_DISPLAY_NAME,
                "modelReady": self._llm is not None and self._state == "ready",
                "modelState": self._state,
                "modelPath": str(self.model_path),
                "modelError": self._error,
            }


_runtime: LocalModelRuntime | None = None
_runtime_lock = threading.Lock()


def get_model_runtime() -> LocalModelRuntime:
    global _runtime
    with _runtime_lock:
        if _runtime is None:
            _runtime = LocalModelRuntime()
        return _runtime
