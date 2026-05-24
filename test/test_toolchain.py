from backend.fh_radio_studio_cli import toolchain


def _section(status):
    return {"status": status, "summary": status}


def test_overall_status_treats_ai_and_hardware_as_optional():
    overall = toolchain._overall_status(
        {
            "uv": _section("ready"),
            "audio_tools": _section("ready"),
            "python": _section("needs_sync"),
            "hardware": _section("missing"),
            "ai": _section("missing"),
        }
    )

    assert overall["status"] == "ready"
    assert overall["label"] == "OK"


def test_overall_status_blocks_on_core_audio_tools():
    overall = toolchain._overall_status(
        {
            "uv": _section("ready"),
            "audio_tools": _section("missing"),
            "python": _section("ready"),
            "hardware": _section("ready"),
            "ai": _section("ready"),
        }
    )

    assert overall["status"] == "missing"
