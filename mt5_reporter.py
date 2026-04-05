"""
MT5 Reporter — polls MetaTrader5 terminal data and syncs to Aurora API.

Runs as background tasks inside the bridge agent when mt5_config_id is set.
Requires: pip install MetaTrader5  (Windows only)

Sync schedule:
  - Account snapshot + open positions: every snapshot_interval seconds (default 30s)
  - Closed trade history:              every history_interval seconds (default 300s)
"""

import asyncio
import logging
from datetime import datetime, timezone
from typing import Optional

import aiohttp

logger = logging.getLogger("aurora-bridge")

try:
    import MetaTrader5 as mt5
    MT5_AVAILABLE = True
except ImportError:
    MT5_AVAILABLE = False


class MT5Reporter:
    """Polls the local MT5 terminal and syncs performance data to Aurora API."""

    def __init__(
        self,
        token: str,
        api_url: str,
        mt5_config_id: str,
        mt5_exe_path: Optional[str] = None,
        snapshot_interval: int = 30,
        history_interval: int = 300,
    ):
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.mt5_config_id = mt5_config_id
        self.mt5_exe_path = mt5_exe_path
        self.snapshot_interval = snapshot_interval
        self.history_interval = history_interval
        self._running = False
        self._initialized = False

    @property
    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }

    # ── MT5 initialisation ────────────────────────────────────────────────────

    def _init_mt5(self) -> bool:
        if not MT5_AVAILABLE:
            return False
        if self._initialized:
            return True
        kwargs = {}
        if self.mt5_exe_path:
            kwargs["path"] = self.mt5_exe_path
        if mt5.initialize(**kwargs):
            self._initialized = True
            info = mt5.account_info()
            if info:
                logger.info(f"MT5 reporter connected: {info.server} #{info.login}")
            return True
        logger.warning(f"MT5 reporter: initialize failed — {mt5.last_error()}")
        return False

    # ── HTTP helpers ──────────────────────────────────────────────────────────

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

    # ── Data collectors ───────────────────────────────────────────────────────

    def _collect_snapshot(self) -> Optional[dict]:
        info = mt5.account_info()
        if info is None:
            return None
        return {
            "mt5ConfigId": self.mt5_config_id,
            "balance": float(info.balance),
            "equity": float(info.equity),
            "margin": float(info.margin),
            "freeMargin": float(info.margin_free),
            "marginLevel": float(info.margin_level) if info.margin_level else None,
            "floatingPnl": float(info.profit),
            "currency": info.currency,
            "leverage": int(info.leverage),
        }

    def _collect_positions(self) -> list[dict]:
        positions = mt5.positions_get()
        if not positions:
            return []
        result = []
        for p in positions:
            result.append({
                "ticket": str(p.ticket),
                "symbol": p.symbol,
                "direction": "BUY" if p.type == mt5.ORDER_TYPE_BUY else "SELL",
                "lots": float(p.volume),
                "openPrice": float(p.price_open),
                "currentPrice": float(p.price_current),
                "sl": float(p.sl) if p.sl else None,
                "tp": float(p.tp) if p.tp else None,
                "floatingPnl": float(p.profit),
                "swap": float(p.swap),
                "commission": float(getattr(p, "commission", 0) or 0),
                "openedAt": datetime.fromtimestamp(p.time, tz=timezone.utc).isoformat(),
            })
        return result

    def _collect_history(self) -> list[dict]:
        """Build a list of completed trades from MT5 deal history (all time)."""
        date_from = datetime(2000, 1, 1, tzinfo=timezone.utc)
        date_to = datetime.now(tz=timezone.utc)

        deals = mt5.history_deals_get(date_from, date_to)
        if not deals:
            return []

        # Group entry + exit deals by position_id
        entries: dict[int, dict] = {}
        exits: dict[int, dict] = {}

        for d in deals:
            if d.entry == mt5.DEAL_ENTRY_IN:
                entries[d.position_id] = {
                    "ticket": str(d.position_id),
                    "symbol": d.symbol,
                    "direction": "BUY" if d.type == mt5.DEAL_TYPE_BUY else "SELL",
                    "lots": float(d.volume),
                    "openPrice": float(d.price),
                    "openedAt": datetime.fromtimestamp(d.time, tz=timezone.utc).isoformat(),
                    "commissionIn": float(d.commission),
                }
            elif d.entry == mt5.DEAL_ENTRY_OUT and d.position_id in entries:
                exits[d.position_id] = {
                    "closePrice": float(d.price),
                    "closedAt": datetime.fromtimestamp(d.time, tz=timezone.utc).isoformat(),
                    "pnl": float(d.profit),
                    "swap": float(d.swap),
                    "commissionOut": float(d.commission),
                }

        trades = []
        for pos_id, entry in entries.items():
            exit_ = exits.get(pos_id)
            if not exit_:
                continue  # still open

            commission = entry["commissionIn"] + exit_["commissionOut"]
            price_diff = abs(exit_["closePrice"] - entry["openPrice"])

            open_dt = datetime.fromisoformat(entry["openedAt"])
            close_dt = datetime.fromisoformat(exit_["closedAt"])
            duration_minutes = int((close_dt - open_dt).total_seconds() / 60)

            trades.append({
                "ticket": entry["ticket"],
                "mt5ConfigId": self.mt5_config_id,
                "symbol": entry["symbol"],
                "direction": entry["direction"],
                "lots": entry["lots"],
                "openPrice": entry["openPrice"],
                "closePrice": exit_["closePrice"],
                "pnl": exit_["pnl"],
                "swap": exit_["swap"],
                "commission": commission,
                "priceDiff": price_diff,
                "openedAt": entry["openedAt"],
                "closedAt": exit_["closedAt"],
                "durationMinutes": duration_minutes,
            })

        return trades

    # ── Background loops ──────────────────────────────────────────────────────

    async def _snapshot_loop(self):
        while self._running:
            try:
                if not self._init_mt5():
                    self._initialized = False
                    await asyncio.sleep(self.snapshot_interval)
                    continue

                snapshot = self._collect_snapshot()
                if snapshot:
                    await self._post("/mt5-performance/snapshot", snapshot)

                positions = self._collect_positions()
                await self._post("/mt5-performance/positions", {
                    "mt5ConfigId": self.mt5_config_id,
                    "positions": positions,
                })

            except Exception as e:
                logger.debug(f"MT5 snapshot loop error: {e}")
                self._initialized = False

            await asyncio.sleep(self.snapshot_interval)

    async def _history_loop(self):
        while self._running:
            await asyncio.sleep(5)  # short delay on first run so snapshot loop connects first
            try:
                if self._initialized:
                    trades = self._collect_history()
                    if trades:
                        await self._post("/mt5-performance/history", {
                            "mt5ConfigId": self.mt5_config_id,
                            "trades": trades,
                        })
                        logger.info(f"MT5 history synced: {len(trades)} closed trades")
            except Exception as e:
                logger.debug(f"MT5 history loop error: {e}")

            await asyncio.sleep(self.history_interval)

    # ── Public API ────────────────────────────────────────────────────────────

    async def start(self):
        """Start background reporting. No-op if MT5 not available or no config ID."""
        if not MT5_AVAILABLE:
            logger.warning("MT5 reporter: MetaTrader5 package not installed — run: pip install MetaTrader5")
            return
        if not self.mt5_config_id:
            logger.info("MT5 reporter: no --mt5-config-id set, live reporting disabled")
            return

        logger.info(
            f"MT5 reporter starting "
            f"(snapshot every {self.snapshot_interval}s, history every {self.history_interval}s)"
        )
        self._running = True
        asyncio.create_task(self._snapshot_loop())
        asyncio.create_task(self._history_loop())

    def stop(self):
        self._running = False
        if MT5_AVAILABLE and self._initialized:
            try:
                mt5.shutdown()
            except Exception:
                pass
