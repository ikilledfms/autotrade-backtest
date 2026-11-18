//+------------------------------------------------------------------+
//|                                                   AutoTrade.mq5  |
//|  XAUUSD automated scalping — Zona 3-Candle + FIBO50 + SMC Kill   |
//|  Zone. Spec: ~/workspace/forex/auto trade.md (16 Nov 2026).      |
//|  v1.0 — backtest/research build. MT5 (MQL5).                     |
//|  Research account: HFM MT5 demo (Premium, XAUUSD, $100,        |
//|  lev 1:2000; nomor akun HANYA di GitHub Secrets, bukan di file).  |
//|  Live target later: HFM Cent MT5 (XAUUSDc) — set InpSymbol       |
//|  accordingly; the EA reads contract/tick values from the terminal,|
//|  so lot sizing adapts to both.                                   |
//|  NO live trading before: backtest >=50-100 trades + forward test |
//|  demo 30-50 trades + prince's explicit confirmation.             |
//+------------------------------------------------------------------+
#property copyright "ikilledfms — research build for Prince"
#property version   "1.00"
#property description "XAUUSD auto scalping: Zona 3-Candle (core) + FIBO50 + SMC Kill Zone"
#property description "Risk 1%/trade, RR target 1:3 (min 1:2), max 1 position, max daily loss 3%,"
#property description "stop after 3 consecutive losses, BE trailing after +1R, NFP/FOMC no-trade window."

#include <Trade\Trade.mqh>

//--- Inputs: instrument & identity
input group "=== Instrument & Identity ==="
input string InpSymbol        = "XAUUSD";   // Symbol (demo: XAUUSD, live Cent: XAUUSDc)
input long   InpMagic         = 20261116;   // Magic number
input int    InpDeviationPts  = 30;         // Max deviation (points) for market closes

//--- Inputs: risk
input group "=== Risk (§5) ==="
input double InpRiskPct       = 1.0;        // Risk per trade (% of equity)
input double InpRRTarget      = 3.0;        // TP target in R (min 2.0 enforced)
input double InpMaxDailyLossPct = 3.0;      // Max daily loss (% of day-start equity)
input double InpDailyTargetPct  = 2.0;      // Daily profit target % (0 = disabled) — stop trading once hit
input int    InpMaxConsecLoss = 3;          // Stop after N consecutive losses (per day)
input double InpMaxDrawdownPct  = 15.0;     // Max drawdown from equity peak % (0 = disabled)
input double InpMinLotRiskCapPct = 0.0;     // If computed lot < min volume: allow min lot ONLY if its risk <= this % (0 = strict, skip trade)

//--- Inputs: routes
input group "=== Routes (§1-§2) ==="
input bool   InpUseRouteA     = true;       // Route A: Zona 3-Candle (core)
input bool   InpUseRouteB     = true;       // Route B: FIBO50 (reserve)
input bool   InpUseRouteC     = true;       // Route C: SMC Kill Zone (third)

//--- Inputs: Route A — Zona 3-Candle
input group "=== Route A: Zona 3-Candle (§1) ==="
input int    InpZoneHourWIB   = 5;          // Zone candle hour (WIB) — 05:00 WIB = 06:00 MYT
input double InpBreakTolerancePct = 5.0;    // Valid-break tolerance (% of zone height) — book says 0.5-1.5%, translated to zone height; calibrate in backtest
input double InpEntryBufferUSD   = 0.30;    // Buy/sell stop buffer beyond zone edge (USD/oz)
input double InpSLBufferUSD      = 0.30;    // SL buffer beyond opposite zone edge (USD/oz)
input int    InpSetupMaxAgeBars  = 3;       // Setup expires N H1 bars after CS2 (no FOMO / no chasing)

//--- Inputs: Route B — FIBO50
input group "=== Route B: FIBO50 (§2) ==="
input int    InpSwingBars     = 5;          // Bars each side for swing high/low detection
input double InpMinSwingUSD   = 5.0;        // Minimum swing range (USD/oz) to consider
input double InpFiboClose1    = 0.50;       // Partial close at TP1 (+1R): fraction of volume
input double InpFiboClose2    = 0.25;       // Partial close at TP2 (+2R): fraction of original volume (rest runs to TP3 = +3R)

//--- Inputs: Route C — SMC Kill Zone
input group "=== Route C: SMC Kill Zone (§2) ==="
input double InpImpulseMinATR = 1.0;        // Impulse candle body >= N x ATR(14,H1)
input double InpSMC_TPExt     = 261.8;      // TP Fib extension % (261.8 or 423.6)

//--- Inputs: filters (§3)
input group "=== Filters (§3) ==="
input double InpADXMin        = 25.0;       // ADX(14,H4) minimum for trend entries (0 = disable)
input bool   InpUseBBMAFilter = true;       // BBMA filter: price vs EMA50 + BB midline
input bool   InpUseRSIFilter  = true;       // RSI(14) H1+H4 must agree with direction (vs 50)
input bool   InpRequireH1Pattern = false;   // Require H1 candle-pattern confirmation (engulfing/hammer/harami/star/tweezer)
input double InpMaxSpreadUSD  = 1.00;       // Max spread at entry (USD/oz) — calibrate (Premium demo ~0.35)
input double InpMinDailyRangeUSD = 20.0;    // Min expected daily range = ATR(14,D1) (USD/oz) — book pip numbers must be recalibrated to $/oz
input bool   InpAvoidRoundNumbers = true;   // Don't place entry exactly on round numbers (10/20/25/50/100)
input double InpRoundNudgeUSD = 0.50;       // Nudge off round numbers (USD/oz)

//--- Inputs: time & news (§4)
input group "=== Time & News (§4) ==="
input bool   InpTradeOnlyInKillZone = true; // Trade only inside kill-zone hours
input int    InpKZLondonStartWIB = 13;      // London kill zone start (WIB)
input int    InpKZLondonEndWIB   = 16;      // London kill zone end (WIB)
input int    InpKZNYStartWIB     = 19;      // New York kill zone start (WIB, covers NY 19-22 + overlap to 24:00)
input int    InpKZNYEndWIB       = 24;      // New York kill zone end (WIB)
input bool   InpAvoidFridayAfternoon = true;// No new trades Friday afternoon
input int    InpFridayCutoffWIB  = 15;      // Friday no-trade from this hour (WIB)
input int    InpNewsBeforeMin    = 30;      // NFP/FOMC no-trade window: minutes BEFORE release
input int    InpNewsAfterMin     = 60;      // NFP/FOMC no-trade window: minutes AFTER release
input bool   InpUseNewsCalendar  = true;    // Use built-in economic calendar (live only; tester has no calendar)
input string InpManualNews       = "2026.12.04 20:30,2026.12.17 02:00,2027.01.08 20:30,2027.01.28 02:00,2027.02.05 20:30";
                                                // Manual NFP/FOMC times (WIB, "yyyy.MM.dd hh:mi", comma-separated).
                                                // Defaults: NFP first Friday 20:30 WIB; FOMC decision ~02:00 WIB.
                                                // VERIFY and extend this list — it is the only news source in the Strategy Tester.

