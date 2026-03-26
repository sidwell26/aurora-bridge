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
input double   RiskPercent      = 1.0;              // Risk % per trade (override)
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
      return;

   int handle = FileOpen(SignalFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;

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

   if(lineCount < 2) return;  // Header only or empty

   // Process each line (skip header)
   string updatedLines[];
   ArrayResize(updatedLines, lineCount);
   updatedLines[0] = lines[0];  // Keep header

   for(int i = 1; i < lineCount; i++)
   {
      string fields[];
      StringSplit(lines[i], ',', fields);

      // Expected: timestamp,pair,direction,sl_method,sl_value,sl_multiplier,min_sl_pips,risk_reward,risk_pct,status
      if(ArraySize(fields) < 10)
      {
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

      // Map pair name to broker symbol (handles suffix like "EURUSD.raw")
      string symbol = FindSymbol(pair);
      if(symbol == "")
      {
         Print("Symbol not found for: ", pair);
         fields[9] = "SYMBOL_NOT_FOUND";
         updatedLines[i] = JoinFields(fields);
         continue;
      }

      // Check per-pair trade limit
      if(MaxTradesPerPair > 0 && CountOpenTrades(symbol) >= MaxTradesPerPair)
      {
         Print("Max trades per pair reached for ", symbol, " (", MaxTradesPerPair, ")");
         fields[9] = "MAX_PER_PAIR";
         updatedLines[i] = JoinFields(fields);
         continue;
      }

      // Calculate SL in pips
      double slPips = CalculateSLPips(symbol, slMethod, slValue, slMult, minSlPips, direction);
      if(slPips <= 0) slPips = DefaultSLPips;

      // Calculate TP from R:R
      double tpPips = slPips * rr;

      // Execute
      bool success = ExecuteTrade(symbol, direction, slPips, tpPips, riskPct);
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
//| Count open trades for a symbol with our magic number              |
//+------------------------------------------------------------------+
int CountOpenTrades(string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
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

   // Try common suffixes
   string suffixes[] = {".raw", ".pro", ".ecn", ".std", ".m", ".i", "_"};
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
bool ExecuteTrade(string symbol, string direction, double slPips, double tpPips, double riskPct)
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
      sl = price - slPips * pipSize;
      tp = price + tpPips * pipSize;
   }
   else if(direction == "SELL")
   {
      orderType = ORDER_TYPE_SELL;
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
      sl = price + slPips * pipSize;
      tp = price - tpPips * pipSize;
   }
   else
   {
      Print("Unknown direction: ", direction);
      return false;
   }

   double lots = CalculateLots(symbol, slPips, riskPct);
   if(lots <= 0)
   {
      Print("Lot size calculation failed for ", symbol);
      return false;
   }

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = symbol;
   request.volume    = lots;
   request.type      = orderType;
   request.price     = price;
   request.sl        = NormalizeDouble(sl, digits);
   request.tp        = NormalizeDouble(tp, digits);
   request.deviation = MaxSlippage;
   request.magic     = MagicNumber;
   request.comment   = "AuroraX";

   if(!OrderSend(request, result))
   {
      Print("Order failed: ", result.retcode, " — ", result.comment);
      return false;
   }

   Print("Order executed: ", symbol, " ", direction, " ", lots, " lots",
         " SL=", NormalizeDouble(sl, digits), " TP=", NormalizeDouble(tp, digits),
         " Ticket=", result.order);
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
