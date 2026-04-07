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

extern string  SignalFile       = "signals.csv";
extern double  RiskPercent      = 1.0;
extern double  MaxRiskReward    = 0;
extern int     MaxSlippage      = 3;
extern int     MagicNumber      = 202603;
extern int     PollIntervalMs   = 2000;
extern double  DefaultSLPips    = 20;
extern int     MaxTradesPerPair = 1;

datetime lastReportTime = 0;
string   g_perfFolder   = "";   // aurora_{AccountNumber}\ — set in OnInit
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

      // Check per-pair trade limit
      if(MaxTradesPerPair > 0 && CountOpenTrades(symbol) >= MaxTradesPerPair)
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
                             "AuroraX", MagicNumber);

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

int CountOpenTrades(string symbol)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == symbol && OrderMagicNumber() == MagicNumber)
            count++;
      }
   }
   return count;
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
            IntegerToString((int)OrderOpenTime()) + "\n"
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
            IntegerToString((int)OrderOpenTime()) + "," +
            IntegerToString((int)OrderCloseTime()) + "\n"
         );
      }
      FileClose(hHandle);
   }
}

void OnTick() {}
