//+------------------------------------------------------------------+
//|                                          XAUUSD_Scalper_EA.mq4   |
//|   Gold momentum scalper for MetaTrader 4                         |
//|   Sudden surge UP -> go LONG, sudden drop -> go SHORT,           |
//|   close as soon as the trade shows a small $ profit.             |
//+------------------------------------------------------------------+
#property copyright "AUT"
#property version   "1.30"
#property strict
#property description "Gold (XAUUSD) momentum scalper. Watches price tick by tick: a sudden surge up opens a LONG,"
#property description "a sudden drop opens a SHORT. Closes as soon as the trade is TakeProfitMoney in profit."
#property description "Every trade has a hard stop loss. Scalping is high risk - test on a demo account first."

enum ENUM_TRADE_DIR
{
   DIR_BOTH  = 0,   // Long and short
   DIR_LONG  = 1,   // Long (buy) only
   DIR_SHORT = 2    // Short (sell) only
};

//============================ INPUTS ===============================
input string   InpEntryHeader       = "===== Surge entry (real time) =====";  // ----------
input ENUM_TRADE_DIR TradeDirection = DIR_BOTH; // Trade direction
input int      SurgeSeconds         = 10;     // Look-back window for a surge (seconds)
input double   SurgeATR             = 0.6;    // Surge = move of at least ATR(M1) x this ...
input double   MinSurgePrice        = 1.00;   // ... and at least this many $ of gold price
input double   SurgeHoldPct         = 70.0;   // Price must still be near the extreme of the move (%)
input int      ATRPeriod            = 14;     // ATR period (M1)
input bool     UseTrendFilter       = false;  // Only trade in the direction of the M5 trend
input int      TrendEMA             = 50;     // M5 EMA period for the trend filter

input string   InpExitHeader        = "===== Quick exit =====";  // ----------
input double   TakeProfitMoney      = 2.0;    // Close as soon as the trade is this much in profit (account currency)
input double   BreakEvenMoney       = 1.0;    // Start protecting profit once the trade is this much up (0 = off)
input double   LockProfitMoney      = 0.50;   // ...by moving the stop to lock in this much profit (0 = plain break-even)
input double   TrailLockPct         = 50.0;   // ...then keep this % of the trade's profit as it grows (0 = off)
input double   StopLossATR          = 2.0;    // Hard stop loss = ATR(M1) x this
input double   MinStopPrice         = 2.0;    // Minimum stop loss ($ of gold price)
input double   MaxStopPrice         = 8.0;    // Skip the trade if the stop would be wider than this ($, 0 = off)
input int      MaxHoldSeconds       = 600;    // Close the trade after this many seconds, win or lose (0 = off)

input string   InpRiskHeader        = "===== Risk =====";  // ----------
input double   RiskPercent          = 5.0;    // Max loss per trade if the stop is hit (% of balance)
input double   FixedLot             = 0.0;    // Fixed lot size (0 = calculate from RiskPercent)
input bool     AllowMinLotOverRisk  = true;   // Use the minimum lot if the risk-based size is smaller...
input double   MaxRiskAtMinLot      = 8.0;    // ...but never if the minimum lot would risk more than this %
input double   CommissionPerLot     = 0.0;    // Round-turn commission per 1.00 lot (account currency)
input int      MaxOpenTrades        = 4;      // Max trades open at once (longs + shorts together)
input int      MaxLongTrades        = 2;      // Max LONG trades open at once
input int      MaxShortTrades       = 2;      // Max SHORT trades open at once
input int      EntryGapSeconds      = 15;     // Min seconds between two entries in the same direction
input double   MaxTotalRiskPercent  = 15.0;   // Max combined stop-loss risk of all open trades (% of balance, 0 = off)
input double   MaxDailyLossPercent  = 10.0;   // Stop for the day after this loss % (0 = off)
input int      MaxConsecLosses      = 3;      // Pause after this many losses in a row (0 = off)
input int      PauseMinutes         = 30;     // ...for this many minutes
input int      CooldownSeconds      = 30;     // Wait after a trade closes before the next one in the same direction
input int      MaxTradesPerDay      = 40;     // Max trades per day (0 = unlimited)

