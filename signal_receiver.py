"""Signal Receiver — REST polling (primary) + SSE (optional enhancement).

Polls /bridge/signals/pending every 5 seconds as the primary delivery method.
Optionally maintains an SSE connection for instant delivery when available.
SSE failures use exponential backoff to avoid log spam.
Deduplicates signals using a local set of seen IDs.
"""

import asyncio
import json
import logging
from typing import AsyncIterator

import aiohttp

from models import Signal

logger = logging.getLogger("aurora-bridge")


class SignalReceiver:
    """Receives signals from Aurora API via SSE + polling fallback."""

    def __init__(self, token: str, api_url: str, poll_interval: int = 5,
                 mt5_config_id: str | None = None):
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.poll_interval = poll_interval
        self.mt5_config_id = mt5_config_id      # this bridge's MT5 config UUID
        self.seen_ids: set[str] = set()
        self._signal_queue: asyncio.Queue[Signal] = asyncio.Queue()
        self._running = False

    @property
    def headers(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"}

    def _is_for_this_bridge(self, signal: Signal) -> bool:
        """Return True if this signal should be executed by this bridge instance.

        Routing rules:
          - signal.mt5ConfigId is None → broadcast; all bridges execute it.
          - signal.mt5ConfigId is set AND this bridge has no mt5_config_id → skip
            (another specific terminal was targeted, we don't know which one we are).
          - signal.mt5ConfigId is set AND matches this bridge's mt5_config_id → execute.
          - signal.mt5ConfigId is set AND does NOT match → skip.
        """
        if signal.mt5ConfigId is None:
            return True  # broadcast signal
        if self.mt5_config_id is None:
            logger.debug(
                f"Signal {signal.id[:8]} targets mt5ConfigId={signal.mt5ConfigId[:8]} "
                f"but this bridge has no mt5_config_id configured — skipping"
            )
            return False
        match = signal.mt5ConfigId == self.mt5_config_id
        if not match:
            logger.debug(
                f"Signal {signal.id[:8]} targets {signal.mt5ConfigId[:8]}, "
                f"this bridge is {self.mt5_config_id[:8]} — skipping"
            )
        return match

    async def fetch_pending(self) -> list[Signal]:
        """Fetch all pending signals (used on startup + polling fallback)."""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{self.api_url}/bridge/signals/pending",
                    headers=self.headers,
                    timeout=aiohttp.ClientTimeout(total=10),
                ) as resp:
                    if resp.status == 401:
                        logger.error("Authentication failed — token may be expired or revoked")
                        return []
                    if resp.status != 200:
                        logger.warning(f"Failed to fetch pending signals: HTTP {resp.status}")
                        return []
                    data = await resp.json()
                    signals = [Signal(**s) for s in data.get("signals", [])]
                    return [s for s in signals
                            if s.id not in self.seen_ids and self._is_for_this_bridge(s)]
        except Exception as e:
            logger.error(f"Error fetching pending signals: {e}")
            return []

    async def ack(self, signal_id: str, status: str, mt5_ticket: str | None = None,
                  failure_reason: str | None = None):
        """Report signal status back to Aurora API."""
        try:
            body = {"status": status}
            if mt5_ticket:
                body["mt5Ticket"] = mt5_ticket
            if failure_reason:
                body["failureReason"] = failure_reason

            async with aiohttp.ClientSession() as session:
                async with session.patch(
                    f"{self.api_url}/bridge/signals/{signal_id}/status",
                    headers={**self.headers, "Content-Type": "application/json"},
                    json=body,
                    timeout=aiohttp.ClientTimeout(total=10),
                ) as resp:
                    if resp.status == 200:
                        logger.info(f"Signal {signal_id[:8]} status → {status}")
                    else:
                        logger.warning(f"Failed to ack signal {signal_id[:8]}: HTTP {resp.status}")
        except Exception as e:
            logger.error(f"Error acking signal {signal_id[:8]}: {e}")

    async def _sse_loop(self):
        """Connect to SSE stream — optional enhancement, failures are non-fatal."""
        sse_backoff = 5  # Start at 5s, increase on failure
        max_backoff = 120  # Cap at 2 minutes

        while self._running:
            try:
                logger.debug(f"Connecting to SSE stream...")
                timeout = aiohttp.ClientTimeout(total=None, sock_read=60)
                async with aiohttp.ClientSession(timeout=timeout) as session:
                    async with session.get(
                        f"{self.api_url}/bridge/signals/stream",
                        headers=self.headers,
                    ) as resp:
                        if resp.status == 401:
                            logger.error("SSE auth failed — token may be expired")
                            return  # Don't retry auth failures
                        if resp.status != 200:
                            logger.debug(f"SSE connection failed: HTTP {resp.status}")
                            await asyncio.sleep(sse_backoff)
                            sse_backoff = min(sse_backoff * 2, max_backoff)
                            continue

                        logger.info("SSE stream connected ✓")
                        sse_backoff = 5  # Reset backoff on success
                        buffer = ""
                        async for chunk in resp.content:
                            if not self._running:
                                return
                            buffer += chunk.decode("utf-8", errors="replace")
                            while "\n\n" in buffer:
                                message, buffer = buffer.split("\n\n", 1)
                                await self._parse_sse_message(message)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.debug(f"SSE connection lost: {e}")

            if not self._running:
                return
            await asyncio.sleep(sse_backoff)
            sse_backoff = min(sse_backoff * 2, max_backoff)

    async def _parse_sse_message(self, raw: str):
        """Parse an SSE message and queue the signal."""
        event_type = ""
        data = ""
        for line in raw.strip().split("\n"):
            if line.startswith("event: "):
                event_type = line[7:]
            elif line.startswith("data: "):
                data = line[6:]

        if event_type == "signal" and data:
            try:
                signal = Signal(**json.loads(data))
                if signal.id not in self.seen_ids and self._is_for_this_bridge(signal):
                    self.seen_ids.add(signal.id)
                    await self._signal_queue.put(signal)
                    logger.info(f"SSE → {signal.pair} {signal.direction} ({signal.id[:8]})")
            except Exception as e:
                logger.warning(f"Failed to parse SSE signal: {e}")
        elif event_type == "connected":
            logger.info("SSE handshake complete")
        elif event_type == "ping":
            pass  # keepalive

    async def _poll_loop(self):
        """Polling fallback: fetch pending signals periodically."""
        while self._running:
            try:
                signals = await self.fetch_pending()
                for signal in signals:
                    # fetch_pending already applies _is_for_this_bridge, but
                    # guard here too in case signals arrive via other paths.
                    if signal.id not in self.seen_ids and self._is_for_this_bridge(signal):
                        self.seen_ids.add(signal.id)
                        await self._signal_queue.put(signal)
                        logger.info(f"POLL → {signal.pair} {signal.direction} ({signal.id[:8]})")
            except Exception as e:
                logger.warning(f"Poll error: {e}")
            await asyncio.sleep(self.poll_interval)

    async def stream(self) -> AsyncIterator[Signal]:
        """Main stream: polling is primary, SSE runs in background as enhancement."""
        self._running = True

        # Start polling as primary delivery (every 5 seconds)
        poll_task = asyncio.create_task(self._poll_loop())

        # Start SSE as optional background enhancement (non-blocking, auto-reconnects)
        sse_task = asyncio.create_task(self._sse_loop())

        try:
            while self._running:
                try:
                    signal = await asyncio.wait_for(self._signal_queue.get(), timeout=1.0)
                    yield signal
                except asyncio.TimeoutError:
                    continue
        finally:
            self._running = False
            poll_task.cancel()
            sse_task.cancel()
            try:
                await poll_task
            except asyncio.CancelledError:
                pass
            try:
                await sse_task
            except asyncio.CancelledError:
                pass

    def stop(self):
        """Stop the receiver."""
        self._running = False
