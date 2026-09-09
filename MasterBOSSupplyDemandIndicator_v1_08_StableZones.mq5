//+------------------------------------------------------------------+
//|             MasterBOSSupplyDemandIndicator_v1_08_StableZones.mq5              |
//| Prev-day H/L -> rolling HH/LL -> stable zone -> armed retest     |
//| Research only: NEVER opens, modifies, or closes real trades.     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.08"
#property indicator_chart_window
#property indicator_plots   2
#property indicator_buffers 12

#property indicator_label1  "BOS Buy"
#property indicator_type1   DRAW_ARROW
#property indicator_width1  1
#property indicator_label2  "BOS Sell"
#property indicator_type2   DRAW_ARROW
#property indicator_width2  1

//============================== INPUTS ===============================
input int      LookbackBars                    = 500;

// DAILY STRUCTURE ENGINE:
// The first closed M15 candle of each broker/server day seeds Day High/Low.
// Thereafter:
//   close > previous Day High + buffer => new Higher High / bullish BOS
//   close < previous Day Low  - buffer => new Lower Low  / bearish BOS
// The current candle's wick high/low then becomes part of the next reference.
input double   BreakBufferPips                 = 0.5;
input int      LastOppositeCandleSearchBars    = 12;

// Seed each new broker/server trading day from the PREVIOUS completed day.
// After a confirmed close break, that breakout candle's wick becomes the
// next rolling HH/LL reference for the current day.
input bool     UsePreviousDaySeed              = true;
input bool     ResetZonesOnNewTradingDay       = true;

// Proper-retest state machine:
// CREATED -> DEPARTED -> RETEST/REJECTION -> SIGNALED
input double   DepartureDistancePips           = 0.5;

input double   ZoneInvalidationBufferPips      = 1.0;
input int      MaxZoneAgeBars                  = 96;
input int      MinBarsBeforeRetest             = 1;
input bool     OneSignalPerZone                = true;

// Only allow retest signals in the direction of the latest confirmed BOS.
// Old opposite zones may remain visible, but cannot trigger entries.
input bool     RequireLatestBOSDirection        = true;

input double   RetestTolerancePips             = 0.5;
input bool     RequireRejectionCandle          = true;
input double   RejectionWickRatio              = 1.0;
input bool     RequireCloseBeyondZoneEdge      = true;

input int      MaxDemandZonesToDraw            = 3;
input int      MaxSupplyZonesToDraw            = 3;
input bool     DrawZoneRectangles              = true;
input bool     FillZoneRectangles              = false;
input bool     ShowDashboard                   = true;
input double   VisualArrowOffsetPips           = 0.5; // display only; entry remains confirmation close

//============================= BUFFERS ===============================
double BuySignalBuffer[];
double SellSignalBuffer[];
double SignalZoneLowBuffer[];
double SignalZoneHighBuffer[];
double DemandLowBuffer[];
double DemandHighBuffer[];
double SupplyLowBuffer[];
double SupplyHighBuffer[];
double BOSDirectionBuffer[];
double SignalZoneIdBuffer[];
double BuyEntryPriceBuffer[];
double SellEntryPriceBuffer[];

// Buffer contract:
// 0 BuySignal visual arrow (signal flag; NOT the trade entry price)
// 1 SellSignal visual arrow (signal flag; NOT the trade entry price)
// 2 SignalZoneLow
// 3 SignalZoneHigh
// 4 NearestDemandLow
// 5 NearestDemandHigh
// 6 NearestSupplyLow
// 7 NearestSupplyHigh
// 8 BOSDirection (+1 bull, -1 bear)
// 9 SignalZoneId
// 10 BuyEntryPrice  = confirmation candle close
// 11 SellEntryPrice = confirmation candle close

//============================== TYPES ================================
struct BOSZone
{
   int      id;
   bool     demand;
   double   low;
   double   high;
   datetime source_time;
   datetime bos_time;
   datetime broken_swing_time;
   double   broken_swing_price;
   int      age_bars;
   bool     valid;
   bool     signaled;

   // Proper-retest state. A zone cannot signal until price first moves
   // completely away from it in the expected impulse direction.
   bool     departed;
   datetime departed_time;

   long     invalidated_at_count; // g_processed_bar_count snapshot when this zone went invalid
};

// Once an invalid zone is older than this many processed bars it is dropped
// from g_zones entirely, so the array does not grow without bound on a
// chart that is left running for weeks/months. Kept large relative to any
// realistic ZoneSourceAlreadyExists re-trigger window.
#define ZONE_PRUNE_RETENTION_BARS 1000

BOSZone g_zones[];

datetime g_last_processed_bar = 0;

// Broker/server-day structure state.
int      g_trading_day_key = 0;
double   g_day_high_ref = 0.0;
double   g_day_low_ref = 0.0;
datetime g_day_high_time = 0;
datetime g_day_low_time = 0;
int      g_day_hh_breaks = 0;
int      g_day_ll_breaks = 0;

int      g_last_bos_dir = 0;
string   g_last_signal_text = "NONE";
string   g_prefix = "MBOSSD108S_";
bool     g_replaying = false;
long     g_processed_bar_count = 0;