input string   InpFilterHeader      = "===== Filters =====";  // ----------
input double   MaxSpreadPrice       = 0.40;   // Max spread in $ of gold price
input int      StartHour            = 8;      // Trading start hour (broker server time)
input int      EndHour              = 20;     // Trading end hour (broker server time)
input bool     AvoidFridayLate      = true;   // No new trades late on Friday
input int      FridayEndHour        = 18;     // Friday cut-off hour (server time)

input string   InpOrderHeader       = "===== Orders & alerts =====";  // ----------
input int      MagicNumber          = 717171; // Magic number (unique per chart)
input int      SlippagePoints       = 30;     // Max slippage (points)
input bool     ECNMode              = false;  // ECN broker: send order first, then add SL/TP
input string   TradeComment         = "XAU_Scalp"; // Order comment
input bool     ShowPanel            = true;   // Show live panel on chart
input bool     PushNotifications    = true;   // Send alerts to the MT4 phone app (needs MetaQuotes ID)
input bool     PopupAlerts          = false;  // Also show a pop-up alert on the PC

//============================ GLOBALS ==============================
#define PFX "XSCP_"
#define TB  4096                 // tick buffer size

datetime g_tt[TB];               // tick times
double   g_tp[TB];               // tick prices (Bid)
int      g_head = 0, g_cnt = 0;

string   g_gvDayKey = "", g_gvDayBal = "";
string   g_status    = "Starting...";
string   g_lastEvent = "-";
int      g_known[];
int      g_srvOffset = 0;
datetime g_lastDraw = 0;
datetime g_lastEntry[2];         // last entry time   [0] = LONG, [1] = SHORT
datetime g_cooldown[2];          // cooldown end time [0] = LONG, [1] = SHORT
datetime g_pauseUntil = 0;
int      g_consecLosses = 0;
int      g_closeTicket = -1;     // last ticket the EA closed itself, and why
string   g_closeReason = "";
datetime g_pauseNotified = 0;

//========================== HELPERS ================================
string Px(double v)    { return DoubleToString(v, Digits); }
string Money(double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2); }

bool DirAllowed(int dir)
{
   return TradeDirection == DIR_BOTH || (dir > 0 && TradeDirection == DIR_LONG) || (dir < 0 && TradeDirection == DIR_SHORT);
}
int    Idx(int dir)  { return dir > 0 ? 0 : 1; }
string DName(int dir) { return dir > 0 ? "LONG" : "SHORT"; }

string DirText()
{
   return TradeDirection == DIR_BOTH ? "LONG + SHORT" : (TradeDirection == DIR_LONG ? "LONG only" : "SHORT only");
}

// Account money per 1.00 lot per $1 move in the gold price
double ValuePerPrice()
{
   double tv = MarketInfo(Symbol(), MODE_TICKVALUE);
   double ts = MarketInfo(Symbol(), MODE_TICKSIZE);
   return (tv > 0 && ts > 0) ? tv / ts : 0;
}

void Notify(string msg)
{
   Print("XAU_Scalp: ", msg);
   g_lastEvent = TimeToString(TimeCurrent(), TIME_SECONDS) + "  " + msg;
   if(IsTesting()) return;
   if(PushNotifications) SendNotification("XAU_Scalp: " + msg);
   if(PopupAlerts) Alert("XAU_Scalp: " + msg);
}