//--- Inputs: position management (§5)
input group "=== Position Management (§5) ==="
input int    InpMaxHoldHours  = 10;         // Max position lifetime (hours) — book: 5-10 candles
input bool   InpUseHeartbeat  = false;      // Kill-switch: block new trades if Muse heartbeat GlobalVariable is stale/missing
input string InpHeartbeatGV   = "AutoTrade_Heartbeat"; // GlobalVariable name holding last heartbeat time (unix seconds)
input int    InpHeartbeatMaxAgeSec = 300;   // Max heartbeat age (seconds)

//--- Globals
CTrade      g_trade;
string      g_symbol;
int         g_digits;
double      g_point;
double      g_tickSize, g_tickValue;
double      g_volMin, g_volMax, g_volStep;
long        g_stopsLevelPts, g_freezeLevelPts;

int hEMA20H4, hEMA30H4, hEMA50H4;
int hEMA5H1, hEMA20H1, hEMA55H1, hEMA50H1;
int hADX_H4, hRSI_H1, hRSI_H4, hBB_H1, hATR_H1, hATR_D1;

string      g_usedKeys[];          // setup keys already traded (per run)
int         g_aVoidDir = 0;        // Route A: direction voided for today (0 none, 1 long, -1 short)
datetime    g_aVoidDay = 0;        // WIB day-start (shifted) of the void
ulong       g_seenTickets[];       // position tickets already registered (initial SL stored in GV)

//+------------------------------------------------------------------+
//| Time helpers — all trading hours are WIB (UTC+7).                |
//| WIB wall-clock is computed with pure Unix arithmetic from GMT,   |
//| so broker server-time/DST shifts cannot corrupt it. A "WIB      |
//| shifted" timestamp is a Unix time whose UTC components equal the |
//| WIB wall clock (i.e. GMT time + 7h).                             |
//+------------------------------------------------------------------+
long ServerGMTOffsetSec()
{
   return((long)TimeCurrent() - (long)TimeGMT());
}
// Current moment expressed as a WIB-shifted timestamp.
datetime WIBNowShifted()
{
   return(TimeGMT() + 7 * 3600);
}
// Start of the current WIB day, in WIB-shifted terms.
datetime WIBDayStartShifted()
{
   datetime w = WIBNowShifted();
   return((datetime)(w - (w % 86400)));
}
// Start of the WIB day containing a server timestamp, WIB-shifted.
datetime WIBDayStartShifted(datetime serverTime)
{
   datetime w = (datetime)(serverTime + (7 * 3600 - ServerGMTOffsetSec()));
   return((datetime)(w - (w % 86400)));
}
// Convert a WIB-shifted timestamp to server time.
datetime WIBShiftedToServer(datetime wibShifted)
{
   return((datetime)(wibShifted - 7 * 3600 + ServerGMTOffsetSec()));
}
int WIBHour()
{
   return((int)((WIBNowShifted() / 3600) % 24));
}
int WIBDayOfWeek()
{
   // 1970-01-01 was a Thursday (day 4, with 0=Sunday).
   return((int)(((WIBNowShifted() / 86400) + 4) % 7));
}

//+------------------------------------------------------------------+
//| Symbol helpers                                                   |
//+------------------------------------------------------------------+
double SpreadUSD()
{
   return(SymbolInfoDouble(g_symbol, SYMBOL_ASK) - SymbolInfoDouble(g_symbol, SYMBOL_BID));
}
double NormPrice(double price)
{
   return(NormalizeDouble(price, g_digits));
}
// Nudge an entry price off round psychological numbers (10/20/25/50/100).
// Buy-side levels move up, sell-side levels move down (§3f).
double NudgeOffRound(double price, bool isBuy)
{
   if(!InpAvoidRoundNumbers) return(price);
   double step = 10.0; // round-number grid in USD/oz
   double nearest = MathRound(price / step) * step;
   if(MathAbs(price - nearest) <= InpRoundNudgeUSD)
      price = isBuy ? nearest + InpRoundNudgeUSD : nearest - InpRoundNudgeUSD;
   return(NormPrice(price));
}
// Lot from risk %: lot = (equity * risk%) / (SL distance in ticks * tick value).
// Uses the symbol's own contract/tick values, so it adapts to Premium and Cent accounts.
double CalcLot(double slDistanceUSD)
{
   if(slDistanceUSD <= 0 || g_tickSize <= 0 || g_tickValue <= 0) return(0.0);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct / 100.0;
   double lossPerLot = (slDistanceUSD / g_tickSize) * g_tickValue;
   if(lossPerLot <= 0) return(0.0);
   double lots = riskMoney / lossPerLot;
   // normalize to volume step
   lots = MathFloor(lots / g_volStep) * g_volStep;
   lots = NormalizeDouble(lots, 2);
   return(lots);
}
// Risk % of equity that min volume would represent for a given SL distance.
double MinLotRiskPct(double slDistanceUSD)
{
   if(slDistanceUSD <= 0 || g_tickSize <= 0 || g_tickValue <= 0) return(100.0);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return(100.0);
   double lossMin = (slDistanceUSD / g_tickSize) * g_tickValue * g_volMin;
   return(lossMin / equity * 100.0);
}
bool CheckStopsLevel(double entry, double sl, double tp)
{
   double minDist = (double)(g_stopsLevelPts + 2) * g_point;
   if(MathAbs(entry - sl) < minDist) return(false);
   if(MathAbs(tp - entry) < minDist) return(false);
   return(true);
}

//+------------------------------------------------------------------+
//| Indicator value helpers (last closed bar = shift 1)              |
//+------------------------------------------------------------------+
double IndVal(int handle, int buffer, int shift)
{
   double buf[];
   if(CopyBuffer(handle, buffer, shift, 1, buf) != 1) return(EMPTY_VALUE);
   return(buf[0]);
}
double EMA_H4(int period, int shift)
{
   int h = (period == 20) ? hEMA20H4 : (period == 30) ? hEMA30H4 : hEMA50H4;
   return(IndVal(h, 0, shift));
}
double EMA_H1(int period, int shift)
{
   int h = (period == 5) ? hEMA5H1 : (period == 20) ? hEMA20H1 : (period == 55) ? hEMA55H1 : hEMA50H1;
   return(IndVal(h, 0, shift));
}

//+------------------------------------------------------------------+
//| Daily stats (§5a): day-start equity, realized P&L today,         |
//| consecutive losses today, equity peak. WIB day.                  |
//+------------------------------------------------------------------+
double g_dayStartEquity = 0.0;
datetime g_dayKey = 0;
double g_equityPeak = 0.0;

