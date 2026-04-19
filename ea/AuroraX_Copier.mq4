//+------------------------------------------------------------------+
//| AuroraX_Copier.mq4                                               |
//| Aurora X Trade Copier EA (MT4)                                    |
//|                                                                    |
//| Reads signals.csv from MQL4/Files/ and executes trades.           |
//| The Python copier.py writes to this file when alerts arrive.      |
//+------------------------------------------------------------------+
#property copyright "Aurora X"
#property version   "1.00"
#property strict

// ─── Inputs ──────────────────────────────────────────────────────────────────

extern string  SignalFile            = "signals.csv";
extern double  RiskPercent           = 1.0;
extern double  MaxRiskReward         = 0;
extern int     MaxSlippage           = 3;
extern int     MagicNumber           = 202603;
extern int     PollIntervalMs        = 2000;
extern double  DefaultSLPips         = 20;
extern int     MaxTradesPerPair      = 1;
extern bool    EnableSpreadSLWiden   = true;  // Widen SL during NY→Asia spread window
extern int     SpreadWindowWidenPips = 30;    // Pips to widen SL during spread window

datetime lastReportTime  = 0;
string   g_perfFolder    = "";   // aurora_{AccountNumber}\ — set in OnInit
bool     g_inSpreadWindow = false;
#define REPORT_INTERVAL_SEC 60