//========================== LIFECYCLE ==============================
int OnInit()
{
   if(RiskPercent <= 0 || RiskPercent > 50)    { Alert("XAU_Scalp: RiskPercent must be between 0 and 50."); return INIT_PARAMETERS_INCORRECT; }
   if(TakeProfitMoney <= 0)                    { Alert("XAU_Scalp: TakeProfitMoney must be > 0."); return INIT_PARAMETERS_INCORRECT; }
   if(SurgeSeconds < 5 || ATRPeriod <= 0)      { Alert("XAU_Scalp: SurgeSeconds must be >= 5 and ATRPeriod > 0."); return INIT_PARAMETERS_INCORRECT; }
   if(StopLossATR <= 0 && MinStopPrice <= 0)   { Alert("XAU_Scalp: a stop loss is required."); return INIT_PARAMETERS_INCORRECT; }
   if(MaxOpenTrades < 1 || MaxLongTrades < 0 || MaxShortTrades < 0)
   { Alert("XAU_Scalp: MaxOpenTrades must be at least 1 and the long/short limits >= 0."); return INIT_PARAMETERS_INCORRECT; }
   ArrayInitialize(g_lastEntry, 0);
   ArrayInitialize(g_cooldown, 0);

   string sym = Symbol();
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("XAU_Scalp WARNING: this EA is tuned for gold (XAUUSD), but it is attached to ", Symbol());

   string gvBase = "XAU_Scalp_" + (IsTesting() ? "TEST_" : "") + IntegerToString(AccountNumber()) + "_" +
                   Symbol() + "_" + IntegerToString(MagicNumber);
   g_gvDayKey = gvBase + "_day";
   g_gvDayBal = gvBase + "_bal";
   UpdateDailyAnchor();

   SnapshotOpenTickets(g_known);
   g_srvOffset = (int)(TimeCurrent() - TimeLocal());
   EventSetTimer(1);
   Notify(StringFormat("Scalper started on %s (%s), take %s %s per trade, balance %.2f",
                       Symbol(), DirText(), Money(TakeProfitMoney), AccountCurrency(), AccountBalance()));
   return INIT_SUCCEEDED;
}

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

void OnTick()
{
   g_srvOffset = (int)(TimeCurrent() - TimeLocal());
   PushTick();
   UpdateDailyAnchor();
   CheckClosedTrades();
   ManageTrades();
   TryEntry();

   if(ShowPanel && TimeLocal() != g_lastDraw) { g_lastDraw = TimeLocal(); DrawPanel(); }
}

//========================== TICK BUFFER ============================
void PushTick()
{
   if(g_cnt == TB) { g_head = (g_head + 1) % TB; g_cnt--; }
   int i = (g_head + g_cnt) % TB;
   g_tt[i] = TimeCurrent();
   g_tp[i] = Bid;
   g_cnt++;
   // drop ticks older than the surge window
   while(g_cnt > 1 && g_tt[g_head] < TimeCurrent() - SurgeSeconds) { g_head = (g_head + 1) % TB; g_cnt--; }
}

void ResetTicks() { g_head = 0; g_cnt = 0; }   // a new surge must build from scratch

// +1 = surge up, -1 = surge down, 0 = none. Fills in the measurements for the panel.
int SurgeDirection(double &move, double &needed, double &holdPct, bool &enoughData)
{
   move = 0; holdPct = 0;
   double atr = iATR(NULL, PERIOD_M1, ATRPeriod, 1);
   needed = MathMax(atr * SurgeATR, MinSurgePrice);
   enoughData = (g_cnt >= 2 && TimeCurrent() - g_tt[g_head] >= SurgeSeconds / 2);
   if(!enoughData) return 0;

   double start = g_tp[g_head], hi = start, lo = start;
   for(int k = 0; k < g_cnt; k++)
   {
      double p = g_tp[(g_head + k) % TB];
      if(p > hi) hi = p;
      if(p < lo) lo = p;
   }
   move = Bid - start;
   double range = hi - lo;
   if(range <= 0) return 0;

   holdPct = (move >= 0) ? (Bid - lo) / range * 100.0 : (hi - Bid) / range * 100.0;
   if(move >=  needed && holdPct >= SurgeHoldPct) return  1;
   if(move <= -needed && holdPct >= SurgeHoldPct) return -1;
   return 0;
}

int TrendDirection()
{
   double e1 = iMA(NULL, PERIOD_M5, TrendEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double e3 = iMA(NULL, PERIOD_M5, TrendEMA, 0, MODE_EMA, PRICE_CLOSE, 3);
   if(Bid > e1 && e1 > e3) return  1;
   if(Bid < e1 && e1 < e3) return -1;
   return 0;
}

//========================== ENTRY ==================================
void TryEntry()
{
   double move, needed, hold; bool enough;
   int dir = SurgeDirection(move, needed, hold, enough);
   if(dir == 0) { if(CountOpenTrades(0) == 0) g_status = enough ? "Watching for a surge..." : "Collecting tick data..."; return; }

   string d = dir > 0 ? "UP" : "DOWN";
   if(!DirAllowed(dir)) { g_status = "Surge " + d + " - direction disabled"; return; }
   if(UseTrendFilter && TrendDirection() != dir) { g_status = "Surge " + d + " - against M5 trend"; return; }

   string reason = "";
   if(!CanOpenNewTrade(dir, reason)) { g_status = "Surge " + d + " - " + reason; return; }

   if(OpenTrade(dir, move))
   {
      g_lastEntry[Idx(dir)] = TimeCurrent();
      SnapshotOpenTickets(g_known);
   }
}

int TradesToday()
{
   datetime day = iTime(NULL, PERIOD_D1, 0);
   int n = CountOpenTrades(0);
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() <= OP_SELL && OrderOpenTime() >= day) n++;
   }
   return n;
}