void UpdateDailyStats()
{
   datetime dayKey = WIBDayStartShifted();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak) g_equityPeak = equity;
   if(dayKey != g_dayKey)
   {
      g_dayKey = dayKey;
      g_dayStartEquity = equity;
      GlobalVariableSet("AT_dayEquity", equity);
      GlobalVariableSet("AT_peak", g_equityPeak);
   }
   else if(g_dayStartEquity <= 0)
   {
      g_dayStartEquity = GlobalVariableCheck("AT_dayEquity") ? GlobalVariableGet("AT_dayEquity") : equity;
   }
   if(g_equityPeak <= 0)
      g_equityPeak = GlobalVariableCheck("AT_peak") ? GlobalVariableGet("AT_peak") : equity;
}

// Realized P&L of OUR closed deals today (WIB day), in account currency.
double RealizedToday()
{
   datetime from = WIBShiftedToServer(WIBDayStartShifted());
   if(!HistorySelect(from, TimeCurrent())) return(0.0);
   double sum = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != g_symbol) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN) continue; // only closes (OUT / IN_OUT)
      sum += HistoryDealGetDouble(ticket, DEAL_PROFIT)
           + HistoryDealGetDouble(ticket, DEAL_SWAP)
           + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return(sum);
}

// Consecutive losing CLOSED positions today (grouped by position id).
int ConsecLossesToday()
{
   datetime from = WIBShiftedToServer(WIBDayStartShifted());
   if(!HistorySelect(from, TimeCurrent())) return(0);
   // collect closed-position net profits in chronological order
   ulong  ids[];
   double profits[];
   int n = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != g_symbol) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN) continue;
      ulong pid = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
               + HistoryDealGetDouble(ticket, DEAL_SWAP)
               + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      int idx = -1;
      for(int k = 0; k < n; k++) if(ids[k] == pid) { idx = k; break; }
      if(idx < 0)
      {
         ArrayResize(ids, n + 1); ArrayResize(profits, n + 1);
         ids[n] = pid; profits[n] = p; n++;
      }
      else profits[idx] += p;
   }
   int consec = 0;
   for(int k = n - 1; k >= 0; k--)
   {
      if(profits[k] < 0) consec++;
      else break;
   }
   return(consec);
}

//+------------------------------------------------------------------+
//| News gate (§4b): NFP/FOMC no-trade window.                       |
//| Primary source in live trading: built-in economic calendar.      |
//| In the Strategy Tester the calendar is unavailable, so the       |
//| manual list (InpManualNews, WIB) is authoritative there.         |
//+------------------------------------------------------------------+
bool ManualNewsBlocked()
{
   if(InpManualNews == "") return(false);
   string parts[];
   int cnt = StringSplit(InpManualNews, ',', parts);
   for(int i = 0; i < cnt; i++)
   {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s == "") continue;
      datetime relWIB = StringToTime(s);
      if(relWIB == 0) continue;
      datetime relGMT = relWIB - 7 * 3600;
      datetime from = relGMT - InpNewsBeforeMin * 60;
      datetime to   = relGMT + InpNewsAfterMin * 60;
      datetime nowGMT = TimeGMT();
      if(nowGMT >= from && nowGMT <= to) return(true);
   }
   return(false);
}
bool CalendarNewsBlocked()
{
   if(!InpUseNewsCalendar) return(false);
   if(MQLInfoInteger(MQL_TESTER)) return(false); // no calendar in tester
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - 3 * 3600;
   datetime to   = TimeCurrent() + 3 * 3600;
   if(!CalendarValueHistory(values, from, to, NULL, "USD")) return(false);
   for(int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      string name = ev.name;
      if(StringFind(name, "Nonfarm") < 0 && StringFind(name, "FOMC") < 0) continue;
      // Event time zone is not documented precisely; test both server and GMT clocks.
      datetime evT = values[i].time;
      datetime wFrom = evT - InpNewsBeforeMin * 60;
      datetime wTo   = evT + InpNewsAfterMin * 60;
      if((TimeCurrent() >= wFrom && TimeCurrent() <= wTo) ||
         (TimeGMT()     >= wFrom && TimeGMT()     <= wTo))
         return(true);
   }
   return(false);
}
bool IsNewsBlocked()
{
   return(ManualNewsBlocked() || CalendarNewsBlocked());
}

//+------------------------------------------------------------------+
//| Time gates (§4a)                                                 |
//+------------------------------------------------------------------+
bool IsKillZone()
{
   int h = WIBHour();
   if(h >= InpKZLondonStartWIB && h < InpKZLondonEndWIB) return(true);
   if(h >= InpKZNYStartWIB && h < InpKZNYEndWIB) return(true);
   return(false);
}
bool IsFridayAfternoon()
{
   if(!InpAvoidFridayAfternoon) return(false);
   return(WIBDayOfWeek() == 5 && WIBHour() >= InpFridayCutoffWIB);
}