// Runtime diagnostic de-duplication. These arrays are intentionally NOT
// cleared by ResetEngine(), because ReplayHistory() may rebuild state.
// They only suppress repeated log lines for the same stable zone ID.
// Compacted in lockstep with PruneInvalidZones() (see PruneLoggedIdArray)
// so they don't grow without bound over a long-running chart either -
// once a zone id is no longer tracked in g_zones it can never recur
// (StableZoneId is derived from a source candle's unique open time), so
// dropping its dedup entry is always safe.
int g_logged_new_zone_ids[];
int g_logged_departed_zone_ids[];

//============================= HELPERS ===============================
// NOTE: "pip" here means the conventional FX pip (10x point on 3/5-digit
// FX quotes). Pip-based inputs (tolerances/buffers) are only meaningful
// on FX symbols; on indices/stocks/crypto they resolve to raw points.
double PipSize()
{
   if(_Digits == 3 || _Digits == 5)
      return _Point * 10.0;
   return _Point;
}

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, _Digits);
}

// Stable zone identity:
// one M15 source candle + one direction always maps to the same ID.
// This does not depend on replay order, g_zones array order, or a
// resettable counter, so recovery/replay cannot recycle an old zone ID.
int StableZoneId(const datetime source_time,const bool demand)
{
   // Epoch-minute IDs are ~60 million in 2026, comfortably inside int.
   const long minute_key=(long)source_time/60;
   const long raw_id=minute_key*2 + (demand ? 1 : 0);
   return (int)raw_id;
}

string DirName(const int dir)
{
   if(dir > 0) return "BULLISH";
   if(dir < 0) return "BEARISH";
   return "NONE";
}

int TradingDayKey(const datetime value)
{
   MqlDateTime dt;
   TimeToStruct(value,dt);
   return dt.year*10000 + dt.mon*100 + dt.day;
}

string TradingDayText(const int day_key)
{
   if(day_key<=0) return "none";

   const int year = day_key/10000;
   const int mon  = (day_key/100)%100;
   const int day  = day_key%100;

   return IntegerToString(year)+"."+
          StringFormat("%02d",mon)+"."+
          StringFormat("%02d",day);
}

bool IsBullishCandle(const double o, const double c) { return c > o; }
bool IsBearishCandle(const double o, const double c) { return c < o; }

bool IdArrayContains(const int &values[],const int value)
{
   for(int i=0;i<ArraySize(values);i++)
      if(values[i]==value) return true;
   return false;
}

void IdArrayAddUnique(int &values[],const int value)
{
   if(IdArrayContains(values,value)) return;
   const int n=ArraySize(values);
   ArrayResize(values,n+1);
   values[n]=value;
}

bool ZoneOverlap(const BOSZone &z, const double h, const double l)
{
   const double tol = RetestTolerancePips * PipSize();
   return !(l > z.high + tol || h < z.low - tol);
}

bool BullishRejection(const BOSZone &z,
                      const double o,const double h,
                      const double l,const double c)
{
   if(!ZoneOverlap(z,h,l)) return false;
   if(!RequireRejectionCandle) return true;
   if(c <= o) return false;

   const double body = MathMax(MathAbs(c-o), PipSize()*0.05);
   const double lower_wick = MathMin(o,c) - l;
   const double midpoint = (z.low + z.high) * 0.5;

   if(lower_wick < body * RejectionWickRatio) return false;
   if(RequireCloseBeyondZoneEdge) return c > z.high;
   return c >= midpoint;
}

bool BearishRejection(const BOSZone &z,
                      const double o,const double h,
                      const double l,const double c)
{
   if(!ZoneOverlap(z,h,l)) return false;
   if(!RequireRejectionCandle) return true;
   if(c >= o) return false;

   const double body = MathMax(MathAbs(c-o), PipSize()*0.05);
   const double upper_wick = h - MathMax(o,c);
   const double midpoint = (z.low + z.high) * 0.5;

   if(upper_wick < body * RejectionWickRatio) return false;
   if(RequireCloseBeyondZoneEdge) return c < z.low;
   return c <= midpoint;
}

int ActiveZoneCount(const bool demand)
{
   int total=0;
   for(int i=0; i<ArraySize(g_zones); i++)
      if(g_zones[i].valid && g_zones[i].demand==demand)
         total++;
   return total;
}

int FindZoneBySource(const datetime source_time,const bool demand)
{
   for(int i=0; i<ArraySize(g_zones); i++)
      if(g_zones[i].source_time==source_time &&
         g_zones[i].demand==demand)
         return i;

   return -1;
}

int FindZoneById(const int id)
{
   for(int i=0; i<ArraySize(g_zones); i++)
      if(g_zones[i].id==id)
         return i;

   return -1;
}

bool ZoneSourceAlreadyExists(const datetime source_time,const bool demand)
{
   return FindZoneBySource(source_time,demand)>=0;
}

// Drops dedup entries whose zone is no longer tracked in g_zones. Safe
// because a StableZoneId can never recur (it's derived from a unique
// source-candle open time), so once the zone itself has been pruned
// there is no future zone that could need suppressing under that id.
void PruneLoggedIdArray(int &values[])
{
   const int total=ArraySize(values);
   int write=0;

   for(int read=0; read<total; read++)
   {
      if(FindZoneById(values[read])<0)
         continue;

      if(write!=read)
         values[write]=values[read];
      write++;
   }

   if(write<total)
      ArrayResize(values,write);
}

