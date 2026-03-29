//+------------------------------------------------------------------+
//| AuroraX_Copier.mq5                                               |
//| Aurora X Trade Copier EA                                          |
//|                                                                    |
//| Reads signals.csv from Common/Files/ and executes trades.         |
//| The Python bridge agent writes to this file when alerts arrive.   |
//|                                                                    |
//| YOU are responsible for your own trading decisions.                |
//| This tool is provided as-is with no guarantees.                   |
//+------------------------------------------------------------------+
#property copyright "Aurora X"
#property version   "1.00"
#property strict

// ─── Inputs ──────────────────────────────────────────────────────────────────

input string   SignalFile       = "signals.csv";    // Signal file name (in Common/Files/)
input double   RiskPercent      = 0;                // Risk % override (0 = use signal value)
input double   MaxRiskReward    = 0;                // Max R:R to accept (0 = use signal value)
input int      MaxSlippage      = 3;                // Max slippage in points
input int      MagicNumber      = 202603;           // EA magic number
input int      PollIntervalMs   = 2000;             // How often to check file (ms)
input bool     AutoCalculateSL  = true;             // Calculate SL from method params
input double   DefaultSLPips    = 20;               // Fallback SL if method unknown
input int      MaxTradesPerPair = 1;                // Max open trades per pair (0 = unlimited)

// ─── Globals ─────────────────────────────────────────────────────────────────

datetime lastCheck = 0;
string   processedFile = "signals_done.csv";

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Aurora X Copier EA started");
   Print("Signal file: ", SignalFile);
   Print("Risk: ", RiskPercent, "% | Magic: ", MagicNumber);
   EventSetMillisecondTimer(PollIntervalMs);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("Aurora X Copier EA stopped");
}

//+------------------------------------------------------------------+
//| Timer event — poll for new signals                                |
//+------------------------------------------------------------------+
void OnTimer()
{
   CheckSignals();
}

