//+------------------------------------------------------------------+
//|                                              XAUUSD_MTF_EA.mq4   |
//|   Gold (XAUUSD) Expert Advisor for MetaTrader 4 - long & short   |
//|   M15 = trend direction  |  M5 = entry timing                    |
//|   Lot size calculated from a fixed % risk per trade              |
//+------------------------------------------------------------------+
#property copyright "AUT"
#property version   "1.10"
#property strict
#property description "Gold (XAUUSD) multi-timeframe EA: M15 trend filter + M5 entries. Trades long and short."
#property description "Position size is calculated so that a stop-loss hit loses RiskPercent of the account."
#property description "Trading is risky. Test on a demo account first."

enum ENUM_TRADE_DIR
{
   DIR_BOTH  = 0,   // Long and short
   DIR_LONG  = 1,   // Long (buy) only
   DIR_SHORT = 2    // Short (sell) only
};

//============================ INPUTS ===============================
input string   InpDirHeader         = "===== Direction =====";  // ----------
input ENUM_TRADE_DIR TradeDirection = DIR_BOTH;  // Trade direction: buys in uptrends, sells in downtrends

input string   InpRiskHeader        = "===== Risk management =====";   // ----------
input double   RiskPercent          = 5.0;    // Risk per trade (% of account)
input bool     RiskOnEquity         = false;  // Use equity instead of balance for risk
input double   CommissionPerLot     = 0.0;    // Round-turn commission per 1.00 lot (account currency)
input double   MaxLotSize           = 0.0;    // Hard cap on lot size (0 = broker maximum)
input int      MaxOpenTrades        = 1;      // Max trades open at once by this EA
input double   MaxDailyLossPercent  = 10.0;   // Pause new trades for the day after this loss % (0 = off)
input bool     AllowMinLotOverRisk  = false;  // Small accounts: trade the minimum lot even if it risks more than RiskPercent
input double   MaxRiskAtMinLot      = 10.0;   // ...but never if the minimum lot would risk more than this %

input string   InpTrendHeader       = "===== M15 trend filter =====";  // ----------
input int      TrendFastEMA         = 50;     // M15 fast EMA
input int      TrendSlowEMA         = 200;    // M15 slow EMA
input int      ADXPeriod            = 14;     // M15 ADX period
input double   MinADX               = 20.0;   // Minimum M15 ADX (trend strength, 0 = off)

input string   InpEntryHeader       = "===== M5 entry signal =====";   // ----------
input int      EntryFastEMA         = 9;      // M5 fast EMA
input int      EntrySlowEMA         = 21;     // M5 slow EMA
input int      RSIPeriod            = 14;     // M5 RSI period
input double   RSIBuyMin            = 50.0;   // Buy only if RSI >= this
input double   RSIBuyMax            = 70.0;   // ...and RSI <= this (avoid overbought)
input double   RSISellMin           = 30.0;   // Sell only if RSI >= this (avoid oversold)
input double   RSISellMax           = 50.0;   // ...and RSI <= this

input string   InpExitHeader        = "===== Stop loss / take profit =====";  // ----------
input int      ATRPeriod            = 14;     // ATR period (on M15)
input double   StopLossATR          = 1.5;    // Stop loss = ATR(M15) x this
input double   MinStopPrice         = 3.0;    // Minimum stop loss in $ of gold price (avoids tiny stops in quiet hours)
input double   RewardRisk           = 2.0;    // Take profit = stop distance x this (R:R)
input double   BreakEvenAtR         = 1.0;    // Move SL to break-even at this many R profit (0 = off)
input double   BreakEvenLockR       = 0.1;    // ...locking in this many R
input double   TrailStartR          = 1.5;    // Start trailing stop at this many R profit (0 = off)
input double   TrailATR             = 1.0;    // Trailing distance = ATR(M15) x this
input bool     CloseOnOpposite      = false;  // Close a trade on an opposite M5 signal

input string   InpFilterHeader      = "===== Filters =====";  // ----------
input double   MaxSpreadPrice       = 0.60;   // Max spread in $ of gold price (0.60 = 60 cents)
input int      StartHour            = 7;      // Trading start hour (broker server time)
input int      EndHour              = 20;     // Trading end hour (broker server time)
input bool     AvoidFridayLate      = true;   // No new trades late on Friday
input int      FridayEndHour        = 18;     // Friday cut-off hour (server time)