//=========================== ZONE ENGINE =============================
bool AddZone(const bool demand,
             const double zone_low,
             const double zone_high,
             const datetime source_time,
             const datetime bos_time,
             const datetime reference_time,
             const double reference_price)
{
   if(zone_high<=zone_low || source_time<=0)
      return false;

   const int stable_id=StableZoneId(source_time,demand);
   const int existing=FindZoneBySource(source_time,demand);

   // One source candle can create only ONE zone in a given direction.
   // If a later HH/LL break still points to that same opposite candle,
   // keep/reuse the existing zone and do not stack another rectangle.
   if(existing>=0)
   {
      if(!g_replaying)
         Print("BOS ZONE SKIP DUPLICATE #",IntegerToString(stable_id)," ",
               demand ? "DEMAND" : "SUPPLY",
               " source=",TimeToString(source_time,TIME_DATE|TIME_MINUTES),
               " laterBOS=",TimeToString(bos_time,TIME_DATE|TIME_MINUTES));
      return false;
   }

   const int n=ArraySize(g_zones);
   ArrayResize(g_zones,n+1);

   g_zones[n].id=stable_id;
   g_zones[n].demand=demand;
   g_zones[n].low=NormalizePrice(zone_low);
   g_zones[n].high=NormalizePrice(zone_high);
   g_zones[n].source_time=source_time;
   g_zones[n].bos_time=bos_time;
   g_zones[n].broken_swing_time=reference_time;
   g_zones[n].broken_swing_price=NormalizePrice(reference_price);
   g_zones[n].age_bars=0;
   g_zones[n].valid=true;
   g_zones[n].signaled=false;
   g_zones[n].departed=false;
   g_zones[n].departed_time=0;
   g_zones[n].invalidated_at_count=0;

   if(!g_replaying && !IdArrayContains(g_logged_new_zone_ids,stable_id))
   {
      IdArrayAddUnique(g_logged_new_zone_ids,stable_id);

      Print("BOS ZONE NEW #",IntegerToString(g_zones[n].id)," ",
            demand ? "DEMAND" : "SUPPLY",
            " [",DoubleToString(g_zones[n].low,_Digits),
            "-",DoubleToString(g_zones[n].high,_Digits),"]",
            " source=",TimeToString(source_time,TIME_DATE|TIME_MINUTES),
            " BOS=",TimeToString(bos_time,TIME_DATE|TIME_MINUTES),
            " brokenRef=",DoubleToString(reference_price,_Digits));
   }

   return true;
}

void InvalidateZone(const int index,const string reason)
{
   g_zones[index].valid=false;
   g_zones[index].invalidated_at_count=g_processed_bar_count;

   if(!g_replaying)
      Print("BOS ZONE INVALID #",IntegerToString(g_zones[index].id)," ",reason);
}

void AgeAndInvalidateZones(const double closed_price)
{
   const double buffer=ZoneInvalidationBufferPips*PipSize();

   for(int i=0; i<ArraySize(g_zones); i++)
   {
      if(!g_zones[i].valid) continue;

      g_zones[i].age_bars++;

      if(MaxZoneAgeBars>0 && g_zones[i].age_bars>MaxZoneAgeBars)
      {
         InvalidateZone(i,"MAX AGE");
         continue;
      }

      if(g_zones[i].demand)
      {
         if(closed_price < g_zones[i].low-buffer)
            InvalidateZone(i,"DEMAND close="+DoubleToString(closed_price,_Digits));
      }
      else
      {
         if(closed_price > g_zones[i].high+buffer)
            InvalidateZone(i,"SUPPLY close="+DoubleToString(closed_price,_Digits));
      }
   }
}

// Drops long-invalid zones from g_zones so the array does not grow without
// bound over the lifetime of a live chart. Zones are kept well past their
// invalidation point so ZoneSourceAlreadyExists still guards against
// re-creating a duplicate zone from the same source candle.
void PruneInvalidZones()
{
   const int total=ArraySize(g_zones);
   int write=0;

   for(int read=0; read<total; read++)
   {
      const bool drop = !g_zones[read].valid &&
         (g_processed_bar_count-g_zones[read].invalidated_at_count) > ZONE_PRUNE_RETENTION_BARS;

      if(drop) continue;

      if(write!=read)
         g_zones[write]=g_zones[read];
      write++;
   }

   if(write<total)
      ArrayResize(g_zones,write);
}

int FindLastOppositeCandle(const bool bullish_bos,
                           const int bos_index,
                           const datetime &time[],
                           const double &open[],
                           const double &close[],
                           const int rates_total)
{
   const int first=bos_index+1;
   const int last=MathMin(rates_total-1,
                         bos_index+MathMax(1,LastOppositeCandleSearchBars));

   // Deliberately NOT restricted to the BOS candle's own trading day.
   // UsePreviousDaySeed seeds each day's reference from the PREVIOUS
   // completed day's H/L specifically so an early break (session open,
   // gap-and-go through yesterday's level) is tradable; a same-day-only
   // search would make exactly those breaks unable to find their last
   // opposite candle (it usually sits a bar or two into yesterday) and
   // silently produce a BOS with no zone. Series arrays: first match is
   // the last candle before the BOS candle, regardless of which
   // calendar day it falls on.
   for(int i=first; i<=last; i++)
   {
      if(bullish_bos && IsBearishCandle(open[i],close[i])) return i;
      if(!bullish_bos && IsBullishCandle(open[i],close[i])) return i;
   }

   return -1;
}