//+------------------------------------------------------------------+
//| Read and process signal file                                      |
//+------------------------------------------------------------------+
void CheckSignals()
{
   if(!FileIsExist(SignalFile, FILE_COMMON))
   {
      Print("DEBUG: signals.csv not found");
      return;
   }

   int handle = FileOpen(SignalFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
   {
      Print("DEBUG: Failed to open signals.csv, error=", GetLastError());
      return;
   }

   string lines[];
   int lineCount = 0;
   bool hasUnprocessed = false;

   // Read all lines
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(StringLen(line) > 0)
      {
         ArrayResize(lines, lineCount + 1);
         lines[lineCount] = line;
         lineCount++;
      }
   }
   FileClose(handle);

   Print("DEBUG: Read ", lineCount, " lines from signals.csv");

   if(lineCount < 2) return;  // Header only or empty

   // Process each line (skip header)
   string updatedLines[];
   ArrayResize(updatedLines, lineCount);
   updatedLines[0] = lines[0];  // Keep header

   for(int i = 1; i < lineCount; i++)
   {
      string fields[];
      StringSplit(lines[i], ',', fields);

      Print("DEBUG: Line ", i, " has ", ArraySize(fields), " fields, status=", (ArraySize(fields) >= 10 ? fields[9] : "N/A"));

      // Expected: timestamp,pair,direction,sl_method,sl_value,sl_multiplier,min_sl_pips,risk_reward,risk_pct,status,signal_id,action[,max_trades]
      if(ArraySize(fields) < 12)
      {
         Print("DEBUG: Skipping line ", i, " — only ", ArraySize(fields), " fields (need 12)");
         updatedLines[i] = lines[i];
         continue;
      }

      string status = fields[9];
      StringTrimRight(status);
      StringTrimLeft(status);

      if(status != "PENDING")
      {
         updatedLines[i] = lines[i];
         continue;
      }

      hasUnprocessed = true;

      string pair      = fields[1];
      string direction = fields[2];
      string slMethod  = fields[3];
      string slValue   = fields[4];
      double slMult    = StringToDouble(fields[5]);
      double minSlPips = StringToDouble(fields[6]);
      double rr        = StringToDouble(fields[7]);
      double riskPct   = StringToDouble(fields[8]);

      // Use input overrides if set
      if(RiskPercent > 0) riskPct = RiskPercent;
      if(MaxRiskReward > 0 && rr > MaxRiskReward) rr = MaxRiskReward;

      Print("DEBUG: Processing signal — pair=", pair, " dir=", direction, " sl_method=", slMethod, " sl_value=", slValue, " rr=", rr, " risk=", riskPct);

      // Map pair name to broker symbol (handles suffix like "EURUSD.raw")
      string symbol = FindSymbol(pair);
      Print("DEBUG: FindSymbol(", pair, ") → ", symbol);
      if(symbol == "")
      {
         Print("Symbol not found for: ", pair);
         fields[9] = "SYMBOL_NOT_FOUND";
         updatedLines[i] = JoinFields(fields);
         continue;
      }

      // Per-signal magic number (unique per strategy/alert)
      int signalMagic = MagicNumber;
      if(ArraySize(fields) >= 14 && StringLen(fields[13]) > 0)
      {
         int parsed = (int)StringToInteger(fields[13]);
         if(parsed > 0) signalMagic = parsed;
      }

      // Check per-pair trade limit (use signal value if present, else EA input)
      int maxTrades = MaxTradesPerPair;
      if(ArraySize(fields) >= 13 && StringLen(fields[12]) > 0)
      {
         int signalMax = (int)StringToInteger(fields[12]);
         if(signalMax > 0) maxTrades = signalMax;
      }
      if(maxTrades > 0 && CountOpenTradesWithMagic(symbol, signalMagic) >= maxTrades)
      {
         Print("Max trades per pair reached for ", symbol, " (", maxTrades, ")");
         fields[9] = "MAX_PER_PAIR";
         updatedLines[i] = JoinFields(fields);
         continue;
      }

      // Calculate SL in pips (0 = no SL)
      double slPips = 0;
      if(slMethod != "" && slMethod != "NONE")
      {
         slPips = CalculateSLPips(symbol, slMethod, slValue, slMult, minSlPips, direction);
         Print("DEBUG: SL pips=", slPips, " (method=", slMethod, " value=", slValue, " mult=", slMult, ")");
         if(slPips <= 0 && AutoCalculateSL) slPips = DefaultSLPips;
      }

      // Calculate TP from R:R (0 = no TP)
      double tpPips = (slPips > 0 && rr > 0) ? slPips * rr : 0;

      string signalId = fields[10];
      StringTrimRight(signalId);
      StringTrimLeft(signalId);

      // Execute
      bool success = ExecuteTrade(symbol, direction, slPips, tpPips, riskPct, signalId, signalMagic);
      fields[9] = success ? "EXECUTED" : "FAILED";
      updatedLines[i] = JoinFields(fields);
   }

   // Rewrite file with updated statuses
   if(hasUnprocessed)
   {
      int wHandle = FileOpen(SignalFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(wHandle != INVALID_HANDLE)
      {
         for(int i = 0; i < lineCount; i++)
            FileWriteString(wHandle, updatedLines[i] + "\n");
         FileClose(wHandle);
      }
   }
}

//+------------------------------------------------------------------+
//| Count open trades for a symbol with a specific magic number       |
//+------------------------------------------------------------------+
int CountOpenTradesWithMagic(string symbol, int magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == magic)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Find broker symbol matching pair name                             |
//+------------------------------------------------------------------+
string FindSymbol(string pair)
{
   // Try exact match first
   if(SymbolSelect(pair, true))
      return pair;

   // Try common suffixes (covers most brokers)
   string suffixes[] = {"p", ".raw", ".pro", ".ecn", ".std", ".m", ".i", "_", "m", ".r", ".z", "-ECN", ".stp"};
   for(int i = 0; i < ArraySize(suffixes); i++)
   {
      string test = pair + suffixes[i];
      if(SymbolSelect(test, true))
         return test;
   }

   // Search all symbols
   for(int i = 0; i < SymbolsTotal(false); i++)
   {
      string sym = SymbolName(i, false);
      if(StringFind(sym, pair) == 0)  // Starts with pair name
      {
         SymbolSelect(sym, true);
         return sym;
      }
   }

   return "";
}

//+------------------------------------------------------------------+
//| Calculate SL in pips from method and params                       |
//+------------------------------------------------------------------+
double CalculateSLPips(string symbol, string method, string value, double mult, double minPips, string direction)
{
   double pips = 0;

   if(method == "ATR")
   {
      // value contains something like "15.2 pips"
      pips = ExtractPipsFromValue(value);
      if(pips <= 0 && mult > 0)
      {
         // Calculate from ATR
         double atr[];
         int atrHandle = iATR(symbol, PERIOD_CURRENT, 14);
         if(atrHandle != INVALID_HANDLE)
         {
            CopyBuffer(atrHandle, 0, 0, 1, atr);
            IndicatorRelease(atrHandle);
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
            double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;
            pips = (atr[0] * mult) / pipSize;
         }
      }
   }
   else if(method == "EMA" || method == "SMA")
   {
      // value contains the price level like "1.08250"
      double level = StringToDouble(value);
      if(level > 0)
      {
         double price = SymbolInfoDouble(symbol, SYMBOL_BID);
         double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;

         // Check if EMA/SMA is on the wrong side (SL would be above entry for BUY, below for SELL)
         bool wrongSide = (direction == "BUY" && level > price) ||
                          (direction == "SELL" && level < price);
         if(wrongSide)
         {
            Print("EMA/SMA on wrong side for ", direction, " (level=", level, " price=", price, ") — using fallback SL");
            pips = 0;  // Will fall through to DefaultSLPips
         }
         else
         {
            pips = MathAbs(price - level) / pipSize;
         }
      }
   }
   else if(method == "FIXED_PIPS")
   {
      pips = ExtractPipsFromValue(value);
   }
   else if(method == "NDAY_HIGH_LOW")
   {
      pips = ExtractPipsFromValue(value);
   }

   // Apply minimum
   if(minPips > 0 && pips < minPips)
      pips = minPips;

   return pips;
}

//+------------------------------------------------------------------+
//| Extract numeric pips value from string like "15.2 pips"           |
//+------------------------------------------------------------------+
double ExtractPipsFromValue(string value)
{
   // Remove "pips" and whitespace
   StringReplace(value, "pips", "");
   StringReplace(value, "pip", "");
   StringTrimRight(value);
   StringTrimLeft(value);
   return StringToDouble(value);
}

//+------------------------------------------------------------------+
//| Calculate lot size from risk % and SL pips                        |
//+------------------------------------------------------------------+
double CalculateLots(string symbol, double slPips, double riskPct)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * riskPct / 100.0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize   = (digits == 3 || digits == 5) ? point * 10 : point;

   double pipValue = tickValue * (pipSize / tickSize);
   if(pipValue <= 0) return 0;

   double lots = riskAmount / (slPips * pipValue);

   // Clamp to broker limits
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return lots;
}