input string   InpOrderHeader       = "===== Orders =====";  // ----------
input int      MagicNumber          = 515151; // Magic number (unique per chart)
input int      SlippagePoints       = 30;     // Max slippage (points)
input bool     ECNMode              = false;  // ECN broker: send order first, then add SL/TP
input string   TradeComment         = "XAUUSD_MTF"; // Order comment
input bool     ShowPanel            = true;   // Show live info panel on chart

input string   InpAlertHeader       = "===== Alerts =====";  // ----------
input bool     PushNotifications    = true;   // Send alerts to the MT4 phone app (needs MetaQuotes ID)
input bool     PopupAlerts          = false;  // Also show a pop-up alert window on the PC

//============================ GLOBALS ==============================
datetime g_lastM5Bar  = 0;
string   g_gvDayKey   = "";
string   g_gvDayBal   = "";
string   g_status     = "Starting...";
string   g_lastEvent  = "-";
int      g_known[];              // tickets open on the previous tick (to detect closed trades)
datetime g_pauseNotified = 0;    // day we last sent the "daily limit hit" alert
int      g_srvOffset  = 0;       // server time - local time, keeps the countdown ticking between ticks

#define PFX "XMTF_"

// All distances on gold are in price units: 1.00 = a $1 move in the gold price
bool DirAllowed(int dir)
{
   return TradeDirection == DIR_BOTH || (dir > 0 && TradeDirection == DIR_LONG) || (dir < 0 && TradeDirection == DIR_SHORT);
}
string DirText()
{
   return TradeDirection == DIR_BOTH ? "LONG + SHORT" : (TradeDirection == DIR_LONG ? "LONG only" : "SHORT only");
}
string Px(double v) { return DoubleToString(v, Digits); }

