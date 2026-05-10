"""Aurora Config File Loader (Phase 9 P2)

Reads `aurora.config.json` from the agent's executable directory (or cwd as
a fallback) on startup. If the file is present and valid, hydrates the
AgentConfig with `apiKey`, `apiBase`, `mt5ConfigId`, persists it via the
encrypted local config store, then renames the file to
`aurora.config.imported.json` so the plaintext API key isn't sitting on
disk forever.

This skips the OAuth-via-browser dance + the --mt5-config-id CLI flag for
users who downloaded the agent + config bundle from Aurora X. If the file
is absent or invalid, the agent falls back to its existing OAuth/CLI flow
(no regression for current users).

File shape (issued by backend `/bridge/agent-download`):
    {
      "apiBase": "https://aurora-x.app",
      "apiKey": "bridge_<hex>",
      "issuedAt": "2026-05-10T07:00:00.000Z",
      "expiresAt": "2026-08-08T07:00:00.000Z",
      "heartbeatIntervalSec": 30,
      "mt5ConfigId": "<uuid>",       // optional — present when scoped
      "mt5ConfigName": "..."           // optional — for human display only
    }
"""

import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

from models import AgentConfig

logger = logging.getLogger("aurora-bridge")

CONFIG_FILE_NAME = "aurora.config.json"
IMPORTED_SUFFIX_NAME = "aurora.config.imported.json"

REQUIRED_KEYS = ("apiKey", "apiBase")


def _candidate_paths() -> list[Path]:
    """Where to look for aurora.config.json, in priority order.

    1. Next to the running executable (where users naturally drop it after
       unzipping the AuroraBridge bundle).
    2. The current working directory (when the user launches from a
       terminal inside a different folder).
    """
    paths: list[Path] = []
    # Where the .exe lives (PyInstaller-bundled) or where agent.py lives (dev)
    if getattr(sys, "frozen", False):
        exe_dir = Path(sys.executable).parent
    else:
        exe_dir = Path(__file__).parent
    paths.append(exe_dir / CONFIG_FILE_NAME)
    # Also try cwd as a fallback (different from exe_dir if user runs from elsewhere)
    cwd = Path.cwd()
    if cwd != exe_dir:
        paths.append(cwd / CONFIG_FILE_NAME)
    return paths


def find_config_file() -> Path | None:
    """Return the first existing aurora.config.json, or None."""
    for p in _candidate_paths():
        if p.is_file():
            return p
    return None


def _validate(payload: dict) -> str | None:
    """Return None if payload is valid; otherwise a human-readable error string."""
    for key in REQUIRED_KEYS:
        v = payload.get(key)
        if not isinstance(v, str) or not v.strip():
            return f"missing or invalid '{key}'"

    api_key = payload["apiKey"]
    if not api_key.startswith("bridge_"):
        return f"apiKey must start with 'bridge_' (got '{api_key[:12]}…')"

    expires_at_raw = payload.get("expiresAt")
    if isinstance(expires_at_raw, str):
        # Be liberal — accept Z-suffix or +00:00, and skip if unparseable
        try:
            # datetime.fromisoformat doesn't accept 'Z' until 3.11; normalise.
            normalized = expires_at_raw.replace("Z", "+00:00")
            expires_at = datetime.fromisoformat(normalized)
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
            if expires_at < datetime.now(timezone.utc):
                return f"apiKey already expired (expiresAt={expires_at_raw})"
        except ValueError:
            logger.debug(f"Could not parse expiresAt='{expires_at_raw}' — skipping expiry check")

    return None


def import_config_file_if_present(config: AgentConfig) -> tuple[AgentConfig, bool]:
    """Look for aurora.config.json and import it if present + valid.

    Returns (config, imported_bool):
      - config: the (possibly mutated) AgentConfig
      - imported_bool: True if a file was found and successfully applied;
        False if no file was present OR the file was invalid (in which case
        we log a warning but leave config unchanged)

    Side effects on success: renames the source file to
    aurora.config.imported.json so the plaintext API key doesn't linger
    in the user's working directory. The renamed file is harmless (still
    readable) but signals the user that it was processed.
    """
    src = find_config_file()
    if not src:
        return config, False

    logger.info(f"Found {src.name} at {src.parent} — importing…")

    try:
        payload = json.loads(src.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"{src.name} is malformed ({e}); falling back to existing config")
        return config, False

    err = _validate(payload)
    if err is not None:
        logger.warning(f"{src.name} invalid: {err}; falling back to existing config")
        return config, False

    # Apply values. apiKey/apiBase are required + validated above; the rest
    # are optional and only override when present.
    config.token = payload["apiKey"]
    config.api_url = payload["apiBase"].rstrip("/")
    if "mt5ConfigId" in payload and isinstance(payload["mt5ConfigId"], str) and payload["mt5ConfigId"].strip():
        config.mt5_config_id = payload["mt5ConfigId"].strip()

    mt5_name = payload.get("mt5ConfigName")
    if isinstance(mt5_name, str) and mt5_name.strip():
        logger.info(f"Imported config targets MT5 account: {mt5_name}")
    if config.mt5_config_id:
        logger.info(f"Targeting mt5_config_id={config.mt5_config_id}")
    else:
        logger.info("No mt5_config_id in config file — running in broadcast mode")

    # Rename the source so the plaintext key doesn't sit there forever.
    # Best-effort: if the rename fails (file in use, permissions), log + continue.
    try:
        target = src.with_name(IMPORTED_SUFFIX_NAME)
        # If a previous import file exists, overwrite it (older imports stale)
        if target.exists():
            target.unlink()
        src.rename(target)
        logger.info(f"Renamed {src.name} → {target.name} (config absorbed into agent's encrypted store)")
    except OSError as e:
        logger.warning(f"Could not rename {src.name} ({e}) — agent works fine but please delete the file manually")

    return config, True