string PauseReason()
{
   if(TimeCurrent() < g_pauseUntil)
      return StringFormat("paused %d min after %d losses in a row", (int)((g_pauseUntil - TimeCurrent()) / 60) + 1, MaxConsecLosses);
   if(MaxTradesPerDay > 0 && TradesToday() >= MaxTradesPerDay)
      return "max trades for today reached";
   return "";
}

// Why a new trade in this direction can't open right now ("" = it can)
string DirBlock(int dir)
{
   int maxDir = dir > 0 ? MaxLongTrades : MaxShortTrades;
   if(maxDir == 0)                                   return DName(dir) + "s disabled (limit 0)";
   if(CountOpenTrades(dir) >= maxDir)                return StringFormat("%d/%d open", CountOpenTrades(dir), maxDir);
   if(CountOpenTrades(0) >= MaxOpenTrades)           return StringFormat("total %d/%d open", CountOpenTrades(0), MaxOpenTrades);
   int i = Idx(dir);
   if(TimeCurrent() < g_cooldown[i])                 return StringFormat("cooldown %ds", (int)(g_cooldown[i] - TimeCurrent()));
   if(TimeCurrent() < g_lastEntry[i] + EntryGapSeconds)
      return StringFormat("next in %ds", (int)(g_lastEntry[i] + EntryGapSeconds - TimeCurrent()));
   return "";
}

bool CanOpenNewTrade(int dir, string &reason)
{
   if(!IsTradeAllowed())                  { reason = "AutoTrading is off"; return false; }
   string b = DirBlock(dir);
   if(b != "")                            { reason = DName(dir) + " " + b; return false; }
   if(DailyLossHit())
   {
      reason = "daily loss limit hit";
      datetime today = iTime(NULL, PERIOD_D1, 0);
      if(g_pauseNotified != today) { g_pauseNotified = today; Notify("Daily loss limit hit - no new trades until tomorrow"); }
      return false;
   }
   string p = PauseReason();
   if(p != "")                            { reason = p; return false; }
   if(Ask - Bid > MaxSpreadPrice)         { reason = StringFormat("spread too wide ($%.2f)", Ask - Bid); return false; }
   if(!InSession())                       { reason = "outside trading hours"; return false; }
   return true;
}

bool InSession()
{
   datetime now = TimeCurrent();
   int h = TimeHour(now);
   if(AvoidFridayLate && TimeDayOfWeek(now) == 5 && h >= FridayEndHour) return false;
   if(StartHour == EndHour) return true;
   if(StartHour < EndHour)  return (h >= StartHour && h < EndHour);
   return (h >= StartHour || h < EndHour);
}

//========================== RISK ===================================
double StopDistance()
{
   double atr = iATR(NULL, PERIOD_M1, ATRPeriod, 1);
   double sl  = MathMax(atr * StopLossATR, MinStopPrice);
   double minDist = (MarketInfo(Symbol(), MODE_STOPLEVEL) + 1) * Point + (Ask - Bid);
   return MathMax(sl, minDist);
}

