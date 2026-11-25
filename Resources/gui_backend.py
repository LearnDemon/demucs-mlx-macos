#!/usr/bin/env python3
"""音乐分轨 GUI 的后端：调用 demucs-mlx，把进度以 JSON Lines 输出到 stdout。

有两种工作方式：

1. 常驻模式（GUI 使用）：``--worker``，从 stdin 逐行读取 JSON 命令。
   - 模型只加载一次，多次分离复用；
   - 切换模型时先卸载旧模型，再加载新模型；
   - 空闲或退出时显式释放内存。
2. 单次模式（命令行调试）：提供 ``--input`` / ``--output-dir`` / ``--mode``，
   跑完一次就退出。

每个输出行都是一个独立的 JSON 对象，例如：
    {"event": "progress", "value": 0.42}
    {"event": "model_loaded", "model": "htdemucs_ft"}
    {"event": "done", "files": ["..."], "output_dir": "..."}
"""

from __future__ import annotations

import argparse
import gc
import json
import signal
import sys
import traceback
from pathlib import Path

MODEL_NAMES = ("htdemucs", "htdemucs_ft")
MODES = ("four", "vocals", "instrumental")

# 与用户原来的 CLI 参数保持一致。
SEPARATOR_OPTIONS = dict(
    shifts=1,
    overlap=0.25,
    split=True,
    progress=False,
    compile=True,
    auto_tune=True,
    attention_precision="fp16",
)


def emit(event: str, **payload) -> None:
    """输出一行 JSON，并立即刷新，保证 GUI 能实时收到。"""
    try:
        print(json.dumps({"event": event, **payload}, ensure_ascii=False), flush=True)
    except (BrokenPipeError, OSError, ValueError):
        # GUI 已经退出时不要因为写管道失败而崩溃。
        pass


def active_memory_mb() -> int | None:
    """返回 MLX 当前占用的内存（MB），失败时返回 None。"""
    try:
        import mlx.core as mx

        return round(mx.get_active_memory() / (1 << 20))
    except Exception:
        return None