bool LoadPreviousCompletedDayLevels(const datetime current_bar_time,
                                    double &prev_high,
                                    double &prev_low,
                                    datetime &prev_time)
{
   prev_high=0.0;
   prev_low=0.0;
   prev_time=0;

   // D1 shift containing current_bar_time is the current broker/server day.
   // The following D1 shift is the previous completed trading day.
   const int current_d1_shift=
      iBarShift(_Symbol,PERIOD_D1,current_bar_time,false);

   if(current_d1_shift<0)
      return false;

   const int prev_shift=current_d1_shift+1;

   const datetime t=iTime(_Symbol,PERIOD_D1,prev_shift);
   const double h=iHigh(_Symbol,PERIOD_D1,prev_shift);
   const double l=iLow(_Symbol,PERIOD_D1,prev_shift);

   if(t<=0 || h<=0.0 || l<=0.0 || h<=l)
      return false;

   prev_high=h;
   prev_low=l;
   prev_time=t;
   return true;
}

void ResetForNewTradingDay(const int day_key,
                           const datetime bar_time,
                           const double bar_high,
                           const double bar_low)
{
   if(ResetZonesOnNewTradingDay)
   {
      for(int i=0; i<ArraySize(g_zones); i++)
      {
         if(g_zones[i].valid)
            InvalidateZone(i,"NEW TRADING DAY RESET");
      }
   }

   g_trading_day_key=day_key;
   g_day_hh_breaks=0;
   g_day_ll_breaks=0;
   g_last_bos_dir=0;

   double prev_high=0.0;
   double prev_low=0.0;
   datetime prev_time=0;

   const bool loaded=
      UsePreviousDaySeed &&
      LoadPreviousCompletedDayLevels(bar_time,prev_high,prev_low,prev_time);

   if(loaded)
   {
      g_day_high_ref=prev_high;
      g_day_low_ref=prev_low;
      g_day_high_time=prev_time;
      g_day_low_time=prev_time;

      if(!g_replaying)
         Print("BOS PREV-DAY RESET day=",TradingDayText(day_key),
               " prevHigh=",DoubleToString(g_day_high_ref,_Digits),
               " prevLow=",DoubleToString(g_day_low_ref,_Digits));
   }
   else
   {
      // Safe fallback when D1 history is not yet available.
      g_day_high_ref=bar_high;
      g_day_low_ref=bar_low;
      g_day_high_time=bar_time;
      g_day_low_time=bar_time;

      if(!g_replaying)
         Print("BOS DAY RESET FALLBACK day=",TradingDayText(day_key),
               " seedHigh=",DoubleToString(g_day_high_ref,_Digits),
               " seedLow=",DoubleToString(g_day_low_ref,_Digits));
   }
}

void DetectAndCreateDailyBOS(const int bar,
                             const datetime &time[],
                             const double &open[],
                             const double &high[],
                             const double &low[],
                             const double &close[],
                             const int rates_total)
{
   const int day_key=TradingDayKey(time[bar]);

   // First CLOSED bar seen for a new broker/server day seeds that day's
   // running High/Low. It cannot be a BOS against itself.
   if(g_trading_day_key!=day_key ||
      g_day_high_ref<=0.0 ||
      g_day_low_ref<=0.0)
   {
      ResetForNewTradingDay(day_key,time[bar],high[bar],low[bar]);
      return;
   }

   const double prior_day_high=g_day_high_ref;
   const double prior_day_low =g_day_low_ref;
   const datetime prior_high_time=g_day_high_time;
   const datetime prior_low_time =g_day_low_time;

   const double break_buffer=BreakBufferPips*PipSize();

   const bool bullish_break=
      close[bar] > prior_day_high + break_buffer;

   const bool bearish_break=
      close[bar] < prior_day_low - break_buffer;

   // A bullish daily-structure break means the candle CLOSED above the
   // running high that existed BEFORE this candle. The candle's own high
   // becomes part of the next HH reference after detection.
   if(bullish_break)
   {
      const int source=
         FindLastOppositeCandle(true,bar,time,open,close,rates_total);

      if(source>=0)
         AddZone(true,low[source],high[source],time[source],time[bar],
                 prior_high_time,prior_day_high);

      g_last_bos_dir=+1;
      g_day_hh_breaks++;
      BOSDirectionBuffer[bar]=+1.0;

      if(!g_replaying)
         Print("DAILY HH BREAK #",g_day_hh_breaks,
               " oldHigh=",DoubleToString(prior_day_high,_Digits),
               " close=",DoubleToString(close[bar],_Digits),
               " newHigh=",DoubleToString(high[bar],_Digits));
   }

   // A bearish daily-structure break means the candle CLOSED below the
   // running low that existed BEFORE this candle. The candle's own low
   // becomes part of the next LL reference after detection.
   if(bearish_break)
   {
      const int source=
         FindLastOppositeCandle(false,bar,time,open,close,rates_total);

      if(source>=0)
         AddZone(false,low[source],high[source],time[source],time[bar],
                 prior_low_time,prior_day_low);

      g_last_bos_dir=-1;
      g_day_ll_breaks++;
      BOSDirectionBuffer[bar]=-1.0;

      if(!g_replaying)
         Print("DAILY LL BREAK #",g_day_ll_breaks,
               " oldLow=",DoubleToString(prior_day_low,_Digits),
               " close=",DoubleToString(close[bar],_Digits),
               " newLow=",DoubleToString(low[bar],_Digits));
   }

   // Advance rolling structure ONLY after a confirmed CLOSE break.
   // A wick through a reference that closes back inside is a sweep, not
   // a new HH/LL. After a valid break, the break candle's wick becomes
   // the next reference.
   if(bullish_break)
   {
      g_day_high_ref=high[bar];
      g_day_high_time=time[bar];
   }

   if(bearish_break)
   {
      g_day_low_ref=low[bar];
      g_day_low_time=time[bar];
   }
}