double CalcLots(double slDist, bool quiet = false)
{
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double vpp     = ValuePerPrice();
   if(vpp <= 0 || lotStep <= 0 || slDist <= 0)
   { if(!quiet) Print("XAU_Scalp: invalid symbol info, cannot size position."); return 0; }

   double lossPerLot = slDist * vpp + CommissionPerLot;
   double bal = AccountBalance();
   double lots;
   if(FixedLot > 0) lots = MathMax(FixedLot, minLot);
   else
   {
      lots = bal * RiskPercent / 100.0 / lossPerLot;
      lots = MathFloor(lots / lotStep + 1e-9) * lotStep;      // round DOWN
      if(lots < minLot && AllowMinLotOverRisk && minLot * lossPerLot <= bal * MaxRiskAtMinLot / 100.0)
         lots = minLot;
   }
   lots = MathMin(lots, maxLot);
   if(lots < minLot)
   {
      if(!quiet) PrintFormat("XAU_Scalp: minimum lot %.2f would risk %.2f (%.1f%%) - more than allowed. Trade skipped.",
                             minLot, minLot * lossPerLot, minLot * lossPerLot / bal * 100.0);
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
   if(AccountBalance() < startBal * 0.5) { GlobalVariableSet(g_gvDayBal, AccountBalance()); return false; }
   return AccountEquity() <= startBal * (1.0 - MaxDailyLossPercent / 100.0);
}

//========================== ORDERS =================================
// dir: 0 = all, 1 = longs, -1 = shorts
int CountOpenTrades(int dir)
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() > OP_SELL) continue;
      if(dir == 0 || (dir > 0 && OrderType() == OP_BUY) || (dir < 0 && OrderType() == OP_SELL)) n++;
   }
   return n;
}

// Money lost if every open trade hit its stop now (stops at break-even or better count as 0)
double OpenRisk()
{
   double vpp = ValuePerPrice(), risk = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() > OP_SELL) continue;
      double sl = OrderStopLoss();
      double dist = (sl == 0) ? StopDistance()
                  : (OrderType() == OP_BUY ? OrderOpenPrice() - sl : sl - OrderOpenPrice());
      if(dist > 0) risk += dist * vpp * OrderLots();
      risk += CommissionPerLot * OrderLots();
   }
   return risk;
}

// dir: 1 = longs, -1 = shorts. Returns combined P/L and sets count.
double OpenPL(int dir, int &count)
{
   double pl = 0; count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() > OP_SELL) continue;
      if((dir > 0 && OrderType() != OP_BUY) || (dir < 0 && OrderType() != OP_SELL)) continue;
      pl += OrderProfit() + OrderSwap() + OrderCommission();
      count++;
   }
   return pl;
}

bool IsRetryable(int err)
{
   return err == ERR_REQUOTE || err == ERR_PRICE_CHANGED || err == ERR_OFF_QUOTES ||
          err == ERR_SERVER_BUSY || err == ERR_TRADE_CONTEXT_BUSY || err == ERR_BROKER_BUSY;
}

bool OpenTrade(int dir, double surgeMove)
{
   double slDist = StopDistance();
   if(MaxStopPrice > 0 && slDist > MaxStopPrice)
   { g_status = StringFormat("Surge skipped - stop $%.2f wider than max $%.2f", slDist, MaxStopPrice); return false; }

   double lots = CalcLots(slDist);
   if(lots <= 0) { g_status = "Surge skipped - account too small for minimum lot"; return false; }

   double newRisk = lots * (slDist * ValuePerPrice() + CommissionPerLot);
   double cap     = AccountBalance() * MaxTotalRiskPercent / 100.0;
   if(MaxTotalRiskPercent > 0 && OpenRisk() + newRisk > cap)
   { g_status = StringFormat("Surge skipped - total risk would be %.2f (max %.2f)", OpenRisk() + newRisk, cap); return false; }

   // broker-side take profit at the money target (filled instantly by the broker, even between ticks)
   double vpp    = ValuePerPrice();
   double tpDist = (TakeProfitMoney + CommissionPerLot * lots) / (lots * vpp);
   double minDist = (MarketInfo(Symbol(), MODE_STOPLEVEL) + 1) * Point;
   tpDist = MathMax(tpDist, minDist);

   int type = (dir > 0) ? OP_BUY : OP_SELL;
   ResetLastError();
   if(AccountFreeMarginCheck(Symbol(), type, lots) <= 0 || GetLastError() == ERR_NOT_ENOUGH_MONEY)
   { g_status = StringFormat("Surge skipped - not enough margin for %.2f lots", lots); return false; }

   for(int attempt = 1; attempt <= 3; attempt++)
   {
      RefreshRates();
      double price = (type == OP_BUY) ? Ask : Bid;
      double sl = NormalizeDouble(type == OP_BUY ? price - slDist : price + slDist, Digits);
      double tp = NormalizeDouble(type == OP_BUY ? price + tpDist : price - tpDist, Digits);
      price = NormalizeDouble(price, Digits);
      color clr = (type == OP_BUY) ? clrDodgerBlue : clrTomato;

      int ticket = ECNMode
         ? OrderSend(Symbol(), type, lots, price, SlippagePoints, 0, 0, TradeComment, MagicNumber, 0, clr)
         : OrderSend(Symbol(), type, lots, price, SlippagePoints, sl, tp, TradeComment, MagicNumber, 0, clr);
      if(ticket > 0)
      {
         if(ECNMode) AttachStops(ticket, slDist, tpDist);
         g_status = (type == OP_BUY ? "LONG open" : "SHORT open");
         Notify(StringFormat("%s %.2f @ %s (surge %s$%.2f) SL %s TP %s, target %s",
                type == OP_BUY ? "LONG" : "SHORT", lots, Px(price), surgeMove >= 0 ? "+" : "-", MathAbs(surgeMove),
                Px(sl), Px(tp), Money(TakeProfitMoney)));
         return true;
      }
      int err = GetLastError();
      PrintFormat("XAU_Scalp: OrderSend failed (attempt %d): error %d", attempt, err);
      if(!IsRetryable(err)) { Notify(StringFormat("Order FAILED, error %d (see Experts tab)", err)); break; }
      Sleep(200);
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
      if(OrderModify(ticket, open, NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits), 0, clrNONE)) return;
      Sleep(300);
      RefreshRates();
   }
   Alert("XAU_Scalp WARNING: could not set SL/TP on ticket #", ticket, " - set them manually!");
   Notify(StringFormat("WARNING: no SL/TP on ticket #%d - set them manually!", ticket));
}

