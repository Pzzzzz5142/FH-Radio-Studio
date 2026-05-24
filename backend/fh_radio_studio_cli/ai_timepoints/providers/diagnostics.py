from __future__ import annotations

from contextlib import contextmanager
from time import perf_counter
from typing import Dict, Iterator, List, Optional


class ProviderTimer:
    def __init__(self) -> None:
        self._started = perf_counter()
        self._stages: List[Dict[str, object]] = []

    @contextmanager
    def stage(self, name: str) -> Iterator[None]:
        started = perf_counter()
        try:
            yield
        finally:
            self._stages.append(
                {
                    "name": name,
                    "runtime_ms": int(round((perf_counter() - started) * 1000)),
                }
            )

    def elapsed_ms(self) -> int:
        return int(round((perf_counter() - self._started) * 1000))

    def snapshot(self, *, total_ms: Optional[int] = None) -> Dict[str, object]:
        elapsed_ms = self.elapsed_ms() if total_ms is None else int(total_ms)
        measured_ms = sum(int(item["runtime_ms"]) for item in self._stages)
        return {
            "total_ms": elapsed_ms,
            "stages": list(self._stages),
            "unattributed_ms": max(0, elapsed_ms - measured_ms),
        }


def torch_model_runtime(model: object, **extra: object) -> Dict[str, object]:
    info: Dict[str, object] = {key: value for key, value in extra.items() if value is not None}
    try:
        import torch
    except Exception as exc:
        info["torch_available"] = False
        info["torch_error"] = f"{type(exc).__name__}: {exc}"
        return info

    info["torch_available"] = True
    info["torch_version"] = torch.__version__
    try:
        info["cuda_available"] = bool(torch.cuda.is_available())
        if torch.cuda.is_available():
            info["cuda_device_name"] = torch.cuda.get_device_name(0)
    except Exception:
        info["cuda_available"] = False
    try:
        info["float32_matmul_precision"] = torch.get_float32_matmul_precision()
    except Exception:
        pass

    parameters = getattr(model, "parameters", None)
    if callable(parameters):
        parameter_dtypes = set()
        parameter_devices = set()
        parameter_count = 0
        trainable_parameter_count = 0
        try:
            for parameter in parameters():
                parameter_dtypes.add(str(parameter.dtype).replace("torch.", ""))
                parameter_devices.add(str(parameter.device))
                parameter_count += int(parameter.numel())
                if bool(getattr(parameter, "requires_grad", False)):
                    trainable_parameter_count += int(parameter.numel())
            info["parameter_dtypes"] = sorted(parameter_dtypes)
            info["parameter_devices"] = sorted(parameter_devices)
            info["parameter_count"] = parameter_count
            info["trainable_parameter_count"] = trainable_parameter_count
        except Exception as exc:
            info["parameter_error"] = f"{type(exc).__name__}: {exc}"

    buffers = getattr(model, "buffers", None)
    if callable(buffers):
        buffer_dtypes = set()
        buffer_devices = set()
        try:
            for buffer in buffers():
                buffer_dtypes.add(str(buffer.dtype).replace("torch.", ""))
                buffer_devices.add(str(buffer.device))
            if buffer_dtypes:
                info["buffer_dtypes"] = sorted(buffer_dtypes)
            if buffer_devices:
                info["buffer_devices"] = sorted(buffer_devices)
        except Exception as exc:
            info["buffer_error"] = f"{type(exc).__name__}: {exc}"
    return info
