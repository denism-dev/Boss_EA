//+------------------------------------------------------------------+
//|              MasterBOSTradeQualityTracker_v1_08_M5ConfluenceLab.mq5              |
//| Non-trading quality tracker for Master BOS Supply Demand v1.08 StableZones   |
//| Measures raw BOS/retest signals; NEVER places or manages orders. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.08"
#property description "Non-trading trade-quality tracker for Master BOS Supply Demand v1.08 StableZones."

//============================== INPUTS ===============================
// The indicator must already be attached to the SAME chart.
input string AttachedIndicatorShortName = "Master BOS Supply Demand v1.08 StableZones";

// v1.05 indicator buffer contract.
input int BuySignalBufferIndex       = 0;
input int SellSignalBufferIndex      = 1;
input int SignalZoneLowBufferIndex   = 2;
input int SignalZoneHighBufferIndex  = 3;
input int SignalZoneIdBufferIndex    = 9;
input int BuyEntryPriceBufferIndex   = 10;
input int SellEntryPriceBufferIndex  = 11;

// Entry model.
// false = exact confirmation-candle close stored by the indicator.
// true  = market price on the first tracker tick after detection
//         (BUY ask / SELL bid). Keep false while measuring signal quality.
input bool UseNextTickMarketEntry    = false;

// Virtual trade rules.
input double StopBufferPips          = 1.0;
input double FallbackStopPips        = 15.0;
input int    TimeoutBars             = 12;   // 12 M15 bars = 3 hours

input double Target5Pips             = 5.0;
input double Target6Pips             = 6.0;
input double Target8Pips             = 8.0;
input double Target10Pips            = 10.0;

//======================== M5 CONFLUENCE LAB =========================
// DIAGNOSTICS ONLY: none of these fields block a v1.08 signal.
// We first collect evidence, then decide later which deserve filters.
input bool   EnableM5ConfluenceDiagnostics = true;

input int    TrendFastEMA              = 9;
input int    TrendSlowEMA              = 21;

// M5 velocity = signal-side body size relative to average absolute body
// of the prior bars.
input int    VelocityLookbackBars       = 20;
input double StrongVelocityMultiple     = 1.50;
input double MediumVelocityMultiple     = 1.00;

// Tick-volume spike relative to the prior M5 average.
// Spot-FX volume is broker tick volume, not centralized exchange volume.
input int    VolumeLookbackBars         = 20;
input double VolumeSpikeMultiple        = 1.50;

// Tick-volume VWAP proxy, anchored to broker/server midnight.
input bool   UseDailyTickVWAP           = true;

// Previous-day fakeout diagnostic: look back this many CLOSED M5 bars.
// BUY: sweep below previous-day low then close back above it.
// SELL: sweep above previous-day high then close back below it.
input int    PrevDayFakeoutLookbackM5   = 6;

// Configurable 15-minute opening range in BROKER/SERVER time.
// Defaults are intentionally inputs because FX has no universal open.
input int    OpeningRangeStartHour      = 7;
input int    OpeningRangeStartMinute    = 0;
input int    OpeningRangeMinutes        = 15;

// Session diagnostics only; never filters signals.
input bool EnableSessionDiagnostics  = true;
input int  AsiaStartUTC              = 0;
input int  AsiaEndUTC                = 8;
input int  LondonStartUTC            = 7;
input int  LondonEndUTC              = 16;
input int  NewYorkStartUTC           = 12;
input int  NewYorkEndUTC             = 21;

// Logging.
input bool   EnableCSVLogging         = true;
input bool   LogToCommonFolder        = true;
input string SignalEventsFileName     = "MasterBOS_v1_08_M5Confluence_Signals.csv";
input string ResultsFileName          = "MasterBOS_v1_08_M5Confluence_Results.csv";

// Display/storage.
input bool ShowDashboard              = true;
input int  MaxStoredSignals           = 500; // cap on CONCURRENT active signals, not lifetime total

//============================= STRUCTS ===============================
struct VirtualSignal
{
   bool     active;
   long     id;
   int      direction; // +1 BUY, -1 SELL

   datetime signal_bar_time;
   datetime detected_time;

   long     zone_id;
   double   zone_low;
   double   zone_high;
   double   zone_width_pips;

   double   signal_close;
   double   entry_price;
   double   spread_pips;
   double   edge_clearance_pips;

   double   stop_price;
   double   risk_pips;

   double   tp5_price;
   double   tp6_price;
   double   tp8_price;
   double   tp10_price;

   double   tp1r_price;
   double   tp15r_price;
   double   tp2r_price;

   int      outcome_5p;   // 1 win, -1 loss, 0 unresolved=>timeout
   int      outcome_6p;
   int      outcome_8p;
   int      outcome_10p;
   int      outcome_1r;
   int      outcome_15r;
   int      outcome_2r;

   datetime hit_5p_time;
   datetime hit_6p_time;
   datetime hit_8p_time;
   datetime hit_10p_time;
   datetime hit_1r_time;
   datetime hit_15r_time;
   datetime hit_2r_time;
   datetime stop_time;

   double   mfe_pips;
   double   mae_pips;

   double   exit_price;
   double   exit_pl_pips;
   double   timeout_pl_pips;
   int      bars_held;
   datetime last_counted_bar;

   string   session_label;
   int      utc_hour;
   int      server_hour;
   double   server_utc_offset_hours;

   // v1.08 / M5 confluence snapshot at entry.
   string   bos_structure;
   string   proper_retest;
   string   m15_trend;
   string   h1_trend;
   string   ema_9_21;
   string   vwap_status;
   string   volume_spike;
   string   velocity;
   string   prev_day_fakeout;
   string   opening_range_position;

   double   m5_fast_ema;
   double   m5_slow_ema;
   double   m15_fast_ema;
   double   m15_slow_ema;
   double   h1_fast_ema;
   double   h1_slow_ema;
   double   daily_tick_vwap;
   double   volume_ratio;
   double   velocity_ratio;
   double   opening_range_high;
   double   opening_range_low;
   double   prev_day_high;
   double   prev_day_low;

   datetime entry_time;
   double   time_to_5p_minutes;
};

VirtualSignal g_signals[];

//============================= GLOBALS ===============================
int      g_indicator_handle = INVALID_HANDLE;
long     g_next_id = 1;
datetime g_last_chart_bar_time = 0;

// Trend/confluence handles.
int g_m5_fast_ema_handle  = INVALID_HANDLE;
int g_m5_slow_ema_handle  = INVALID_HANDLE;
int g_m15_fast_ema_handle = INVALID_HANDLE;
int g_m15_slow_ema_handle = INVALID_HANDLE;
int g_h1_fast_ema_handle  = INVALID_HANDLE;
int g_h1_slow_ema_handle  = INVALID_HANDLE;

string g_prefix = "MBOSTQ108M5_";
string g_last_buy_gv = "";
string g_last_sell_gv = "";

// Finalized (inactive) signals accumulate in g_signals between prune
// passes; this counts how many are waiting so OnTick only pays for a
// compaction when there is actually something to drop.
int g_finalized_since_prune = 0;

// Completed summary.
int g_completed = 0;
int g_buy_completed = 0;
int g_sell_completed = 0;

int g_stop_exits = 0;
int g_timeout_exits = 0;