//+------------------------------------------------------------------+
//| Trend & filters (§3)                                             |
//+------------------------------------------------------------------+
// H4 trend: +1 up, -1 down, 0 unclear. EMA 20/30/50 alignment + price vs EMA50.
int TrendH4()
{
   double e20 = EMA_H4(20, 1), e30 = EMA_H4(30, 1), e50 = EMA_H4(50, 1);
   double close = iClose(g_symbol, PERIOD_H4, 1);
   if(e20 == EMPTY_VALUE || e30 == EMPTY_VALUE || e50 == EMPTY_VALUE || close == 0) return(0);
   if(e20 > e30 && e30 > e50 && close > e50) return(1);
   if(e20 < e30 && e30 < e50 && close < e50) return(-1);
   return(0);
}
double ADX_H4()
{
   return(IndVal(hADX_H4, 0, 1));
}
// H1 candle-pattern confirmation (§3d). shift = last closed bar index.
bool BullishPattern(int shift)
{
   double o1 = iOpen(g_symbol, PERIOD_H1, shift),     c1 = iClose(g_symbol, PERIOD_H1, shift);
   double o2 = iOpen(g_symbol, PERIOD_H1, shift + 1), c2 = iClose(g_symbol, PERIOD_H1, shift + 1);
   double o3 = iOpen(g_symbol, PERIOD_H1, shift + 2), c3 = iClose(g_symbol, PERIOD_H1, shift + 2);
   double h1 = iHigh(g_symbol, PERIOD_H1, shift),     l1 = iLow(g_symbol, PERIOD_H1, shift);
   double l2 = iLow(g_symbol, PERIOD_H1, shift + 1);
   double atr = IndVal(hATR_H1, 0, shift);
   if(atr == EMPTY_VALUE || atr <= 0) atr = (h1 - l1);
   double b1 = MathAbs(c1 - o1);
   // engulfing
   if(c2 < o2 && c1 > o1 && o1 <= c2 && c1 >= o2) return(true);
   // hammer: long lower wick, small upper wick, bullish body
   if(c1 > o1 && b1 > 0 && (MathMin(o1, c1) - l1) >= 2 * b1 && (h1 - MathMax(o1, c1)) <= 0.3 * b1) return(true);
   // harami (bullish inside bearish)
   if(c2 < o2 && c1 > o1 && o1 > c2 && c1 < o2) return(true);
   // morning star
   if(c3 < o3 && b1 > 0 && c1 > o1 && c1 > (o3 + c3) / 2.0 && MathAbs(c2 - o2) <= 0.3 * MathAbs(c3 - o3)) return(true);
   // tweezer bottom: similar lows, second candle bullish
   if(c1 > o1 && MathAbs(l1 - l2) <= 0.1 * atr && c2 < o2) return(true);
   return(false);
}
bool BearishPattern(int shift)
{
   double o1 = iOpen(g_symbol, PERIOD_H1, shift),     c1 = iClose(g_symbol, PERIOD_H1, shift);
   double o2 = iOpen(g_symbol, PERIOD_H1, shift + 1), c2 = iClose(g_symbol, PERIOD_H1, shift + 1);
   double o3 = iOpen(g_symbol, PERIOD_H1, shift + 2), c3 = iClose(g_symbol, PERIOD_H1, shift + 2);
   double h1 = iHigh(g_symbol, PERIOD_H1, shift),     l1 = iLow(g_symbol, PERIOD_H1, shift);
   double h2 = iHigh(g_symbol, PERIOD_H1, shift + 1);
   double atr = IndVal(hATR_H1, 0, shift);
   if(atr == EMPTY_VALUE || atr <= 0) atr = (h1 - l1);
   double b1 = MathAbs(c1 - o1);
   // engulfing
   if(c2 > o2 && c1 < o1 && o1 >= c2 && c1 <= o2) return(true);
   // shooting star / inverted hammer: long upper wick, small lower wick, bearish body
   if(c1 < o1 && b1 > 0 && (h1 - MathMax(o1, c1)) >= 2 * b1 && (MathMin(o1, c1) - l1) <= 0.3 * b1) return(true);
   // harami (bearish inside bullish)
   if(c2 > o2 && c1 < o1 && o1 < c2 && c1 > o2) return(true);
   // evening star
   if(c3 > o3 && b1 > 0 && c1 < o1 && c1 < (o3 + c3) / 2.0 && MathAbs(c2 - o2) <= 0.3 * MathAbs(c3 - o3)) return(true);
   // tweezer top: similar highs, second candle bearish
   if(c1 < o1 && MathAbs(h1 - h2) <= 0.1 * atr && c2 > o2) return(true);
   return(false);
}
// Common filter stack for a direction (+1 long / -1 short). Returns false with reason.
bool FiltersOK(int dir, string &reason)
{
   int trend = TrendH4();
   if(trend != dir) { reason = "H4 trend disagrees"; return(false); }
   if(InpADXMin > 0)
   {
      double adx = ADX_H4();
      if(adx == EMPTY_VALUE) { reason = "ADX unavailable"; return(false); }
      if(adx < InpADXMin) { reason = "ADX below threshold"; return(false); }
   }
   if(InpUseRSIFilter)
   {
      double rsiH1 = IndVal(hRSI_H1, 0, 1), rsiH4 = IndVal(hRSI_H4, 0, 1);
      if(rsiH1 == EMPTY_VALUE || rsiH4 == EMPTY_VALUE) { reason = "RSI unavailable"; return(false); }
      if(dir == 1 && (rsiH1 <= 50 || rsiH4 <= 50)) { reason = "RSI H1/H4 disagree (long)"; return(false); }
      if(dir == -1 && (rsiH1 >= 50 || rsiH4 >= 50)) { reason = "RSI H1/H4 disagree (short)"; return(false); }
   }
   if(InpUseBBMAFilter)
   {
      double e50 = EMA_H1(50, 1);
      double bbMid = IndVal(hBB_H1, 0, 1);
      double close = iClose(g_symbol, PERIOD_H1, 1);
      if(e50 == EMPTY_VALUE || bbMid == EMPTY_VALUE) { reason = "BBMA unavailable"; return(false); }
      if(dir == 1 && !(close > e50 && close > bbMid)) { reason = "BBMA disagrees (long)"; return(false); }
      if(dir == -1 && !(close < e50 && close < bbMid)) { reason = "BBMA disagrees (short)"; return(false); }
   }
   if(InpRequireH1Pattern)
   {
      bool ok = (dir == 1) ? BullishPattern(1) : BearishPattern(1);
      if(!ok) { reason = "No H1 pattern confirmation"; return(false); }
   }
   // Expected daily range (ATR D1) must clear the minimum (§3g).
   double atrD1 = IndVal(hATR_D1, 0, 1);
   if(atrD1 == EMPTY_VALUE) { reason = "ATR D1 unavailable"; return(false); }
   if(atrD1 < InpMinDailyRangeUSD) { reason = "Daily ATR below minimum"; return(false); }
   return(true);
}

//+------------------------------------------------------------------+
//| Position / order counting (our magic + symbol only)              |
//+------------------------------------------------------------------+
int CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      n++;
   }
   return(n);
}
int CountPending()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      n++;
   }
   return(n);
}
bool KeyUsed(string key)
{
   for(int i = 0; i < ArraySize(g_usedKeys); i++)
      if(g_usedKeys[i] == key) return(true);
   return(false);
}
void MarkUsed(string key)
{
   if(KeyUsed(key)) return;
   int n = ArraySize(g_usedKeys);
   if(n > 200) // cap: drop oldest
   {
      for(int i = 0; i < n - 1; i++) g_usedKeys[i] = g_usedKeys[i + 1];
      g_usedKeys[n - 1] = key;
      return;
   }
   ArrayResize(g_usedKeys, n + 1);
   g_usedKeys[n] = key;
}
string SetupKey(string route, int dir, datetime barTime)
{
   return(StringFormat("%s%d|%I64d", route, dir, (long)barTime));
}