class SeparationWorker:
    """持有唯一一个已加载的模型，负责加载、分离和卸载。"""

    def __init__(self) -> None:
        self._separator = None
        self._model_name: str | None = None

    @property
    def loaded_model(self) -> str | None:
        return self._model_name

    def unload(self, reason: str = "request") -> None:
        """把当前模型从内存里彻底释放。

        Separator.close() 只是标记关闭，并不会释放 ``_model``，所以这里必须
        显式删除引用，再触发 GC 和 MLX 缓存清理。
        """
        if self._separator is None and self._model_name is None:
            return

        name = self._model_name
        separator = self._separator
        self._separator = None
        self._model_name = None

        if separator is not None:
            try:
                separator.close()
            except Exception:
                pass
            try:
                model = getattr(separator, "_model", None)
                if model is not None:
                    del model
            except Exception:
                pass
        del separator

        gc.collect()
        try:
            import mlx.core as mx

            mx.clear_cache()
            mx.reset_peak_memory()
        except Exception:
            pass

        emit(
            "model_unloaded",
            model=name,
            reason=reason,
            active_memory_mb=active_memory_mb(),
        )

    def load(self, name: str):
        """加载指定模型；如果内存里是别的模型，先卸载再加载。"""
        if name not in MODEL_NAMES:
            raise ValueError(f"未知模型：{name}")
        if self._separator is not None and self._model_name == name:
            return self._separator
        if self._separator is not None:
            # 关键：同一时间只保留一个模型，避免两份权重同时占用内存。
            self.unload(reason="switch")

        emit("indeterminate", text=f"加载模型 {name}…")
        from demucs_mlx.api import Separator

        separator = Separator(model=name, **SEPARATOR_OPTIONS)
        self._separator = separator
        self._model_name = name
        emit("model_loaded", model=name, active_memory_mb=active_memory_mb())
        return separator

    def separate(self, request: dict) -> None:
        model = str(request.get("model") or MODEL_NAMES[0])
        mode = str(request.get("mode") or "four")
        raw_input = request.get("input")
        raw_output = request.get("output_dir")

        if not raw_input or not raw_output:
            raise ValueError("命令缺少 input 或 output_dir")
        if mode not in MODES:
            raise ValueError(f"未知模式：{mode}")

        input_path = Path(str(raw_input)).expanduser()
        output_dir = Path(str(raw_output)).expanduser()
        if not input_path.is_file():
            raise FileNotFoundError(f"找不到输入文件：{input_path}")
        output_dir.mkdir(parents=True, exist_ok=True)

        separator = self.load(model)

        emit("stage", text="读取音频…", progress=0.05)
        emit("indeterminate", text="正在分离音频…")
        mix, stems = separator.separate(str(input_path), return_mx=True)

        emit("stage", text="保存结果…", progress=0.90)
        from demucs_mlx.audio import save_audio
        import mlx.core as mx

        samplerate = separator.samplerate
        saved: list[str] = []

        def save(stem_name: str, array) -> None:
            destination = output_dir / f"{stem_name}.wav"
            save_audio(
                array,
                destination,
                samplerate=samplerate,
                clip="rescale",
                bits_per_sample=16,
            )
            saved.append(str(destination))

        if mode == "four":
            # 固定顺序，GUI 会按此顺序展示。
            for name in ("vocals", "drums", "bass", "other"):
                emit(
                    "stage",
                    text=f"保存 {name}.wav…",
                    progress=min(0.98, 0.90 + 0.02 * len(saved)),
                )
                save(name, stems[name])
        elif mode == "vocals":
            save("vocals", stems["vocals"])
        else:
            # Demucs 的原生四轨是 鼓 / 贝斯 / 其他 / 人声。
            # 把“人声以外的三轨”相加，就得到伴奏。
            emit("stage", text="合并伴奏轨道…", progress=0.91)
            instrumental = stems["drums"] + stems["bass"] + stems["other"]
            mx.eval(instrumental)
            save("instrumental", instrumental)
            del instrumental

        # 分离过程中的中间数组用完就清掉，模型本身保留给下一次复用。
        del stems, mix
        gc.collect()
        try:
            mx.clear_cache()
        except Exception:
            pass

        emit(
            "done",
            files=saved,
            output_dir=str(output_dir),
            active_memory_mb=active_memory_mb(),
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Music stem separation backend")
    parser.add_argument(
        "--worker",
        action="store_true",
        help="常驻模式：从 stdin 读取 JSON 命令",
    )
    parser.add_argument("--input", help="输入音频文件（单次模式）")
    parser.add_argument("--output-dir", help="输出目录（单次模式）")
    parser.add_argument(
        "--mode",
        choices=MODES,
        help="four=四轨；vocals=仅人声；instrumental=仅伴奏",
    )
    parser.add_argument(
        "--model",
        choices=MODEL_NAMES,
        default=MODEL_NAMES[0],
        help="使用的模型（默认 htdemucs）",
    )
    return parser


def worker_loop() -> int:
    worker = SeparationWorker()

    def handle_signal(signum, frame):  # noqa: ARG001
        worker.unload(reason="signal")
        raise SystemExit(0)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, handle_signal)
        except Exception:
            pass

    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError as exc:
                emit("error", message=f"命令格式错误：{exc}")
                continue

            command = request.get("cmd")
            if command == "separate":
                try:
                    worker.separate(request)
                except Exception as exc:  # noqa: BLE001 - 单次失败不能拖垮常驻进程
                    traceback.print_exc(file=sys.stderr)
                    emit("error", message=str(exc) or exc.__class__.__name__)
            elif command == "unload":
                worker.unload(reason=str(request.get("reason") or "request"))
            elif command == "status":
                emit(
                    "status",
                    model=worker.loaded_model,
                    active_memory_mb=active_memory_mb(),
                )
            elif command == "ping":
                emit("pong")
            elif command == "shutdown":
                break
            else:
                emit("error", message=f"未知命令：{command}")
    finally:
        worker.unload(reason="shutdown")
    return 0


def run_once(args: argparse.Namespace) -> int:
    worker = SeparationWorker()
    try:
        worker.separate(
            {
                "input": args.input,
                "output_dir": args.output_dir,
                "mode": args.mode,
                "model": args.model,
            }
        )
        return 0
    except Exception as exc:  # noqa: BLE001 - 要把真实错误显示到界面上
        traceback.print_exc(file=sys.stderr)
        emit("error", message=str(exc) or exc.__class__.__name__)
        return 1
    finally:
        worker.unload(reason="exit")


def main() -> int:
    args = build_parser().parse_args()
    if args.worker:
        return worker_loop()
    if not (args.input and args.output_dir and args.mode):
        build_parser().error("单次模式需要同时提供 --input、--output-dir、--mode")
    return run_once(args)


if __name__ == "__main__":
    raise SystemExit(main())