int g_5p_wins = 0,  g_5p_losses = 0,  g_5p_timeouts = 0;
int g_6p_wins = 0,  g_6p_losses = 0,  g_6p_timeouts = 0;
int g_8p_wins = 0,  g_8p_losses = 0,  g_8p_timeouts = 0;
int g_10p_wins = 0, g_10p_losses = 0, g_10p_timeouts = 0;

int g_1r_wins = 0,  g_1r_losses = 0,  g_1r_timeouts = 0;
int g_15r_wins = 0, g_15r_losses = 0, g_15r_timeouts = 0;
int g_2r_wins = 0,  g_2r_losses = 0,  g_2r_timeouts = 0;

int g_zero_mfe_completed = 0;
int g_zero_mfe_stops = 0;

double g_sum_mfe = 0.0;
double g_sum_mae = 0.0;
double g_sum_risk = 0.0;
double g_sum_final_pl = 0.0;

//============================= HELPERS ===============================
double PipSize()
{
   if(_Digits == 3 || _Digits == 5)
      return _Point * 10.0;
   return _Point;
}

string DirectionName(const int direction)
{
   return direction > 0 ? "BUY" : "SELL";
}

string OutcomeName(const int outcome)
{
   if(outcome > 0) return "WIN";
   if(outcome < 0) return "LOSS";
   return "TIMEOUT";
}

bool IsUsableValue(const double value)
{
   if(!MathIsValidNumber(value))
      return false;

   if(value == EMPTY_VALUE)
      return false;

   return true;
}

double CurrentSpreadPips()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return 0.0;

   return (tick.ask - tick.bid) / PipSize();
}

bool HourInWindow(const int hour_value,
                  const int start_hour,
                  const int end_hour)
{
   if(start_hour == end_hour)
      return true;

   if(start_hour < end_hour)
      return hour_value >= start_hour && hour_value < end_hour;

   return hour_value >= start_hour || hour_value < end_hour;
}

string SessionLabelFromUTC(const int hour_value)
{
   if(!EnableSessionDiagnostics)
      return "OFF";

   const bool asia =
      HourInWindow(hour_value, AsiaStartUTC, AsiaEndUTC);

   const bool london =
      HourInWindow(hour_value, LondonStartUTC, LondonEndUTC);

   const bool ny =
      HourInWindow(hour_value, NewYorkStartUTC, NewYorkEndUTC);

   if(london && ny) return "LONDON_NY_OVERLAP";
   if(london)       return "LONDON";
   if(ny)           return "NEW_YORK";
   if(asia)         return "ASIA";
   return "OFF_SESSION";
}

void FillSessionDiagnostics(VirtualSignal &s)
{
   MqlDateTime server_dt;
   TimeToStruct(TimeTradeServer(), server_dt);
   s.server_hour = server_dt.hour;

   const datetime gmt = TimeGMT();
   MqlDateTime utc_dt;
   TimeToStruct(gmt, utc_dt);
   s.utc_hour = utc_dt.hour;

   s.server_utc_offset_hours =
      (double)(TimeTradeServer() - gmt) / 3600.0;

   s.session_label = SessionLabelFromUTC(s.utc_hour);
}

int ActiveCount()
{
   int total = 0;
   for(int i=0; i<ArraySize(g_signals); i++)
      if(g_signals[i].active)
         total++;
   return total;
}

bool HasStorageRoom()
{
   if(MaxStoredSignals <= 0)
      return true;

   // Cap concurrently ACTIVE signals, not lifetime signals ever created.
   // Finalized signals are pruned out of g_signals shortly after they
   // complete (see PruneCompletedSignals), so ArraySize() alone would
   // otherwise permanently lock out new signals once enough had ever
   // fired, regardless of how many were still open.
   return ActiveCount() < MaxStoredSignals;
}

// Drops finalized (inactive) signals from g_signals. Their CSV row was
// already written by LogCompletedResult at the moment they finalized, so
// nothing is lost - this just stops the array growing without bound over
// a long-running session and keeps HasStorageRoom()'s cap meaningful.
void PruneCompletedSignals()
{
   const int total = ArraySize(g_signals);
   int write = 0;

   for(int read=0; read<total; read++)
   {
      if(!g_signals[read].active)
         continue;

      if(write != read)
         g_signals[write] = g_signals[read];
      write++;
   }

   if(write < total)
      ArrayResize(g_signals, write);
}

//============================= INDICATOR =============================
bool ReadBufferValue(const int buffer,
                     const int shift,
                     double &value)
{
   value = EMPTY_VALUE;

   if(g_indicator_handle == INVALID_HANDLE)
      return false;

   double data[1];
   ResetLastError();

   if(CopyBuffer(g_indicator_handle, buffer, shift, 1, data) != 1)
      return false;

   if(!IsUsableValue(data[0]))
      return false;

   value = data[0];
   return true;
}

double SafeBuffer(const int buffer,
                  const int shift,
                  const double fallback)
{
   double value = 0.0;
   if(ReadBufferValue(buffer, shift, value))
      return value;
   return fallback;
}

bool TryAttachedIndicator()
{
   ResetLastError();

   const int handle =
      ChartIndicatorGet(
         ChartID(),
         0,
         AttachedIndicatorShortName
      );

   if(handle == INVALID_HANDLE)
      return false;

   g_indicator_handle = handle;

   Print(
      "BOSTracker v1.08 M5Lab: connected to ATTACHED indicator: ",
      AttachedIndicatorShortName
   );

   return true;
}

bool CreateIndicatorHandle()
{
   if(g_indicator_handle != INVALID_HANDLE)
      return true;

   if(TryAttachedIndicator())
      return true;

   Print(
      "BOSTracker v1.08 M5Lab: indicator not found. Attach '",
      AttachedIndicatorShortName,
      "' to this chart first."
   );

   return false;
}


//======================== M5 CONFLUENCE HELPERS =====================
string AlignmentStatus(const int direction,
                       const double fast,
                       const double slow)
{
   if(fast<=0.0 || slow<=0.0)
      return "NA";

   if(direction>0)
      return fast>slow ? "PASS" : "FAIL";

   return fast<slow ? "PASS" : "FAIL";
}

string TrendName(const double fast,const double slow)
{
   if(fast<=0.0 || slow<=0.0)
      return "NA";

   if(fast>slow) return "BULLISH";
   if(fast<slow) return "BEARISH";
   return "FLAT";
}

bool CopyOneIndicatorValue(const int handle,
                           const int shift,
                           double &value)
{
   value=0.0;

   if(handle==INVALID_HANDLE || shift<0)
      return false;

   double data[1];
   if(CopyBuffer(handle,0,shift,1,data)!=1)
      return false;

   if(!MathIsValidNumber(data[0]) || data[0]==EMPTY_VALUE)
      return false;

   value=data[0];
   return true;
}

int ClosedBarShiftAtTime(const ENUM_TIMEFRAMES tf,
                         const datetime entry_time)
{
   if(entry_time<=0)
      return -1;

   const int containing=iBarShift(_Symbol,tf,entry_time-1,false);
   if(containing<0)
      return -1;

   const datetime open_time=iTime(_Symbol,tf,containing);
   const int seconds=PeriodSeconds(tf);

   // If that timeframe candle was already closed by entry_time, use it.
   // Otherwise use the immediately previous fully closed candle.
   if(open_time>0 && seconds>0 && open_time+seconds<=entry_time)
      return containing;

   return containing+1;
}