//+------------------------------------------------------------------+
//| Master gates (§5 + §4). No new trade unless ALL pass.            |
//+------------------------------------------------------------------+
bool GatesOK(string &reason)
{
   if(CountPositions() > 0) { reason = "position already open"; return(false); }
   if(CountPending() > 0)   { reason = "pending order already placed"; return(false); }
   if(IsNewsBlocked())      { reason = "NFP/FOMC no-trade window"; return(false); }
   if(InpTradeOnlyInKillZone && !IsKillZone()) { reason = "outside kill-zone hours"; return(false); }
   if(IsFridayAfternoon())  { reason = "Friday afternoon — no trade"; return(false); }
   if(SpreadUSD() > InpMaxSpreadUSD) { reason = "spread too wide"; return(false); }
   double realized = RealizedToday();
   if(g_dayStartEquity > 0)
   {
      if(realized <= -InpMaxDailyLossPct / 100.0 * g_dayStartEquity)
         { reason = "max daily loss hit"; return(false); }
      if(InpDailyTargetPct > 0 && realized >= InpDailyTargetPct / 100.0 * g_dayStartEquity)
         { reason = "daily target reached"; return(false); }
   }
   if(ConsecLossesToday() >= InpMaxConsecLoss)
      { reason = "consecutive-loss stop"; return(false); }
   if(InpMaxDrawdownPct > 0 && g_equityPeak > 0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity < g_equityPeak * (1.0 - InpMaxDrawdownPct / 100.0))
         { reason = "max drawdown hit"; return(false); }
   }
   if(InpUseHeartbeat)
   {
      if(!GlobalVariableCheck(InpHeartbeatGV)) { reason = "heartbeat missing (kill-switch)"; return(false); }
      double hb = GlobalVariableGet(InpHeartbeatGV);
      if(TimeCurrent() - (datetime)hb > InpHeartbeatMaxAgeSec)
         { reason = "heartbeat stale (kill-switch)"; return(false); }
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Pending-order placement (§6): SL/TP fixed BEFORE entry, order   |
//| expires at end of the WIB day, single position at a time.        |
//+------------------------------------------------------------------+
bool PlacePendingOrder(ENUM_ORDER_TYPE type, double price, double sl, double tp,
                       string route, string key)
{
   string reason;
   if(!GatesOK(reason))
   {
      PrintFormat("AutoTrade: gates blocked %s %s — %s", route, key, reason);
      return(false);
   }
   int dir = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT) ? 1 : -1;
   price = NormPrice(price); sl = NormPrice(sl); tp = NormPrice(tp);
   if(!CheckStopsLevel(price, sl, tp))
   {
      PrintFormat("AutoTrade: stops level violated %s %s", route, key);
      MarkUsed(key);
      return(false);
   }
   double slDist = MathAbs(price - sl);
   double lots = CalcLot(slDist);
   if(lots < g_volMin)
   {
      double riskAtMin = MinLotRiskPct(slDist);
      if(InpMinLotRiskCapPct > 0 && riskAtMin <= InpMinLotRiskCapPct)
      {
         lots = g_volMin;
         PrintFormat("AutoTrade: min-lot override %s %s — risk %.2f%% (cap %.2f%%)", route, key, riskAtMin, InpMinLotRiskCapPct);
      }
      else
      {
         PrintFormat("AutoTrade: SKIP %s %s — computed lot %.4f < min %.2f (risk at min %.2f%% of equity; account too small for 1%% risk at this SL)", route, key, lots, g_volMin, riskAtMin);
         MarkUsed(key);
         return(false);
      }
   }
   if(lots > g_volMax) lots = g_volMax;
   // margin check
   double margin = 0.0;
   ENUM_ORDER_TYPE mtype = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(mtype, g_symbol, lots, price, margin) || margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      PrintFormat("AutoTrade: insufficient free margin %s %s", route, key);
      MarkUsed(key);
      return(false);
   }
   // expiration: end of WIB day (23:59 WIB) converted to server time
   datetime expiry = WIBShiftedToServer(WIBDayStartShifted() + 23 * 3600 + 59 * 60);
   string comment = route + "|" + key;
   if(StringLen(comment) > 31) comment = StringSubstr(comment, 0, 31);
   bool ok = false;
   switch(type)
   {
      case ORDER_TYPE_BUY_STOP:  ok = g_trade.BuyStop(lots, price, g_symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, comment); break;
      case ORDER_TYPE_SELL_STOP: ok = g_trade.SellStop(lots, price, g_symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, comment); break;
      case ORDER_TYPE_BUY_LIMIT: ok = g_trade.BuyLimit(lots, price, g_symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, comment); break;
      case ORDER_TYPE_SELL_LIMIT: ok = g_trade.SellLimit(lots, price, g_symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, comment); break;
      default: break;
   }
   if(ok)
   {
      MarkUsed(key);
      PrintFormat("AutoTrade: PLACED %s %s type=%d lot=%.2f entry=%.2f SL=%.2f TP=%.2f order=%I64u",
                  route, key, (int)type, lots, price, sl, tp, g_trade.ResultOrder());
      return(true);
   }
   PrintFormat("AutoTrade: OrderSend FAILED %s %s retcode=%d %s", route, key,
               (int)g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   MarkUsed(key);
   return(false);
}

