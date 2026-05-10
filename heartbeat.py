"""Heartbeat — POSTs /bridge/heartbeat on a fixed cadence.

Lets the Aurora dashboard show "agent online" without depending on the SSE
connection (which can drop mid-session). Also keeps the agent's bridge token
fresh against the stale-cleanup cron — that cron revokes tokens whose
last_heartbeat_at AND last_used_at have both been silent for 30+ days.

Failures here MUST NOT crash the agent. We log a warning and try again on
the next tick. Network blips, brief 5xx, server restart — all fine to retry.

Cadence: 30s (matches the heartbeatIntervalSec default in
bridge.agent-download manifest). Could be config-driven later.
"""

import asyncio
import logging

import aiohttp

logger = logging.getLogger("aurora-bridge")

DEFAULT_INTERVAL_SEC = 30
REQUEST_TIMEOUT_SEC = 10


class Heartbeat:
    """Background task that pings /bridge/heartbeat at a fixed interval."""

    def __init__(self, token: str, api_url: str, interval_sec: int = DEFAULT_INTERVAL_SEC):
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.interval_sec = interval_sec
        self._task: asyncio.Task | None = None
        self._stop_event = asyncio.Event()

    @property
    def headers(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"}

    async def _tick(self) -> None:
        """One heartbeat post. Swallows any error so the loop stays alive."""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.api_url}/bridge/heartbeat",
                    headers=self.headers,
                    timeout=aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SEC),
                ) as resp:
                    if resp.status == 200:
                        logger.debug("heartbeat ok")
                    elif resp.status == 401:
                        # Token revoked/expired — log loudly but keep running so
                        # the rest of the agent (which will hit the same 401 on
                        # /signals/pending) can surface the issue consistently.
                        logger.warning("heartbeat: token rejected (HTTP 401)")
                    else:
                        body = await resp.text()
                        logger.warning(f"heartbeat: HTTP {resp.status} — {body[:200]}")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            # Network blips, DNS, server restart — retry on next tick.
            logger.debug(f"heartbeat tick failed (will retry): {e}")

    async def _loop(self) -> None:
        """Main heartbeat loop. Sleeps interval_sec between ticks."""
        logger.info(f"Heartbeat started (every {self.interval_sec}s)")
        while not self._stop_event.is_set():
            await self._tick()
            try:
                # Wait for either the interval to elapse or stop to be signalled.
                await asyncio.wait_for(self._stop_event.wait(), timeout=self.interval_sec)
            except asyncio.TimeoutError:
                pass  # interval elapsed normally — loop again
        logger.info("Heartbeat stopped")

    def start(self) -> None:
        """Spawn the heartbeat task. Idempotent — safe to call twice."""
        if self._task is None or self._task.done():
            self._stop_event.clear()
            self._task = asyncio.create_task(self._loop(), name="heartbeat")

    def stop(self) -> None:
        """Signal the heartbeat task to stop. Doesn't await — the agent's
        main shutdown handler will await all pending tasks."""
        self._stop_event.set()
        if self._task and not self._task.done():
            self._task.cancel()
