"""MT5 Writer — writes signals to MT5 Common/Files/signals.csv.

Uses the same CSV format the existing AuroraX_Copier EA reads.
Writes to FILE_COMMON path so it's accessible to all MT5 terminals.
Appends new signals without overwriting unprocessed ones.
"""

import csv
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from models import Signal

logger = logging.getLogger("aurora-bridge")

# CSV columns matching what the EA expects
CSV_HEADER = [
    "timestamp", "pair", "direction", "sl_method", "sl_value",
    "sl_multiplier", "min_sl_pips", "risk_reward", "risk_pct",
    "status", "signal_id", "action", "max_trades",
]


class MT5Writer:
    """Writes trade signals to MT5's signals.csv file."""

    def __init__(self, mt5_files_path: str, signal_filename: str = "signals.csv"):
        self.files_dir = Path(mt5_files_path)
        self.signal_file = self.files_dir / signal_filename
        self._ensure_dir()

    def _ensure_dir(self):
        """Ensure the MT5 files directory exists."""
        if not self.files_dir.exists():
            logger.warning(f"MT5 files directory not found: {self.files_dir}")
            logger.warning("Signals will be queued until the directory is available.")

    def write(self, signal: Signal) -> bool:
        """Write a signal to signals.csv. Returns True on success."""
        try:
            if not self.files_dir.exists():
                logger.warning(f"MT5 files dir missing: {self.files_dir}")
                return False

            file_exists = self.signal_file.exists()

            # Check for duplicate: don't write if signal_id already in file
            if file_exists and self._signal_exists(signal.id):
                logger.info(f"Signal {signal.id[:8]} already in CSV, skipping")
                return True

            # Build SL value string (matches copier.py format)
            sl_value = ""
            sl_multiplier = ""
            min_sl_pips = ""

            if signal.slPips is not None:
                sl_value = f"{signal.slPips} pips"
            elif signal.slLevel is not None:
                sl_value = str(signal.slLevel)

            # Append to CSV
            with open(self.signal_file, "a", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)

                # Write header if new file
                if not file_exists or os.path.getsize(self.signal_file) == 0:
                    writer.writerow(CSV_HEADER)

                writer.writerow([
                    datetime.now(timezone.utc).isoformat(),
                    signal.pair,
                    signal.direction,                # BUY or SELL
                    signal.slMethod or "ATR",
                    sl_value,
                    sl_multiplier,
                    min_sl_pips,
                    signal.riskReward or "",
                    signal.riskPercent or "",
                    "PENDING",                       # EA will update this
                    signal.id,
                    signal.action or "OPEN",
                    signal.maxOpenTrades or "",
                ])

            logger.info(f"Signal written → {signal.pair} {signal.direction} ({signal.id[:8]})")
            return True

        except PermissionError:
            logger.error(f"Permission denied writing to {self.signal_file}")
            return False
        except Exception as e:
            logger.error(f"Failed to write signal: {e}")
            return False

    def _signal_exists(self, signal_id: str) -> bool:
        """Check if a signal ID already exists in the CSV."""
        try:
            with open(self.signal_file, "r", encoding="utf-8") as f:
                reader = csv.reader(f)
                next(reader, None)  # skip header
                for row in reader:
                    if len(row) >= 11 and row[10] == signal_id:
                        return True
        except Exception:
            pass
        return False

    def get_executed_signals(self) -> list[dict]:
        """Read signals that the EA has marked as EXECUTED or FAILED."""
        results = []
        if not self.signal_file.exists():
            return results

        try:
            with open(self.signal_file, "r", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    status = row.get("status", "").upper()
                    if status in ("EXECUTED", "FAILED", "SYMBOL_NOT_FOUND", "MAX_PER_PAIR"):
                        results.append(row)
        except Exception as e:
            logger.error(f"Error reading signal results: {e}")

        return results