bool CloseTicket(int ticket, string why)
{
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      if(!OrderSelect(ticket, SELECT_BY_TICKET) || OrderCloseTime() != 0) return true;
      RefreshRates();
      double price = (OrderType() == OP_BUY) ? Bid : Ask;
      g_closeTicket = ticket; g_closeReason = why;
      if(OrderClose(ticket, OrderLots(), NormalizeDouble(price, Digits), SlippagePoints, clrYellow)) return true;
      int err = GetLastError();
      PrintFormat("XAU_Scalp: OrderClose #%d failed (attempt %d): error %d", ticket, attempt, err);
      if(!IsRetryable(err)) break;
      Sleep(200);
   }
   return false;
}

// Quick profit exit, break-even and time limit - checked on every tick
void ManageTrades()
{
   double vpp = ValuePerPrice();
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() > OP_SELL) continue;

      int    ticket = OrderTicket();
      int    type   = OrderType();
      double open   = OrderOpenPrice(), sl = OrderStopLoss(), tp = OrderTakeProfit(), lots = OrderLots();
      double net    = OrderProfit() + OrderSwap() + OrderCommission();

      // 1. Take the money as soon as the target is reached
      if(net >= TakeProfitMoney) { CloseTicket(ticket, "profit target"); continue; }

      // 2. Time limit
      if(MaxHoldSeconds > 0 && TimeCurrent() - OrderOpenTime() >= MaxHoldSeconds) { CloseTicket(ticket, "time limit"); continue; }

      // 3. Profit lock: once up BreakEvenMoney, move the stop so the trade can't close at 0.00.
      //    Locks LockProfitMoney first, then TrailLockPct % of the current profit (stop only ever moves forward).
      if(BreakEvenMoney > 0 && net >= BreakEvenMoney && vpp > 0)
      {
         double lockMoney = MathMax(LockProfitMoney, net * TrailLockPct / 100.0);
         if(lockMoney >= net) lockMoney = net * 0.5;                       // never place the stop at the current price
         double dist    = (lockMoney + CommissionPerLot * lots) / (lots * vpp);
         double minStep = MathMax(Point, 0.10 / (lots * vpp));            // move in steps of at least 0.10 profit
         RefreshRates();
         if(type == OP_BUY)
         {
            double ns = NormalizeDouble(open + dist, Digits);
            if(ns >= sl + minStep && Bid - ns > stopLevel && OrderModify(ticket, open, ns, tp, 0, clrNONE) && sl < open)
               Notify(StringFormat("LONG #%d profit locked: stop at %s (%s)", ticket, Px(ns), Money(lockMoney)));
         }
         else
         {
            double ns = NormalizeDouble(open - dist, Digits);
            if((sl == 0 || ns <= sl - minStep) && ns - Ask > stopLevel && OrderModify(ticket, open, ns, tp, 0, clrNONE) && (sl == 0 || sl > open))
               Notify(StringFormat("SHORT #%d profit locked: stop at %s (%s)", ticket, Px(ns), Money(lockMoney)));
         }
      }
   }
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

      double pl  = OrderProfit() + OrderSwap() + OrderCommission();
      double cp  = OrderClosePrice();
      double tol = 3 * Point;
      string why;
      if(OrderTicket() == g_closeTicket)                              why = g_closeReason;
      else if(OrderTakeProfit() > 0 && MathAbs(cp - OrderTakeProfit()) <= tol) why = "take profit";
      else if(OrderStopLoss() > 0 && MathAbs(cp - OrderStopLoss()) <= tol)     why = pl >= 0 ? "profit-lock stop" : "stop loss";
      else                                                            why = "closed manually";

      Notify(StringFormat("%s #%d CLOSED %s %s (%s) - balance %.2f",
             OrderType() == OP_BUY ? "LONG" : "SHORT", OrderTicket(), Money(pl), AccountCurrency(), why, AccountBalance()));

      if(pl < 0) g_consecLosses++; else g_consecLosses = 0;
      if(MaxConsecLosses > 0 && g_consecLosses >= MaxConsecLosses)
      {
         g_pauseUntil = TimeCurrent() + PauseMinutes * 60;
         g_consecLosses = 0;
         Notify(StringFormat("%d losses in a row - pausing for %d minutes", MaxConsecLosses, PauseMinutes));
      }
      g_cooldown[OrderType() == OP_BUY ? 0 : 1] = TimeCurrent() + CooldownSeconds;
   }
   ArrayResize(g_known, ArraySize(cur));
   for(int i = 0; i < ArraySize(cur); i++) g_known[i] = cur[i];
}

