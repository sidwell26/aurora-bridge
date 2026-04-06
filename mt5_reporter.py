"""
MT5 Reporter — reads EA-written CSV files and syncs to Aurora API.

The EA writes 3 files to the MT5 Common/Files directory every 60s:
  aurora_account.csv   — balance, equity, margin, floating P&L
  aurora_positions.csv — open positions
  aurora_history.csv   — closed trade history (last 90 days)

The bridge reads these and POSTs to the backend.
No MetaTrader5 Python package needed — works with any number of terminals.
"""

import asyncio
import csv
import logging
import os
from datetime import datetime, timezone
from typing import Optional

import aiohttp

logger = logging.getLogger("aurora-bridge")

# How often to check for updated CSV files (seconds)
POLL_INTERVAL = 65  # slightly more than EA write interval to ensure fresh data


class MT5Reporter:
    """Reads EA performance CSVs and POSTs data to Aurora API."""

    def __init__(
        self,
        token: str,
        api_url: str,
        mt5_config_id: str,
        mt5_signal_file: Optional[str] = None,   # path to MT5 Files dir (same as signal file dir)
        mt5_exe_path: Optional[str] = None,       # unused — kept for config compat
    ):
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.mt5_config_id = mt5_config_id
        self.files_dir = mt5_signal_file          # directory containing aurora_*.csv files
        self._running = False

    @property
    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _csv_path(self, filename: str) -> Optional[str]:
        if not self.files_dir:
            return None
        return os.path.join(self.files_dir, filename)

    def _read_csv(self, filename: str) -> Optional[list[dict]]:
        path = self._csv_path(filename)
        if not path or not os.path.exists(path):
            return None
        try:
            with open(path, newline="", encoding="utf-8", errors="replace") as f:
                reader = csv.DictReader(f)
                return list(reader)
        except Exception as e:
            logger.debug(f"MT5 reporter: failed to read {filename}: {e}")
            return None

    def _unix_to_iso(self, ts_str: str) -> Optional[str]:
        try:
            ts = int(ts_str)
            if ts <= 0:
                return None
            return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
        except Exception:
            return None

    async def _post(self, path: str, payload: dict) -> bool:
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.api_url}{path}",
                    headers=self._headers,
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=15),
                ) as resp:
                    if resp.status not in (200, 201):
                        text = await resp.text()
                        logger.debug(f"MT5 reporter POST {path} → HTTP {resp.status}: {text[:120]}")
                    return resp.status in (200, 201)
        except Exception as e:
            logger.debug(f"MT5 reporter POST {path} failed: {e}")
            return False

    # ── Sync methods ──────────────────────────────────────────────────────────

    async def _sync_account(self):
        rows = self._read_csv("aurora_account.csv")
        if not rows:
            return
        r = rows[0]
        try:
            payload = {
                "mt5ConfigId": self.mt5_config_id,
                "balance":     float(r.get("balance", 0) or 0),
                "equity":      float(r.get("equity", 0) or 0),
                "margin":      float(r.get("margin", 0) or 0),
                "freeMargin":  float(r.get("free_margin", 0) or 0),
                "floatingPnl": float(r.get("floating_pnl", 0) or 0),
                "currency":    r.get("currency", "USD").strip(),
                "leverage":    int(r.get("leverage", 0) or 0),
            }
            await self._post("/mt5-performance/snapshot", payload)
        except Exception as e:
            logger.debug(f"MT5 reporter: account parse error: {e}")

    async def _sync_positions(self):
        rows = self._read_csv("aurora_positions.csv")
        if rows is None:
            return
        positions = []
        for r in rows:
            try:
                positions.append({
                    "ticket":       r.get("ticket", "").strip(),
                    "symbol":       r.get("symbol", "").strip(),
                    "direction":    r.get("direction", "").strip(),
                    "lots":         float(r.get("lots", 0) or 0),
                    "openPrice":    float(r.get("open_price", 0) or 0),
                    "currentPrice": float(r.get("current_price", 0) or 0) or None,
                    "sl":           float(r.get("sl", 0) or 0) or None,
                    "tp":           float(r.get("tp", 0) or 0) or None,
                    "floatingPnl":  float(r.get("floating_pnl", 0) or 0),
                    "swap":         float(r.get("swap", 0) or 0),
                    "openedAt":     self._unix_to_iso(r.get("opened_at", "0")),
                })
            except Exception as e:
                logger.debug(f"MT5 reporter: position parse error: {e}")
        await self._post("/mt5-performance/positions", {
            "mt5ConfigId": self.mt5_config_id,
            "positions": positions,
        })

    async def _sync_history(self):
        rows = self._read_csv("aurora_history.csv")
        if not rows:
            return
        trades = []
        for r in rows:
            try:
                open_price  = float(r.get("open_price", 0) or 0)
                close_price = float(r.get("close_price", 0) or 0)
                opened_at   = self._unix_to_iso(r.get("opened_at", "0"))
                closed_at   = self._unix_to_iso(r.get("closed_at", "0"))
                duration    = None
                if opened_at and closed_at:
                    try:
                        dur = (datetime.fromisoformat(closed_at) - datetime.fromisoformat(opened_at)).total_seconds()
                        duration = int(dur / 60)
                    except Exception:
                        pass
                trades.append({
                    "ticket":          r.get("position_id", "").strip(),
                    "symbol":          r.get("symbol", "").strip(),
                    "direction":       r.get("direction", "").strip(),
                    "lots":            float(r.get("lots", 0) or 0),
                    "openPrice":       open_price,
                    "closePrice":      close_price,
                    "pnl":             float(r.get("pnl", 0) or 0),
                    "swap":            float(r.get("swap", 0) or 0),
                    "commission":      float(r.get("commission", 0) or 0),
                    "priceDiff":       abs(close_price - open_price),
                    "openedAt":        opened_at,
                    "closedAt":        closed_at,
                    "durationMinutes": duration,
                })
            except Exception as e:
                logger.debug(f"MT5 reporter: history parse error: {e}")

        if trades:
            await self._post("/mt5-performance/history", {
                "mt5ConfigId": self.mt5_config_id,
                "trades": trades,
            })
            logger.info(f"MT5 reporter: synced {len(trades)} history trades")

    # ── Main loop ─────────────────────────────────────────────────────────────

    async def _loop(self):
        while self._running:
            if not self.files_dir:
                logger.debug("MT5 reporter: no MT5 files path — skipping")
                await asyncio.sleep(POLL_INTERVAL)
                continue
            try:
                await asyncio.gather(
                    self._sync_account(),
                    self._sync_positions(),
                    self._sync_history(),
                )
            except Exception as e:
                logger.debug(f"MT5 reporter loop error: {e}")
            await asyncio.sleep(POLL_INTERVAL)

    # ── Public API ────────────────────────────────────────────────────────────

    async def start(self):
        if not self.mt5_config_id:
            logger.info("MT5 reporter: no --mt5-config-id set — live reporting disabled")
            return
        if not self.files_dir:
            logger.warning("MT5 reporter: no MT5 files path configured — reporting disabled")
            return
        logger.info(f"MT5 reporter starting (polling EA CSVs every {POLL_INTERVAL}s from {self.files_dir})")
        self._running = True
        asyncio.create_task(self._loop())

    def stop(self):
        self._running = False