int LastClosedM5Shift(const datetime entry_time)
{
   return ClosedBarShiftAtTime(PERIOD_M5,entry_time);
}

bool ReadEMAAtTime(const int handle,
                   const ENUM_TIMEFRAMES tf,
                   const datetime entry_time,
                   double &value)
{
   const int shift=ClosedBarShiftAtTime(tf,entry_time);
   return CopyOneIndicatorValue(handle,shift,value);
}

double AveragePriorM5Body(const int signal_shift,const int lookback)
{
   if(signal_shift<0 || lookback<=0)
      return 0.0;

   double sum=0.0;
   int count=0;

   for(int k=1;k<=lookback;k++)
   {
      const int sh=signal_shift+k;
      const double o=iOpen(_Symbol,PERIOD_M5,sh);
      const double c=iClose(_Symbol,PERIOD_M5,sh);

      if(o<=0.0 || c<=0.0)
         continue;

      sum+=MathAbs(c-o);
      count++;
   }

   return count>0 ? sum/count : 0.0;
}

double AveragePriorM5TickVolume(const int signal_shift,const int lookback)
{
   if(signal_shift<0 || lookback<=0)
      return 0.0;

   double sum=0.0;
   int count=0;

   for(int k=1;k<=lookback;k++)
   {
      const long v=iVolume(_Symbol,PERIOD_M5,signal_shift+k);
      if(v<=0)
         continue;

      sum+=(double)v;
      count++;
   }

   return count>0 ? sum/count : 0.0;
}

string VelocityLabel(const int direction,
                     const int m5_shift,
                     double &ratio)
{
   ratio=0.0;

   if(m5_shift<0)
      return "NA";

   const double o=iOpen(_Symbol,PERIOD_M5,m5_shift);
   const double c=iClose(_Symbol,PERIOD_M5,m5_shift);

   if(o<=0.0 || c<=0.0)
      return "NA";

   const bool aligned=
      direction>0 ? c>o : c<o;

   if(!aligned)
      return "WEAK";

   const double avg=
      AveragePriorM5Body(m5_shift,VelocityLookbackBars);

   if(avg<=0.0)
      return "NA";

   ratio=MathAbs(c-o)/avg;

   if(ratio>=StrongVelocityMultiple)
      return "STRONG";

   if(ratio>=MediumVelocityMultiple)
      return "MEDIUM";

   return "WEAK";
}

string VolumeSpikeLabel(const int m5_shift,double &ratio)
{
   ratio=0.0;

   if(m5_shift<0)
      return "NA";

   const long current=iVolume(_Symbol,PERIOD_M5,m5_shift);
   const double avg=
      AveragePriorM5TickVolume(m5_shift,VolumeLookbackBars);

   if(current<=0 || avg<=0.0)
      return "NA";

   ratio=(double)current/avg;
   return ratio>=VolumeSpikeMultiple ? "YES" : "NO";
}

bool PreviousDayLevels(const datetime entry_time,
                       double &prev_high,
                       double &prev_low)
{
   prev_high=0.0;
   prev_low=0.0;

   const int current_d1=iBarShift(_Symbol,PERIOD_D1,entry_time-1,false);
   if(current_d1<0)
      return false;

   const int prev_shift=current_d1+1;
   prev_high=iHigh(_Symbol,PERIOD_D1,prev_shift);
   prev_low=iLow(_Symbol,PERIOD_D1,prev_shift);

   return prev_high>0.0 && prev_low>0.0 && prev_high>prev_low;
}

string PrevDayFakeoutLabel(const int direction,
                           const datetime entry_time,
                           const int last_m5_shift,
                           double &prev_high,
                           double &prev_low)
{
   if(!PreviousDayLevels(entry_time,prev_high,prev_low))
      return "NA";

   if(last_m5_shift<0)
      return "NA";

   const int lookback=MathMax(1,PrevDayFakeoutLookbackM5);

   for(int k=0;k<lookback;k++)
   {
      const int sh=last_m5_shift+k;
      const double h=iHigh(_Symbol,PERIOD_M5,sh);
      const double l=iLow(_Symbol,PERIOD_M5,sh);
      const double c=iClose(_Symbol,PERIOD_M5,sh);

      if(h<=0.0 || l<=0.0 || c<=0.0)
         continue;

      // Diagnostic is directional: SELL likes a failed break above PDH,
      // BUY likes a failed break below PDL.
      if(direction<0 && h>prev_high && c<prev_high)
         return "YES";

      if(direction>0 && l<prev_low && c>prev_low)
         return "YES";
   }

   return "NO";
}

datetime ServerDayStart(const datetime value)
{
   MqlDateTime dt;
   TimeToStruct(value,dt);
   dt.hour=0;
   dt.min=0;
   dt.sec=0;
   return StructToTime(dt);
}

bool CalculateDailyTickVWAP(const datetime entry_time,
                            double &vwap)
{
   vwap=0.0;

   if(!UseDailyTickVWAP || entry_time<=0)
      return false;

   const datetime start=ServerDayStart(entry_time);

   MqlRates rates[];
   const int copied=
      CopyRates(_Symbol,PERIOD_M5,start,entry_time-1,rates);

   if(copied<=0)
      return false;

   double pv=0.0;
   double vol=0.0;

   for(int i=0;i<copied;i++)
   {
      const double typical=
         (rates[i].high+rates[i].low+rates[i].close)/3.0;

      const double v=(double)rates[i].tick_volume;

      if(v<=0.0)
         continue;

      pv+=typical*v;
      vol+=v;
   }

   if(vol<=0.0)
      return false;

   vwap=pv/vol;
   return true;
}

string VWAPStatus(const int direction,
                  const double entry_price,
                  const double vwap)
{
   if(vwap<=0.0)
      return "NA";

   if(direction>0)
      return entry_price>vwap ? "PASS" : "FAIL";

   return entry_price<vwap ? "PASS" : "FAIL";
}

bool BuildOpeningRangeTimes(const datetime entry_time,
                            datetime &range_start,
                            datetime &range_end)
{
   if(entry_time<=0 || OpeningRangeMinutes<=0)
      return false;

   MqlDateTime dt;
   TimeToStruct(entry_time,dt);

   dt.hour=MathMax(0,MathMin(23,OpeningRangeStartHour));
   dt.min=MathMax(0,MathMin(59,OpeningRangeStartMinute));
   dt.sec=0;

   range_start=StructToTime(dt);
   range_end=range_start+OpeningRangeMinutes*60;

   return true;
}

