"""
Aurora Bridge Agent — Direct signal delivery from Aurora X to MT5.

Replaces the Telegram-based trade copier with a direct API connection.
No Python dependencies needed for the end user (compiled to .exe via PyInstaller).

Usage:
  python agent.py              # Normal start
  python agent.py --setup      # Force re-authentication
  python agent.py --mt5-path "C:\\path\\to\\MQL5\\Files"  # Manual MT5 path
"""

import argparse
import asyncio
import logging
import signal
import sys

from config_store import load_config, save_config, detect_mt5_path, install_ea
from auth_manager import AuthManager
from signal_receiver import SignalReceiver
from mt5_writer import MT5Writer
from result_reader import ResultReader
from health_monitor import HealthMonitor, HealthStatus

# ─── Logging setup ───────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("aurora_bridge.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("aurora-bridge")


# ─── Main ────────────────────────────────────────────────────────────────────

async def main():
    parser = argparse.ArgumentParser(description="Aurora Bridge Agent")
    parser.add_argument("--setup", action="store_true", help="Force re-authentication")
    parser.add_argument("--token", type=str, help="Bridge API key (from Aurora X → Strategy Builder → Trader tab)")
    parser.add_argument("--mt5-path", type=str, help="Manual path to MT5 Files directory")
    parser.add_argument("--api-url", type=str, help="Aurora API URL override")
    args = parser.parse_args()

    # Load config
    config = load_config()
    if args.api_url:
        config.api_url = args.api_url
        save_config(config)
    if args.mt5_path:
        config.mt5_signal_file = args.mt5_path
        save_config(config)

    logger.info("═" * 50)
    logger.info("  Aurora Bridge Agent v1.5.1")
    logger.info("═" * 50)
    logger.info(f"API: {config.api_url}")

    # ── Step 1: Authentication ────────────────────────────────────────────
    if args.token:
        # Direct token via CLI flag
        config.token = args.token
        save_config(config)
        logger.info("Token set via --token flag")
    elif args.setup or not config.token:
        # Try interactive prompt first, fall back to OAuth if no stdin (windowed mode)
        try:
            logger.info("No API key found. Get one from Aurora X → Strategy Builder → Trader tab.")
            logger.info("")
            token_input = input("Paste your Bridge API Key (or press Enter for browser login): ").strip()
            if token_input:
                config.token = token_input
                save_config(config)
                logger.info("Token saved!")
            else:
                raise EOFError()  # trigger browser flow
        except (EOFError, RuntimeError, OSError):
            # No stdin available (windowed .exe) — try browser OAuth
            logger.info("Opening browser for authentication...")
            auth = AuthManager(config.api_url)
            token = await auth.authenticate()
            if not token:
                logger.error("Authentication failed. Run from command line with:")
                logger.error("  AuroraBridge.exe --token YOUR_API_KEY")
                sys.exit(1)
            config.token = token
            save_config(config)

    # ── Step 2: Detect MT5 path ───────────────────────────────────────────
    if not config.mt5_signal_file:
        detected = detect_mt5_path()
        if detected:
            config.mt5_signal_file = detected
            logger.info(f"MT5 path auto-detected: {detected}")
            save_config(config)
        else:
            logger.warning("MT5 path not found. Use --mt5-path to set manually.")
            logger.warning("Signals will be received but NOT written to MT5.")

    # ── Step 2b: Auto-install EA into MT5 Experts folder ────────────────
    ea_paths = install_ea()
    if ea_paths:
        logger.info(f"EA auto-installed to {len(ea_paths)} terminal(s)")
        logger.info("Open MT5 → drag AuroraX_Copier onto any chart to activate")

    # ── Step 3: Initialize components ─────────────────────────────────────
    receiver = SignalReceiver(config.token, config.api_url, config.poll_interval_seconds)
    writer = MT5Writer(config.mt5_signal_file) if config.mt5_signal_file else None
    health = HealthMonitor(config.mt5_signal_file)

    # Start system tray
    shutdown_event = asyncio.Event()

    def on_quit():
        shutdown_event.set()

    health.start_tray(on_quit=on_quit)

    # Handle Ctrl+C
    def signal_handler(sig, frame):
        logger.info("Shutting down...")
        shutdown_event.set()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # ── Step 4: Fetch missed signals ──────────────────────────────────────
    logger.info("Fetching any missed signals...")
    pending = await receiver.fetch_pending()
    if pending:
        logger.info(f"Found {len(pending)} pending signals")
        for s in pending:
            if writer:
                written = writer.write(s)
                if written:
                    await receiver.ack(s.id, "delivered")
            else:
                logger.info(f"Signal {s.pair} {s.direction} received (no MT5 path configured)")
                await receiver.ack(s.id, "delivered")
    else:
        logger.info("No pending signals")

    health.update_status(HealthStatus.CONNECTED)

    # ── Step 5: Start result reader (report EA execution back to API) ─────
    result_task = None
    if writer and config.mt5_signal_file:
        result_reader = ResultReader(config.mt5_signal_file)

        async def read_results():
            async for result in result_reader.watch():
                await receiver.ack(
                    result.signal_id,
                    result.status,
                    mt5_ticket=result.ticket,
                    failure_reason=result.error_message,
                )

        result_task = asyncio.create_task(read_results())

    # ── Step 6: Main signal loop ──────────────────────────────────────────
    logger.info("Listening for signals...")
    logger.info("Press Ctrl+C to stop")

    try:
        async for s in receiver.stream():
            if shutdown_event.is_set():
                break

            logger.info(f"{'─' * 40}")
            logger.info(f"SIGNAL: {s.pair} {s.direction} ({s.action})")
            logger.info(f"  ID: {s.id[:12]}...")
            logger.info(f"  SL: {s.slMethod} | R:R {s.riskReward}")

            if writer:
                written = writer.write(s)
                if written:
                    await receiver.ack(s.id, "delivered")
                    health.update_status(HealthStatus.CONNECTED)
                else:
                    await receiver.ack(s.id, "failed", failure_reason="Failed to write to MT5 files")
                    health.update_status(HealthStatus.MT5_ERROR)
            else:
                logger.warning("No MT5 path — signal received but not written")
                await receiver.ack(s.id, "delivered")

    except asyncio.CancelledError:
        pass
    finally:
        receiver.stop()
        if result_task:
            result_task.cancel()
        health.stop()
        logger.info("Aurora Bridge Agent stopped.")


if __name__ == "__main__":
    asyncio.run(main())