// Log an event, show it on the panel and (optionally) push it to the phone app
void Notify(string msg)
{
   Print("XAUUSD_MTF: ", msg);
   g_lastEvent = TimeToString(TimeCurrent(), TIME_MINUTES) + "  " + msg;
   if(IsTesting()) return;
   if(PushNotifications) SendNotification("XAUUSD_MTF: " + msg);
   if(PopupAlerts) Alert("XAUUSD_MTF: " + msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(RiskPercent <= 0 || RiskPercent > 50)
   { Alert("XAUUSD_MTF: RiskPercent must be between 0 and 50."); return INIT_PARAMETERS_INCORRECT; }
   if(StopLossATR <= 0 || RewardRisk <= 0 || ATRPeriod <= 0)
   { Alert("XAUUSD_MTF: StopLossATR, RewardRisk and ATRPeriod must be > 0."); return INIT_PARAMETERS_INCORRECT; }
   if(EntryFastEMA >= EntrySlowEMA || TrendFastEMA >= TrendSlowEMA)
   { Alert("XAUUSD_MTF: fast EMA periods must be smaller than slow EMA periods."); return INIT_PARAMETERS_INCORRECT; }
   if(MaxOpenTrades < 1)
   { Alert("XAUUSD_MTF: MaxOpenTrades must be at least 1."); return INIT_PARAMETERS_INCORRECT; }

   string sym = Symbol();
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("XAUUSD_MTF WARNING: this EA is designed for gold (XAUUSD), but it is attached to ", Symbol());

   // Separate keys per account and for the Strategy Tester, so a backtest can't
   // overwrite the live account's daily starting balance (MT4 shares global variables).
   string gvBase = "XAUUSD_MTF_" + (IsTesting() ? "TEST_" : "") + IntegerToString(AccountNumber()) + "_" +
                   Symbol() + "_" + IntegerToString(MagicNumber);
   g_gvDayKey = gvBase + "_day";
   g_gvDayBal = gvBase + "_bal";
   UpdateDailyAnchor();

   SnapshotOpenTickets(g_known);
   g_srvOffset = (int)(TimeCurrent() - TimeLocal());
   EventSetTimer(1);              // refresh the panel every second, even without new ticks
   Notify(StringFormat("Bot started on %s (%s), risk %.1f%% per trade, balance %.2f %s",
                       Symbol(), DirText(), RiskPercent, AccountBalance(), AccountCurrency()));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   Comment("");
}

void OnTimer()
{
   if(ShowPanel) { RefreshRates(); DrawPanel(); }
}

//+------------------------------------------------------------------+
void OnTick()
{
   g_srvOffset = (int)(TimeCurrent() - TimeLocal());
   UpdateDailyAnchor();
   CheckClosedTrades();
   ManageOpenTrades();

   datetime m5Bar = iTime(NULL, PERIOD_M5, 0);
   if(m5Bar > 0 && m5Bar != g_lastM5Bar)
   {
      bool firstRun = (g_lastM5Bar == 0);
      g_lastM5Bar = m5Bar;
      if(!firstRun)            // don't act on an old signal right after attaching
         ProcessNewBar();
   }

   if(ShowPanel) DrawPanel();
}

//========================== SIGNALS ================================

// +1 = uptrend, -1 = downtrend, 0 = no clear trend (uses last closed M15 bar)
int TrendDirection()
{
   double fast  = iMA(NULL, PERIOD_M15, TrendFastEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double slow  = iMA(NULL, PERIOD_M15, TrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double close = iClose(NULL, PERIOD_M15, 1);

   if(MinADX > 0)
   {
      double adx = iADX(NULL, PERIOD_M15, ADXPeriod, PRICE_CLOSE, MODE_MAIN, 1);
      if(adx < MinADX) return 0;
   }
   if(fast > slow && close > slow) return  1;
   if(fast < slow && close < slow) return -1;
   return 0;
}

// +1 = buy signal, -1 = sell signal, 0 = none (EMA cross on last closed M5 bar + RSI filter)
int EntrySignal()
{
   double f1 = iMA(NULL, PERIOD_M5, EntryFastEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double s1 = iMA(NULL, PERIOD_M5, EntrySlowEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double f2 = iMA(NULL, PERIOD_M5, EntryFastEMA, 0, MODE_EMA, PRICE_CLOSE, 2);
   double s2 = iMA(NULL, PERIOD_M5, EntrySlowEMA, 0, MODE_EMA, PRICE_CLOSE, 2);
   double rsi = iRSI(NULL, PERIOD_M5, RSIPeriod, PRICE_CLOSE, 1);

   if(f2 <= s2 && f1 > s1 && rsi >= RSIBuyMin  && rsi <= RSIBuyMax)  return  1;
   if(f2 >= s2 && f1 < s1 && rsi >= RSISellMin && rsi <= RSISellMax) return -1;
   return 0;
}

bool HistoryReady()
{
   return iBars(NULL, PERIOD_M15) > TrendSlowEMA + 10 &&
          iBars(NULL, PERIOD_M5)  > EntrySlowEMA + 10;
}

//========================== MAIN LOGIC =============================

void ProcessNewBar()
{
   if(!HistoryReady()) { g_status = "Waiting for M5/M15 history to load"; return; }

   int trend  = TrendDirection();
   int signal = EntrySignal();

   if(CloseOnOpposite && signal != 0)
      CloseTrades(signal > 0 ? OP_SELL : OP_BUY);

   if(signal == 0)      { g_status = "No M5 entry signal"; return; }
   if(signal != trend)  { g_status = "M5 signal against M15 trend - skipped"; return; }
   if(!DirAllowed(signal))
   { g_status = signal > 0 ? "BUY signal - longs disabled (TradeDirection)" : "SELL signal - shorts disabled (TradeDirection)"; return; }

   string reason = "";
   if(!CanOpenNewTrade(reason)) { g_status = reason; Print("XAUUSD_MTF: signal skipped - ", reason); return; }

   if(OpenTrade(signal)) { g_status = (signal > 0 ? "BUY opened" : "SELL opened"); SnapshotOpenTickets(g_known); }
}

bool CanOpenNewTrade(string &reason)
{
   if(!IsTradeAllowed())                  { reason = "Trading not allowed (enable AutoTrading)"; return false; }
   if(CountOpenTrades() >= MaxOpenTrades) { reason = "Max open trades reached"; return false; }
   if(DailyLossHit())
   {
      reason = "Daily loss limit hit - paused until tomorrow";
      datetime today = iTime(NULL, PERIOD_D1, 0);
      if(g_pauseNotified != today) { g_pauseNotified = today; Notify("Daily loss limit hit - no new trades until tomorrow"); }
      return false;
   }
   if(Ask - Bid > MaxSpreadPrice)        { reason = StringFormat("Spread too wide ($%.2f)", Ask - Bid); return false; }
   if(!InSession())                       { reason = "Outside trading hours"; return false; }
   return true;
}

bool InSession()
{
   datetime now = TimeCurrent();
   int h = TimeHour(now);
   if(AvoidFridayLate && TimeDayOfWeek(now) == 5 && h >= FridayEndHour) return false;
   if(StartHour == EndHour) return true;                       // 24h
   if(StartHour < EndHour)  return (h >= StartHour && h < EndHour);
   return (h >= StartHour || h < EndHour);                     // window crosses midnight
}

//========================== RISK ===================================

// Lot size so that hitting a stop of 'slDist' (price units) loses RiskPercent of the account
double CalcLots(double slDist, bool quiet = false)
{
   double base       = RiskOnEquity ? AccountEquity() : AccountBalance();
   double riskMoney  = base * RiskPercent / 100.0;
   double tickValue  = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize   = MarketInfo(Symbol(), MODE_TICKSIZE);
   double lotStep    = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot     = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot     = MarketInfo(Symbol(), MODE_MAXLOT);

   if(tickValue <= 0 || tickSize <= 0 || lotStep <= 0 || slDist <= 0)
   { if(!quiet) Print("XAUUSD_MTF: invalid symbol info, cannot size position."); return 0; }

   double lossPerLot = (slDist / tickSize) * tickValue + CommissionPerLot;
   double lots = riskMoney / lossPerLot;

   lots = MathFloor(lots / lotStep + 1e-9) * lotStep;   // round DOWN so risk is never exceeded
   if(MaxLotSize > 0) lots = MathMin(lots, MaxLotSize);
   lots = MathMin(lots, maxLot);

   if(lots < minLot && AllowMinLotOverRisk && minLot * lossPerLot <= base * MaxRiskAtMinLot / 100.0)
   {
      if(!quiet) PrintFormat("XAUUSD_MTF: using minimum lot %.2f - risks %.2f (%.2f%% of account) instead of %.2f%%.",
                             minLot, minLot * lossPerLot, minLot * lossPerLot / base * 100.0, RiskPercent);
      lots = minLot;
   }

   if(lots < minLot)
   {
      if(!quiet) PrintFormat("XAUUSD_MTF: account too small for this stop. Need %.2f lots but minimum is %.2f "
                  "(would risk %.2f instead of %.2f). Trade skipped. See AllowMinLotOverRisk.",
                  lots, minLot, minLot * lossPerLot, riskMoney);
      return 0;
   }
   int digits = (int)MathMax(0, MathCeil(-MathLog10(lotStep) - 1e-9));
   return NormalizeDouble(lots, digits);
}

void UpdateDailyAnchor()
{
   datetime today = iTime(NULL, PERIOD_D1, 0);
   if(today == 0) return;
   if(!GlobalVariableCheck(g_gvDayKey) || (datetime)GlobalVariableGet(g_gvDayKey) != today)
   {
      GlobalVariableSet(g_gvDayKey, (double)today);
      GlobalVariableSet(g_gvDayBal, AccountBalance());
   }
}

bool DailyLossHit()
{
   if(MaxDailyLossPercent <= 0) return false;
   double startBal = GlobalVariableGet(g_gvDayBal);
   if(startBal <= 0) return false;
   // Safety: a stored balance far above today's balance can't be a real intraday loss
   // (e.g. stale value or a withdrawal) - re-anchor instead of blocking trading.
   if(AccountBalance() < startBal * 0.5)
   {
      GlobalVariableSet(g_gvDayBal, AccountBalance());
      return false;
   }
   return AccountEquity() <= startBal * (1.0 - MaxDailyLossPercent / 100.0);
}

//========================== ORDERS =================================

int CountOpenTrades()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() <= OP_SELL) n++;
   }
   return n;
}

bool IsRetryable(int err)
{
   return err == ERR_REQUOTE || err == ERR_PRICE_CHANGED || err == ERR_OFF_QUOTES ||
          err == ERR_SERVER_BUSY || err == ERR_TRADE_CONTEXT_BUSY || err == ERR_BROKER_BUSY;
}

bool OpenTrade(int dir)
{
   double atr = iATR(NULL, PERIOD_M15, ATRPeriod, 1);
   if(atr <= 0) { Print("XAUUSD_MTF: ATR not available."); return false; }

   double slDist  = MathMax(atr * StopLossATR, MinStopPrice);
   double minDist = (MarketInfo(Symbol(), MODE_STOPLEVEL) + 1) * Point + (Ask - Bid);
   if(slDist < minDist) slDist = minDist;
   double tpDist  = slDist * RewardRisk;

   double lots = CalcLots(slDist);
   if(lots <= 0) return false;

   int type = (dir > 0) ? OP_BUY : OP_SELL;

   ResetLastError();
   if(AccountFreeMarginCheck(Symbol(), type, lots) <= 0 || GetLastError() == ERR_NOT_ENOUGH_MONEY)
   { PrintFormat("XAUUSD_MTF: not enough free margin for %.2f lots.", lots); return false; }

   for(int attempt = 1; attempt <= 3; attempt++)
   {
      RefreshRates();
      double price = (type == OP_BUY) ? Ask : Bid;
      double sl    = (type == OP_BUY) ? price - slDist : price + slDist;
      double tp    = (type == OP_BUY) ? price + tpDist : price - tpDist;
      price = NormalizeDouble(price, Digits);
      sl    = NormalizeDouble(sl, Digits);
      tp    = NormalizeDouble(tp, Digits);
      color clr = (type == OP_BUY) ? clrDodgerBlue : clrTomato;

      int ticket = ECNMode
         ? OrderSend(Symbol(), type, lots, price, SlippagePoints, 0, 0, TradeComment, MagicNumber, 0, clr)
         : OrderSend(Symbol(), type, lots, price, SlippagePoints, sl, tp, TradeComment, MagicNumber, 0, clr);

      if(ticket > 0)
      {
         if(ECNMode) AttachStops(ticket, slDist, tpDist);
         Notify(StringFormat("%s %.2f lots opened @ %s  SL %s  TP %s  (stop $%.2f, risk %.1f%%)",
                type == OP_BUY ? "LONG/BUY" : "SHORT/SELL", lots, Px(price), Px(sl), Px(tp), slDist, RiskPercent));
         return true;
      }
      int err = GetLastError();
      PrintFormat("XAUUSD_MTF: OrderSend failed (attempt %d): error %d", attempt, err);
      if(!IsRetryable(err)) { Notify(StringFormat("Order FAILED, error %d (see Experts tab)", err)); break; }
      Sleep(500);
   }
   return false;
}

void AttachStops(int ticket, double slDist, double tpDist)
{
   for(int attempt = 1; attempt <= 5; attempt++)
   {
      if(!OrderSelect(ticket, SELECT_BY_TICKET)) break;
      double open = OrderOpenPrice();
      double sl = (OrderType() == OP_BUY) ? open - slDist : open + slDist;
      double tp = (OrderType() == OP_BUY) ? open + tpDist : open - tpDist;
      if(OrderModify(ticket, open, NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits), 0, clrNONE))
         return;
      Sleep(500);
      RefreshRates();
   }
   Alert("XAUUSD_MTF WARNING: could not set SL/TP on ticket #", ticket, " - set them manually!");
   Notify(StringFormat("WARNING: no SL/TP on ticket #%d - set them manually!", ticket));
}

void CloseTrades(int typeToClose)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() != typeToClose) continue;
      RefreshRates();
      double price = (typeToClose == OP_BUY) ? Bid : Ask;
      if(!OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(price, Digits), SlippagePoints, clrYellow))
         PrintFormat("XAUUSD_MTF: OrderClose #%d failed: error %d", OrderTicket(), GetLastError());
   }
}