string OpeningRangePosition(const datetime entry_time,
                            const double entry_price,
                            double &range_high,
                            double &range_low)
{
   range_high=0.0;
   range_low=0.0;

   datetime start=0,end=0;
   if(!BuildOpeningRangeTimes(entry_time,start,end))
      return "NA";

   if(entry_time<end)
      return "NOT_READY";

   MqlRates rates[];
   const int copied=CopyRates(_Symbol,PERIOD_M5,start,end-1,rates);

   if(copied<=0)
      return "NA";

   range_high=-DBL_MAX;
   range_low=DBL_MAX;

   for(int i=0;i<copied;i++)
   {
      if(rates[i].high>range_high)
         range_high=rates[i].high;

      if(rates[i].low<range_low)
         range_low=rates[i].low;
   }

   if(range_high<=0.0 || range_low<=0.0 || range_high<=range_low)
      return "NA";

   if(entry_price>range_high) return "ABOVE";
   if(entry_price<range_low)  return "BELOW";
   return "INSIDE";
}

void FillM5ConfluenceDiagnostics(VirtualSignal &s)
{
   // These two PASS fields are guaranteed by the v1.08 signal engine:
   // it only emits after a valid structure break and an armed retest.
   s.bos_structure="PASS";
   s.proper_retest="PASS";

   if(!EnableM5ConfluenceDiagnostics)
   {
      s.m15_trend="OFF";
      s.h1_trend="OFF";
      s.ema_9_21="OFF";
      s.vwap_status="OFF";
      s.volume_spike="OFF";
      s.velocity="OFF";
      s.prev_day_fakeout="OFF";
      s.opening_range_position="OFF";
      return;
   }

   const int m5_shift=LastClosedM5Shift(s.entry_time);

   // M5 EMA 9/21 alignment.
   CopyOneIndicatorValue(g_m5_fast_ema_handle,m5_shift,s.m5_fast_ema);
   CopyOneIndicatorValue(g_m5_slow_ema_handle,m5_shift,s.m5_slow_ema);
   s.ema_9_21=
      AlignmentStatus(s.direction,s.m5_fast_ema,s.m5_slow_ema);

   // M15 anchor trend: use fully closed M15 information at entry.
   ReadEMAAtTime(g_m15_fast_ema_handle,PERIOD_M15,s.entry_time,s.m15_fast_ema);
   ReadEMAAtTime(g_m15_slow_ema_handle,PERIOD_M15,s.entry_time,s.m15_slow_ema);
   s.m15_trend=TrendName(s.m15_fast_ema,s.m15_slow_ema);

   // H1 anchor trend: last fully closed H1 bar only, avoiding look-ahead.
   ReadEMAAtTime(g_h1_fast_ema_handle,PERIOD_H1,s.entry_time,s.h1_fast_ema);
   ReadEMAAtTime(g_h1_slow_ema_handle,PERIOD_H1,s.entry_time,s.h1_slow_ema);
   s.h1_trend=TrendName(s.h1_fast_ema,s.h1_slow_ema);

   s.volume_spike=
      VolumeSpikeLabel(m5_shift,s.volume_ratio);

   s.velocity=
      VelocityLabel(s.direction,m5_shift,s.velocity_ratio);

   if(CalculateDailyTickVWAP(s.entry_time,s.daily_tick_vwap))
      s.vwap_status=
         VWAPStatus(s.direction,s.entry_price,s.daily_tick_vwap);
   else
      s.vwap_status="NA";

   s.prev_day_fakeout=
      PrevDayFakeoutLabel(
         s.direction,
         s.entry_time,
         m5_shift,
         s.prev_day_high,
         s.prev_day_low
      );

   s.opening_range_position=
      OpeningRangePosition(
         s.entry_time,
         s.entry_price,
         s.opening_range_high,
         s.opening_range_low
      );
}

//=============================== CSV ================================
string SanitizeFilePart(string value)
{
   StringReplace(value, "/", "_");
   StringReplace(value, "\\", "_");
   StringReplace(value, ":", "_");
   StringReplace(value, " ", "_");
   return value;
}

string ScopedCsvName(const string filename)
{
   const string symbol = SanitizeFilePart(_Symbol);
   const string tf =
      SanitizeFilePart(EnumToString((ENUM_TIMEFRAMES)_Period));

   const int dot = StringFind(filename, ".csv");

   if(dot >= 0)
      return StringSubstr(filename, 0, dot) +
             "_" + symbol + "_" + tf + ".csv";

   return filename + "_" + symbol + "_" + tf;
}

int OpenCsvAppend(const string filename,
                  const string header)
{
   if(!EnableCSVLogging)
      return INVALID_HANDLE;

   int flags =
      FILE_CSV |
      FILE_READ |
      FILE_WRITE |
      FILE_ANSI |
      FILE_SHARE_READ |
      FILE_SHARE_WRITE;

   if(LogToCommonFolder)
      flags |= FILE_COMMON;

   const string scoped = ScopedCsvName(filename);

   ResetLastError();

   const int handle = FileOpen(scoped, flags, ',');

   if(handle == INVALID_HANDLE)
   {
      Print(
         "BOSTracker CSV open failed: ",
         scoped,
         " err=", GetLastError()
      );
      return INVALID_HANDLE;
   }

   if(FileSize(handle) == 0)
      FileWriteString(handle, header + "\r\n");

   FileSeek(handle, 0, SEEK_END);
   return handle;
}

