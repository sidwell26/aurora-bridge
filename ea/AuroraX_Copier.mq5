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

input string   SignalFile             = "signals.csv";  // Signal file name (in Common/Files/)
input double   RiskPercent            = 0;              // Risk % override (0 = use signal value)
input double   MaxRiskReward          = 0;              // Max R:R to accept (0 = use signal value)
input int      MaxSlippage            = 3;              // Max slippage in points
input int      MagicNumber            = 202603;         // EA magic number
input int      PollIntervalMs         = 2000;           // How often to check file (ms)
input bool     AutoCalculateSL        = true;           // Calculate SL from method params
input double   DefaultSLPips          = 20;             // Fallback SL if method unknown
input int      MaxTradesPerPair       = 1;              // Fallback max trades per pair if signal doesn't specify
input bool     EnableSpreadSLWiden    = true;           // Widen SL during NY→Asia spread window
input int      SpreadWindowWidenPips  = 30;             // Pips to widen SL during spread window

// ─── Globals ─────────────────────────────────────────────────────────────────

datetime lastCheck      = 0;
datetime lastReportTime = 0;
string   processedFile  = "signals_done.csv";
string   g_perfFolder   = "";   // aurora_{AccountLogin}\ — set in OnInit
bool     g_inSpreadWindow = false; // true while inside the NY/Asia spread window

#define REPORT_INTERVAL_SEC 60

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create per-account subfolder so multiple terminals don't share the same CSVs
   g_perfFolder = "aurora_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\\";
   FolderCreate(StringSubstr(g_perfFolder, 0, StringLen(g_perfFolder) - 1), FILE_COMMON);

   Print("Aurora X Copier EA started");
   Print("Signal file: ", SignalFile);
   Print("Performance folder: ", g_perfFolder, " (Common/Files)");
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
//| Timer event — poll for new signals + 60s performance reporting   |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(EnableSpreadSLWiden) CheckSpreadWindow();

   CheckSignals();

   datetime now = TimeCurrent();
   if(now - lastReportTime >= REPORT_INTERVAL_SEC)
   {
      lastReportTime = now;
      WritePerformanceFiles();
   }
}