// Break-even and trailing stop. 1R is recovered from the fixed TP: R = |TP - open| / RewardRisk
void ManageOpenTrades()
{
   if(BreakEvenAtR <= 0 && TrailStartR <= 0) return;

   double atr       = iATR(NULL, PERIOD_M15, ATRPeriod, 1);
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      int type = OrderType();
      if(type > OP_SELL) continue;

      double open = OrderOpenPrice();
      double sl   = OrderStopLoss();
      double tp   = OrderTakeProfit();
      if(tp <= 0) continue;
      double R = MathAbs(tp - open) / RewardRisk;
      if(R <= 0) continue;
      double minStep = MathMax(Point * 10, 0.05 * R);   // avoid spamming the server with tiny modifications

      RefreshRates();
      double newSL = sl;

      if(type == OP_BUY)
      {
         double profit = Bid - open;
         if(BreakEvenAtR > 0 && profit >= BreakEvenAtR * R)
         {
            double be = open + BreakEvenLockR * R;
            if(newSL < be) newSL = be;
         }
         if(TrailStartR > 0 && atr > 0 && profit >= TrailStartR * R)
         {
            double tr = Bid - TrailATR * atr;
            if(tr > newSL) newSL = tr;
         }
         newSL = NormalizeDouble(newSL, Digits);
         if(newSL >= sl + minStep && Bid - newSL > stopLevel)
         {
            bool toBE = (sl < open && newSL >= open);
            if(ModifySL(OrderTicket(), open, newSL, tp) && toBE)
               Notify(StringFormat("BUY #%d stop moved to break-even (%s)", OrderTicket(), Px(newSL)));
         }
      }
      else
      {
         double profit = open - Ask;
         if(BreakEvenAtR > 0 && profit >= BreakEvenAtR * R)
         {
            double be = open - BreakEvenLockR * R;
            if(newSL == 0 || newSL > be) newSL = be;
         }
         if(TrailStartR > 0 && atr > 0 && profit >= TrailStartR * R)
         {
            double tr = Ask + TrailATR * atr;
            if(newSL == 0 || tr < newSL) newSL = tr;
         }
         newSL = NormalizeDouble(newSL, Digits);
         if(newSL > 0 && (sl == 0 || newSL <= sl - minStep) && newSL - Ask > stopLevel)
         {
            bool toBE = ((sl == 0 || sl > open) && newSL <= open);
            if(ModifySL(OrderTicket(), open, newSL, tp) && toBE)
               Notify(StringFormat("SELL #%d stop moved to break-even (%s)", OrderTicket(), Px(newSL)));
         }
      }
   }
}