void LogSignalEvent(const VirtualSignal &s)
{
   const string header =
      "id,symbol,timeframe,direction,signal_bar_time,detected_time,"
      "zone_id,zone_low,zone_high,zone_width_pips,signal_close,"
      "entry_price,spread_pips,edge_clearance_pips,stop_price,risk_pips,"
      "tp5,tp6,tp8,tp10,tp1r,tp15r,tp2r,session,utc_hour,server_hour,"
      "server_utc_offset_hours,bos_structure,proper_retest,m15_trend,h1_trend,"
      "ema_9_21,vwap_status,volume_spike,velocity,prev_day_fakeout,"
      "opening_range_position,m5_fast_ema,m5_slow_ema,m15_fast_ema,m15_slow_ema,"
      "h1_fast_ema,h1_slow_ema,daily_tick_vwap,volume_ratio,velocity_ratio,"
      "opening_range_high,opening_range_low,prev_day_high,prev_day_low";

   const int h = OpenCsvAppend(SignalEventsFileName, header);
   if(h == INVALID_HANDLE)
      return;

   FileWrite(
      h,
      s.id,
      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      DirectionName(s.direction),
      TimeToString(s.signal_bar_time, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
      TimeToString(s.detected_time, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
      s.zone_id,
      DoubleToString(s.zone_low,_Digits),
      DoubleToString(s.zone_high,_Digits),
      DoubleToString(s.zone_width_pips,2),
      DoubleToString(s.signal_close,_Digits),
      DoubleToString(s.entry_price,_Digits),
      DoubleToString(s.spread_pips,2),
      DoubleToString(s.edge_clearance_pips,2),
      DoubleToString(s.stop_price,_Digits),
      DoubleToString(s.risk_pips,2),
      DoubleToString(s.tp5_price,_Digits),
      DoubleToString(s.tp6_price,_Digits),
      DoubleToString(s.tp8_price,_Digits),
      DoubleToString(s.tp10_price,_Digits),
      DoubleToString(s.tp1r_price,_Digits),
      DoubleToString(s.tp15r_price,_Digits),
      DoubleToString(s.tp2r_price,_Digits),
      s.session_label,
      s.utc_hour,
      s.server_hour,
      DoubleToString(s.server_utc_offset_hours,2),
      s.bos_structure,
      s.proper_retest,
      s.m15_trend,
      s.h1_trend,
      s.ema_9_21,
      s.vwap_status,
      s.volume_spike,
      s.velocity,
      s.prev_day_fakeout,
      s.opening_range_position,
      DoubleToString(s.m5_fast_ema,_Digits),
      DoubleToString(s.m5_slow_ema,_Digits),
      DoubleToString(s.m15_fast_ema,_Digits),
      DoubleToString(s.m15_slow_ema,_Digits),
      DoubleToString(s.h1_fast_ema,_Digits),
      DoubleToString(s.h1_slow_ema,_Digits),
      DoubleToString(s.daily_tick_vwap,_Digits),
      DoubleToString(s.volume_ratio,2),
      DoubleToString(s.velocity_ratio,2),
      DoubleToString(s.opening_range_high,_Digits),
      DoubleToString(s.opening_range_low,_Digits),
      DoubleToString(s.prev_day_high,_Digits),
      DoubleToString(s.prev_day_low,_Digits)
   );

   FileClose(h);
}

void LogCompletedResult(const VirtualSignal &s,
                        const string reason,
                        const datetime close_time)
{
   const string header =
      "id,symbol,timeframe,direction,signal_bar_time,close_time,reason,"
      "zone_id,zone_low,zone_high,zone_width_pips,signal_close,entry_price,"
      "spread_pips,edge_clearance_pips,stop_price,risk_pips,"
      "outcome_5p,outcome_6p,outcome_8p,outcome_10p,"
      "outcome_1r,outcome_15r,outcome_2r,mfe_pips,mae_pips,bars_held,"
      "exit_price,exit_pl_pips,timeout_pl_pips,session,"
      "bos_structure,proper_retest,m15_trend,h1_trend,ema_9_21,vwap_status,"
      "volume_spike,velocity,prev_day_fakeout,opening_range_position,"
      "time_to_5p_minutes";

   const int h = OpenCsvAppend(ResultsFileName, header);
   if(h == INVALID_HANDLE)
      return;

   FileWrite(
      h,
      s.id,
      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      DirectionName(s.direction),
      TimeToString(s.signal_bar_time, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
      TimeToString(close_time, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
      reason,
      s.zone_id,
      DoubleToString(s.zone_low,_Digits),
      DoubleToString(s.zone_high,_Digits),
      DoubleToString(s.zone_width_pips,2),
      DoubleToString(s.signal_close,_Digits),
      DoubleToString(s.entry_price,_Digits),
      DoubleToString(s.spread_pips,2),
      DoubleToString(s.edge_clearance_pips,2),
      DoubleToString(s.stop_price,_Digits),
      DoubleToString(s.risk_pips,2),
      OutcomeName(s.outcome_5p),
      OutcomeName(s.outcome_6p),
      OutcomeName(s.outcome_8p),
      OutcomeName(s.outcome_10p),
      OutcomeName(s.outcome_1r),
      OutcomeName(s.outcome_15r),
      OutcomeName(s.outcome_2r),
      DoubleToString(s.mfe_pips,2),
      DoubleToString(s.mae_pips,2),
      s.bars_held,
      DoubleToString(s.exit_price,_Digits),
      DoubleToString(s.exit_pl_pips,2),
      DoubleToString(s.timeout_pl_pips,2),
      s.session_label,
      s.bos_structure,
      s.proper_retest,
      s.m15_trend,
      s.h1_trend,
      s.ema_9_21,
      s.vwap_status,
      s.volume_spike,
      s.velocity,
      s.prev_day_fakeout,
      s.opening_range_position,
      DoubleToString(s.time_to_5p_minutes,1)
   );

   FileClose(h);
}

//========================== SIGNAL CREATION ==========================
bool IsAlreadyConsumed(const int direction,
                       const datetime signal_time)
{
   const string gv = direction > 0 ? g_last_buy_gv : g_last_sell_gv;

   if(!GlobalVariableCheck(gv))
      return false;

   const datetime last = (datetime)GlobalVariableGet(gv);
   return signal_time <= last;
}

void MarkConsumed(const int direction,
                  const datetime signal_time)
{
   const string gv = direction > 0 ? g_last_buy_gv : g_last_sell_gv;
   GlobalVariableSet(gv, (double)signal_time);
}

bool CreateVirtualSignal(const int direction,
                         const int shift)
{
   if(!HasStorageRoom())
   {
      Print("BOSTracker: MaxStoredSignals (active) reached; new signal ignored.");
      return false;
   }

   const datetime signal_time = iTime(_Symbol, _Period, shift);

   if(signal_time <= 0)
      return false;

   if(IsAlreadyConsumed(direction, signal_time))
      return false;

   const double zone_low =
      SafeBuffer(SignalZoneLowBufferIndex, shift, 0.0);

   const double zone_high =
      SafeBuffer(SignalZoneHighBufferIndex, shift, 0.0);

   if(zone_low <= 0.0 || zone_high <= zone_low)
   {
      Print(
         "BOSTracker: malformed signal zone at ",
         TimeToString(signal_time, TIME_DATE|TIME_MINUTES),
         "; signal ignored."
      );
      return false;
   }

   const double raw_entry =
      direction > 0
      ? SafeBuffer(BuyEntryPriceBufferIndex, shift,
                   iClose(_Symbol,_Period,shift))
      : SafeBuffer(SellEntryPriceBufferIndex, shift,
                   iClose(_Symbol,_Period,shift));

   if(raw_entry <= 0.0)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   // NOTE: VirtualSignal carries several string fields (session_label,
   // bos_structure, m15_trend, ...). MQL5 already zero/empty-initializes
   // every field of a freshly declared local struct (numerics to 0,
   // strings to ""), so no explicit reset is needed here. Do NOT call
   // ZeroMemory() on this struct - MQL5 warns against using it on
   // structures containing strings/dynamic arrays, since it overwrites
   // the string descriptor directly instead of releasing it properly.
   VirtualSignal s;

   s.active = true;
   s.id = g_next_id++;
   s.direction = direction;
   s.signal_bar_time = signal_time;
   s.detected_time = TimeCurrent();

   s.zone_id =
      (long)MathRound(
         SafeBuffer(SignalZoneIdBufferIndex, shift, 0.0)
      );

   s.zone_low = zone_low;
   s.zone_high = zone_high;
   s.zone_width_pips =
      (zone_high - zone_low) / PipSize();

   s.signal_close = raw_entry;
   s.spread_pips = (tick.ask - tick.bid) / PipSize();

   // Indicator signal is on a CLOSED chart candle; entry time is the
   // theoretical close time of that confirmation candle.
   s.entry_time =
      s.signal_bar_time + PeriodSeconds((ENUM_TIMEFRAMES)_Period);

   if(UseNextTickMarketEntry)
      s.entry_price = direction > 0 ? tick.ask : tick.bid;
   else
      s.entry_price = raw_entry;

   s.edge_clearance_pips =
      direction > 0
      ? (s.entry_price - s.zone_high) / PipSize()
      : (s.zone_low - s.entry_price) / PipSize();

   if(direction > 0)
   {
      s.stop_price = s.zone_low - StopBufferPips * PipSize();

      if(s.stop_price >= s.entry_price)
         s.stop_price =
            s.entry_price - FallbackStopPips * PipSize();

      s.risk_pips =
         (s.entry_price - s.stop_price) / PipSize();

      s.tp5_price  = s.entry_price + Target5Pips  * PipSize();
      s.tp6_price  = s.entry_price + Target6Pips  * PipSize();
      s.tp8_price  = s.entry_price + Target8Pips  * PipSize();
      s.tp10_price = s.entry_price + Target10Pips * PipSize();

      s.tp1r_price  = s.entry_price + s.risk_pips * PipSize();
      s.tp15r_price = s.entry_price + 1.5 * s.risk_pips * PipSize();
      s.tp2r_price  = s.entry_price + 2.0 * s.risk_pips * PipSize();
   }
   else
   {
      s.stop_price = s.zone_high + StopBufferPips * PipSize();

      if(s.stop_price <= s.entry_price)
         s.stop_price =
            s.entry_price + FallbackStopPips * PipSize();

      s.risk_pips =
         (s.stop_price - s.entry_price) / PipSize();

      s.tp5_price  = s.entry_price - Target5Pips  * PipSize();
      s.tp6_price  = s.entry_price - Target6Pips  * PipSize();
      s.tp8_price  = s.entry_price - Target8Pips  * PipSize();
      s.tp10_price = s.entry_price - Target10Pips * PipSize();

      s.tp1r_price  = s.entry_price - s.risk_pips * PipSize();
      s.tp15r_price = s.entry_price - 1.5 * s.risk_pips * PipSize();
      s.tp2r_price  = s.entry_price - 2.0 * s.risk_pips * PipSize();
   }

   if(s.risk_pips <= 0.0)
   {
      Print("BOSTracker: invalid virtual risk; signal ignored.");
      return false;
   }

   FillSessionDiagnostics(s);
   FillM5ConfluenceDiagnostics(s);

   s.mfe_pips = 0.0;
   s.mae_pips = 0.0;
   s.exit_price = s.entry_price;
   s.exit_pl_pips = 0.0;
   s.timeout_pl_pips = 0.0;
   s.bars_held = 0;
   s.last_counted_bar = iTime(_Symbol,_Period,0);

   const int n = ArraySize(g_signals);
   ArrayResize(g_signals, n+1);
   g_signals[n] = s;

   MarkConsumed(direction, signal_time);
   LogSignalEvent(s);

   Print(
      "BOSTracker NEW ",
      DirectionName(direction),
      " #",s.id,
      " | BOS structure:",s.bos_structure,
      " | Proper retest:",s.proper_retest,
      " | M15 trend:",s.m15_trend,
      " | H1 trend:",s.h1_trend,
      " | EMA 9/21:",s.ema_9_21,
      " | VWAP:",s.vwap_status,
      " | Volume spike:",s.volume_spike,
      " | Velocity:",s.velocity,
      " | Prev-day fakeout:",s.prev_day_fakeout,
      " | Opening range position:",s.opening_range_position,
      " | Risk:",DoubleToString(s.risk_pips,1),"p",
      " | zone#",s.zone_id,
      " [",DoubleToString(s.zone_low,_Digits),
      "-",DoubleToString(s.zone_high,_Digits),"]",
      " | entry=",DoubleToString(s.entry_price,_Digits),
      " | spr=",DoubleToString(s.spread_pips,1),"p"
   );

   return true;
}

void ProcessSignalAtShift(const int shift)
{
   if(g_indicator_handle == INVALID_HANDLE)
      return;

   double buy_value = EMPTY_VALUE;
   double sell_value = EMPTY_VALUE;

   const bool has_buy =
      ReadBufferValue(BuySignalBufferIndex, shift, buy_value);

   const bool has_sell =
      ReadBufferValue(SellSignalBufferIndex, shift, sell_value);

   if(has_buy && has_sell)
   {
      Print(
         "BOSTracker: BUY and SELL both present on same bar; ignored."
      );
      return;
   }

   if(has_buy)
      CreateVirtualSignal(+1, shift);
   else if(has_sell)
      CreateVirtualSignal(-1, shift);
}

//============================ TRACKING ===============================
void UpdateMfeMae(VirtualSignal &s,
                  const double liquidation_price)
{
   const double pip = PipSize();

   const double favorable =
      s.direction > 0
      ? (liquidation_price - s.entry_price) / pip
      : (s.entry_price - liquidation_price) / pip;

   const double adverse =
      s.direction > 0
      ? (s.entry_price - liquidation_price) / pip
      : (liquidation_price - s.entry_price) / pip;

   if(favorable > s.mfe_pips)
      s.mfe_pips = favorable;

   if(adverse > s.mae_pips)
      s.mae_pips = adverse;
}

void CountOutcome(const int outcome,
                  int &wins,
                  int &losses,
                  int &timeouts)
{
   if(outcome > 0) wins++;
   else if(outcome < 0) losses++;
   else timeouts++;
}

void FinalizeSignal(VirtualSignal &s,
                    const string reason,
                    const datetime close_time)
{
   if(!s.active)
      return;

   s.active = false;
   g_completed++;
   g_finalized_since_prune++;

   if(s.direction > 0) g_buy_completed++;
   else                g_sell_completed++;

   if(reason == "STOP_HIT") g_stop_exits++;
   else                     g_timeout_exits++;

   CountOutcome(s.outcome_5p,
                g_5p_wins,g_5p_losses,g_5p_timeouts);

   CountOutcome(s.outcome_6p,
                g_6p_wins,g_6p_losses,g_6p_timeouts);

   CountOutcome(s.outcome_8p,
                g_8p_wins,g_8p_losses,g_8p_timeouts);

   CountOutcome(s.outcome_10p,
                g_10p_wins,g_10p_losses,g_10p_timeouts);

   CountOutcome(s.outcome_1r,
                g_1r_wins,g_1r_losses,g_1r_timeouts);

   CountOutcome(s.outcome_15r,
                g_15r_wins,g_15r_losses,g_15r_timeouts);

   CountOutcome(s.outcome_2r,
                g_2r_wins,g_2r_losses,g_2r_timeouts);

   g_sum_mfe += s.mfe_pips;
   g_sum_mae += s.mae_pips;
   g_sum_risk += s.risk_pips;
   g_sum_final_pl += s.exit_pl_pips;

   if(s.mfe_pips < 0.05)
   {
      g_zero_mfe_completed++;

      if(reason == "STOP_HIT")
         g_zero_mfe_stops++;
   }

   LogCompletedResult(s, reason, close_time);

   Print(
      "BOSTracker COMPLETE #",s.id,
      " ",DirectionName(s.direction),
      " | 5p target:",OutcomeName(s.outcome_5p),
      " | 1.5R:",OutcomeName(s.outcome_15r),
      " | MFE:",DoubleToString(s.mfe_pips,1),"p",
      " | MAE:",DoubleToString(s.mae_pips,1),"p",
      " | Time to 5p:",
      (s.time_to_5p_minutes>0.0
         ? DoubleToString(s.time_to_5p_minutes,1)+" min"
         : "NA"),
      " | 6p:",OutcomeName(s.outcome_6p),
      " | 8p:",OutcomeName(s.outcome_8p),
      " | 10p:",OutcomeName(s.outcome_10p),
      " | 1R:",OutcomeName(s.outcome_1r),
      " | 2R:",OutcomeName(s.outcome_2r),
      " | bars:",s.bars_held,
      " | exitPL:",DoubleToString(s.exit_pl_pips,1),"p",
      " | reason:",reason,
      " | session:",s.session_label
   );
}

void ResolveStopLosses(VirtualSignal &s)
{
   if(s.outcome_5p == 0)  s.outcome_5p = -1;
   if(s.outcome_6p == 0)  s.outcome_6p = -1;
   if(s.outcome_8p == 0)  s.outcome_8p = -1;
   if(s.outcome_10p == 0) s.outcome_10p = -1;

   if(s.outcome_1r == 0)  s.outcome_1r = -1;
   if(s.outcome_15r == 0) s.outcome_15r = -1;
   if(s.outcome_2r == 0)  s.outcome_2r = -1;
}

void UpdateVirtualSignals()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   const datetime current_bar = iTime(_Symbol,_Period,0);
   const double pip = PipSize();

   for(int i=0; i<ArraySize(g_signals); i++)
   {
      if(!g_signals[i].active)
         continue;

      VirtualSignal s = g_signals[i];

      // Realistic liquidation side:
      // BUY closes at bid; SELL closes at ask.
      const double exit_price =
         s.direction > 0 ? tick.bid : tick.ask;

      s.exit_price = exit_price;

      s.exit_pl_pips =
         s.direction > 0
         ? (exit_price - s.entry_price) / pip
         : (s.entry_price - exit_price) / pip;

      UpdateMfeMae(s, exit_price);

      if(current_bar > 0 &&
         current_bar != s.last_counted_bar)
      {
         s.bars_held++;
         s.last_counted_bar = current_bar;
      }

      if(s.direction > 0)
      {
         if(s.outcome_5p == 0 && exit_price >= s.tp5_price)
         {
            s.outcome_5p = 1;
            s.hit_5p_time = TimeCurrent();

            if(s.entry_time>0)
               s.time_to_5p_minutes=
                  (double)(s.hit_5p_time-s.entry_time)/60.0;
         }

         if(s.outcome_6p == 0 && exit_price >= s.tp6_price)
         {
            s.outcome_6p = 1;
            s.hit_6p_time = TimeCurrent();
         }

         if(s.outcome_8p == 0 && exit_price >= s.tp8_price)
         {
            s.outcome_8p = 1;
            s.hit_8p_time = TimeCurrent();
         }

         if(s.outcome_10p == 0 && exit_price >= s.tp10_price)
         {
            s.outcome_10p = 1;
            s.hit_10p_time = TimeCurrent();
         }

         if(s.outcome_1r == 0 && exit_price >= s.tp1r_price)
         {
            s.outcome_1r = 1;
            s.hit_1r_time = TimeCurrent();
         }

         if(s.outcome_15r == 0 && exit_price >= s.tp15r_price)
         {
            s.outcome_15r = 1;
            s.hit_15r_time = TimeCurrent();
         }

         if(s.outcome_2r == 0 && exit_price >= s.tp2r_price)
         {
            s.outcome_2r = 1;
            s.hit_2r_time = TimeCurrent();
         }

         if(exit_price <= s.stop_price)
         {
            s.stop_time = TimeCurrent();
            ResolveStopLosses(s);
            FinalizeSignal(s,"STOP_HIT",TimeCurrent());
            g_signals[i] = s;
            continue;
         }
      }
      else
      {
         if(s.outcome_5p == 0 && exit_price <= s.tp5_price)
         {
            s.outcome_5p = 1;
            s.hit_5p_time = TimeCurrent();

            if(s.entry_time>0)
               s.time_to_5p_minutes=
                  (double)(s.hit_5p_time-s.entry_time)/60.0;
         }

         if(s.outcome_6p == 0 && exit_price <= s.tp6_price)
         {
            s.outcome_6p = 1;
            s.hit_6p_time = TimeCurrent();
         }

         if(s.outcome_8p == 0 && exit_price <= s.tp8_price)
         {
            s.outcome_8p = 1;
            s.hit_8p_time = TimeCurrent();
         }

         if(s.outcome_10p == 0 && exit_price <= s.tp10_price)
         {
            s.outcome_10p = 1;
            s.hit_10p_time = TimeCurrent();
         }

         if(s.outcome_1r == 0 && exit_price <= s.tp1r_price)
         {
            s.outcome_1r = 1;
            s.hit_1r_time = TimeCurrent();
         }

         if(s.outcome_15r == 0 && exit_price <= s.tp15r_price)
         {
            s.outcome_15r = 1;
            s.hit_15r_time = TimeCurrent();
         }

         if(s.outcome_2r == 0 && exit_price <= s.tp2r_price)
         {
            s.outcome_2r = 1;
            s.hit_2r_time = TimeCurrent();
         }

         if(exit_price >= s.stop_price)
         {
            s.stop_time = TimeCurrent();
            ResolveStopLosses(s);
            FinalizeSignal(s,"STOP_HIT",TimeCurrent());
            g_signals[i] = s;
            continue;
         }
      }

      // Do NOT finalize simply because 2R was reached.
      // Fixed 5/6/8/10-pip quality is allowed to keep developing
      // until the structural stop or the common timeout horizon.
      if(TimeoutBars > 0 &&
         s.bars_held >= TimeoutBars)
      {
         s.timeout_pl_pips = s.exit_pl_pips;
         FinalizeSignal(s,"TIMEOUT",TimeCurrent());
         g_signals[i] = s;
         continue;
      }

      g_signals[i] = s;
   }
}

//=========================== NEW-BAR SCAN ============================
void ProcessNewClosedBars()
{
   const datetime current_bar = iTime(_Symbol,_Period,0);

   if(current_bar <= 0)
      return;

   // First tracker tick: inspect only the latest closed candle.
   // We intentionally do not import the whole historical arrow set.
   if(g_last_chart_bar_time == 0)
   {
      g_last_chart_bar_time = current_bar;
      ProcessSignalAtShift(1);
      return;
   }

   if(current_bar == g_last_chart_bar_time)
      return;

   int previous_current_index = -1;

   const int bars = Bars(_Symbol,_Period);
   const int scan_limit = MathMin(bars-1, 200);

   for(int i=1; i<=scan_limit; i++)
   {
      if(iTime(_Symbol,_Period,i) == g_last_chart_bar_time)
      {
         previous_current_index = i;
         break;
      }
   }

   if(previous_current_index > 0)
   {
      // Oldest newly closed bar -> newest newly closed bar.
      for(int shift=previous_current_index; shift>=1; shift--)
         ProcessSignalAtShift(shift);
   }
   else
   {
      // History rebuild or a very large gap: avoid back-importing history.
      // Resume safely from the latest closed bar only.
      ProcessSignalAtShift(1);
   }

   g_last_chart_bar_time = current_bar;
}

//============================ DASHBOARD ==============================
void DeleteDashboard()
{
   const string name = g_prefix + "PANEL";

   if(ObjectFind(ChartID(),name) >= 0)
      ObjectDelete(ChartID(),name);
}

void DrawDashboard()
{
   if(!ShowDashboard)
   {
      DeleteDashboard();
      return;
   }

   const string name = g_prefix + "PANEL";

   if(ObjectFind(ChartID(),name) < 0)
   {
      if(!ObjectCreate(ChartID(),name,OBJ_LABEL,0,0,0))
         return;

      ObjectSetInteger(ChartID(),name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(ChartID(),name,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(ChartID(),name,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(ChartID(),name,OBJPROP_YDISTANCE,55);
      ObjectSetInteger(ChartID(),name,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(ChartID(),name,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(ChartID(),name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(ChartID(),name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(ChartID(),name,OBJPROP_ZORDER,1000);
      ObjectSetString(ChartID(),name,OBJPROP_FONT,"Arial");
   }

   const double hit5 =
      g_completed > 0
      ? 100.0 * (double)g_5p_wins / (double)g_completed
      : 0.0;

   const double avg_mfe =
      g_completed > 0 ? g_sum_mfe/g_completed : 0.0;

   const double avg_mae =
      g_completed > 0 ? g_sum_mae/g_completed : 0.0;

   const double avg_risk =
      g_completed > 0 ? g_sum_risk/g_completed : 0.0;

   const double avg_pl =
      g_completed > 0 ? g_sum_final_pl/g_completed : 0.0;

   string text = "BOS v1.08 M5 CONFLUENCE LAB\n";
   text += "RAW SIGNALS / NON-TRADING\n";
   text += "M5 CONFLUENCE = RECORD ONLY / NO FILTERING\n";
   text += "Active: "+IntegerToString(ActiveCount())+
           " | Completed: "+IntegerToString(g_completed)+"\n";

   text += "BUY:"+IntegerToString(g_buy_completed)+
           " | SELL:"+IntegerToString(g_sell_completed)+"\n";

   text += "5p  W:"+IntegerToString(g_5p_wins)+
           " L:"+IntegerToString(g_5p_losses)+
           " T:"+IntegerToString(g_5p_timeouts)+
           " | hit "+DoubleToString(hit5,1)+"%\n";

   text += "6p  W:"+IntegerToString(g_6p_wins)+
           " L:"+IntegerToString(g_6p_losses)+
           " T:"+IntegerToString(g_6p_timeouts)+"\n";

   text += "8p  W:"+IntegerToString(g_8p_wins)+
           " L:"+IntegerToString(g_8p_losses)+
           " T:"+IntegerToString(g_8p_timeouts)+"\n";

   text += "10p W:"+IntegerToString(g_10p_wins)+
           " L:"+IntegerToString(g_10p_losses)+
           " T:"+IntegerToString(g_10p_timeouts)+"\n";

   text += "1R W:"+IntegerToString(g_1r_wins)+
           " L:"+IntegerToString(g_1r_losses)+
           " T:"+IntegerToString(g_1r_timeouts)+"\n";

   text += "1.5R W:"+IntegerToString(g_15r_wins)+
           " L:"+IntegerToString(g_15r_losses)+
           " T:"+IntegerToString(g_15r_timeouts)+
           " | 2R W:"+IntegerToString(g_2r_wins)+
           " L:"+IntegerToString(g_2r_losses)+
           " T:"+IntegerToString(g_2r_timeouts)+"\n";

   text += "Avg MFE:"+DoubleToString(avg_mfe,1)+
           "p | MAE:"+DoubleToString(avg_mae,1)+
           "p | Risk:"+DoubleToString(avg_risk,1)+"p\n";

   text += "Stops:"+IntegerToString(g_stop_exits)+
           " | Timeouts:"+IntegerToString(g_timeout_exits)+
           " | 0-MFE stops:"+IntegerToString(g_zero_mfe_stops)+"\n";

   text += "Avg final P/L:"+DoubleToString(avg_pl,1)+"p\n";
   text += UseNextTickMarketEntry
           ? "Entry: NEXT-TICK MARKET"
           : "Entry: CONFIRMATION CLOSE";

   ObjectSetString(ChartID(),name,OBJPROP_TEXT,text);
}

//============================== MT5 ==================================
int OnInit()
{
   ArrayResize(g_signals,0);
   g_finalized_since_prune=0;

   // Create confluence EMA handles. These are diagnostics only.
   g_m5_fast_ema_handle=
      iMA(_Symbol,PERIOD_M5,TrendFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_m5_slow_ema_handle=
      iMA(_Symbol,PERIOD_M5,TrendSlowEMA,0,MODE_EMA,PRICE_CLOSE);

   g_m15_fast_ema_handle=
      iMA(_Symbol,PERIOD_M15,TrendFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_m15_slow_ema_handle=
      iMA(_Symbol,PERIOD_M15,TrendSlowEMA,0,MODE_EMA,PRICE_CLOSE);

   g_h1_fast_ema_handle=
      iMA(_Symbol,PERIOD_H1,TrendFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_h1_slow_ema_handle=
      iMA(_Symbol,PERIOD_H1,TrendSlowEMA,0,MODE_EMA,PRICE_CLOSE);

   g_last_buy_gv =
      "MBOSTQ108M5_LAST_BUY_" +
      SanitizeFilePart(_Symbol) + "_" +
      IntegerToString((int)_Period);

   g_last_sell_gv =
      "MBOSTQ108M5_LAST_SELL_" +
      SanitizeFilePart(_Symbol) + "_" +
      IntegerToString((int)_Period);

   CreateIndicatorHandle();

   Print(
      "MasterBOSTradeQualityTracker v1.08 M5 Confluence Lab initialized on ",
      _Symbol,
      " ",
      EnumToString((ENUM_TIMEFRAMES)_Period),
      ". v1.08 + M5 confluence diagnostics / RECORD-ONLY / NON-TRADING."
   );

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteDashboard();

   if(g_indicator_handle != INVALID_HANDLE)
      IndicatorRelease(g_indicator_handle);

   if(g_m5_fast_ema_handle!=INVALID_HANDLE)
      IndicatorRelease(g_m5_fast_ema_handle);
   if(g_m5_slow_ema_handle!=INVALID_HANDLE)
      IndicatorRelease(g_m5_slow_ema_handle);
   if(g_m15_fast_ema_handle!=INVALID_HANDLE)
      IndicatorRelease(g_m15_fast_ema_handle);
   if(g_m15_slow_ema_handle!=INVALID_HANDLE)
      IndicatorRelease(g_m15_slow_ema_handle);
   if(g_h1_fast_ema_handle!=INVALID_HANDLE)
      IndicatorRelease(g_h1_fast_ema_handle);
   if(g_h1_slow_ema_handle!=INVALID_HANDLE)
      IndicatorRelease(g_h1_slow_ema_handle);
}

void OnTick()
{
   if(g_indicator_handle == INVALID_HANDLE)
   {
      CreateIndicatorHandle();
      DrawDashboard();
      return;
   }

   // Existing virtual trades are monitored every tick.
   UpdateVirtualSignals();

   // Compact finalized signals out of g_signals so the array reflects
   // concurrently active signals only - their CSV row is already
   // durable, so nothing is lost by dropping them from memory here.
   if(g_finalized_since_prune > 0)
   {
      PruneCompletedSignals();
      g_finalized_since_prune = 0;
   }

   // New signals are collected only from candles that have actually closed.
   ProcessNewClosedBars();

   DrawDashboard();
}
//+------------------------------------------------------------------+