void TodayStats(int &n, int &wins, double &pl)
{
   n = 0; wins = 0; pl = 0;
   datetime day = iTime(NULL, PERIOD_D1, 0);
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber || OrderType() > OP_SELL) continue;
      if(OrderCloseTime() < day) continue;
      double p = OrderProfit() + OrderSwap() + OrderCommission();
      n++; pl += p; if(p > 0) wins++;
   }
}

//========================== PANEL ==================================
#define P_X     10
#define P_Y     95
#define P_W     540
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
void PRow(int row, int state, string title, string value, color valueClr = clrWhite)
{
   int y = P_Y + 30 + row * P_ROW;
   string icon = state == 1 ? CharToStr(252) : (state == 0 ? CharToStr(251) : CharToStr(159));
   color  ic   = state == 1 ? clrLimeGreen : (state == 0 ? clrTomato : clrGray);
   if(StringLen(value) > 56) value = StringSubstr(value, 0, 54) + "..";
   PLabel("i" + IntegerToString(row), P_X + 8,  y, icon, ic, 10, "Wingdings");
   PLabel("t" + IntegerToString(row), P_X + 28, y, title, clrSilver);
   PLabel("v" + IntegerToString(row), P_X + 150, y, value, state == 0 ? clrTomato : valueClr);
}

