"""Development-only persistent MLX Audio worker for the Qwen app prototype."""

from __future__ import annotations

from contextlib import redirect_stdout
import argparse
import json
import os
from pathlib import Path
import sys
import time


def emit(message: dict[str, object]) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    args = parser.parse_args()
    if not args.model.is_dir():
        emit({"type": "startup_error", "message": "The local Qwen model directory is missing."})
        return 2

    os.environ.update({
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
    })

    try:
        import mlx.core as mx
        try:
            from mlx_audio.stt.utils import load_model
        except ImportError:
            from mlx_audio.stt import load as load_model

        started = time.perf_counter()
        with redirect_stdout(sys.stderr):
            model = load_model(str(args.model))
        emit({
            "type": "ready",
            "load_seconds": time.perf_counter() - started,
            "mlx_available": mx.metal.is_available(),
        })
    except Exception:
        emit({"type": "startup_error", "message": "Qwen could not load its local MLX model."})
        return 1

    for line in sys.stdin:
        request: dict[str, object] = {}
        try:
            request = json.loads(line)
            request_id = str(request["request_id"])
            audio_path = Path(str(request["audio_path"]))
            max_tokens = int(request["max_tokens"])
            if not audio_path.is_file():
                raise FileNotFoundError("The recording file is unavailable.")
            if max_tokens < 1:
                raise ValueError("The output token limit must be positive.")

            mx.synchronize()
            started = time.perf_counter()
            with redirect_stdout(sys.stderr):
                result = model.generate(
                    str(audio_path),
                    batch_size=1,
                    chunk_duration=1200.0,
                    min_chunk_duration=1.0,
                    language="English",
                    max_tokens=min(max_tokens, 8_192),
                    temperature=0.0,
                    top_p=1.0,
                    top_k=0,
                    prefill_step_size=2048,
                    system_prompt=None,
                    hotwords=None,
                    verbose=False,
                )
            mx.synchronize()
            emit({
                "type": "result",
                "request_id": request_id,
                "text": str(result.text or "").strip(),
                "inference_seconds": time.perf_counter() - started,
            })
        except Exception:
            emit({
                "type": "error",
                "request_id": str(request.get("request_id", "")),
                "message": "Qwen could not transcribe this recording.",
            })

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