//+------------------------------------------------------------------+
//| Execute a trade                                                    |
//+------------------------------------------------------------------+
bool ExecuteTrade(string symbol, string direction, double slPips, double tpPips, double riskPct, string signal_id = "", int magic = 0)
{
   ENUM_ORDER_TYPE orderType;
   double price, sl, tp;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;

   if(direction == "BUY")
   {
      orderType = ORDER_TYPE_BUY;
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      sl = slPips > 0 ? price - slPips * pipSize : 0;
      tp = tpPips > 0 ? price + tpPips * pipSize : 0;
   }
   else if(direction == "SELL")
   {
      orderType = ORDER_TYPE_SELL;
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
      sl = slPips > 0 ? price + slPips * pipSize : 0;
      tp = tpPips > 0 ? price - tpPips * pipSize : 0;
   }
   else
   {
      Print("Unknown direction: ", direction);
      return false;
   }

   // Lot sizing: use risk-based if SL and risk% are set, otherwise use min lot
   double lots;
   if(slPips > 0 && riskPct > 0)
   {
      lots = CalculateLots(symbol, slPips, riskPct);
   }
   else
   {
      lots = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   }
   if(lots <= 0)
   {
      Print("Lot size calculation failed for ", symbol);
      return false;
   }

   Print("DEBUG: Executing ", direction, " ", lots, " lots ", symbol, " @ ", price, " SL=", sl, " TP=", tp);

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = symbol;
   request.volume    = lots;
   request.type      = orderType;
   request.price     = price;
   request.sl        = sl > 0 ? NormalizeDouble(sl, digits) : 0;
   request.tp        = tp > 0 ? NormalizeDouble(tp, digits) : 0;
   request.deviation = MaxSlippage;
   request.magic     = magic > 0 ? magic : MagicNumber;
   request.comment   = "AuroraX";

   if(!OrderSend(request, result))
   {
      Print("Order failed: ", result.retcode, " — ", result.comment);
      return false;
   }

   Print("Order executed: ", symbol, " ", direction, " ", lots, " lots",
         " SL=", NormalizeDouble(sl, digits), " TP=", NormalizeDouble(tp, digits),
         " Ticket=", result.order);

   // Write ticket to a file the bridge agent can read
   string ticketFile = "last_ticket.csv";
   int tHandle = FileOpen(ticketFile, FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(tHandle != INVALID_HANDLE)
   {
      FileSeek(tHandle, 0, SEEK_END);
      FileWriteString(tHandle, signal_id + "," + IntegerToString(result.order) + "\n");
      FileClose(tHandle);
   }

   return true;
}

//+------------------------------------------------------------------+
//| Join string array back to CSV line                                 |
//+------------------------------------------------------------------+
string JoinFields(string &fields[])
{
   string result = "";
   for(int i = 0; i < ArraySize(fields); i++)
   {
      if(i > 0) result += ",";
      result += fields[i];
   }
   return result;
}

//+------------------------------------------------------------------+
//| Tick event (not used — timer-based)                                |
//+------------------------------------------------------------------+
void OnTick() {}
//+------------------------------------------------------------------+
