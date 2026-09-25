"""Optional local speech inference service for both native apps.

The UI, capture and OCR are native. This is an optional model runtime,
analogous to running Ollama for language-model inference.
"""
import argparse
import os
from pathlib import Path
import tempfile
import threading


def create_app(whisper, model_name):
    from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
    app = FastAPI(title="Rewind local speech", docs_url=None, redoc_url=None)
    lock = threading.Lock()

    @app.middleware("http")
    async def local_requests(request: Request, call_next):
        from starlette.responses import JSONResponse
        if request.headers.get("origin"):
            return JSONResponse({"detail": "Browser origins are not accepted."}, status_code=403)
        return await call_next(request)

    @app.get("/v1/models")
    def models():
        return {"object": "list", "data": [{"id": "whisper-1", "object": "model", "owned_by": "local"}, {"id": model_name, "object": "model", "owned_by": "local"}]}

    @app.post("/v1/audio/transcriptions")
    def transcribe(file: UploadFile = File(...), model: str = Form("whisper-1"), response_format: str = Form("verbose_json")):
        if model not in {"whisper-1", model_name}:
            raise HTTPException(400, "Choose whisper-1 or the model loaded by this server.")
        if response_format not in {"verbose_json", "json"}:
            raise HTTPException(400, "Use json or verbose_json.")
        suffix = Path(file.filename or "audio.wav").suffix
        if suffix.lower() not in {".wav", ".m4a", ".mp4", ".mp3", ".webm", ".ogg", ".flac"}:
            raise HTTPException(400, "Unsupported audio file type.")
        name = None
        try:
            with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as target:
                name = target.name
                size = 0
                while chunk := file.file.read(1024 * 1024):
                    size += len(chunk)
                    if size > 24 * 1024 * 1024:
                        raise HTTPException(413, "Audio segment exceeds 24 MB.")
                    target.write(chunk)
            with lock:
                segments, info = whisper.transcribe(name, beam_size=5, vad_filter=True)
                rows = [{"id": i, "start": s.start, "end": s.end, "text": s.text.strip()} for i, s in enumerate(segments)]
            result = {"text": " ".join(s["text"] for s in rows)}
            if response_format == "verbose_json":
                result.update(language=info.language, duration=info.duration, segments=rows)
            return result
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(422, "Unable to decode or transcribe this audio segment.") from exc
        finally:
            if name:
                Path(name).unlink(missing_ok=True)
            file.file.close()
    return app


def main():
    parser = argparse.ArgumentParser(description="Run local speech inference for Rewind Replica.")
    parser.add_argument("--model", default="base", help="Whisper model name or local model directory")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--device", choices=["cpu", "cuda"], default="cpu")
    parser.add_argument("--offline", action="store_true", help="Use cached models only; never download")
    args = parser.parse_args()
    from faster_whisper import WhisperModel
    import uvicorn
    whisper = WhisperModel(args.model, device=args.device, compute_type="int8" if args.device == "cpu" else "float16", local_files_only=args.offline)
    # Binding is intentionally fixed to loopback. This is not an internet-facing service.
    uvicorn.run(create_app(whisper, args.model), host="127.0.0.1", port=args.port, access_log=False)


if __name__ == "__main__":
    main()
