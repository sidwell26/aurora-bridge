"""Pydantic models for Aurora Bridge Agent."""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel


class Signal(BaseModel):
    """Trade signal received from Aurora API."""
    id: str
    userId: str
    alertId: str
    pair: str           # e.g. EURUSD
    timeframe: str      # e.g. H1
    action: str         # OPEN or CLOSE
    direction: str      # BUY or SELL
    slMethod: Optional[str] = None
    slPips: Optional[float] = None
    slLevel: Optional[float] = None
    tpPips: Optional[float] = None
    tpLevel: Optional[float] = None
    lotSize: Optional[float] = 0.01
    riskReward: Optional[float] = None
    riskPercent: Optional[float] = None
    status: str = "pending"
    createdAt: Optional[str] = None


class ExecutionResult(BaseModel):
    """Trade execution result from MT5 EA."""
    signal_id: str
    status: str         # executed or failed
    ticket: Optional[str] = None
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    executed_at: Optional[str] = None


class MT5Config(BaseModel):
    """MT5 terminal configuration."""
    broker_server: str
    account_number: str
    password: Optional[str] = None
    mt5_path: Optional[str] = None
    environment: str = "demo"  # live or demo


class AgentConfig(BaseModel):
    """Bridge Agent configuration."""
    api_url: str = "https://market-analysis-backend-9rg3.onrender.com"
    token: Optional[str] = None
    mt5_signal_file: Optional[str] = None       # auto-detected or manual
    mt5_result_file: Optional[str] = None       # auto-detected or manual
    poll_interval_seconds: int = 5
    mt5: Optional[MT5Config] = None