//+------------------------------------------------------------------+
//| Read and process signal file                                      |
//+------------------------------------------------------------------+
void CheckSignals()
{
   string signalPath = g_perfFolder + SignalFile;
   if(!FileIsExist(signalPath, FILE_COMMON))
      return;

   int handle = FileOpen(signalPath, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
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

      // Weekend-close: a CLOSE action means flatten all open positions for this
      // alert's magic on this symbol. Used by the server's close_before_weekend
      // guard. Magic is per-strategy so we only touch positions from this alert.
      string signalAction = fields[11];
      StringTrimRight(signalAction); StringTrimLeft(signalAction);
      if(signalAction == "CLOSE")
      {
         int closed = CloseTradesWithMagic(symbol, signalMagic);
         Print("CLOSE signal: flattened ", closed, " position(s) on ", symbol, " magic=", signalMagic);
         fields[9] = "EXECUTED";
         updatedLines[i] = JoinFields(fields);
         continue;
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
      int wHandle = FileOpen(signalPath, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(wHandle != INVALID_HANDLE)
      {
         for(int i = 0; i < lineCount; i++)
            FileWriteString(wHandle, updatedLines[i] + "\n");
         FileClose(wHandle);
      }
   }
}

//+------------------------------------------------------------------+
//| Detect NY→Asia spread window and widen/restore SLs               |
//| Window: Mon–Thu 20:55–22:00 UTC (Fri covered by weekend flatten) |
//+------------------------------------------------------------------+
void CheckSpreadWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int mins = dt.hour * 60 + dt.min;
   int day  = dt.day_of_week; // 0=Sun,1=Mon,...,6=Sat

   bool shouldWiden = (day >= 1 && day <= 4)
                   && (mins >= 20 * 60 + 55)
                   && (mins <  22 * 60);

   if(shouldWiden && !g_inSpreadWindow)
   {
      g_inSpreadWindow = true;
      Print("[SpreadWindow] NY/Asia changeover — widening all SLs by ", SpreadWindowWidenPips, " pips");
      WidenAllSLs();
   }
   else if(!shouldWiden && g_inSpreadWindow)
   {
      g_inSpreadWindow = false;
      Print("[SpreadWindow] Window closed — restoring original SLs");
      RestoreAllSLs();
   }
}

//+------------------------------------------------------------------+
//| Widen every open position's SL by SpreadWindowWidenPips pips     |
//| Stores original SL in a Global Variable for later restore         |
//+------------------------------------------------------------------+
void WidenAllSLs()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      double currentSL = PositionGetDouble(POSITION_SL);
      string gvName    = "aurora_orig_sl_" + IntegerToString((long)ticket);

      // Always store original so RestoreAllSLs knows what to put back
      GlobalVariableSet(gvName, currentSL);

      if(currentSL == 0) continue; // No SL set — nothing to widen

      string symbol  = PositionGetString(POSITION_SYMBOL);
      double point   = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double widenDist = SpreadWindowWidenPips * pipSize;
      // BUY: SL is below entry — push it further down
      // SELL: SL is above entry — push it further up
      double newSL = (ptype == POSITION_TYPE_BUY)
                   ? currentSL - widenDist
                   : currentSL + widenDist;

      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action   = TRADE_ACTION_SLTP;
      req.position = ticket;
      req.symbol   = symbol;
      req.sl       = NormalizeDouble(newSL, digits);
      req.tp       = PositionGetDouble(POSITION_TP);

      if(OrderSend(req, res))
         Print("[SpreadWindow] Widened SL ticket=", ticket, " ", symbol,
               "  orig=", currentSL, " → ", NormalizeDouble(newSL, digits));
      else
         Print("[SpreadWindow] Widen failed ticket=", ticket,
               " retcode=", res.retcode, " err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Restore every open position's SL from its stored Global Variable  |
//+------------------------------------------------------------------+
void RestoreAllSLs()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      string gvName = "aurora_orig_sl_" + IntegerToString((long)ticket);
      if(!GlobalVariableCheck(gvName)) continue;

      double origSL = GlobalVariableGet(gvName);
      GlobalVariableDel(gvName);

      if(origSL == 0) continue; // Was no-SL, skip

      string symbol = PositionGetString(POSITION_SYMBOL);
      int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action   = TRADE_ACTION_SLTP;
      req.position = ticket;
      req.symbol   = symbol;
      req.sl       = NormalizeDouble(origSL, digits);
      req.tp       = PositionGetDouble(POSITION_TP);

      if(OrderSend(req, res))
         Print("[SpreadWindow] Restored SL ticket=", ticket, " ", symbol,
               " → ", NormalizeDouble(origSL, digits));
      else
         Print("[SpreadWindow] Restore failed ticket=", ticket,
               " retcode=", res.retcode, " err=", GetLastError());
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
//| Close all open positions for a symbol with a specific magic       |
//+------------------------------------------------------------------+
int CloseTradesWithMagic(string symbol, int magic)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = symbol;
      req.volume       = PositionGetDouble(POSITION_VOLUME);
      req.type         = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price        = (ptype == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(symbol, SYMBOL_BID)
                         : SymbolInfoDouble(symbol, SYMBOL_ASK);
      req.deviation    = MaxSlippage;
      req.magic        = magic;
      req.type_filling = ORDER_FILLING_IOC;
      if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         closed++;
      else
         Print("CLOSE failed ticket=", ticket, " retcode=", res.retcode, " err=", GetLastError());
   }
   return closed;
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

   // Set filling mode based on what the broker supports
   long fillMode = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      request.type_filling = ORDER_FILLING_FOK;
   else if((fillMode & SYMBOL_FILLING_IOC) != 0)
      request.type_filling = ORDER_FILLING_IOC;
   else
      request.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(request, result))
   {
      Print("Order failed: ", result.retcode, " — ", result.comment);
      return false;
   }

   Print("Order executed: ", symbol, " ", direction, " ", lots, " lots",
         " SL=", NormalizeDouble(sl, digits), " TP=", NormalizeDouble(tp, digits),
         " Ticket=", result.order);

   // Write ticket to a file the bridge agent can read
   string ticketFile = g_perfFolder + "last_ticket.csv";
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
//| Write account, positions and history CSVs for bridge reporter    |
//+------------------------------------------------------------------+
void WritePerformanceFiles()
{
   // ── aurora_account.csv ──────────────────────────────────────────
   int aHandle = FileOpen(g_perfFolder + "aurora_account.csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(aHandle != INVALID_HANDLE)
   {
      FileWriteString(aHandle, "balance,equity,margin,free_margin,floating_pnl,currency,leverage\n");
      FileWriteString(aHandle,
         DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," +
         DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "," +
         DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + "," +
         DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + "," +
         DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT), 2) + "," +
         AccountInfoString(ACCOUNT_CURRENCY) + "," +
         IntegerToString((int)AccountInfoInteger(ACCOUNT_LEVERAGE)) + "\n"
      );
      FileClose(aHandle);
   }

   // ── aurora_positions.csv ─────────────────────────────────────────
   int pHandle = FileOpen(g_perfFolder + "aurora_positions.csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(pHandle != INVALID_HANDLE)
   {
      FileWriteString(pHandle, "ticket,symbol,direction,lots,open_price,current_price,sl,tp,floating_pnl,swap,opened_at\n");
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         string dir = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL";
         FileWriteString(pHandle,
            IntegerToString((long)ticket) + "," +
            PositionGetString(POSITION_SYMBOL) + "," +
            dir + "," +
            DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "," +
            DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 5) + "," +
            DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), 5) + "," +
            DoubleToString(PositionGetDouble(POSITION_SL), 5) + "," +
            DoubleToString(PositionGetDouble(POSITION_TP), 5) + "," +
            DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "," +
            DoubleToString(PositionGetDouble(POSITION_SWAP), 2) + "," +
            IntegerToString((long)PositionGetInteger(POSITION_TIME) - (TimeCurrent() - TimeGMT())) + "\n"
         );
      }
      FileClose(pHandle);
   }

   // ── aurora_history.csv ───────────────────────────────────────────
   // Fetch last 90 days of closed deals
   datetime fromDate = TimeCurrent() - 90 * 86400;
   HistorySelect(fromDate, TimeCurrent());

   int hHandle = FileOpen(g_perfFolder + "aurora_history.csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(hHandle != INVALID_HANDLE)
   {
      FileWriteString(hHandle, "position_id,symbol,direction,lots,open_price,close_price,pnl,swap,commission,opened_at,closed_at\n");

      // Collect entry deals indexed by position_id
      int total = HistoryDealsTotal();
      ulong entryTickets[];
      ulong entryPosIds[];
      ArrayResize(entryTickets, 0);
      ArrayResize(entryPosIds, 0);

      for(int i = 0; i < total; i++)
      {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket == 0) continue;
         if(HistoryDealGetInteger(dTicket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         int sz = ArraySize(entryPosIds);
         ArrayResize(entryPosIds, sz + 1);
         ArrayResize(entryTickets, sz + 1);
         entryPosIds[sz]  = (ulong)HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
         entryTickets[sz] = dTicket;
      }

      // Match exit deals
      for(int i = 0; i < total; i++)
      {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket == 0) continue;
         if(HistoryDealGetInteger(dTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

         ulong posId = (ulong)HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);

         // Find matching entry
         ulong entryTicket = 0;
         for(int j = 0; j < ArraySize(entryPosIds); j++)
         {
            if(entryPosIds[j] == posId) { entryTicket = entryTickets[j]; break; }
         }
         if(entryTicket == 0) continue;

         string dir = HistoryDealGetInteger(dTicket, DEAL_TYPE) == DEAL_TYPE_BUY ? "SELL" : "BUY"; // Exit type is opposite
         // Use entry deal type for direction
         string entryDir = HistoryDealGetInteger(entryTicket, DEAL_TYPE) == DEAL_TYPE_BUY ? "BUY" : "SELL";

         FileWriteString(hHandle,
            IntegerToString((long)posId) + "," +
            HistoryDealGetString(dTicket, DEAL_SYMBOL) + "," +
            entryDir + "," +
            DoubleToString(HistoryDealGetDouble(dTicket, DEAL_VOLUME), 2) + "," +
            DoubleToString(HistoryDealGetDouble(entryTicket, DEAL_PRICE), 5) + "," +
            DoubleToString(HistoryDealGetDouble(dTicket, DEAL_PRICE), 5) + "," +
            DoubleToString(HistoryDealGetDouble(dTicket, DEAL_PROFIT), 2) + "," +
            DoubleToString(HistoryDealGetDouble(dTicket, DEAL_SWAP), 2) + "," +
            DoubleToString(HistoryDealGetDouble(dTicket, DEAL_COMMISSION), 2) + "," +
            IntegerToString((long)HistoryDealGetInteger(entryTicket, DEAL_TIME) - (TimeCurrent() - TimeGMT())) + "," +
            IntegerToString((long)HistoryDealGetInteger(dTicket, DEAL_TIME) - (TimeCurrent() - TimeGMT())) + "\n"
         );
      }
      FileClose(hHandle);
   }
}

//+------------------------------------------------------------------+
//| Tick event (not used — timer-based)                                |
//+------------------------------------------------------------------+
void OnTick() {}
//+------------------------------------------------------------------+