//+------------------------------------------------------------------+
//| Init                                                               |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create per-account subfolder so multiple terminals don't share the same CSVs
   g_perfFolder = "aurora_" + IntegerToString(AccountNumber()) + "\\";
   FolderCreate(StringSubstr(g_perfFolder, 0, StringLen(g_perfFolder) - 1));

   Print("Aurora X Copier EA (MT4) started");
   Print("Performance folder: ", g_perfFolder);
   EventSetMillisecondTimer(PollIntervalMs);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Timer — poll signal file                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(EnableSpreadSLWiden) CheckSpreadWindow4();

   datetime now = TimeCurrent();
   if(now - lastReportTime >= REPORT_INTERVAL_SEC)
   {
      lastReportTime = now;
      WritePerformanceFiles();
   }

   string signalPath = g_perfFolder + SignalFile;
   if(!FileIsExist(signalPath))
      return;

   int handle = FileOpen(signalPath, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return;

   string lines[];
   int lineCount = 0;
   bool hasUnprocessed = false;

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

   if(lineCount < 2) return;

   string updatedLines[];
   ArrayResize(updatedLines, lineCount);
   updatedLines[0] = lines[0];

   for(int i = 1; i < lineCount; i++)
   {
      string fields[];
      StringSplit(lines[i], ',', fields);

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
      double slMult    = StrToDouble(fields[5]);
      double minSlPips = StrToDouble(fields[6]);
      double rr        = StrToDouble(fields[7]);
      double riskPct   = StrToDouble(fields[8]);

      // Per-signal magic (field 13) — default to EA input MagicNumber
      int signalMagic = MagicNumber;
      if(ArraySize(fields) >= 14 && StringLen(fields[13]) > 0)
      {
         int parsed = (int)StrToInteger(fields[13]);
         if(parsed > 0) signalMagic = parsed;
      }

      if(RiskPercent > 0) riskPct = RiskPercent;
      if(MaxRiskReward > 0 && rr > MaxRiskReward) rr = MaxRiskReward;

      // Find symbol
      string symbol = pair;
      if(MarketInfo(symbol, MODE_BID) == 0)
      {
         // Try with suffix
         string suffixes[] = {".raw", ".pro", ".ecn", ".std", ".m", ".i"};
         bool found = false;
         for(int s = 0; s < ArraySize(suffixes); s++)
         {
            string test = pair + suffixes[s];
            if(MarketInfo(test, MODE_BID) > 0)
            {
               symbol = test;
               found = true;
               break;
            }
         }
         if(!found)
         {
            Print("Symbol not found: ", pair);
            fields[9] = "SYMBOL_NOT_FOUND";
            updatedLines[i] = JoinFields(fields);
            continue;
         }
      }

      // Weekend-close: flatten all open positions for this alert's magic on
      // this symbol. Triggered by the server's close_before_weekend guard.
      string signalAction = ArraySize(fields) >= 12 ? fields[11] : "OPEN";
      StringTrimRight(signalAction); StringTrimLeft(signalAction);
      if(signalAction == "CLOSE")
      {
         int closed = CloseTradesWithMagic(symbol, signalMagic);
         Print("CLOSE signal: flattened ", closed, " position(s) on ", symbol, " magic=", signalMagic);
         fields[9] = "EXECUTED";
         updatedLines[i] = JoinFields(fields);
         continue;
      }

      // Check per-pair trade limit (scoped to this strategy's magic)
      if(MaxTradesPerPair > 0 && CountOpenTradesWithMagic(symbol, signalMagic) >= MaxTradesPerPair)
      {
         Print("Max trades per pair reached for ", symbol, " (", MaxTradesPerPair, ")");
         fields[9] = "MAX_PER_PAIR";
         updatedLines[i] = JoinFields(fields);
         continue;
      }

      // Calculate SL pips
      double slPips = 0;
      if(slMethod == "ATR")
      {
         slPips = ExtractPips(slValue);
         if(slPips <= 0 && slMult > 0)
         {
            double atr = iATR(symbol, 0, 14, 0);
            double pipSz = MarketInfo(symbol, MODE_POINT);
            if(Digits == 3 || Digits == 5) pipSz *= 10;
            if(pipSz > 0) slPips = (atr * slMult) / pipSz;
         }
      }
      else if(slMethod == "EMA" || slMethod == "SMA")
      {
         double level = StrToDouble(slValue);
         if(level > 0)
         {
            double bid = MarketInfo(symbol, MODE_BID);
            double pipSz = MarketInfo(symbol, MODE_POINT);
            if(Digits == 3 || Digits == 5) pipSz *= 10;

            // Check if EMA/SMA is on wrong side — SL would be above entry for BUY or below for SELL
            bool wrongSide = (direction == "BUY" && level > bid) ||
                             (direction == "SELL" && level < bid);
            if(wrongSide)
            {
               Print("EMA/SMA wrong side for ", direction, " (level=", level, " price=", bid, ") — using min SL");
               slPips = 0;  // Falls through to minSlPips or DefaultSLPips
            }
            else
            {
               slPips = MathAbs(bid - level) / pipSz;
            }
         }
      }
      else if(slMethod == "FIXED_PIPS" || slMethod == "NDAY_HIGH_LOW")
      {
         slPips = ExtractPips(slValue);
      }

      if(slPips <= 0) slPips = DefaultSLPips;
      if(minSlPips > 0 && slPips < minSlPips) slPips = minSlPips;

      double tpPips = slPips * rr;

      // Lot size
      double pipSz = MarketInfo(symbol, MODE_POINT);
      if(Digits == 3 || Digits == 5) pipSz *= 10;
      double pipVal = MarketInfo(symbol, MODE_TICKVALUE) * (pipSz / MarketInfo(symbol, MODE_TICKSIZE));
      double lots = 0;
      if(pipVal > 0) lots = (AccountBalance() * riskPct / 100.0) / (slPips * pipVal);
      lots = MathMax(MarketInfo(symbol, MODE_MINLOT),
                     MathMin(MarketInfo(symbol, MODE_MAXLOT),
                             NormalizeDouble(lots, 2)));
      double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
      lots = MathFloor(lots / lotStep) * lotStep;

      // Execute
      int cmd = direction == "BUY" ? OP_BUY : OP_SELL;
      double price = direction == "BUY" ? MarketInfo(symbol, MODE_ASK) : MarketInfo(symbol, MODE_BID);
      double sl = direction == "BUY" ? price - slPips * pipSz : price + slPips * pipSz;
      double tp = direction == "BUY" ? price + tpPips * pipSz : price - tpPips * pipSz;

      int ticket = OrderSend(symbol, cmd, lots, price, MaxSlippage,
                             NormalizeDouble(sl, Digits),
                             NormalizeDouble(tp, Digits),
                             "AuroraX", signalMagic);

      if(ticket > 0)
      {
         Print("Order OK: ", symbol, " ", direction, " ", lots, " lots  ticket=", ticket);
         fields[9] = "EXECUTED";
      }
      else
      {
         Print("Order FAILED: ", symbol, " error=", GetLastError());
         fields[9] = "FAILED";
      }
      updatedLines[i] = JoinFields(fields);
   }

   if(hasUnprocessed)
   {
      int wHandle = FileOpen(signalPath, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(wHandle != INVALID_HANDLE)
      {
         for(int i = 0; i < lineCount; i++)
            FileWriteString(wHandle, updatedLines[i] + "\n");
         FileClose(wHandle);
      }
   }
}

//+------------------------------------------------------------------+
//| Detect NY→Asia spread window and widen/restore SLs (MT4)         |
//| Window: Mon–Thu 20:55–22:00 UTC                                  |
//+------------------------------------------------------------------+
void CheckSpreadWindow4()
{
   datetime gmt  = TimeGMT();
   int dt_hour   = TimeHour(gmt);
   int dt_min    = TimeMinute(gmt);
   int day       = TimeDayOfWeek(gmt); // 0=Sun,1=Mon,...,6=Sat
   int mins      = dt_hour * 60 + dt_min;

   bool shouldWiden = (day >= 1 && day <= 4)
                   && (mins >= 20 * 60 + 55)
                   && (mins <  22 * 60);

   if(shouldWiden && !g_inSpreadWindow)
   {
      g_inSpreadWindow = true;
      Print("[SpreadWindow] NY/Asia changeover — widening all SLs by ", SpreadWindowWidenPips, " pips");
      WidenAllSLs4();
   }
   else if(!shouldWiden && g_inSpreadWindow)
   {
      g_inSpreadWindow = false;
      Print("[SpreadWindow] Window closed — restoring original SLs");
      RestoreAllSLs4();
   }
}

//+------------------------------------------------------------------+
//| Widen every open position's SL by SpreadWindowWidenPips pips     |
//+------------------------------------------------------------------+
void WidenAllSLs4()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      int    ticket    = OrderTicket();
      double currentSL = OrderStopLoss();
      string gvName    = "aurora_orig_sl_" + IntegerToString(ticket);

      // If GlobalVariable already exists, this position was widened in a
      // previous session (EA restart mid-window) — don't overwrite the
      // true original with the already-widened value.
      if(GlobalVariableCheck(gvName)) continue;

      GlobalVariableSet(gvName, currentSL);

      if(currentSL == 0) continue;

      string symbol  = OrderSymbol();
      double point   = MarketInfo(symbol, MODE_POINT);
      int    digits  = (int)MarketInfo(symbol, MODE_DIGITS);
      double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;

      double widenDist = SpreadWindowWidenPips * pipSize;
      double newSL = (OrderType() == OP_BUY)
                   ? currentSL - widenDist
                   : currentSL + widenDist;

      if(OrderModify(ticket, OrderOpenPrice(), NormalizeDouble(newSL, digits), OrderTakeProfit(), 0, clrNONE))
         Print("[SpreadWindow] Widened SL ticket=", ticket, " ", symbol,
               "  orig=", currentSL, " → ", NormalizeDouble(newSL, digits));
      else
         Print("[SpreadWindow] Widen failed ticket=", ticket, " err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Restore every open position's SL from its stored Global Variable  |
//+------------------------------------------------------------------+
void RestoreAllSLs4()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      int    ticket = OrderTicket();
      string gvName = "aurora_orig_sl_" + IntegerToString(ticket);
      if(!GlobalVariableCheck(gvName)) continue;

      double origSL = GlobalVariableGet(gvName);
      GlobalVariableDel(gvName);

      if(origSL == 0) continue;

      string symbol = OrderSymbol();
      int    digits = (int)MarketInfo(symbol, MODE_DIGITS);

      if(OrderModify(ticket, OrderOpenPrice(), NormalizeDouble(origSL, digits), OrderTakeProfit(), 0, clrNONE))
         Print("[SpreadWindow] Restored SL ticket=", ticket, " ", symbol,
               " → ", NormalizeDouble(origSL, digits));
      else
         Print("[SpreadWindow] Restore failed ticket=", ticket, " err=", GetLastError());
   }
}