bool ModifySL(int ticket, double open, double newSL, double tp)
{
   if(OrderModify(ticket, open, newSL, tp, 0, clrNONE)) return true;
   PrintFormat("XAUUSD_MTF: OrderModify #%d failed: error %d", ticket, GetLastError());
   return false;
}

//========================== TRADE TRACKING =========================

void SnapshotOpenTickets(int &arr[])
{
   ArrayResize(arr, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() > OP_SELL) continue;
      int n = ArraySize(arr);
      ArrayResize(arr, n + 1);
      arr[n] = OrderTicket();
   }
}

// Detect trades that closed since the last tick (SL, TP, manual) and report the result
void CheckClosedTrades()
{
   int cur[];
   SnapshotOpenTickets(cur);
   for(int k = 0; k < ArraySize(g_known); k++)
   {
      bool stillOpen = false;
      for(int j = 0; j < ArraySize(cur); j++) if(cur[j] == g_known[k]) { stillOpen = true; break; }
      if(stillOpen) continue;
      if(!OrderSelect(g_known[k], SELECT_BY_TICKET) || OrderCloseTime() == 0) continue;
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      Notify(StringFormat("%s #%d CLOSED %s%.2f %s @ %s - balance now %.2f",
             OrderType() == OP_BUY ? "BUY" : "SELL", OrderTicket(), pl >= 0 ? "+" : "", pl,
             AccountCurrency(), Px(OrderClosePrice()), AccountBalance()));
   }
   ArrayResize(g_known, ArraySize(cur));
   for(int i = 0; i < ArraySize(cur); i++) g_known[i] = cur[i];
}