bool FindNearestActiveZone(const bool demand,
                           const double price,
                           BOSZone &result)
{
   bool found=false;
   double best=DBL_MAX;

   for(int i=0; i<ArraySize(g_zones); i++)
   {
      if(!g_zones[i].valid || g_zones[i].demand!=demand) continue;

      double dist=0.0;
      if(price<g_zones[i].low) dist=g_zones[i].low-price;
      else if(price>g_zones[i].high) dist=price-g_zones[i].high;

      if(dist<best)
      {
         best=dist;
         result=g_zones[i];
         found=true;
      }
   }
   return found;
}

void UpdateZoneDepartureState(const datetime bar_time,
                              const double bar_high,
                              const double bar_low)
{
   const double distance=DepartureDistancePips*PipSize();

   for(int i=0; i<ArraySize(g_zones); i++)
   {
      if(!g_zones[i].valid || g_zones[i].signaled || g_zones[i].departed)
         continue;

      // DEMAND: the entire closed candle must be above the zone before
      // a later return is allowed to count as a proper retest.
      if(g_zones[i].demand)
      {
         if(bar_low > g_zones[i].high + distance)
         {
            g_zones[i].departed=true;
            g_zones[i].departed_time=bar_time;

            if(!g_replaying &&
               !IdArrayContains(g_logged_departed_zone_ids,g_zones[i].id))
            {
               IdArrayAddUnique(g_logged_departed_zone_ids,g_zones[i].id);
               Print("BOS ZONE DEPARTED #",IntegerToString(g_zones[i].id),
                     " DEMAND time=",
                     TimeToString(bar_time,TIME_DATE|TIME_MINUTES));
            }
         }
      }
      // SUPPLY: the entire closed candle must be below the zone before
      // a later return is allowed to count as a proper retest.
      else
      {
         if(bar_high < g_zones[i].low - distance)
         {
            g_zones[i].departed=true;
            g_zones[i].departed_time=bar_time;

            if(!g_replaying &&
               !IdArrayContains(g_logged_departed_zone_ids,g_zones[i].id))
            {
               IdArrayAddUnique(g_logged_departed_zone_ids,g_zones[i].id);
               Print("BOS ZONE DEPARTED #",IntegerToString(g_zones[i].id),
                     " SUPPLY time=",
                     TimeToString(bar_time,TIME_DATE|TIME_MINUTES));
            }
         }
      }
   }
}

