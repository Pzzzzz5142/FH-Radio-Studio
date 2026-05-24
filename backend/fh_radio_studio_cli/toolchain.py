from __future__ import annotations

import importlib.metadata
import importlib.util
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from .ai_timepoints.cache import (
    PROFILE_SYNC_GROUPS,
    PROVIDER_INSTALL_SPECS,
    default_model_dir,
    profile_sync_plan,
    torch_install_plan,
)
from .ai_timepoints.providers import baseline_mir, beat_this, demucs, mert, songformer
from .ai_timepoints.providers.runtime import module_exists, package_version, torch_device
from .common import REPO_ROOT, datetime, json, os, python_version, shutil, timezone
from .external_tools import collect_tool_status

PROFILES = ("local-base", "local-deep", "local-heavy")


def _profile_label(profile: str) -> str:
    return {
        "local-base": "中杯",
        "local-deep": "大杯",
        "local-heavy": "超大杯",
    }.get(profile, profile)


def _model_dir(value: Optional[str]) -> Path:
    return Path(value).expanduser() if value else default_model_dir()


def _enabled_providers(profile: str) -> Dict[str, bool]:
    deep = profile in ("local-deep", "local-heavy")
    heavy = profile == "local-heavy"
    return {
        "beat_this": deep,
        "songformer": deep,
        "mert": deep,
        "demucs": heavy,
    }


def _section(
    status: str,
    title: str,
    summary: str,
    items: List[Dict[str, object]],
    warnings: Optional[List[str]] = None,
) -> Dict[str, object]:
    return {
        "title": title,
        "status": status,
        "summary": summary,
        "items": items,
        "warnings": warnings or [],
    }


def _item(label: str, value: object, detail: str = "", status: str = "info") -> Dict[str, object]:
    return {
        "label": label,
        "value": "" if value is None else str(value),
        "detail": detail,
        "status": status,
    }


def _status_from_bool(ok: bool) -> str:
    return "ready" if ok else "missing"


def _version_for_package(name: str) -> Optional[str]:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def _normalize_package_name(name: str) -> str:
    if "/" in name:
        return name.split("/", 1)[-1]
    return name