int CountOpenTradesWithMagic(string symbol, int magic)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == symbol && OrderMagicNumber() == magic)
            count++;
      }
   }
   return count;
}

int CloseTradesWithMagic(string symbol, int magic)
{
   int closed = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != symbol) continue;
      if(OrderMagicNumber() != magic) continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL) continue;
      double price = (type == OP_BUY) ? MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
      if(OrderClose(OrderTicket(), OrderLots(), price, MaxSlippage))
         closed++;
      else
         Print("CLOSE failed ticket=", OrderTicket(), " err=", GetLastError());
   }
   return closed;
}

double ExtractPips(string value)
{
   StringReplace(value, "pips", "");
   StringReplace(value, "pip", "");
   StringTrimRight(value);
   StringTrimLeft(value);
   return StrToDouble(value);
}

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

void WritePerformanceFiles()
{
   // ── aurora_account.csv ──────────────────────────────────────────
   int aHandle = FileOpen(g_perfFolder + "aurora_account.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(aHandle != INVALID_HANDLE)
   {
      FileWriteString(aHandle, "balance,equity,margin,free_margin,floating_pnl,currency,leverage\n");
      FileWriteString(aHandle,
         DoubleToStr(AccountBalance(), 2) + "," +
         DoubleToStr(AccountEquity(), 2) + "," +
         DoubleToStr(AccountMargin(), 2) + "," +
         DoubleToStr(AccountFreeMargin(), 2) + "," +
         DoubleToStr(AccountProfit(), 2) + "," +
         AccountCurrency() + "," +
         IntegerToString(AccountLeverage()) + "\n"
      );
      FileClose(aHandle);
   }

   // ── aurora_positions.csv ─────────────────────────────────────────
   int pHandle = FileOpen(g_perfFolder + "aurora_positions.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(pHandle != INVALID_HANDLE)
   {
      FileWriteString(pHandle, "ticket,symbol,direction,lots,open_price,current_price,sl,tp,floating_pnl,swap,opened_at\n");
      for(int i = 0; i < OrdersTotal(); i++)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         string dir = OrderType() == OP_BUY ? "BUY" : "SELL";
         double curPrice = OrderType() == OP_BUY
            ? MarketInfo(OrderSymbol(), MODE_BID)
            : MarketInfo(OrderSymbol(), MODE_ASK);
         FileWriteString(pHandle,
            IntegerToString(OrderTicket()) + "," +
            OrderSymbol() + "," +
            dir + "," +
            DoubleToStr(OrderLots(), 2) + "," +
            DoubleToStr(OrderOpenPrice(), 5) + "," +
            DoubleToStr(curPrice, 5) + "," +
            DoubleToStr(OrderStopLoss(), 5) + "," +
            DoubleToStr(OrderTakeProfit(), 5) + "," +
            DoubleToStr(OrderProfit(), 2) + "," +
            DoubleToStr(OrderSwap(), 2) + "," +
            IntegerToString((int)OrderOpenTime() - (TimeCurrent() - TimeGMT())) + "\n"
         );
      }
      FileClose(pHandle);
   }

   // ── aurora_history.csv ───────────────────────────────────────────
   int hHandle = FileOpen(g_perfFolder + "aurora_history.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(hHandle != INVALID_HANDLE)
   {
      FileWriteString(hHandle, "position_id,symbol,direction,lots,open_price,close_price,pnl,swap,commission,opened_at,closed_at\n");
      datetime fromDate = TimeCurrent() - 90 * 86400;
      for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         if(OrderCloseTime() < fromDate) continue;
         string dir = OrderType() == OP_BUY ? "BUY" : "SELL";
         FileWriteString(hHandle,
            IntegerToString(OrderTicket()) + "," +
            OrderSymbol() + "," +
            dir + "," +
            DoubleToStr(OrderLots(), 2) + "," +
            DoubleToStr(OrderOpenPrice(), 5) + "," +
            DoubleToStr(OrderClosePrice(), 5) + "," +
            DoubleToStr(OrderProfit(), 2) + "," +
            DoubleToStr(OrderSwap(), 2) + "," +
            DoubleToStr(OrderCommission(), 2) + "," +
            IntegerToString((int)OrderOpenTime() - (TimeCurrent() - TimeGMT())) + "," +
            IntegerToString((int)OrderCloseTime() - (TimeCurrent() - TimeGMT())) + "\n"
         );
      }
      FileClose(hHandle);
   }
}

void OnTick() {}