void ProcessRetestSignals(const int bar,
                          const datetime &time[],
                          const double &open[],
                          const double &high[],
                          const double &low[],
                          const double &close[])
{
   // Newest matching zone wins if zones overlap.
   for(int i=ArraySize(g_zones)-1; i>=0; i--)
   {
      if(!g_zones[i].valid) continue;
      if(g_zones[i].age_bars<MinBarsBeforeRetest) continue;
      if(OneSignalPerZone && g_zones[i].signaled) continue;

      // Proper retest: a CREATED zone is not eligible. It must first
      // become DEPARTED, and the retest must happen on a later bar.
      if(!g_zones[i].departed) continue;
      if(g_zones[i].departed_time>=time[bar]) continue;

      if(g_zones[i].demand)
      {
         // Demand may trigger BUY only while the latest confirmed
         // market-structure break is bullish.
         if(RequireLatestBOSDirection && g_last_bos_dir != +1)
            continue;

         if(!BullishRejection(g_zones[i],open[bar],high[bar],low[bar],close[bar]))
            continue;

         // Visual arrow points to the signal candle from below.
         // Exact research/tracker entry is stored separately at the CLOSE.
         BuySignalBuffer[bar]=
            low[bar]-VisualArrowOffsetPips*PipSize();
         BuyEntryPriceBuffer[bar]=close[bar];

         SignalZoneLowBuffer[bar]=g_zones[i].low;
         SignalZoneHighBuffer[bar]=g_zones[i].high;
         SignalZoneIdBuffer[bar]=(double)g_zones[i].id;
         g_zones[i].signaled=true;
         g_last_signal_text="BUY zone#"+IntegerToString(g_zones[i].id);

         if(!g_replaying)
            Print("BOS BUY SIGNAL zone#",IntegerToString(g_zones[i].id),
                  " time=",TimeToString(time[bar],TIME_DATE|TIME_MINUTES),
                  " zone=[",DoubleToString(g_zones[i].low,_Digits),
                  "-",DoubleToString(g_zones[i].high,_Digits),"]",
                  " close=",DoubleToString(close[bar],_Digits));
         return;
      }
      else
      {
         // Supply may trigger SELL only while the latest confirmed
         // market-structure break is bearish.
         if(RequireLatestBOSDirection && g_last_bos_dir != -1)
            continue;

         if(!BearishRejection(g_zones[i],open[bar],high[bar],low[bar],close[bar]))
            continue;

         // Visual arrow points to the signal candle from above.
         // Exact research/tracker entry is stored separately at the CLOSE.
         SellSignalBuffer[bar]=
            high[bar]+VisualArrowOffsetPips*PipSize();
         SellEntryPriceBuffer[bar]=close[bar];

         SignalZoneLowBuffer[bar]=g_zones[i].low;
         SignalZoneHighBuffer[bar]=g_zones[i].high;
         SignalZoneIdBuffer[bar]=(double)g_zones[i].id;
         g_zones[i].signaled=true;
         g_last_signal_text="SELL zone#"+IntegerToString(g_zones[i].id);

         if(!g_replaying)
            Print("BOS SELL SIGNAL zone#",IntegerToString(g_zones[i].id),
                  " time=",TimeToString(time[bar],TIME_DATE|TIME_MINUTES),
                  " zone=[",DoubleToString(g_zones[i].low,_Digits),
                  "-",DoubleToString(g_zones[i].high,_Digits),"]",
                  " close=",DoubleToString(close[bar],_Digits));
         return;
      }
   }
}

void SetNearestZoneBuffers(const int bar,const double price)
{
   BOSZone d,s;

   if(FindNearestActiveZone(true,price,d))
   {
      DemandLowBuffer[bar]=d.low;
      DemandHighBuffer[bar]=d.high;
   }

   if(FindNearestActiveZone(false,price,s))
   {
      SupplyLowBuffer[bar]=s.low;
      SupplyHighBuffer[bar]=s.high;
   }
}

void ProcessClosedBar(const int bar,
                      const datetime &time[],
                      const double &open[],
                      const double &high[],
                      const double &low[],
                      const double &close[],
                      const int rates_total,
                      const bool allow_signals)
{
   BuySignalBuffer[bar]=EMPTY_VALUE;
   SellSignalBuffer[bar]=EMPTY_VALUE;
   SignalZoneLowBuffer[bar]=EMPTY_VALUE;
   SignalZoneHighBuffer[bar]=EMPTY_VALUE;
   SignalZoneIdBuffer[bar]=0.0;
   BuyEntryPriceBuffer[bar]=EMPTY_VALUE;
   SellEntryPriceBuffer[bar]=EMPTY_VALUE;
   DemandLowBuffer[bar]=EMPTY_VALUE;
   DemandHighBuffer[bar]=EMPTY_VALUE;
   SupplyLowBuffer[bar]=EMPTY_VALUE;
   SupplyHighBuffer[bar]=EMPTY_VALUE;
   BOSDirectionBuffer[bar]=0.0;

   g_processed_bar_count++;

   AgeAndInvalidateZones(close[bar]);
   DetectAndCreateDailyBOS(bar,time,open,high,low,close,rates_total);

   // CREATED -> DEPARTED. The departure bar itself cannot also be the
   // retest because ProcessRetestSignals requires a later timestamp.
   UpdateZoneDepartureState(time[bar],high[bar],low[bar]);

   if(allow_signals)
      ProcessRetestSignals(bar,time,open,high,low,close);

   SetNearestZoneBuffers(bar,close[bar]);

   if(g_processed_bar_count % 50 == 0)
   {
      PruneInvalidZones();
      PruneLoggedIdArray(g_logged_new_zone_ids);
      PruneLoggedIdArray(g_logged_departed_zone_ids);
   }
}

//============================== REPLAY ================================
void ResetEngine()
{
   ArrayResize(g_zones,0);

   g_trading_day_key=0;
   g_day_high_ref=0.0;
   g_day_low_ref=0.0;
   g_day_high_time=0;
   g_day_low_time=0;
   g_day_hh_breaks=0;
   g_day_ll_breaks=0;

   g_last_bos_dir=0;
   g_last_signal_text="NONE";
   g_processed_bar_count=0;
}

void ReplayHistory(const datetime &time[],
                   const double &open[],
                   const double &high[],
                   const double &low[],
                   const double &close[],
                   const int rates_total)
{
   ResetEngine();

   int start=MathMin(LookbackBars,
                     rates_total-2);
   if(start<1) return;

   // Oldest to newest. Simulate signals so one-signal-per-zone state
   // matches live behavior, but suppress replay log spam.
   g_replaying=true;

   for(int bar=start; bar>=1; bar--)
      ProcessClosedBar(bar,time,open,high,low,close,rates_total,true);

   g_replaying=false;
}