def _run_version(executable: Optional[str], args: Iterable[str]) -> Optional[str]:
    if not executable:
        return None
    try:
        result = subprocess.run(
            [executable, *args],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=8,
            check=False,
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None
    text = (result.stdout or result.stderr).strip()
    return text.splitlines()[0] if text else None


def _path_state(raw: Optional[str]) -> Dict[str, object]:
    if not raw:
        return {"path": None, "exists": False, "writable": False}
    path = Path(raw).expanduser()
    exists = path.exists()
    probe = path if exists else path.parent
    writable = probe.exists() and os.access(probe, os.W_OK)
    return {
        "path": str(path),
        "exists": exists,
        "writable": writable,
    }


def _uv_section() -> Dict[str, object]:
    executable = os.environ.get("FH_RADIO_STUDIO_UV_EXE") or shutil.which("uv")
    version = _run_version(executable, ["--version"])
    mode = os.environ.get("FH_RADIO_STUDIO_UV_MODE", "unknown")
    project_environment = os.environ.get("UV_PROJECT_ENVIRONMENT") or os.environ.get(
        "FH_RADIO_STUDIO_UV_PROJECT_ENVIRONMENT"
    )
    cache_dir = os.environ.get("UV_CACHE_DIR") or os.environ.get("FH_RADIO_STUDIO_UV_CACHE_DIR")
    torch_extra = os.environ.get("FH_RADIO_STUDIO_TORCH_EXTRA", "")
    status = "ready" if version else "missing"
    warnings = [] if version else ["uv executable was not found or `uv --version` failed."]
    return _section(
        status,
        "uv 运行时",
        version or "uv 未就绪",
        [
            _item("uv", executable or "未找到", version or "", status),
            _item("模式", mode),
            _item("环境", project_environment or "未设置", _path_detail(project_environment)),
            _item("缓存", cache_dir or "未设置", _path_detail(cache_dir)),
            _item("Torch Extra", torch_extra or "未设置"),
        ],
        warnings,
    )


def _path_detail(raw: Optional[str]) -> str:
    state = _path_state(raw)
    if not state["path"]:
        return ""
    if state["exists"]:
        return "路径存在" + ("，可写" if state["writable"] else "，不可写")
    return "路径尚未创建" + ("，父目录可写" if state["writable"] else "，父目录不可写")


def _audio_tools_section() -> Dict[str, object]:
    tools, ok = collect_tool_status()
    missing = [name for name, info in tools.items() if not info.get("ok")]
    items = [
        _item(
            name,
            info.get("path") or "missing",
            str(info.get("version") or info.get("error") or ""),
            status=_status_from_bool(bool(info.get("ok"))),
        )
        for name, info in tools.items()
    ]
    status = "ready" if ok else "missing"
    summary = "核心音频处理组件可用" if ok else "缺少 " + ", ".join(missing)
    return _section(status, "核心音频工具", summary, items)


def _python_section(profile: str) -> Dict[str, object]:
    groups = PROFILE_SYNC_GROUPS.get(profile, [])
    core_package_names = set(_runtime_packages_for_profile("local-base"))
    package_names = _runtime_packages_for_profile(profile)
    packages: List[Dict[str, object]] = []
    missing_core: List[str] = []
    missing_optional: List[str] = []
    for name in package_names:
        normalized = _normalize_package_name(name)
        version = _version_for_package(normalized)
        if version is None and normalized == "beat-this":
            version = package_version("beat-this", "beat_this")
        if version is None:
            if name in core_package_names:
                missing_core.append(normalized)
            else:
                missing_optional.append(normalized)
        packages.append(
            _item(
                normalized,
                version or "missing",
                status="ready" if version else "missing",
            )
        )
    if missing_core:
        status = "missing"
        summary = "核心 Python 依赖缺失：" + ", ".join(missing_core[:4])
    elif missing_optional:
        status = "needs_sync"
        summary = "基础 Python 可用；可选 AI 依赖待同步：" + ", ".join(missing_optional[:4])
    else:
        status = "ready"
        summary = "Python 依赖已覆盖当前杯型"
    items = [
        _item("Python", sys.executable, sys.version.split()[0], "ready"),
        _item("Profile", _profile_label(profile)),
        _item("Groups", ", ".join(groups) if groups else "无"),
        *packages,
    ]
    return _section(status, "Python 环境", summary, items)


def _runtime_packages_for_profile(profile: str) -> List[str]:
    providers = ["baseline_mir"]
    enabled = _enabled_providers(profile)
    providers.extend(name for name, is_enabled in enabled.items() if is_enabled)
    out: List[str] = []
    for provider in providers:
        spec = PROVIDER_INSTALL_SPECS.get(provider, {})
        for raw in spec.get("runtime_packages", []):
            name = str(raw)
            if name not in out:
                out.append(name)
    return out


def _hardware_section() -> Dict[str, object]:
    nvidia_smi = shutil.which("nvidia-smi")
    gpu_list = _run_version(nvidia_smi, ["-L"]) if nvidia_smi else None
    torch_available = module_exists("torch")
    torch_info: Dict[str, object] = {
        "available": torch_available,
        "device": torch_device(),
    }
    warnings: List[str] = []
    if torch_available:
        try:
            import torch

            torch_info.update(
                {
                    "version": torch.__version__,
                    "cuda_available": bool(torch.cuda.is_available()),
                    "cuda_version": getattr(torch.version, "cuda", None),
                    "device_name": (
                        torch.cuda.get_device_name(0) if torch.cuda.is_available() else None
                    ),
                }
            )
        except Exception as exc:
            torch_info["error"] = f"{type(exc).__name__}: {exc}"
            warnings.append(str(torch_info["error"]))
    else:
        warnings.append("torch is not installed in the current Python environment.")

    requested = os.environ.get("FH_RADIO_STUDIO_TORCH_EXTRA", "")
    gpu_detected = bool(gpu_list)
    cuda_available = bool(torch_info.get("cuda_available"))
    if gpu_detected and torch_available and not cuda_available:
        status = "degraded"
        summary = "检测到 NVIDIA GPU，但当前 torch 不能使用 CUDA"
    elif torch_available:
        status = "ready"
        summary = "CUDA 可用" if cuda_available else "CPU fallback 可用"
    else:
        status = "missing"
        summary = "torch 未安装"
    return _section(
        status,
        "硬件加速",
        summary,
        [
            _item("NVIDIA", gpu_list or "未检测到", status="ready" if gpu_detected else "info"),
            _item(
                "Torch",
                torch_info.get("version") or "missing",
                status="ready" if torch_available else "missing",
            ),
            _item("Device", torch_info.get("device") or "unknown"),
            _item("CUDA", str(torch_info.get("cuda_available", False)).lower()),
            _item("选择", requested or "未设置"),
        ],
        warnings,
    )


def _ai_section(profile: str, model_dir: Path) -> Dict[str, object]:
    enabled = _enabled_providers(profile)
    statuses = [
        baseline_mir.check(),
        beat_this.check(model_dir, enabled["beat_this"]),
        songformer.check(model_dir, enabled["songformer"]),
        mert.check(model_dir, enabled["mert"]),
        demucs.check(model_dir, enabled["demucs"]),
    ]
    active = [status for status in statuses if status.status != "disabled"]
    deep = [status for status in active if status.name != "baseline_mir"]
    ready = [status for status in deep if status.status in {"ready", "ok"}]
    partial = [status for status in deep if status.status == "partial"]
    missing = [status for status in deep if status.status in {"missing", "error"}]
    warnings: List[str] = []
    for status in active:
        warnings.extend(status.warnings)
    if not deep:
        overall = "ready"
        summary = "只启用中杯分析"
    elif len(ready) == len(deep):
        overall = "ready"
        summary = "AI Providers 已就绪"
    elif partial or ready:
        overall = "degraded"
        summary = f"{len(ready)} / {len(deep)} 个深度 Provider 就绪"
    else:
        overall = "missing"
        summary = "深度 AI Providers 尚未就绪"

    items = [
        _item("Model Dir", str(model_dir.resolve()), _path_detail(str(model_dir))),
        *[
            _item(
                status.name,
                status.status,
                status.version or "",
                status.status if status.status != "ok" else "ready",
            )
            for status in active
        ],
    ]
    section = _section(overall, "AI 分析", summary, items, warnings)
    section["providers"] = [status.to_json() for status in statuses]
    section["model_dir"] = str(model_dir.resolve())
    return section


def _overall_status(sections: Dict[str, Dict[str, object]]) -> Dict[str, object]:
    core_statuses = [
        str(sections["uv"].get("status", "")),
        str(sections["audio_tools"].get("status", "")),
        str(sections["python"].get("status", "")),
    ]
    if any(status in {"error", "missing"} for status in core_statuses):
        return {
            "status": "missing",
            "label": "需要处理",
            "summary": "核心工具链有缺失项，请先修复基础处理组件。",
        }
    optional_statuses = [
        str(sections["hardware"].get("status", "")),
        str(sections["ai"].get("status", "")),
    ]
    if sections["python"].get("status") == "needs_sync" or any(
        status in {"degraded", "partial", "needs_sync", "missing", "error"}
        for status in optional_statuses
    ):
        return {
            "status": "ready",
            "label": "OK",
            "summary": "核心工具链可用；AI 和硬件加速会按实际能力降级。",
        }
    return {
        "status": "ready",
        "label": "OK",
        "summary": "工具链检查通过。",
    }


def _fixes(
    profile: str, model_dir: Path, sections: Dict[str, Dict[str, object]]
) -> List[Dict[str, object]]:
    fixes: List[Dict[str, object]] = []
    cli_command = os.environ.get("FH_RADIO_STUDIO_CLI_COMMAND", "fh-radio-studio")
    runtime_root = os.environ.get("FH_RADIO_STUDIO_RUNTIME_ROOT") or str(REPO_ROOT)
    py_version = python_version()
    uv_run_prefix = (
        f"uv run --project {runtime_root} --python {py_version} --managed-python {cli_command}"
    )
    uv_status = sections["uv"].get("status")
    if uv_status != "ready":
        fixes.append(
            {
                "id": "configure_uv",
                "label": "配置 uv 运行时",
                "detail": "设置 FH_RADIO_STUDIO_UV_EXE，或在 release 包里提供 bundled uv。",
                "command": "uv --version",
                "severity": "danger",
            }
        )
    if sections["audio_tools"].get("status") != "ready":
        fixes.append(
            {
                "id": "install_audio_tools",
                "label": "修复核心处理组件",
                "detail": "安装或强制修复 ffmpeg、vgmstream-cli 和 fsbankcl 到当前 toolchain 的 tools/audio。",
                "command": f"{uv_run_prefix} install-tools --force",
                "severity": "warn",
            }
        )
    if sections["python"].get("status") in {"missing", "needs_sync"}:
        groups = PROFILE_SYNC_GROUPS.get(profile, [])
        extra = os.environ.get("FH_RADIO_STUDIO_TORCH_EXTRA", "torch-cpu")
        group_args = " ".join(f"--group {group}" for group in groups)
        core_missing = sections["python"].get("status") == "missing"
        fixes.append(
            {
                "id": "sync_python_env",
                "label": "同步 Python 环境" if core_missing else "同步可选 AI 环境",
                "detail": f"按{_profile_label(profile)}恢复 Dependency Groups，并选择 {extra}。",
                "command": (
                    f"uv sync --project {REPO_ROOT} --python {py_version} "
                    f"--managed-python {group_args} --extra {extra}"
                ).strip(),
                "severity": "danger" if core_missing else "info",
            }
        )
    if sections["ai"].get("status") in {"missing", "degraded"}:
        fixes.append(
            {
                "id": "prepare_ai_cache",
                "label": "准备 AI 模型缓存",
                "detail": "创建模型 cache manifest；需要完整离线分析时再 Warmup 具体 Provider。",
                "command": (
                    f"{uv_run_prefix} prepare-ai-cache "
                    f"--profile {profile} --model-dir {model_dir.resolve()}"
                ),
                "severity": "info",
            }
        )
    return fixes


def build_toolchain_status_payload(args) -> Dict[str, object]:
    model_dir = _model_dir(args.model_dir)
    sections = {
        "uv": _uv_section(),
        "audio_tools": _audio_tools_section(),
        "python": _python_section(args.profile),
        "hardware": _hardware_section(),
        "ai": _ai_section(args.profile, model_dir),
    }
    overall = _overall_status(sections)
    return {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "profile": args.profile,
        "repo_root": str(REPO_ROOT),
        "model_dir": str(model_dir.resolve()),
        "runtime_network_required": False,
        "install_network_required": True,
        "overall": overall,
        "sections": sections,
        "dependency_sync": profile_sync_plan(args.profile),
        "torch": torch_install_plan(),
        "fixes": _fixes(args.profile, model_dir, sections),
    }


def cmd_toolchain_status(args) -> int:
    payload = build_toolchain_status_payload(args)
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    overall = payload["overall"]
    print(f"Toolchain : {overall['label']} - {overall['summary']}")
    print(f"Profile   : {payload['profile']}")
    for section_id, section in payload["sections"].items():
        print(f"  {section_id:<12} {section['status']:<10} {section['summary']}")
    fixes = payload.get("fixes") or []
    if fixes:
        print("Fix plan:")
        for fix in fixes:
            print(f"  - {fix['label']}: {fix['command']}")
    return 0