void DrawPanel()
{
   int row = 0;
   bool canTrade = IsTradeAllowed() && IsExpertEnabled();
   PBox(30 + 17 * P_ROW + 8);
   PLabel("hdr", P_X + 8, P_Y + 6, "XAUUSD SCALPER", clrWhite, 11, "Arial Bold");
   PLabel("run", P_X + 170, P_Y + 8,
          canTrade ? "RUNNING - live " + (IsDemo() ? "(DEMO)" : "(REAL MONEY)") : "AUTOTRADING OFF",
          canTrade ? clrLimeGreen : clrTomato, 9, "Arial Bold");

   // --- 1-2. surge
   double move, needed, hold; bool enough;
   int dir = SurgeDirection(move, needed, hold, enough);
   bool bigEnough = enough && MathAbs(move) >= needed;
   string sv = !enough ? "collecting tick data..."
             : StringFormat("%s $%.2f in %ds  (need $%.2f)", move >= 0 ? "UP" : "DOWN", MathAbs(move), SurgeSeconds, needed);
   PRow(row++, bigEnough ? 1 : 0, "Surge", sv);
   PRow(row++, (enough && hold >= SurgeHoldPct && move != 0) ? 1 : 0, "Still pushing",
        StringFormat("%.0f%% of the move held  (need %.0f%%)", hold, SurgeHoldPct));

   // --- 3-7. filters
   double spread = Ask - Bid;
   PRow(row++, spread <= MaxSpreadPrice ? 1 : 0, "Spread", StringFormat("$%.2f  (max $%.2f)", spread, MaxSpreadPrice));
   datetime srv = TimeLocal() + g_srvOffset;
   PRow(row++, InSession() ? 1 : 0, "Trading hours",
        StringFormat("%s server  (%02d:00-%02d:00)", TimeToString(srv, TIME_SECONDS), StartHour, EndHour));
   bool dl = DailyLossHit();
   PRow(row++, dl ? 0 : 1, "Daily loss limit", dl ? "HIT - stopped for today" : StringFormat("OK  (limit %.0f%%)", MaxDailyLossPercent));
   string pr = PauseReason();
   PRow(row++, pr == "" ? 1 : 0, "Not paused", pr == "" ? "yes" : pr);
   string lb = DirAllowed(1)  ? DirBlock(1)  : "disabled";
   string sb = DirAllowed(-1) ? DirBlock(-1) : "disabled";
   PRow(row++, (lb == "" || sb == "") ? 1 : 0, "Slots",
        "LONG " + (lb == "" ? "ready" : lb) + " | SHORT " + (sb == "" ? "ready" : sb));

   // --- open trades
   int nl, ns;
   double pll = OpenPL(1, nl), pls = OpenPL(-1, ns);
   PRow(row++, -1, "Open LONGs",  nl == 0 ? "none" : StringFormat("%d trade(s)  P/L %s  (each closes at %s)", nl, Money(pll), Money(TakeProfitMoney)),
        pll >= 0 ? clrLimeGreen : clrTomato);
   PRow(row++, -1, "Open SHORTs", ns == 0 ? "none" : StringFormat("%d trade(s)  P/L %s  (each closes at %s)", ns, Money(pls), Money(TakeProfitMoney)),
        pls >= 0 ? clrLimeGreen : clrTomato);
   double orisk = OpenRisk();
   PRow(row++, -1, "Open risk", StringFormat("%.2f of max %.2f %s  (%.1f%% of balance)", orisk,
        AccountBalance() * MaxTotalRiskPercent / 100.0, AccountCurrency(), orisk / AccountBalance() * 100.0));
   PRow(row++, -1, "Directions", DirText() + (UseTrendFilter ? "  (with M5 trend)" : "  (follows the surge)"));

   // --- next trade preview
   double slDist = StopDistance();
   double lots   = CalcLots(slDist, true);
   double vpp    = ValuePerPrice();
   string nt;
   if(MaxStopPrice > 0 && slDist > MaxStopPrice) nt = StringFormat("stop $%.2f too wide - would skip", slDist);
   else if(lots <= 0) nt = "account too small for minimum lot";
   else
   {
      double risk = lots * (slDist * vpp + CommissionPerLot);
      nt = StringFormat("%.2f lots, take %s, stop %s (%.1f%%)", lots, Money(TakeProfitMoney), Money(-risk),
                        risk / AccountBalance() * 100.0);
   }
   PRow(row++, -1, "Next trade", nt);

   int n, wins; double tpl;
   TodayStats(n, wins, tpl);
   PRow(row++, -1, "Today", StringFormat("%d trades, %d wins, P/L %s %s  (bal %.2f)", n, wins, Money(tpl),
        AccountCurrency(), AccountBalance()), tpl >= 0 ? clrLimeGreen : clrTomato);
   PRow(row++, -1, "Status", g_status);
   PRow(row++, -1, "Last event", g_lastEvent);
   PLabel("foot", P_X + 8, P_Y + 30 + row * P_ROW + 2,
          "A trade opens when the first 7 lines are green. Each trade closes at its own profit target.", clrGray, 8, "Arial");
   ChartRedraw();
}
//+------------------------------------------------------------------+
