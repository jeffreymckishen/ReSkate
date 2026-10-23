"""Static package/API admission only; actual Luau sandbox tests live in plugin_tests.cpp."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().with_name("camera-inspector")


def verify():
    paths = sorted(PACKAGE.rglob("*"))
    for path in paths:
        if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
            raise ValueError("Package reparse paths are refused")
        if path.is_file() and path.suffix.lower() not in (".json", ".lua", ".md"):
            raise ValueError("Only source, manifests and documentation belong in this package")
    declaration = json.loads((PACKAGE / "reskate-plugin.json").read_text(encoding="utf-8"))
    if set(declaration) != {"api", "entry", "side", "permissions"}:
        raise ValueError("Unexpected plugin manifest fields")
    if type(declaration["api"]) is not int or declaration["api"] != 1 or declaration["side"] != "client":
        raise ValueError("Expected current client API1 manifest")
    if sorted(declaration["permissions"]) != ["camera", "menu", "skater.read"]:
        raise ValueError("The inspector must have only camera/menu/read-only skater permissions")
    entry = PurePosixPath(declaration["entry"])
    if entry.is_absolute() or ":" in str(entry) or "\\" in str(entry) or any(p in (".", "..") for p in entry.parts):
        raise ValueError("Unsafe plugin entry path")
    if str(entry) != "plugin/main.lua":
        raise ValueError("Unexpected entry point")
    source = (PACKAGE / str(entry)).read_text(encoding="utf-8")
    allowed = {"camera.get", "camera.look", "camera.release", "camera.held", "skater.get", "menu.page", "on"}
    calls = set(re.findall(r"reskate\.([a-z_]+(?:\.[a-z_]+)?)", source))
    if calls != allowed:
        raise ValueError(f"Unexpected or missing API surface: {calls ^ allowed}")
    world = (ROOT / "Extension/Plugins/plugin_api_world.cpp").read_text(encoding="utf-8")
    basic = (ROOT / "Extension/Plugins/plugin_api.cpp").read_text(encoding="utf-8")
    menu = (ROOT / "Extension/Plugins/plugin_api_ui.cpp").read_text(encoding="utf-8")
    for name in ("get", "look", "release", "held"):
        if not re.search(r'\{"' + name + r'",\s*camera_' + name + r'\}', world):
            raise ValueError("Camera API registration changed: " + name)
    if '{"get", F::skater_get}' not in basic or '{"page", F::page}' not in menu:
        raise ValueError("Read-only skater/menu registration changed")
    manifest = json.loads((PACKAGE / "manifest.json").read_text(encoding="utf-8"))
    if manifest["dependencies"] or not re.fullmatch(r"\d+\.\d+\.\d+", manifest["version_number"]):
        raise ValueError("Unexpected dependency or package version")
    pins = []
    for path in paths:
        if not path.is_file():
            continue
        raw = path.read_bytes()
        if len(raw) > 65536 or raw.startswith(b"MZ"):
            raise ValueError("Package files must be bounded text, never executables")
        raw.decode("utf-8")
        pins.append(dict(path=path.relative_to(PACKAGE).as_posix(), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest().upper()))
    return dict(event="camera_inspector_static_package_admission", files=pins, permissions=declaration["permissions"],
                api_names=sorted(calls), static_package_api_contract_passed=True,
                luau_compiler_or_runtime_executed=False, native_or_controller_actions=0,
                boundary="JSON/package/API registration checks only. Actual Host/Luau UI, validation, permission and release cases are added to dingosdk_plugin_tests and await an authorized quiet build/test window.")


if __name__ == "__main__":
    print(json.dumps(verify(), separators=(",", ":")))