//========================== PANEL ==================================
// Live checklist: a trade opens when every line with a tick/cross is green
// (the M5 cross line turns green only on the candle where a fresh cross happens).

#define P_X     10      // panel position (pixels from the top-left corner)
#define P_Y     95      // below MT4's one-click trading box
#define P_W     520
#define P_ROW   17

void PLabel(string name, int x, int y, string text, color clr, int size = 9, string font = "Consolas")
{
   string n = PFX + name;
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, n, OBJPROP_TEXT, text == "" ? " " : text);
   ObjectSetString(0, n, OBJPROP_FONT, font);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
}

void PBox(int h)
{
   string n = PFX + "bg";
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_BGCOLOR, C'18,22,30');
      ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, n, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, P_X);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE, P_Y);
      ObjectSetInteger(0, n, OBJPROP_XSIZE, P_W);
   }
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
}

// state: 1 = OK (green tick), 0 = blocking (red cross), -1 = info (grey dot)
void PRow(int row, int state, string title, string value)
{
   int y = P_Y + 30 + row * P_ROW;
   string icon = state == 1 ? CharToStr(252) : (state == 0 ? CharToStr(251) : CharToStr(159));
   color  ic   = state == 1 ? clrLimeGreen : (state == 0 ? clrTomato : clrGray);
   PLabel("i" + IntegerToString(row), P_X + 8,  y, icon, ic, 10, "Wingdings");
   PLabel("t" + IntegerToString(row), P_X + 28, y, title, clrSilver);
   if(StringLen(value) > 52) value = StringSubstr(value, 0, 50) + "..";
   PLabel("v" + IntegerToString(row), P_X + 150, y, value, state == 0 ? clrTomato : clrWhite);
}