//============================== DRAWING ===============================
void DeleteZoneObjects()
{
   const long chart_id=ChartID();
   const int total=ObjectsTotal(chart_id,-1,-1);
   const string prefix=g_prefix+"ZONE_";

   for(int i=total-1; i>=0; i--)
   {
      const string name=ObjectName(chart_id,i,-1,-1);
      if(StringFind(name,prefix)==0)
         ObjectDelete(chart_id,name);
   }
}

void DrawOneZone(const BOSZone &z)
{
   if(!DrawZoneRectangles || !z.valid) return;

   const string name=g_prefix+"ZONE_"+
                     (z.demand ? "D_" : "S_")+
                     IntegerToString(z.id);

   const datetime end_time=
      TimeCurrent()+(datetime)(PeriodSeconds(_Period)*40);

   if(!ObjectCreate(ChartID(),name,OBJ_RECTANGLE,0,
                    z.source_time,z.low,end_time,z.high))
      return;

   const color c=z.demand ? clrDeepSkyBlue : clrTomato;

   ObjectSetInteger(ChartID(),name,OBJPROP_COLOR,c);
   ObjectSetInteger(ChartID(),name,OBJPROP_WIDTH,1);
   ObjectSetInteger(ChartID(),name,OBJPROP_BACK,true);
   ObjectSetInteger(ChartID(),name,OBJPROP_FILL,FillZoneRectangles);
   ObjectSetInteger(ChartID(),name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(ChartID(),name,OBJPROP_HIDDEN,true);

   string state="CREATED";
   if(z.signaled) state="SIGNALED";
   else if(z.departed) state="DEPARTED";

   ObjectSetString(ChartID(),name,OBJPROP_TOOLTIP,
      (z.demand ? "DEMAND" : "SUPPLY")+" #"+IntegerToString(z.id)+
      " | source="+TimeToString(z.source_time,TIME_DATE|TIME_MINUTES)+
      " | BOS="+TimeToString(z.bos_time,TIME_DATE|TIME_MINUTES)+
      " | state="+state+
      (z.departed_time>0
         ? " | departed="+TimeToString(z.departed_time,TIME_DATE|TIME_MINUTES)
         : ""));
}

void DrawZones()
{
   DeleteZoneObjects();
   if(!DrawZoneRectangles) return;

   int d=0,s=0;

   for(int i=ArraySize(g_zones)-1; i>=0; i--)
   {
      if(!g_zones[i].valid) continue;

      if(g_zones[i].demand)
      {
         if(d>=MaxDemandZonesToDraw) continue;
         DrawOneZone(g_zones[i]);
         d++;
      }
      else
      {
         if(s>=MaxSupplyZonesToDraw) continue;
         DrawOneZone(g_zones[i]);
         s++;
      }
   }
}

void DeleteDashboard()
{
   const string name=g_prefix+"DASH";
   if(ObjectFind(ChartID(),name)>=0)
      ObjectDelete(ChartID(),name);
}

void RenderDashboard()
{
   if(!ShowDashboard)
   {
      DeleteDashboard();
      return;
   }

   const string name=g_prefix+"DASH";

   if(ObjectFind(ChartID(),name)<0)
   {
      if(!ObjectCreate(ChartID(),name,OBJ_LABEL,0,0,0))
         return;

      ObjectSetInteger(ChartID(),name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(ChartID(),name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(ChartID(),name,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(ChartID(),name,OBJPROP_YDISTANCE,15);
      ObjectSetInteger(ChartID(),name,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(ChartID(),name,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(ChartID(),name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(ChartID(),name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(ChartID(),name,OBJPROP_ZORDER,1000);
      ObjectSetString(ChartID(),name,OBJPROP_FONT,"Arial");
   }

   string dh="none",dl="none";
   if(g_day_high_ref>0.0)
      dh=DoubleToString(g_day_high_ref,_Digits);
   if(g_day_low_ref>0.0)
      dl=DoubleToString(g_day_low_ref,_Digits);

   string text="BOS SUPPLY / DEMAND v1.08 STABLE\n";
   text+="Day: "+TradingDayText(g_trading_day_key)+"\n";
   text+="Last BOS: "+DirName(g_last_bos_dir)+"\n";

   string allowed="BOTH";
   if(RequireLatestBOSDirection)
   {
      if(g_last_bos_dir>0) allowed="BUY ONLY";
      else if(g_last_bos_dir<0) allowed="SELL ONLY";
      else allowed="WAIT";
   }

   text+="Signal side: "+allowed+"\n";
   text+="Day H: "+dh+" | Day L: "+dl+"\n";
   text+="HH breaks: "+IntegerToString(g_day_hh_breaks)+
         " | LL breaks: "+IntegerToString(g_day_ll_breaks)+"\n";
   text+="Demand: "+IntegerToString(ActiveZoneCount(true));
   text+=" | Supply: "+IntegerToString(ActiveZoneCount(false))+"\n";
   text+="Zone IDs: STABLE BY SOURCE\n";
   text+="Last signal: "+g_last_signal_text+"\n";
   text+="PREV DAY H/L -> HH/LL -> STABLE ZONE -> DEPART -> RETEST";

   ObjectSetString(ChartID(),name,OBJPROP_TEXT,text);
}

//=============================== INIT ================================
int OnInit()
{
   SetIndexBuffer(0,BuySignalBuffer,INDICATOR_DATA);
   SetIndexBuffer(1,SellSignalBuffer,INDICATOR_DATA);
   SetIndexBuffer(2,SignalZoneLowBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(3,SignalZoneHighBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(4,DemandLowBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(5,DemandHighBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(6,SupplyLowBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(7,SupplyHighBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(8,BOSDirectionBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(9,SignalZoneIdBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(10,BuyEntryPriceBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(11,SellEntryPriceBuffer,INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BuySignalBuffer,true);
   ArraySetAsSeries(SellSignalBuffer,true);
   ArraySetAsSeries(SignalZoneLowBuffer,true);
   ArraySetAsSeries(SignalZoneHighBuffer,true);
   ArraySetAsSeries(DemandLowBuffer,true);
   ArraySetAsSeries(DemandHighBuffer,true);
   ArraySetAsSeries(SupplyLowBuffer,true);
   ArraySetAsSeries(SupplyHighBuffer,true);
   ArraySetAsSeries(BOSDirectionBuffer,true);
   ArraySetAsSeries(SignalZoneIdBuffer,true);
   ArraySetAsSeries(BuyEntryPriceBuffer,true);
   ArraySetAsSeries(SellEntryPriceBuffer,true);

   PlotIndexSetInteger(0,PLOT_ARROW,233);
   PlotIndexSetInteger(1,PLOT_ARROW,234);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,clrLime);
   PlotIndexSetInteger(1,PLOT_LINE_COLOR,clrTomato);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      "Master BOS Supply Demand v1.08 StableZones");
   IndicatorSetInteger(INDICATOR_DIGITS,_Digits);

   ResetEngine();

   Print("Master BOS Supply Demand v1.08 StableZones initialized on ",
         _Symbol," ",EnumToString((ENUM_TIMEFRAMES)_Period),
         ". Previous-day H/L + rolling HH/LL + stable source IDs + armed retest. Research only / no orders.");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteZoneObjects();
   DeleteDashboard();
}

//========================== MAIN CALCULATION =========================
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // IMPORTANT: all engine logic below assumes MT5 timeseries indexing:
   // [0] current forming bar, [1] latest closed bar, larger = older.
   // Explicitly enforce it so history replay cannot accidentally walk
   // forward from the oldest broker data.
   ArraySetAsSeries(time,true);
   ArraySetAsSeries(open,true);
   ArraySetAsSeries(high,true);
   ArraySetAsSeries(low,true);
   ArraySetAsSeries(close,true);

   const int required=
      MathMax(50,LastOppositeCandleSearchBars+20);

   if(rates_total<required)
      return 0;

   if(prev_calculated==0 || g_last_processed_bar==0)
   {
      ArrayInitialize(BuySignalBuffer,EMPTY_VALUE);
      ArrayInitialize(SellSignalBuffer,EMPTY_VALUE);
      ArrayInitialize(SignalZoneLowBuffer,EMPTY_VALUE);
      ArrayInitialize(SignalZoneHighBuffer,EMPTY_VALUE);
      ArrayInitialize(DemandLowBuffer,EMPTY_VALUE);
      ArrayInitialize(DemandHighBuffer,EMPTY_VALUE);
      ArrayInitialize(SupplyLowBuffer,EMPTY_VALUE);
      ArrayInitialize(SupplyHighBuffer,EMPTY_VALUE);
      ArrayInitialize(BOSDirectionBuffer,0.0);
      ArrayInitialize(SignalZoneIdBuffer,0.0);
      ArrayInitialize(BuyEntryPriceBuffer,EMPTY_VALUE);
      ArrayInitialize(SellEntryPriceBuffer,EMPTY_VALUE);

      ReplayHistory(time,open,high,low,close,rates_total);

      g_last_processed_bar=time[0];
      DrawZones();
      RenderDashboard();
      ChartRedraw();
      return rates_total;
   }

   // Closed-bar operation: normally exactly one new bar since the last
   // call. But if the terminal missed updates (disconnect, minimized
   // chart, etc.) more than one bar can have closed in the meantime -
   // locate how far back the previously-"current" bar now sits and
   // process every bar that closed since then, oldest to newest. If it
   // can no longer be found in the series (gap larger than we can
   // recover, or history was rebuilt), fall back to a full replay
   // instead of silently skipping bars.
   if(time[0]!=g_last_processed_bar)
   {
      int gap_index=-1;
      const int scan_limit=MathMin(rates_total-1,LookbackBars);

      for(int i=1; i<=scan_limit; i++)
      {
         if(time[i]==g_last_processed_bar)
         {
            gap_index=i;
            break;
         }
      }

      if(gap_index<=0)
      {
         ReplayHistory(time,open,high,low,close,rates_total);
      }
      else
      {
         for(int bar=gap_index; bar>=1; bar--)
            ProcessClosedBar(bar,time,open,high,low,close,rates_total,true);
      }

      g_last_processed_bar=time[0];

      DrawZones();
      RenderDashboard();
      ChartRedraw();
   }

   return rates_total;
}
//+------------------------------------------------------------------+