//+------------------------------------------------------------------+
//| Route A — Zona 3-Candle (§1).                                    |
//| Zone = high-low of the H1 candle at 05:00 WIB (06:00 MYT).       |
//| CS1: candle closes out of the zone (body, not wick). CS2: next   |
//| candle same color = confirmation; different color = false        |
//| breakout, setup void for that direction today. Entry = buy/sell  |
//| stop at the zone edge (+buffer). SL outside the opposite edge.   |
//+------------------------------------------------------------------+
bool EvalRouteA()
{
   // zone bar: H1 candle starting 22:00 GMT (= 05:00 WIB) of the current WIB day
   datetime zoneGMT = WIBDayStartShifted() + InpZoneHourWIB * 3600 - 7 * 3600;
   int zb = iBarShift(g_symbol, PERIOD_H1, zoneGMT, true);
   if(zb < 1) return(false); // zone candle not formed yet today
   double zoneHigh = iHigh(g_symbol, PERIOD_H1, zb);
   double zoneLow  = iLow(g_symbol, PERIOD_H1, zb);
   double zoneH = zoneHigh - zoneLow;
   if(zoneH <= 0) return(false);
   double tol = InpBreakTolerancePct / 100.0 * zoneH;
   datetime dayKey = WIBDayStartShifted();
   if(g_aVoidDay != dayKey) { g_aVoidDay = dayKey; g_aVoidDir = 0; }

   // scan H1 bars after the zone bar (index zb-1 .. 1) for the first valid CS1
   for(int j = zb - 1; j >= 2; j--)
   {
      double cj = iClose(g_symbol, PERIOD_H1, j);
      int dir = 0;
      if(cj > zoneHigh + tol) dir = 1;
      else if(cj < zoneLow - tol) dir = -1;
      else continue; // still inside the zone
      if(g_aVoidDir == dir) continue; // this direction already voided today
      // CS2 = next bar (j-1): same color as CS1
      double o2 = iOpen(g_symbol, PERIOD_H1, j - 1), c2 = iClose(g_symbol, PERIOD_H1, j - 1);
      bool sameColor = (dir == 1) ? (c2 > o2) : (c2 < o2);
      if(!sameColor)
      {
         g_aVoidDir = dir; // false breakout — void this direction today
         PrintFormat("AutoTrade: Route A false breakout (dir %d) at %s — voided for today",
                     dir, TimeToString(iTime(g_symbol, PERIOD_H1, j)));
         continue;
      }
      // 2nd-day rule: a later close back inside the zone voids the setup
      bool backInside = false;
      for(int k = j - 1; k >= 1; k--)
      {
         double ck = iClose(g_symbol, PERIOD_H1, k);
         if(dir == 1 && ck < zoneHigh - tol) { backInside = true; break; }
         if(dir == -1 && ck > zoneLow + tol) { backInside = true; break; }
      }
      if(backInside) { g_aVoidDir = dir; continue; }
      // freshness: CS2 bar must be recent (no FOMO on a setup that already ran)
      int ageBars = (j - 1) - 1;
      if(ageBars > InpSetupMaxAgeBars) return(false);
      datetime cs2Time = iTime(g_symbol, PERIOD_H1, j - 1);
      string key = SetupKey("A", dir, cs2Time);
      if(KeyUsed(key)) return(false);
      string reason;
      if(!FiltersOK(dir, reason))
      {
         PrintFormat("AutoTrade: Route A setup %s blocked by filter — %s", key, reason);
         return(false);
      }
      double rr = MathMax(InpRRTarget, 2.0);
      double entry, sl, tp;
      if(dir == 1)
      {
         entry = NudgeOffRound(zoneHigh + InpEntryBufferUSD, true);
         sl    = NormPrice(zoneLow - InpSLBufferUSD);
         tp    = NormPrice(entry + rr * (entry - sl));
         return(PlacePendingOrder(ORDER_TYPE_BUY_STOP, entry, sl, tp, "A", key));
      }
      else
      {
         entry = NudgeOffRound(zoneLow - InpEntryBufferUSD, false);
         sl    = NormPrice(zoneHigh + InpSLBufferUSD);
         tp    = NormPrice(entry - rr * (sl - entry));
         return(PlacePendingOrder(ORDER_TYPE_SELL_STOP, entry, sl, tp, "A", key));
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Route B — FIBO50 (§2).                                           |
//| Last H1 swing: entry = buy/sell limit at Fib 50 of the swing,    |
//| SL below the 61.8% level, TP in 3 tiers (+1R/+2R/+3R, partial    |
//| closes handled by ManagePosition). Pending deleted if untriggered.|
//+------------------------------------------------------------------+
bool IsSwingHigh(int i, int bars)
{
   double h = iHigh(g_symbol, PERIOD_H1, i);
   for(int k = 1; k <= bars; k++)
      if(iHigh(g_symbol, PERIOD_H1, i + k) >= h || iHigh(g_symbol, PERIOD_H1, i - k) >= h) return(false);
   return(true);
}
bool IsSwingLow(int i, int bars)
{
   double l = iLow(g_symbol, PERIOD_H1, i);
   for(int k = 1; k <= bars; k++)
      if(iLow(g_symbol, PERIOD_H1, i + k) <= l || iLow(g_symbol, PERIOD_H1, i - k) <= l) return(false);
   return(true);
}
bool EvalRouteB()
{
   int shBar = -1, slBar = -1;
   for(int i = 1; i <= 60; i++)
   {
      if(shBar < 0 && IsSwingHigh(i, InpSwingBars)) shBar = i;
      if(slBar < 0 && IsSwingLow(i, InpSwingBars)) slBar = i;
      if(shBar > 0 && slBar > 0) break;
   }
   if(shBar < 0 || slBar < 0) return(false);
   double sh = iHigh(g_symbol, PERIOD_H1, shBar);
   double slw = iLow(g_symbol, PERIOD_H1, slBar);
   double range = sh - slw;
   if(range < InpMinSwingUSD) return(false);
   double fib50 = (sh + slw) / 2.0;
   double fib618 = sh - 0.618 * range; // 61.8% retracement level (from the high)
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double rr = MathMax(InpRRTarget, 2.0);
   // Uptrend pullback: swing high formed first, then swing low (retracement).
   if(shBar > slBar)
   {
      if(bid <= fib50) return(false); // already at/below Fib 50 — setup stale
      string key = SetupKey("B", 1, iTime(g_symbol, PERIOD_H1, shBar));
      if(KeyUsed(key)) return(false);
      string reason;
      if(!FiltersOK(1, reason))
      {
         PrintFormat("AutoTrade: Route B setup %s blocked by filter — %s", key, reason);
         return(false);
      }
      double entry = NormPrice(fib50);
      double sl = NormPrice(fib618 - InpSLBufferUSD);
      if(entry - sl <= 0) return(false);
      double tp = NormPrice(entry + rr * (entry - sl)); // TP3 (+3R); tiers managed in ManagePosition
      return(PlacePendingOrder(ORDER_TYPE_BUY_LIMIT, entry, sl, tp, "B", key));
   }
   // Downtrend pullback: swing low first, then swing high.
   if(slBar > shBar)
   {
      if(ask >= fib50) return(false);
      string key = SetupKey("B", -1, iTime(g_symbol, PERIOD_H1, slBar));
      if(KeyUsed(key)) return(false);
      string reason;
      if(!FiltersOK(-1, reason))
      {
         PrintFormat("AutoTrade: Route B setup %s blocked by filter — %s", key, reason);
         return(false);
      }
      double fib618s = slw + 0.618 * range;
      double entry = NormPrice(fib50);
      double sl = NormPrice(fib618s + InpSLBufferUSD);
      if(sl - entry <= 0) return(false);
      double tp = NormPrice(entry - rr * (sl - entry));
      return(PlacePendingOrder(ORDER_TYPE_SELL_LIMIT, entry, sl, tp, "B", key));
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Route C — SMC Kill Zone (§2).                                    |
//| Impulse (body >= N x ATR) that breaks structure by body close    |
//| (BOS). Order block = last opposite candle before the impulse.    |
//| Entry = limit at OB midpoint (discount/premium). SL just outside |
//| the OB. TP at the Fib extension (261.8/423.6), RR >= 2 required.|
//+------------------------------------------------------------------+
bool EvalRouteC()
{
   double atr = IndVal(hATR_H1, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return(false);
   for(int i = 1; i <= 30; i++)
   {
      double o = iOpen(g_symbol, PERIOD_H1, i), c = iClose(g_symbol, PERIOD_H1, i);
      double h = iHigh(g_symbol, PERIOD_H1, i), l = iLow(g_symbol, PERIOD_H1, i);
      double body = MathAbs(c - o);
      if(body < InpImpulseMinATR * atr) continue;
      int dir = (c > o) ? 1 : -1;
      // BOS: body close beyond the recent swing (10 bars before the impulse)
      double refHigh = -DBL_MAX, refLow = DBL_MAX;
      for(int k = i + 1; k <= i + 10; k++)
      {
         refHigh = MathMax(refHigh, iHigh(g_symbol, PERIOD_H1, k));
         refLow  = MathMin(refLow,  iLow(g_symbol, PERIOD_H1, k));
      }
      bool bos = (dir == 1) ? (c > refHigh) : (c < refLow);
      if(!bos) continue;
      // Order block: last opposite-direction candle before the impulse
      int obBar = -1;
      for(int k = i + 1; k <= i + 3; k++)
      {
         double ck = iClose(g_symbol, PERIOD_H1, k), ok2 = iOpen(g_symbol, PERIOD_H1, k);
         if((dir == 1 && ck < ok2) || (dir == -1 && ck > ok2)) { obBar = k; break; }
      }
      if(obBar < 0) obBar = i + 1; // fall back to the candle right before the impulse
      double obHigh = iHigh(g_symbol, PERIOD_H1, obBar);
      double obLow  = iLow(g_symbol, PERIOD_H1, obBar);
      double obMid  = (obHigh + obLow) / 2.0;
      double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      // freshness: impulse must be recent
      if(i - 1 > InpSetupMaxAgeBars) return(false);
      string key = SetupKey("C", dir, iTime(g_symbol, PERIOD_H1, i));
      if(KeyUsed(key)) return(false);
      string reason;
      if(!FiltersOK(dir, reason))
      {
         PrintFormat("AutoTrade: Route C setup %s blocked by filter — %s", key, reason);
         return(false);
      }
      if(dir == 1)
      {
         if(bid <= obMid) return(false); // price already inside/below the OB — stale
         double entry = NormPrice(obMid);
         double sl = NormPrice(obLow - InpSLBufferUSD);
         if(entry - sl <= 0) return(false);
         double leg = h - obLow;
         double tp = NormPrice(obLow + (InpSMC_TPExt / 100.0) * leg);
         double rr = (tp - entry) / (entry - sl);
         if(rr < 2.0)
         {
            PrintFormat("AutoTrade: Route C setup %s skipped — extension RR %.2f < 2.0", key, rr);
            MarkUsed(key);
            return(false);
         }
         return(PlacePendingOrder(ORDER_TYPE_BUY_LIMIT, entry, sl, tp, "C", key));
      }
      else
      {
         if(ask >= obMid) return(false);
         double entry = NormPrice(obMid);
         double sl = NormPrice(obHigh + InpSLBufferUSD);
         if(sl - entry <= 0) return(false);
         double leg = obHigh - l;
         double tp = NormPrice(obHigh - (InpSMC_TPExt / 100.0) * leg);
         double rr = (entry - tp) / (sl - entry);
         if(rr < 2.0)
         {
            PrintFormat("AutoTrade: Route C setup %s skipped — extension RR %.2f < 2.0", key, rr);
            MarkUsed(key);
            return(false);
         }
         return(PlacePendingOrder(ORDER_TYPE_SELL_LIMIT, entry, sl, tp, "C", key));
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Position management (§5b): BE trailing after +1R, FIBO50 partial |
//| TPs, max holding time. SL/TP are NEVER moved after entry except   |
//| the pre-defined +1R breakeven trailing.                          |
//+------------------------------------------------------------------+
string GVName(string base, ulong ticket)
{
   return(StringFormat("AT_%s_%I64u", base, ticket));
}
bool TicketSeen(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_seenTickets); i++)
      if(g_seenTickets[i] == ticket) return(true);
   return(false);
}
void MarkTicketSeen(ulong ticket)
{
   int n = ArraySize(g_seenTickets);
   ArrayResize(g_seenTickets, n + 1);
   g_seenTickets[n] = ticket;
}
void ManagePosition()
{
   ulong ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      ticket = t;
      break;
   }
   if(ticket == 0)
   {
      if(ArraySize(g_seenTickets) > 0) ArrayResize(g_seenTickets, 0);
      return;
   }
   // (re)select our position
   if(!PositionSelectByTicket(ticket)) return;
   long type = PositionGetInteger(POSITION_TYPE);
   bool isBuy = (type == POSITION_TYPE_BUY);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   double bid   = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   string comment = PositionGetString(POSITION_COMMENT);
   string route = (StringLen(comment) > 0) ? StringSubstr(comment, 0, 1) : "?";

   // First sight: register initial risk (R) and original volume.
   if(!TicketSeen(ticket))
   {
      MarkTicketSeen(ticket);
      double rDist = MathAbs(entry - sl);
      if(rDist <= 0 && tp > 0)
         rDist = MathAbs(tp - entry) / MathMax(InpRRTarget, 2.0); // SL already at BE (EA restart)
      GlobalVariableSet(GVName("R", ticket), rDist);
      GlobalVariableSet(GVName("vol", ticket), vol);
      GlobalVariableSet(GVName("tier", ticket), 1.0);
      GlobalVariableSet(GVName("route", ticket), (route == "A") ? 1.0 : (route == "B") ? 2.0 : (route == "C") ? 3.0 : 0.0);
      PrintFormat("AutoTrade: position %I64u registered route=%s entry=%.2f SL=%.2f TP=%.2f R=%.2f vol=%.2f",
                  ticket, route, entry, sl, tp, rDist, vol);
   }
   double R = GlobalVariableCheck(GVName("R", ticket)) ? GlobalVariableGet(GVName("R", ticket)) : 0.0;
   if(R <= 0) return; // cannot compute R — leave the position alone (SL still protects it)
   double price = isBuy ? bid : ask;
   double profitR = isBuy ? (price - entry) / R : (entry - price) / R;

   // Breakeven trailing after +1R (§5a): move SL to entry, once.
   bool slAtBE = isBuy ? (sl >= entry - g_point) : (sl <= entry + g_point);
   if(profitR >= 1.0 && !slAtBE)
   {
      double freezeDist = (double)(g_freezeLevelPts + 2) * g_point;
      if(MathAbs(price - entry) >= freezeDist)
      {
         if(g_trade.PositionModify(ticket, NormPrice(entry), tp))
            PrintFormat("AutoTrade: BE trailing — SL moved to entry %.2f (ticket %I64u, +%.2fR)", entry, ticket, profitR);
         else
            PrintFormat("AutoTrade: BE modify FAILED ticket %I64u retcode=%d", ticket, (int)g_trade.ResultRetcode());
      }
   }
   // FIBO50 tiered TPs (§2): close part at +1R and +2R; the rest runs to TP (+3R).
   if(route == "B")
   {
      double tier = GlobalVariableCheck(GVName("tier", ticket)) ? GlobalVariableGet(GVName("tier", ticket)) : 1.0;
      double origVol = GlobalVariableCheck(GVName("vol", ticket)) ? GlobalVariableGet(GVName("vol", ticket)) : vol;
      if(tier == 1.0 && profitR >= 1.0)
      {
         double closeVol = MathFloor(origVol * InpFiboClose1 / g_volStep) * g_volStep;
         closeVol = NormalizeDouble(closeVol, 2);
         if(closeVol >= g_volMin && vol - closeVol >= g_volMin)
         {
            if(g_trade.PositionClosePartial(ticket, closeVol, (ulong)InpDeviationPts))
            {
               GlobalVariableSet(GVName("tier", ticket), 2.0);
               PrintFormat("AutoTrade: FIBO TP1 +1R — closed %.2f of %.2f (ticket %I64u)", closeVol, origVol, ticket);
            }
         }
         else GlobalVariableSet(GVName("tier", ticket), 2.0);
      }
      else if(tier == 2.0 && profitR >= 2.0)
      {
         double closeVol = MathFloor(origVol * InpFiboClose2 / g_volStep) * g_volStep;
         closeVol = NormalizeDouble(closeVol, 2);
         if(closeVol >= g_volMin && vol - closeVol >= g_volMin)
         {
            if(g_trade.PositionClosePartial(ticket, closeVol, (ulong)InpDeviationPts))
            {
               GlobalVariableSet(GVName("tier", ticket), 3.0);
               PrintFormat("AutoTrade: FIBO TP2 +2R — closed %.2f (ticket %I64u)", closeVol, ticket);
            }
         }
         else GlobalVariableSet(GVName("tier", ticket), 3.0);
      }
   }
   // Max holding time (§5a: 5-10 candles).
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   if(TimeCurrent() - openTime > InpMaxHoldHours * 3600)
   {
      if(g_trade.PositionClose(ticket, (ulong)InpDeviationPts))
         PrintFormat("AutoTrade: max-hold close (ticket %I64u, %.1f h)", ticket, (double)(TimeCurrent() - openTime) / 3600.0);
      else
         PrintFormat("AutoTrade: max-hold close FAILED ticket %I64u retcode=%d", ticket, (int)g_trade.ResultRetcode());
   }
}

// Delete our pending orders from a previous WIB day (safety net —
// orders are also given an end-of-day expiry at placement, §3g/§6).
void ManagePendingCleanup()
{
   datetime today = WIBDayStartShifted();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(WIBDayStartShifted(setup) != today)
      {
         if(g_trade.OrderDelete(ticket))
            PrintFormat("AutoTrade: stale pending deleted (ticket %I64u)", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = InpSymbol;
   if(!SymbolSelect(g_symbol, true))
   {
      PrintFormat("AutoTrade: SymbolSelect failed for %s", g_symbol);
      return(INIT_FAILED);
   }
   if(SymbolInfoDouble(g_symbol, SYMBOL_ASK) <= 0)
   {
      PrintFormat("AutoTrade: no quotes for %s — add it to Market Watch", g_symbol);
      return(INIT_FAILED);
   }
   g_digits       = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   g_point        = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_tickSize     = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue    = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   g_volMin       = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   g_volMax       = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   g_volStep      = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   g_stopsLevelPts  = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevelPts = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(g_tickSize <= 0 || g_tickValue <= 0)
   {
      Print("AutoTrade: tick size/value unavailable — cannot size positions");
      return(INIT_FAILED);
   }
   hEMA20H4 = iMA(g_symbol, PERIOD_H4, 20, 0, MODE_EMA, PRICE_CLOSE);
   hEMA30H4 = iMA(g_symbol, PERIOD_H4, 30, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50H4 = iMA(g_symbol, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
   hEMA5H1  = iMA(g_symbol, PERIOD_H1, 5, 0, MODE_EMA, PRICE_CLOSE);
   hEMA20H1 = iMA(g_symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
   hEMA55H1 = iMA(g_symbol, PERIOD_H1, 55, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50H1 = iMA(g_symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   hADX_H4  = iADX(g_symbol, PERIOD_H4, 14);
   hRSI_H1  = iRSI(g_symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hRSI_H4  = iRSI(g_symbol, PERIOD_H4, 14, PRICE_CLOSE);
   hBB_H1   = iBands(g_symbol, PERIOD_H1, 20, 0, 2.0, PRICE_CLOSE);
   hATR_H1  = iATR(g_symbol, PERIOD_H1, 14);
   hATR_D1  = iATR(g_symbol, PERIOD_D1, 14);
   int handles[13] = {hEMA20H4, hEMA30H4, hEMA50H4, hEMA5H1, hEMA20H1, hEMA55H1, hEMA50H1,
                      hADX_H4, hRSI_H1, hRSI_H4, hBB_H1, hATR_H1, hATR_D1};
   for(int i = 0; i < 13; i++)
   {
      if(handles[i] == INVALID_HANDLE)
      {
         PrintFormat("AutoTrade: indicator handle %d failed", i);
         return(INIT_FAILED);
      }
   }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPts);
   g_trade.SetTypeFillingBySymbol(g_symbol);
   if(InpRRTarget < 2.0)
      Print("AutoTrade: WARNING InpRRTarget < 2.0 — clamped to 2.0 at use (spec: RR min 1:2)");
   UpdateDailyStats();
   PrintFormat("AutoTrade v1.00 init OK — symbol=%s digits=%d point=%.5f tick=%.5f/%.2f vol %.2f-%.2f/%.2f magic=%I64d risk=%.1f%% RR=%.1f",
               g_symbol, g_digits, g_point, g_tickSize, g_tickValue, g_volMin, g_volMax, g_volStep,
               InpMagic, InpRiskPct, MathMax(InpRRTarget, 2.0));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   int handles[13] = {hEMA20H4, hEMA30H4, hEMA50H4, hEMA5H1, hEMA20H1, hEMA55H1, hEMA50H1,
                      hADX_H4, hRSI_H1, hRSI_H4, hBB_H1, hATR_H1, hATR_D1};
   for(int i = 0; i < 13; i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
}

//+------------------------------------------------------------------+
//| OnTick: manage open positions every tick; evaluate signals once  |
//| per new M5 bar. First route that triggers wins (max 1 position, |
//| max 1 pending order — §2/§5b).                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   ManagePosition();
   ManagePendingCleanup();

   static datetime lastBar = 0;
   datetime curBar = iTime(g_symbol, PERIOD_M5, 0);
   if(curBar == lastBar) return;
   lastBar = curBar;

   UpdateDailyStats();
   if(CountPositions() > 0 || CountPending() > 0) return;

   string reason;
   if(!GatesOK(reason)) return; // silent per-bar; PlacePendingOrder logs the reason when a setup exists

   if(InpUseRouteA && EvalRouteA()) return;
   if(InpUseRouteB && EvalRouteB()) return;
   if(InpUseRouteC && EvalRouteC()) return;
}
//+------------------------------------------------------------------+