void DrawPanel()
{
   bool ready = HistoryReady();
   int  trend = ready ? TrendDirection() : 0;
   int  row   = 0;

   // --- header
   bool canTrade = IsTradeAllowed() && IsExpertEnabled();
   PBox(30 + 16 * P_ROW + 8);
   PLabel("hdr", P_X + 8, P_Y + 6, "XAUUSD_MTF EA", clrWhite, 11, "Arial Bold");
   PLabel("run", P_X + 150, P_Y + 8,
          canTrade ? "RUNNING - live " + (IsDemo() ? "(DEMO)" : "(REAL MONEY)") : "AUTOTRADING OFF",
          canTrade ? clrLimeGreen : clrTomato, 9, "Arial Bold");

   // --- 1. M15 trend
   double adx = iADX(NULL, PERIOD_M15, ADXPeriod, PRICE_CLOSE, MODE_MAIN, 1);
   string tv;
   if(!ready)          tv = "loading history...";
   else if(trend > 0)  tv = DirAllowed(1)  ? StringFormat("UP - looking to go LONG (ADX %.0f)", adx)
                                           : StringFormat("UP - but longs disabled (ADX %.0f)", adx);
   else if(trend < 0)  tv = DirAllowed(-1) ? StringFormat("DOWN - looking to go SHORT (ADX %.0f)", adx)
                                           : StringFormat("DOWN - but shorts disabled (ADX %.0f)", adx);
   else if(MinADX > 0 && adx < MinADX) tv = StringFormat("NONE - too weak (ADX %.0f < %.0f)", adx, MinADX);
   else                tv = "NONE - EMAs mixed";
   PRow(row++, (trend != 0 && DirAllowed(trend)) ? 1 : 0, "M15 trend", tv);

   // --- 2. M5 EMA cross (on the last closed candle)
   double f1 = iMA(NULL, PERIOD_M5, EntryFastEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double s1 = iMA(NULL, PERIOD_M5, EntrySlowEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double f2 = iMA(NULL, PERIOD_M5, EntryFastEMA, 0, MODE_EMA, PRICE_CLOSE, 2);
   double s2 = iMA(NULL, PERIOD_M5, EntrySlowEMA, 0, MODE_EMA, PRICE_CLOSE, 2);
   bool crossUp = (f2 <= s2 && f1 > s1), crossDn = (f2 >= s2 && f1 < s1);
   double gap = f1 - s1;
   string cv; bool crossOK = false;
   if((trend > 0 && crossUp) || (trend < 0 && crossDn)) { cv = "FRESH CROSS in trend direction!"; crossOK = true; }
   else if(trend > 0) cv = gap > 0 ? StringFormat("EMA%d above by $%.2f - wait for new cross UP", EntryFastEMA, gap)
                                   : StringFormat("EMA%d below by $%.2f - wait for cross UP", EntryFastEMA, -gap);
   else if(trend < 0) cv = gap < 0 ? StringFormat("EMA%d below by $%.2f - wait for new cross DOWN", EntryFastEMA, -gap)
                                   : StringFormat("EMA%d above by $%.2f - wait for cross DOWN", EntryFastEMA, gap);
   else cv = StringFormat("EMA%d %s EMA%d by $%.2f", EntryFastEMA, gap >= 0 ? "above" : "below", EntrySlowEMA, MathAbs(gap));
   PRow(row++, crossOK ? 1 : 0, StringFormat("M5 EMA %d/%d", EntryFastEMA, EntrySlowEMA), cv);

   // --- 3. RSI
   double rsi = iRSI(NULL, PERIOD_M5, RSIPeriod, PRICE_CLOSE, 1);
   bool rsiOK = trend > 0 ? (rsi >= RSIBuyMin && rsi <= RSIBuyMax)
              : trend < 0 ? (rsi >= RSISellMin && rsi <= RSISellMax) : false;
   string rv = trend > 0 ? StringFormat("%.1f  (buy needs %.0f-%.0f)", rsi, RSIBuyMin, RSIBuyMax)
             : trend < 0 ? StringFormat("%.1f  (sell needs %.0f-%.0f)", rsi, RSISellMin, RSISellMax)
             : StringFormat("%.1f", rsi);
   PRow(row++, rsiOK ? 1 : 0, "M5 RSI", rv);

   // --- 4-7. filters
   double spread = Ask - Bid;
   PRow(row++, spread <= MaxSpreadPrice ? 1 : 0, "Spread", StringFormat("$%.2f  (max $%.2f)", spread, MaxSpreadPrice));

   datetime srv = TimeLocal() + g_srvOffset;
   PRow(row++, InSession() ? 1 : 0, "Trading hours",
        StringFormat("%s server  (%02d:00-%02d:00)", TimeToString(srv, TIME_MINUTES), StartHour, EndHour));

   bool dl = DailyLossHit();
   PRow(row++, dl ? 0 : 1, "Daily loss limit", dl ? "HIT - paused until tomorrow" : StringFormat("OK  (limit %.0f%%)", MaxDailyLossPercent));

   int open = CountOpenTrades();
   PRow(row++, open < MaxOpenTrades ? 1 : 0, "Trade slots", StringFormat("%d / %d open", open, MaxOpenTrades));

   // --- open trade details
   string ot = "none";
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() > OP_SELL) continue;
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      ot = StringFormat("%s %.2f @ %s  P/L %s%.2f", OrderType() == OP_BUY ? "LONG" : "SHORT",
                        OrderLots(), Px(OrderOpenPrice()), pl >= 0 ? "+" : "", pl);
      break;
   }
   PRow(row++, -1, "Open trade", ot);
   PRow(row++, -1, "Directions", DirText() + "  (long in uptrend, short in downtrend)");

   // --- risk preview
   double atr    = iATR(NULL, PERIOD_M15, ATRPeriod, 1);
   double slDist = MathMax(atr * StopLossATR, MinStopPrice);
   double base   = RiskOnEquity ? AccountEquity() : AccountBalance();
   double lots   = CalcLots(slDist, true);
   PRow(row++, -1, "Next trade", lots > 0
        ? StringFormat("%.2f lots, SL $%.2f, TP $%.2f", lots, slDist, slDist * RewardRisk)
        : "account too small for minimum lot");
   PRow(row++, -1, "Risk / trade", StringFormat("%.1f%% = %.2f %s  (balance %.2f)",
        RiskPercent, base * RiskPercent / 100.0, AccountCurrency(), AccountBalance()));

   // --- timing + status
   datetime m5 = iTime(NULL, PERIOD_M5, 0);
   int left = (int)(m5 + 300 - srv);
   if(left < 0) left = 0;
   PRow(row++, -1, "Next M5 check", StringFormat("in %d:%02d", left / 60, left % 60));
   PRow(row++, -1, "Status", g_status);
   PRow(row++, -1, "Last event", g_lastEvent);
   PLabel("foot", P_X + 8, P_Y + 30 + row * P_ROW + 2,
          "A trade opens when the first 7 lines are all green on a new M5 candle.", clrGray, 8, "Arial");

   ChartRedraw();
}
//+------------------------------------------------------------------+
