/**
 * SnowRoller - a pyramiding trade manager
 *
 *
 * For theoretical background and proof-of-concept see the links to "Snowballs and the anti-grid" by Bernd Kreu� (aka 7bit).
 *
 * This EA is a re-implementation of the above concept. It can be used as a trade manager or as a complete trading system.
 * Once started the EA waits until one of the defined start conditions is fulfilled. It then manages the resulting trades in
 * a pyramiding way until one of the defined stop conditions is fulfilled. Start conditions can be price, time or a trend
 * change of one of the supported trend indicators. Stop conditions can be price, time, a trend change of one the supported
 * trend indicators or an absolute or percentage stoploss or takeprofit amount. Multiple start and stop conditions may be
 * combined.
 *
 * If both start and stop parameters define a trend condition the EA waits after a trend stop signal and continues trading
 * when the next trend start condition is fulfilled. The EA finally stops when takeprofit or stoploss are reached.
 *
 * If one of the AutoRestart options is enabled the EA continuously resets itself after takeprofit or stoploss are reached.
 * If AutoRestart is set to "Continue" the EA resets itself to the initial state and immediately continues trading at level 1.
 * If AutoRestart is set to "Reset" the EA resets itself to the initial state and waits for the next start condition to be
 * fulfilled. For both AutoRestart options start and stop parameters must define a trend condition.
 *
 * The EA automatically interrupts and resumes trading during configurable session breaks, e.g. at Midnight or at weekends.
 * During session breaks all pending orders and open positions are closed and the overnight risk is zero. Session break
 * configuration supports holidays.
 *
 * In "/mql4/scripts" there are some accompanying scripts named "SnowRoller.***" to manually control the EA. The EA can be
 * tested in "Strategy Tester" and the scripts work in the tester, too. The EA can't be optimized in the tester.
 *
 * The EA is not FIFO conforming and requires a "hedging" account with support for "close by opposite position". It does not
 * support bucketshop accounts, i.e. accounts where MODE_FREEZELEVEL or MODE_STOPLEVEL are not 0 (zero).
 *
 *  @link  https://sites.google.com/site/prof7bit/snowball       ["Snowballs and the anti-grid"]
 *  @link  https://www.forexfactory.com/showthread.php?t=226059  ["Snowballs and the anti-grid"]
 *  @link  https://www.forexfactory.com/showthread.php?t=239717  ["Trading the anti-grid with the Snowball EA"]
 *
 *
 * Risk warning: The market can range longer without reaching the profit target than a trading account may be able to survive.
 */
#include <stddefines.mqh>
#include <app/snowroller/defines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string   Sequence.ID            = "";                            // instance id in format /T?[0-9]{4,}/, affects magic number and status/logfile names
extern string   GridDirection          = "Long | Short";                // no bi-directional mode
extern int      GridSize               = 20;                            //
extern string   UnitSize               = "[L]{double} | auto*";         // fixed (double), compounding (L{double}) or externally configured (auto) unitsize
extern string   StartConditions        = "";                            // @trend(<indicator>:<timeframe>:<params>) | @price(double) | @time(datetime)
extern string   StopConditions         = "";                            // @trend(<indicator>:<timeframe>:<params>) | @price(double) | @time(datetime) | @tp(double[%]) | @sl(double[%])
extern string   AutoRestart            = "Off* | Continue | Reset";     // whether to continue or reset a sequence after StopSequence(SIGNAL_TP|SIGNAL_SL)
extern int      StartLevel             = 0;                             //
extern bool     ShowProfitInPercent    = true;                          // whether PL is displayed in absolute or percentage terms
extern datetime Sessionbreak.StartTime = D'1970.01.01 23:56:00';        // in FXT, the date part is ignored
extern datetime Sessionbreak.EndTime   = D'1970.01.01 01:02:10';        // in FXT, the date part is ignored

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfHistory.mqh>
#include <rsfLibs.mqh>
#include <functions/BarOpenEvent.mqh>
#include <functions/JoinInts.mqh>
#include <functions/JoinStrings.mqh>
#include <structs/rsf/OrderExecution.mqh>
#include <win32api.mqh>


#define STRATEGY_ID  103                           // unique strategy identifier
bool    SNOWROLLER;
bool    SISYPHUS;


// --- sequence data -----------------------
int      sequence.id;
int      sequence.cycle;                           // counter of restarted sequences if AutoRestart is not "Off"
string   sequence.name     = "";                   // "L.1234"    | "S.5678"
string   sequence.longName = "";                   // "L.1234.+1" | "S.5678.-2"
datetime sequence.created;
bool     sequence.isTest;                          // whether the sequence is/was a test (a finished test can be loaded into an online chart)
double   sequence.unitsize;                        // lots per gridlevel
int      sequence.direction;
int      sequence.status;
int      sequence.level;                           // current gridlevel:      -n...0...+n
int      sequence.maxLevel;                        // max. reached gridlevel: -n...0...+n
int      sequence.missedLevels[];                  // missed gridlevels, e.g. in a fast moving market
double   sequence.startEquity;
int      sequence.stops;                           // number of stopped-out positions: 0...+n
double   sequence.stopsPL;                         // accumulated P/L of all stopped-out positions
double   sequence.closedPL;                        // accumulated P/L of all positions closed at sequence stop
double   sequence.floatingPL;                      // accumulated P/L of all open positions
double   sequence.totalPL;                         // current total P/L of the sequence: totalPL = stopsPL + closedPL + floatingPL
double   sequence.maxProfit;                       // max. experienced total sequence profit:   0...+n
double   sequence.maxDrawdown;                     // max. experienced total sequence drawdown: -n...0
double   sequence.profitPerLevel;                  // current profit amount per gridlevel
double   sequence.breakeven;                       // current breakeven price
double   sequence.commission;                      // commission value per gridlevel: -n...0

int      sequence.start.event [];                  // sequence starts (the moment status changes to STATUS_PROGRESSING)
datetime sequence.start.time  [];
double   sequence.start.price [];                  // average open price of all positions opened at sequence start
double   sequence.start.profit[];

int      sequence.stop.event  [];                  // sequence stops (the moment status changes to STATUS_STOPPED)
datetime sequence.stop.time   [];
double   sequence.stop.price  [];                  // average close price of all positions closed at sequence stop
double   sequence.stop.profit [];

// --- start conditions ("AND" combined) ---
bool     start.conditions;                         // whether any start condition is active

bool     start.trend.condition;
string   start.trend.indicator   = "";
int      start.trend.timeframe;
string   start.trend.params      = "";
string   start.trend.description = "";

bool     start.price.condition;
int      start.price.type;                         // PRICE_BID | PRICE_ASK | PRICE_MEDIAN
double   start.price.value;
double   start.price.lastValue;
string   start.price.description = "";

bool     start.time.condition;
datetime start.time.value;
string   start.time.description = "";

// --- stop conditions ("OR" combined) -----
bool     stop.trend.condition;                     // whether a stop trend condition is active
string   stop.trend.indicator   = "";
int      stop.trend.timeframe;
string   stop.trend.params      = "";
string   stop.trend.description = "";

bool     stop.price.condition;                     // whether a stop price condition is active
int      stop.price.type;                          // PRICE_BID | PRICE_ASK | PRICE_MEDIAN
double   stop.price.value;
double   stop.price.lastValue;
string   stop.price.description = "";

bool     stop.time.condition;                      // whether a stop time condition is active
datetime stop.time.value;
string   stop.time.description = "";

bool     stop.profitAbs.condition;                 // whether an absolute takeprofit condition is active
double   stop.profitAbs.value;
string   stop.profitAbs.description = "";

bool     stop.profitPct.condition;                 // whether a percentage takeprofit condition is active
double   stop.profitPct.value;
double   stop.profitPct.absValue    = INT_MAX;
string   stop.profitPct.description = "";

bool     stop.lossAbs.condition;                   // whether an absolute stoploss condition is active
double   stop.lossAbs.value;
string   stop.lossAbs.description = "";

bool     stop.lossPct.condition;                   // whether a percentage stoploss condition is active
double   stop.lossPct.value;
double   stop.lossPct.absValue    = INT_MIN;
string   stop.lossPct.description = "";

// --- session break management ------------
datetime sessionbreak.starttime;                   // configurable via inputs and framework config
datetime sessionbreak.endtime;
bool     sessionbreak.waiting;                     // whether the sequence waits to resume during or after a session break
int      sessionbreak.startSignal;                 // start signal occurred during sessionbreak

// --- gridbase management -----------------
int      gridbase.event [];                        // gridbase event id
datetime gridbase.time  [];                        // time of gridbase event
double   gridbase.price [];                        // gridbase value
int      gridbase.status[];                        // status at time of gridbase event

// --- order data --------------------------
int      orders.ticket      [];
int      orders.level       [];                    // order gridlevel: -n...-1 | 1...+n
double   orders.gridbase    [];                    // gridbase at the time the order was active
int      orders.pendingType [];                    // pending order type (if applicable)        or -1
datetime orders.pendingTime [];                    // time of OrderOpen() or last OrderModify() or  0
double   orders.pendingPrice[];                    // pending entry limit                       or  0
int      orders.type        [];
int      orders.openEvent   [];
datetime orders.openTime    [];
double   orders.openPrice   [];
int      orders.closeEvent  [];
datetime orders.closeTime   [];
double   orders.closePrice  [];
double   orders.stopLoss    [];
bool     orders.closedBySL  [];
double   orders.swap        [];
double   orders.commission  [];
double   orders.profit      [];

// --- other -------------------------------
int      lastEventId;
int      limitOrderTrailing;                       // limit trailing to one request per <x> seconds (default: 3)
int      lastNetworkError;                         // the last trade server network error (if any)
datetime nextRetry;                                // time of the next trade retry after a network error
int      retries;                                  // number of retries so far

int      ignorePendingOrders  [];                  // orphaned tickets to ignore
int      ignoreOpenPositions  [];                  // ...
int      ignoreClosedPositions[];                  // ...

int      startStopDisplayMode = SDM_PRICE;         // whether start/stop markers are displayed
int      orderDisplayMode     = ODM_PYRAMID;       // current order display mode

string   sLotSize                = "";             // caching vars to speed-up execution of ShowStatus()
string   sGridBase               = "";
string   sSequenceDirection      = "";
string   sSequenceMissedLevels   = "";
string   sSequenceStops          = "";
string   sSequenceStopsPL        = "";
string   sSequenceTotalPL        = "";
string   sSequenceMaxProfit      = "";
string   sSequenceMaxDrawdown    = "";
string   sSequenceProfitPerLevel = "";
string   sSequencePlStats        = "";
string   sStartConditions        = "";
string   sStopConditions         = "";
string   sStartStopStats         = "";
string   sAutoRestart            = "";
string   sRestartStats           = "";

// --- debug settings ----------------------       // configurable via framework config, @see SnowRoller::afterInit()
bool     tester.onStartPause        = false;       // whether to pause the tester on a fulfilled start/resume condition
bool     tester.onStopPause         = false;       // whether to pause the tester on a fulfilled stop condition
bool     tester.onSessionBreakPause = false;       // whether to pause the tester on a sessionbreak stop/resume
bool     tester.onTrendChangePause  = false;       // whether to pause the tester on a fulfilled trend change condition
bool     tester.onTakeProfitPause   = false;       // whether to pause the tester when takeprofit is reached
bool     tester.onStopLossPause     = false;       // whether to pause the tester when stoploss is reached

bool     tester.reduceStatusWrites  = true;        // whether to minimize status file writing in tester
bool     tester.showBreakeven       = false;       // whether to show breakeven markers in tester


#include <app/snowroller/1-init.mqh>
#include <app/snowroller/2-deinit.mqh>
#include <app/snowroller/functions.mqh>


/*
  Program actions, events and status changes:
 +---------------------+---------------------+--------------------+
 |       Actions       |       Events        |       Status       |
 +---------------------+---------------------+--------------------+
 | EA::init()          |         -           | STATUS_UNDEFINED   |
 +---------------------+---------------------+--------------------+
 | EA::start()         |         -           | STATUS_WAITING     |
 |                     |                     |                    |
 | (start condition)   |         -           | STATUS_WAITING     |
 |                     |                     |                    |
 | StartSequence()     | EV_SEQUENCE_START   | STATUS_STARTING    |
 | (open order)        |                     | STATUS_PROGRESSING |
 |                     |                     |                    |
 | TrailPendingOrder() | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order filled)      | EV_POSITION_OPEN    | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order stopped out) | EV_POSITION_STOPOUT | STATUS_PROGRESSING |
 |                     |                     |                    |
 | TrailGridBase()     | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (stop condition)    |         -           | STATUS_PROGRESSING |
 |                     |                     |                    |
 | StopSequence()      |         -           | STATUS_STOPPING    |
 | (close position)    | EV_POSITION_CLOSE   | STATUS_STOPPING    |
 |                     | EV_SEQUENCE_STOP    | STATUS_STOPPED     |
 +---------------------+---------------------+--------------------+
 | (start condition)   |         -           | STATUS_WAITING     |
 |                     |                     |                    |
 | ResumeSequence()    |         -           | STATUS_STARTING    |
 | (update gridbase)   | EV_GRIDBASE_CHANGE  | STATUS_STARTING    |
 | (open position)     | EV_POSITION_OPEN    | STATUS_STARTING    |
 |                     | EV_SEQUENCE_START   | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order filled)      | EV_POSITION_OPEN    | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order stopped out) | EV_POSITION_STOPOUT | STATUS_PROGRESSING |
 |                     |                     |                    |
 | TrailGridBase()     | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |
 | ...                 |                     |                    |
 +---------------------+---------------------+--------------------+
*/


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   if (sequence.status == STATUS_UNDEFINED)
      return(NO_ERROR);

   if (!HandleCommands())      return(last_error);                // process incoming commands
   if (!HandleNetworkErrors()) return(last_error);                // process occurred network errors

   int signal;

   // sequence either waits for start/stop/resume signal...
   if (sequence.status == STATUS_WAITING) {
      if      (IsStopSignal(signal))           StopSequence(signal);
      else if (IsStartSignal(signal)) {
         if (!ArraySize(sequence.start.event)) StartSequence(signal);
         else                                  ResumeSequence(signal);
      }
   }

   // ...or sequence is running...
   else if (sequence.status == STATUS_PROGRESSING) {
      bool gridChanged = false;                                   // whether the current gridbase or gridlevel changed
      if (UpdateStatus(gridChanged)) {
         if (IsStopSignal(signal))        StopSequence(signal);
         else if (Tick==1 || gridChanged) UpdatePendingOrders();
      }
   }

   // ...or sequence is stopped
   else if (sequence.status != STATUS_STOPPED) return(catch("onTick(1)  "+ sequence.longName +" illegal sequence status: "+ StatusToStr(sequence.status), ERR_ILLEGAL_STATE));

   // update equity for equity recorder
   if (EA.RecordEquity) tester.equityValue = sequence.startEquity + sequence.totalPL;

   return(last_error);
}


/**
 * Start a new trade sequence.
 *
 * @param  int signal - signal which triggered a start condition or NULL if no condition was triggered (manual start)
 *
 * @return bool - success status
 */
bool StartSequence(int signal) {
   if (IsLastError())                     return(false);
   if (sequence.status != STATUS_WAITING) return(!catch("StartSequence(1)  "+ sequence.longName +" cannot start "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("StartSequence()", "Do you really want to start a new \""+ StrToLower(TradeDirectionDescription(sequence.direction)) +"\" sequence now?"))
      return(_false(StopSequence(NULL)));

   sequence.status = STATUS_STARTING;

   double gridbase = GetGridbase();
   if (__LOG()) log("StartSequence(2)  "+ sequence.name +" starting sequence at level "+ sequence.level +"..."+ ifString(gridbase, " (predefined gridbase "+ NumberToStr(gridbase, PriceFormat) +")", ""));

   // update start/stop conditions
   switch (signal) {
      case SIGNAL_SESSIONBREAK:
         break;

      case SIGNAL_TREND:
         start.trend.condition = true;
         start.conditions      = true;
         break;

      case SIGNAL_PRICETIME:
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = (start.trend.condition);
         break;

      case NULL:                                                  // manual start
         start.trend.condition = (start.trend.description != "");
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = (start.trend.condition);
         break;

      default: return(!catch("StartSequence(3)  "+ sequence.longName +" unsupported start signal = "+ signal, ERR_INVALID_PARAMETER));
   }
   sessionbreak.waiting = false;
   SS.StartStopConditions();

   // re-calculate start equity and unitsize
   sequence.startEquity = CalculateStartEquity();
   sequence.unitsize    = CalculateUnitSize(sequence.startEquity);

   if (StartLevel != 0) {
      sequence.level    = ifInt(sequence.direction==D_LONG, StartLevel, -StartLevel); SS.SequenceName();
      sequence.maxLevel = sequence.level;
   }

   // calculate new start price and set start/stop data before setting the gridbase
   datetime startTime  = TimeCurrentEx("StartSequence(5)");
   double   startPrice = ifDouble(sequence.direction==D_SHORT, Bid, Ask);

   ArrayPushInt   (sequence.start.event,  CreateEventId());
   ArrayPushInt   (sequence.start.time,   startTime      );
   ArrayPushDouble(sequence.start.price,  startPrice     );
   ArrayPushDouble(sequence.start.profit, 0              );

   ArrayPushInt   (sequence.stop.event,   0);                     // keep sizes of sequence.start/stop.* synchronous
   ArrayPushInt   (sequence.stop.time,    0);
   ArrayPushDouble(sequence.stop.price,   0);
   ArrayPushDouble(sequence.stop.profit,  0);
   SS.StartStopStats();

   // calculate new gridbase and set it after start/stop data
   if (!gridbase)                                                 // use an existing pre-set gridbase
      gridbase = startPrice - sequence.level*GridSize*Pips;
   ResetGridbase(startTime, gridbase);                            // make sure the gridbase event follows the start event

   // open start positions if configured, and update start price according to real gridbase or realized price
   if (!StartLevel) startPrice = NormalizeDouble(gridbase + sequence.level*GridSize*Pips, Digits);
   else if (!RestorePositions(startTime, startPrice)) return(false);

   sequence.start.price[0] = startPrice;
   sequence.status         = STATUS_PROGRESSING;

   // open missing orders
   if (!UpdatePendingOrders(SAVESTATUS_ENFORCE)) return(false);
   RedrawStartStop();

   if (__LOG()) log("StartSequence(6)  "+ sequence.name +" sequence started at level "+ sequence.level +" (start price "+ NumberToStr(startPrice, PriceFormat) +", gridbase "+ NumberToStr(gridbase, PriceFormat) +")");

   // pause the tester according to the configuration
   if (IsTesting()) /*&&*/ if (IsVisualMode()) {
      if      (tester.onStartPause)                                       Tester.Pause("StartSequence(7)");
      else if (tester.onSessionBreakPause && signal==SIGNAL_SESSIONBREAK) Tester.Pause("StartSequence(8)");
      else if (tester.onTrendChangePause  && signal==SIGNAL_TREND)        Tester.Pause("StartSequence(9)");
   }
   return(!catch("StartSequence(10)"));
}


/**
 * Close all open positions and delete pending orders. Stop the sequence and configure auto-resuming: If auto-resuming for a
 * trend condition is enabled the sequence is automatically resumed the next time the trend condition is fulfilled. If the
 * sequence is stopped due to a session break it is automatically resumed after the session break ends.
 *
 * @param  int signal - signal which triggered the stop condition or NULL if no condition was triggered (explicit stop)
 *
 * @return bool - success status
 */
bool StopSequence(int signal) {
   if (IsLastError())                                                          return(false);
   if (sequence.status!=STATUS_WAITING && sequence.status!=STATUS_PROGRESSING) return(!catch("StopSequence(1)  "+ sequence.longName +" cannot stop "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   // a waiting sequence has no open orders (before first start or after stop)
   if (sequence.status == STATUS_WAITING) {
      sequence.status = STATUS_STOPPED;
      if (__LOG()) log("StopSequence(2)  "+ sequence.longName +" stopped");
   }

   // a progressing sequence has open orders to close
   else if (sequence.status == STATUS_PROGRESSING) {
      if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("StopSequence()", "Do you really want to stop sequence "+ sequence.name +"."+ NumberToStr(sequence.level, "+.") +" now?"))
         return(!SetLastError(ERR_CANCELLED_BY_USER));

      sequence.status = STATUS_STOPPING;
      if (__LOG()) log("StopSequence(3)  "+ sequence.longName +" stopping sequence...");

      // close open orders
      double stopPrice, slippage = 2;
      int level, oeFlags, oes[][ORDER_EXECUTION.intSize];
      int pendingLimits[], openPositions[], sizeOfTickets = ArraySize(orders.ticket);
      ArrayResize(pendingLimits, 0);
      ArrayResize(openPositions, 0);

      // get all locally active orders (pending limits and open positions)
      for (int i=sizeOfTickets-1; i >= 0; i--) {
         if (!orders.closeTime[i]) {                                       // local: if (isOpen)
            level = orders.level[i];
            ArrayPushInt(pendingLimits, i);                                // pending entry or exit limit
            if (orders.type[i] != OP_UNDEFINED)
               ArrayPushInt(openPositions, orders.ticket[i]);              // open position
            if (Abs(level) == 1) break;
         }
      }

      // hedge open positions
      int sizeOfPositions = ArraySize(openPositions);
      if (sizeOfPositions > 0) {
         oeFlags  = F_OE_DONT_CHECK_STATUS;                                // skip status check to prevent errors
         oeFlags |= F_ERR_NO_CONNECTION;                                   // custom handling of recoverable network errors
         oeFlags |= F_ERR_TRADESERVER_GONE;
         oeFlags |= F_ERR_TRADE_DISABLED;
         oeFlags |= F_ERR_MARKET_CLOSED;

         int ticket = OrdersHedge(openPositions, slippage, oeFlags, oes);
         if (!ticket) {
            int error = oes.Error(oes, 0);
            switch (error) {
               case ERR_NO_CONNECTION:
               case ERR_TRADESERVER_GONE:
               case ERR_TRADE_DISABLED:
               case ERR_MARKET_CLOSED:
                  return(!SetLastNetworkError(oes));
            }
            return(!SetLastError(error));
         }
         ArrayPushInt(openPositions, ticket);
         sizeOfPositions++;
         stopPrice = oes.ClosePrice(oes, 0);
      }

      // delete all pending limits
      int sizeOfPendings = ArraySize(pendingLimits);
      for (i=0; i < sizeOfPendings; i++) {                                 // ordered by descending gridlevel
         if (orders.type[pendingLimits[i]] == OP_UNDEFINED) {
            error = Grid.DeleteOrder(pendingLimits[i]);                    // removes the order from the order arrays
            if (!error)      continue;
            if (error != -1) return(false);                                // entry stop is already executed

            if (!SelectTicket(orders.ticket[pendingLimits[i]], "StopSequence(4)")) return(false);
            orders.type      [pendingLimits[i]] = OrderType();
            orders.openEvent [pendingLimits[i]] = CreateEventId();
            orders.openTime  [pendingLimits[i]] = OrderOpenTime();
            orders.openPrice [pendingLimits[i]] = OrderOpenPrice();
            orders.swap      [pendingLimits[i]] = OrderSwap();
            orders.commission[pendingLimits[i]] = OrderCommission();
            orders.profit    [pendingLimits[i]] = OrderProfit();
            if (__LOG()) log("StopSequence(5)  "+ sequence.longName +" "+ UpdateStatus.OrderFillMsg(pendingLimits[i]));
            if (IsStopOrderType(orders.pendingType[pendingLimits[i]])) {   // the next gridlevel was triggered
               sequence.level   += Sign(orders.level[pendingLimits[i]]); SS.SequenceName();
               sequence.maxLevel = Sign(orders.level[pendingLimits[i]]) * Max(Abs(sequence.level), Abs(sequence.maxLevel));
            }
            else {                                                         // a previously missed gridlevel was triggered
               ArrayDropInt(sequence.missedLevels, orders.level[pendingLimits[i]]);
               SS.MissedLevels();
            }
            if (__LOG()) log("StopSequence(6)  "+ sequence.longName +" adding ticket #"+ OrderTicket() +" to open positions");
            ArrayPushInt(openPositions, OrderTicket());                    // add to open positions
            i--;                                                           // process the position's stoploss limit
         }
         else {
            error = Grid.DeleteLimit(pendingLimits[i]);
            if (!error)      continue;
            if (error != -1) return(false);                                // stoploss is already executed

            if (!SelectTicket(orders.ticket[pendingLimits[i]], "StopSequence(7)")) return(false);
            orders.closeEvent[pendingLimits[i]] = CreateEventId();
            orders.closeTime [pendingLimits[i]] = OrderCloseTime();
            orders.closePrice[pendingLimits[i]] = OrderClosePrice();
            orders.closedBySL[pendingLimits[i]] = true;
            orders.swap      [pendingLimits[i]] = OrderSwap();
            orders.commission[pendingLimits[i]] = OrderCommission();
            orders.profit    [pendingLimits[i]] = OrderProfit();
            if (__LOG()) log("StopSequence(8)  "+ sequence.longName +" "+ UpdateStatus.StopLossMsg(pendingLimits[i]));
            sequence.stops++;
            sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[pendingLimits[i]] + orders.commission[pendingLimits[i]] + orders.profit[pendingLimits[i]], 2); SS.Stops();
            ArrayDropInt(openPositions, OrderTicket());                    // remove from open positions
         }
      }

      // close open positions
      int pos;
      sizeOfPositions = ArraySize(openPositions);
      double remainingSwap, remainingCommission, remainingProfit;

      if (sizeOfPositions > 0) {
         oeFlags  = F_ERR_NO_CONNECTION;                                   // custom handling of recoverable network errors
         oeFlags |= F_ERR_TRADESERVER_GONE;
         oeFlags |= F_ERR_TRADE_DISABLED;
         oeFlags |= F_ERR_MARKET_CLOSED;

         if (!OrdersClose(openPositions, slippage, CLR_CLOSE, oeFlags, oes)) {
            error = oes.Error(oes, 0);
            switch (error) {
               case ERR_NO_CONNECTION:
               case ERR_TRADESERVER_GONE:
               case ERR_TRADE_DISABLED:
               case ERR_MARKET_CLOSED:
                  return(!SetLastNetworkError(oes));
            }
            return(!SetLastError(error));
         }

         for (i=0; i < sizeOfPositions; i++) {
            pos = SearchIntArray(orders.ticket, openPositions[i]);
            if (pos != -1) {
               orders.closeEvent[pos] = CreateEventId();
               orders.closeTime [pos] = oes.CloseTime (oes, i);
               orders.closePrice[pos] = oes.ClosePrice(oes, i);
               orders.closedBySL[pos] = false;
               orders.swap      [pos] = oes.Swap      (oes, i);
               orders.commission[pos] = oes.Commission(oes, i);
               orders.profit    [pos] = oes.Profit    (oes, i);
            }
            else {
               remainingSwap       += oes.Swap      (oes, i);
               remainingCommission += oes.Commission(oes, i);
               remainingProfit     += oes.Profit    (oes, i);
            }
            sequence.closedPL = NormalizeDouble(sequence.closedPL + oes.Swap(oes, i) + oes.Commission(oes, i) + oes.Profit(oes, i), 2);
         }
         pos = ArraySize(orders.ticket)-1;                                 // the last ticket is always a closed position
         orders.swap      [pos] += remainingSwap;
         orders.commission[pos] += remainingCommission;
         orders.profit    [pos] += remainingProfit;
      }

      // update statistics and sequence status
      sequence.floatingPL = 0;
      sequence.totalPL    = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2); SS.TotalPL();
      if      (sequence.totalPL > sequence.maxProfit  ) { sequence.maxProfit   = sequence.totalPL; SS.MaxProfit();   }
      else if (sequence.totalPL < sequence.maxDrawdown) { sequence.maxDrawdown = sequence.totalPL; SS.MaxDrawdown(); }

      int n = ArraySize(sequence.stop.event) - 1;
      if (!stopPrice) stopPrice = ifDouble(sequence.direction==D_LONG, Bid, Ask);

      sequence.stop.event [n] = CreateEventId();
      sequence.stop.time  [n] = TimeCurrentEx("StopSequence(9)");
      sequence.stop.price [n] = stopPrice;
      sequence.stop.profit[n] = sequence.totalPL;
      RedrawStartStop();

      sequence.status = STATUS_STOPPED;
      if (__LOG()) log("StopSequence(10)  "+ sequence.name +" sequence stopped at level "+ sequence.level +" (stop price "+ NumberToStr(stopPrice, PriceFormat) +", gridbase "+ NumberToStr(GetGridbase(), PriceFormat) +")");
      UpdateProfitTargets();
      ShowProfitTargets();
      SS.ProfitPerLevel();
   }

   sessionbreak.startSignal = NULL;
   sessionbreak.waiting     = false;

   // update start/stop conditions (sequence.status is STATUS_STOPPED)
   switch (signal) {
      case SIGNAL_SESSIONBREAK:
         sessionbreak.waiting = true;
         sequence.status      = STATUS_WAITING;
         break;

      case SIGNAL_TREND:
         if (start.trend.description != "") {               // auto-resume if StartCondition is @trend
            start.conditions      = true;
            start.trend.condition = true;
            stop.trend.condition  = true;                   // stop condition is @trend
            sequence.status       = STATUS_WAITING;
         }
         else {
            stop.trend.condition = false;
         }
         break;

      case SIGNAL_PRICETIME:
         stop.price.condition = false;
         stop.time.condition  = false;
         if (start.trend.description != "") {               // auto-resume if StartCondition is @trend and another
            start.conditions      = true;                   // stop condition is defined
            start.trend.condition = true;
            sequence.status       = STATUS_WAITING;
         }
         break;

      case SIGNAL_TP:                                       // reactivate a triggered TP condition if EA doesn't stop
         stop.profitAbs.condition = (AutoRestart!="Off" && start.trend.description!="" && stop.profitAbs.description!="");
         stop.profitPct.condition = (AutoRestart!="Off" && start.trend.description!="" && stop.profitPct.description!="");
         break;

      case SIGNAL_SL:                                       // reactivate a triggered SL condition if EA doesn't stop
         stop.lossAbs.condition = (AutoRestart!="Off" && start.trend.description!="" && stop.lossAbs.description!="");
         stop.lossPct.condition = (AutoRestart!="Off" && start.trend.description!="" && stop.lossPct.description!="");
         break;

      case NULL:                                            // explicit stop (manual or at end of test)
         break;

      default: return(!catch("StopSequence(11)  "+ sequence.longName +" unsupported stop signal = "+ signal, ERR_INVALID_PARAMETER));
   }
   SS.StartStopConditions();
   SaveStatus();

   // reset the sequence and start a new cycle using the same sequence id
   if (signal == SIGNAL_TP) {
      if (AutoRestart != "Off") {
         double newGridbase      = NULL;
         int    newSequenceLevel = 0;
         if (AutoRestart == "Continue") {                   // continue after TP at level 1 if configured
            newSequenceLevel = ifInt(sequence.direction==D_LONG, 1, -1);
            newGridbase      = stopPrice - newSequenceLevel*GridSize*Pips;
         }
         if (!ResetSequence(newGridbase, newSequenceLevel)) return(false);
         if (AutoRestart == "Continue") StartSequence(NULL);
      }
   }
   else if (signal == SIGNAL_SL) {
      if (AutoRestart != "Off") {
         if (!ResetSequence(NULL, NULL)) return(false);     // full reset (never continue after SL)
      }
   }

   // pause/stop the tester according to the configuration
   if (IsTesting()) {
      if (IsVisualMode()) {
         if      (tester.onStopPause)                                        Tester.Pause("StopSequence(12)");
         else if (tester.onSessionBreakPause && signal==SIGNAL_SESSIONBREAK) Tester.Pause("StopSequence(13)");
         else if (tester.onTrendChangePause  && signal==SIGNAL_TREND)        Tester.Pause("StopSequence(14)");
         else if (tester.onTakeProfitPause   && signal==SIGNAL_TP)           Tester.Pause("StopSequence(15)");
         else if (tester.onStopLossPause     && signal==SIGNAL_SL)           Tester.Pause("StopSequence(16)");
      }
      else if (sequence.status == STATUS_STOPPED)                            Tester.Stop("StopSequence(17)");
   }
   return(!catch("StopSequence(18)"));
}


/**
 * Reset a sequence to its initial state. Called if AutoRestart is enabled and the sequence was stopped due to a reached
 * profit target.
 *
 * @param  double gridbase - the predefined gridbase to reset to       (if trading continues)
 * @param  int    level    - the predefined sequence level to reset to (if trading continues)
 *
 * @return bool - success status
 */
bool ResetSequence(double gridbase, int level) {
   if (IsLastError())                                       return(false);
   if (sequence.status!=STATUS_STOPPED)                     return(!catch("ResetSequence(1)  "+ sequence.longName +" cannot reset "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (AutoRestart=="Off")                                  return(!warn("ResetSequence(2)  "+ sequence.longName +" cannot reset sequence to \"waiting\" (AutoRestart not enabled)", ERR_INVALID_INPUT_PARAMETER));
   if (AutoRestart=="Reset" && start.trend.description=="") return(!warn("ResetSequence(3)  "+ sequence.longName +" cannot reset sequence without a trend start condition", ERR_INVALID_INPUT_PARAMETER));

   // memorize needed vars
   int    iCycle   = sequence.cycle;
   string sPL      = sSequenceTotalPL;
   string sPlStats = sSequencePlStats;

   // reset input parameters
   StartLevel = 0;

   // reset global vars
   // --- sequence data ------------------
   //sequence.id           = ...                         // unchanged
   sequence.cycle++;                                     // increase restart cycle
   //sequence.name         = ...                         // unchanged
   sequence.longName       = sequence.name +"."+ NumberToStr(level, "+.");
   sequence.created        = Max(TimeCurrentEx(), TimeServer());
   //sequence.isTest       = ...                         // unchanged
   //sequence.direction    = ...                         // unchanged
   sequence.status         = STATUS_WAITING;
   sequence.level          = level;
   sequence.maxLevel       = sequence.level;
   ArrayResize(sequence.missedLevels, 0);
   //sequence.startEquity  = ...                         // kept           TODO: really?
   sequence.stops          = 0;
   sequence.stopsPL        = 0;
   sequence.closedPL       = 0;
   sequence.floatingPL     = 0;
   sequence.totalPL        = 0;
   sequence.maxProfit      = 0;
   sequence.maxDrawdown    = 0;
   sequence.profitPerLevel = 0;
   sequence.breakeven      = 0;
   //sequence.commission   = ...                         // kept

   ArrayResize(sequence.start.event,  0);
   ArrayResize(sequence.start.time,   0);
   ArrayResize(sequence.start.price,  0);
   ArrayResize(sequence.start.profit, 0);

   ArrayResize(sequence.stop.event,  0);
   ArrayResize(sequence.stop.time,   0);
   ArrayResize(sequence.stop.price,  0);
   ArrayResize(sequence.stop.profit, 0);

   // --- start conditions ---------------
   start.conditions           = true;
   start.trend.condition      = true;
   //start.trend.indicator    = ...                      // unchanged
   //start.trend.timeframe    = ...                      // unchanged
   //start.trend.params       = ...                      // unchanged
   //start.trend.description  = ...                      // unchanged

   start.price.condition      = false;
   start.price.type           = 0;
   start.price.value          = 0;
   start.price.lastValue      = 0;
   start.price.description    = "";

   start.time.condition       = false;
   start.time.value           = 0;
   start.time.description     = "";

   // --- stop conditions ----------------
   stop.trend.condition       = (stop.trend.description != "");
   stop.trend.indicator       = ifString(stop.trend.condition, stop.trend.indicator,   "");
   stop.trend.timeframe       = ifInt   (stop.trend.condition, stop.trend.timeframe,    0);
   stop.trend.params          = ifString(stop.trend.condition, stop.trend.params,      "");
   stop.trend.description     = ifString(stop.trend.condition, stop.trend.description, "");

   stop.price.condition       = false;
   stop.price.type            = 0;
   stop.price.value           = 0;
   stop.price.lastValue       = 0;
   stop.price.description     = "";

   stop.time.condition        = false;
   stop.time.value            = 0;
   stop.time.description      = "";

   stop.profitAbs.condition   = (stop.profitAbs.description != "");
   stop.profitAbs.value       = ifDouble(stop.profitAbs.condition, stop.profitAbs.value, 0);
   stop.profitAbs.description = ifString(stop.profitAbs.condition, stop.profitAbs.description, "");

   stop.profitPct.condition   = (stop.profitPct.description != "");
   stop.profitPct.value       = ifDouble(stop.profitPct.condition, stop.profitPct.value, 0);
   stop.profitPct.absValue    = ifDouble(stop.profitPct.condition, INT_MAX,              0);
   stop.profitPct.description = ifString(stop.profitPct.condition, stop.profitPct.description, "");

   stop.lossAbs.condition     = (stop.lossAbs.description != "");
   stop.lossAbs.value         = ifDouble(stop.lossAbs.condition, stop.lossAbs.value, 0);
   stop.lossAbs.description   = ifString(stop.lossAbs.condition, stop.lossAbs.description, "");

   stop.lossPct.condition     = (stop.lossPct.description != "");
   stop.lossPct.value         = ifDouble(stop.lossPct.condition, stop.lossPct.value, 0);
   stop.lossPct.absValue      = ifDouble(stop.lossPct.condition, INT_MIN,            0);
   stop.lossPct.description   = ifString(stop.lossPct.condition, stop.lossPct.description, "");

   // --- session break management -------
   sessionbreak.starttime     = 0;
   sessionbreak.endtime       = 0;
   sessionbreak.waiting       = false;

   // --- gridbase management ------------
   ResetGridbase(NULL, gridbase);

   // --- order data ---------------------
   Orders.ResizeArrays(0);

   // --- other --------------------------
   ArrayResize(ignorePendingOrders,   0);
   ArrayResize(ignoreOpenPositions,   0);
   ArrayResize(ignoreClosedPositions, 0);

   //startStopDisplayMode       = ...                    // kept
   //orderDisplayMode           = ...                    // kept

   sLotSize                     = "";
   sGridBase                    = "";
   sSequenceDirection           = "";
   sSequenceMissedLevels        = "";
   sSequenceStops               = "";
   sSequenceStopsPL             = "";
   sSequenceTotalPL             = "";
   sSequenceMaxProfit           = "";
   sSequenceMaxDrawdown         = "";
   sSequenceProfitPerLevel      = "";
   sSequencePlStats             = "";
   sStartConditions             = "";
   sStopConditions              = "";
   sStartStopStats              = "";
   sAutoRestart                 = "";
   sRestartStats                = "-------------------------------------------------------"+ NL
                                 +" "+ iCycle +":  "+ sPL + sPlStats + StrRightFrom(sRestartStats, "--", -1);

   // debug settings stay unchanged

   // store the new status
   SS.All();
   SaveStatus();

   if (__LOG()) log("ResetSequence(4)  "+ sequence.name +" sequence reset to level "+ sequence.level +" ("+ ifString(gridbase, "new gridbase "+ NumberToStr(gridbase, PriceFormat) +", ", "") +"status "+ DoubleQuoteStr(StatusDescription(sequence.status)) +")");
   return(!catch("ResetSequence(5)"));
}


/**
 * Resume a waiting or stopped trade sequence.
 *
 * @param  int signal - signal which triggered a resume condition or NULL if no condition was triggered (manual resume)
 *
 * @return bool - success status
 */
bool ResumeSequence(int signal) {
   if (IsLastError())                                                      return(false);
   if (sequence.status!=STATUS_WAITING && sequence.status!=STATUS_STOPPED) return(!catch("ResumeSequence(1)  "+ sequence.longName +" cannot resume "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("ResumeSequence()", "Do you really want to resume sequence "+ sequence.name +"."+ NumberToStr(sequence.level, "+.") +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   datetime startTime;
   double   lastGridbase = GetGridbase(), stopPrice = sequence.stop.price[ArraySize(sequence.stop.price)-1];
   double   newGridbase, startPrice;

   sequence.status = STATUS_STARTING;
   if (__LOG()) log("ResumeSequence(2)  "+ sequence.name +" resuming sequence at level "+ sequence.level +" (stop price "+ NumberToStr(stopPrice, PriceFormat) +", old gridbase "+ NumberToStr(lastGridbase, PriceFormat) +")");

   // update start/stop conditions
   switch (signal) {
      case SIGNAL_SESSIONBREAK:
         sessionbreak.waiting = false;
         break;

      case SIGNAL_TREND:
         start.trend.condition = true;
         start.conditions      = true;
         break;

      case SIGNAL_PRICETIME:
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = start.trend.condition;
         break;

      case NULL:                                                  // manual resume
         sessionbreak.waiting  = false;
         start.trend.condition = (start.trend.description != "");
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = start.trend.condition;
         break;

      default: return(!catch("ResumeSequence(3)  "+ sequence.longName +" unsupported start signal = "+ signal, ERR_INVALID_PARAMETER));
   }
   SS.StartStopConditions();

   // check for existing positions (after a former error some levels may already be open)
   if (sequence.level > 0) {
      for (int level=1; level <= sequence.level; level++) {
         int i = Grid.FindOpenPosition(level);
         if (i != -1) {
            newGridbase = orders.gridbase[i];                     // get the gridbase to use from already opened positions
            break;
         }
      }
   }
   else if (sequence.level < 0) {
      for (level=-1; level >= sequence.level; level--) {
         i = Grid.FindOpenPosition(level);
         if (i != -1) {
            newGridbase = orders.gridbase[i];
            break;
         }
      }
   }

   // calculate the new gridbase
   if (!newGridbase) {
      // without open positions define the new gridbase using the previous one
      startTime   = TimeCurrentEx("ResumeSequence(4)");
      startPrice  = ifDouble(sequence.direction==D_SHORT, Bid, Ask);
      newGridbase = lastGridbase + startPrice - stopPrice;
      SetGridbase(startTime, newGridbase);
   }
   else {}                                                        // re-use the gridbase of found open positions

   // open the previously active positions and receive last(OrderOpenTime) and avg(OrderOpenPrice)
   if (!RestorePositions(startTime, startPrice)) return(false);

   // store new sequence start
   ArrayPushInt   (sequence.start.event,  CreateEventId() );
   ArrayPushInt   (sequence.start.time,   startTime       );
   ArrayPushDouble(sequence.start.price,  startPrice      );
   ArrayPushDouble(sequence.start.profit, sequence.totalPL);      // same as at the last stop

   ArrayPushInt   (sequence.stop.event,  0);                      // keep sequence.starts/stops synchronous
   ArrayPushInt   (sequence.stop.time,   0);
   ArrayPushDouble(sequence.stop.price,  0);
   ArrayPushDouble(sequence.stop.profit, 0);
   SS.StartStopStats();

   sequence.status = STATUS_PROGRESSING;                          // TODO: correct the resulting gridbase and adjust the previously set stoplosses

   // update stop orders
   if (!UpdatePendingOrders(SAVESTATUS_ENFORCE)) return(false);
   RedrawStartStop();

   if (__LOG()) log("ResumeSequence(5)  "+ sequence.name +" resumed at level "+ sequence.level +" (start price "+ NumberToStr(startPrice, PriceFormat) +", new gridbase "+ NumberToStr(newGridbase, PriceFormat) +")");

   // pause the tester according to the configuration
   if (IsTesting()) /*&&*/ if (IsVisualMode()) {
      if      (tester.onStartPause)                                       Tester.Pause("ResumeSequence(6)");
      else if (tester.onSessionBreakPause && signal==SIGNAL_SESSIONBREAK) Tester.Pause("ResumeSequence(7)");
      else if (tester.onTrendChangePause  && signal==SIGNAL_TREND)        Tester.Pause("ResumeSequence(8)");
   }
   return(!catch("ResumeSequence(9)"));
}


/**
 * Restore open positions and limit orders of missed sequence levels. Called from StartSequence() or ResumeSequence().
 *
 * @param  datetime &lpOpenTime  - variable receiving the OpenTime of the last opened position
 * @param  double   &lpOpenPrice - variable receiving the average OpenPrice of all open positions
 *
 * @return bool - success status
 *
 * Note: If the sequence is at level 0 the passed variables are not modified.
 */
bool RestorePositions(datetime &lpOpenTime, double &lpOpenPrice) {
   if (IsLastError())                      return(false);
   if (sequence.status != STATUS_STARTING) return(!catch("RestorePositions(1)  "+ sequence.longName +" cannot restore positions of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int i, level, levelStep=ifInt(sequence.direction==D_LONG, 1, -1), missedLevels=ArraySize(sequence.missedLevels);
   bool isMissedLevel, success;
   datetime openTime;
   double openPrice;

   // Long
   if (sequence.level > 0) {
      for (level=1; level <= sequence.level; level++) {
         isMissedLevel = IntInArray(sequence.missedLevels, level);

         if (isMissedLevel) success = (Grid.AddPendingOrder(level) != 0);
         else               success =  Grid.AddPosition(level);
         if (!success) return(false);

         i = ArraySize(orders.ticket) - 1;
         if (orders.ticket[i] == -1)                                          // detect a virtually triggered SL
            break;

         if (isMissedLevel) {
            openTime   = Max(openTime, orders.pendingTime[i]);
            openPrice += MarketInfo(Symbol(), MODE_ASK);
         }
         else {
            openTime   = Max(openTime, orders.openTime[i]);
            openPrice += orders.openPrice[i];
         }
      }
   }

   // Short
   else if (sequence.level < 0) {
      for (level=-1; level >= sequence.level; level--) {
         isMissedLevel = IntInArray(sequence.missedLevels, level);

         if (isMissedLevel) success = (Grid.AddPendingOrder(level) != 0);
         else               success =  Grid.AddPosition(level);
         if (!success) return(false);

         i = ArraySize(orders.ticket) - 1;
         if (orders.ticket[i] == -1)                                          // detect a virtually triggered SL
            break;

         if (isMissedLevel) {
            openTime   = Max(openTime, orders.pendingTime[i]);
            openPrice += MarketInfo(Symbol(), MODE_BID);
         }
         else {
            openTime   = Max(openTime, orders.openTime[i]);
            openPrice += orders.openPrice[i];
         }
      }
   }

   // handle a virtually triggered SL
   if (level != 0) {
      if (orders.ticket[i] == -1) {
         if (__LOG()) log("RestorePositions(2)  "+ sequence.longName +" "+ UpdateStatus.StopLossMsg(i));
         sequence.level = orders.level[i] - levelStep; SS.SequenceName();
         Orders.RemoveRecord(i);
      }
   }

   // write-back results to the passed variables
   if (openTime != 0) {                                                       // sequence.level != 0
      lpOpenTime  = openTime;
      lpOpenPrice = NormalizeDouble(openPrice/Abs(sequence.level), Digits);   // avg(OpenPrice)
   }
   return(!catch("RestorePositions(3)"));
}


/**
 * Update internal order and PL status with current market data.
 *
 * @param  _InOut_ bool gridChanged - whether the current gridbase or gridlevel changed
 *
 * @return bool - success status
 */
bool UpdateStatus(bool &gridChanged) {
   gridChanged = gridChanged!=0;
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdateStatus(1)  "+ sequence.longName +" cannot update order status of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int sizeOfTickets = ArraySize(orders.ticket);
   double floatingPL = 0;
   bool entryStopTriggered = false;

   for (int level, i=sizeOfTickets-1; i >= 0; i--) {
      if (level == 1) break;                                                  // iterate backwards and limit tickets to inspect

      level = Abs(orders.level[i]);
      if (orders.closeTime[i] > 0)                                            // skip tickets already known as closed
         continue;

      if (!SelectTicket(orders.ticket[i], "UpdateStatus(2)")) return(false);
      bool wasPending = (orders.type[i] == OP_UNDEFINED);
      bool isClosed   = OrderCloseTime() != 0;

      if (wasPending) {
         // last time a pending order
         if (OrderType() != orders.pendingType[i]) {                          // a pending entry order was executed
            orders.type      [i] = OrderType();
            orders.openEvent [i] = CreateEventId();
            orders.openTime  [i] = OrderOpenTime();
            orders.openPrice [i] = OrderOpenPrice();
            orders.swap      [i] = OrderSwap();
            orders.commission[i] = OrderCommission(); sequence.commission = OrderCommission(); SS.UnitSize();
            orders.profit    [i] = OrderProfit();
            Chart.MarkOrderFilled(i);
            if (__LOG()) log("UpdateStatus(3)  "+ sequence.longName +" "+ UpdateStatus.OrderFillMsg(i));

            if (IsStopOrderType(orders.pendingType[i])) {                     // an executed stop order
               sequence.level     = orders.level[i]; SS.SequenceName();
               sequence.maxLevel  = Sign(sequence.level) * Max(Abs(sequence.level), Abs(sequence.maxLevel));
               entryStopTriggered = true;
               gridChanged        = true;
            }
            else {
               ArrayDropInt(sequence.missedLevels, orders.level[i]);          // an executed limit order => clear missed gridlevels
               SS.MissedLevels();

               if (!isClosed) /*&&*/ if (IsStopLossTriggered(orders.type[i], orders.stopLoss[i])) {
                  string message = "UpdateStatus(4)  "+ sequence.longName +" SL of #"+ orders.ticket[i] +" reached but not executed, closing it manually...";
                  if (!IsTesting()) warn(message);                            // @see  https://github.com/rosasurfer/mt4-mql/issues/10
                  else if (__LOG()) log(message);

                  if (!UpdateStatus.ExecuteStopLoss(orders.ticket[i])) return(false);
                  OrderSelect(orders.ticket[i], SELECT_BY_TICKET);            // refresh order context as it changed during the tick
                  isClosed             = true;
                  orders.closedBySL[i] = true;
               }
            }
         }
      }
      else {
         // last time an open position
         orders.swap      [i] = OrderSwap();
         orders.commission[i] = OrderCommission();
         orders.profit    [i] = OrderProfit();
      }

      if (!isClosed) {                                                        // a still open order
         if (orders.type[i] != OP_UNDEFINED) {
            floatingPL = NormalizeDouble(floatingPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
         }
      }
      else if (orders.type[i] == OP_UNDEFINED) {                              // a now closed pending order
         warn("UpdateStatus(5)  "+ sequence.longName +" "+ UpdateStatus.OrderCancelledMsg(i));
         Orders.RemoveRecord(i);                                              // cancelled pending orders are removed from
         sizeOfTickets--;                                                     // the order arrays
         if (OrderComment() == "deleted [no money]") {
            if (StopSequence(NULL))
               SetLastError(ERR_NOT_ENOUGH_MONEY);
            return(false);
         }
      }
      else {                                                                  // a now closed open position
         orders.closeEvent[i] = CreateEventId();
         orders.closeTime [i] = OrderCloseTime();
         orders.closePrice[i] = OrderClosePrice();
         orders.closedBySL[i] = IsOrderClosedBySL();
         Chart.MarkPositionClosed(i);

         if (orders.closedBySL[i]) {                                          // stopped out
            if (__LOG()) {             log("UpdateStatus(6)  "+ sequence.longName +" "+ UpdateStatus.StopLossMsg(i));
               if (entryStopTriggered) log("UpdateStatus(7)  "+ sequence.longName +" multiple limits triggered: StopEntry and StopLoss");
            }
            if (orders.level[i] == sequence.level) {
               sequence.level -= Sign(orders.level[i]); SS.SequenceName();    // only decrease level when the triggered SL is of the current level (the last)
            }
            sequence.stops++;
            sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2); SS.Stops();
            gridChanged      = true;
         }
         else if (StrStartsWithI(OrderComment(), "so:")) {                    // margin call
            warn("UpdateStatus(8)  "+ sequence.longName +" "+ UpdateStatus.PositionCloseMsg(i), ERR_NOT_ENOUGH_MONEY);
            if (StopSequence(NULL))
               SetLastError(ERR_NOT_ENOUGH_MONEY);
            return(false);
         }
         else {                                                               // manually closed or closed at end of test
            if (__LOG()) log("UpdateStatus(9)  "+ sequence.longName +" "+ UpdateStatus.PositionCloseMsg(i));
            sequence.closedPL = NormalizeDouble(sequence.closedPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
         }
      }
   }

   // update PL numbers
   sequence.floatingPL = floatingPL;
   sequence.totalPL    = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2); SS.TotalPL();
   if      (sequence.totalPL > sequence.maxProfit  ) { sequence.maxProfit   = sequence.totalPL; SS.MaxProfit();   }
   else if (sequence.totalPL < sequence.maxDrawdown) { sequence.maxDrawdown = sequence.totalPL; SS.MaxDrawdown(); }

   // trail gridbase
   if (!sequence.level) {
      if (!sizeOfTickets) {                                                   // the pending order is missing =>
         gridChanged = true;                                                  // enforce execution of UpdatePendingOrders()
      }
      else {
         double gridbase=GetGridbase(), lastGridbase=gridbase;
         if (sequence.direction == D_LONG) gridbase = MathMin(gridbase, NormalizeDouble((Bid + Ask)/2, Digits));
         else                              gridbase = MathMax(gridbase, NormalizeDouble((Bid + Ask)/2, Digits));

         if (NE(gridbase, lastGridbase, Digits)) {
            SetGridbase(TimeCurrentEx("UpdateStatus(10)"), gridbase);
            gridChanged = true;
         }
         else if (NE(orders.gridbase[sizeOfTickets-1], gridbase, Digits)) {   // double-check gridbase of the last ticket as
            gridChanged = true;                                               // online trailing enforces pauses between events
         }
      }
   }
   return(!catch("UpdateStatus(11)"));
}


/**
 * Compose a log message for a cancelled pending order.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.OrderCancelledMsg(int i) {
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was cancelled
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was deleted (not enough money)
   string sType         = OperationTypeDescription(orders.pendingType[i]);
   string sPendingPrice = NumberToStr(orders.pendingPrice[i], PriceFormat);
   string comment       = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message       = "#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(sequence.unitsize, ".+") +" "+ Symbol() +" at "+ sPendingPrice +" (\""+ comment +"\") was ";

   message = message + ifString(OrderComment()=="deleted [no money]", "deleted (not enough money)", "cancelled") +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")";
   return(message);
}


/**
 * Compose a log message for a filled entry order.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.OrderFillMsg(int i) {
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was filled[ at 1.5457'2 (0.3 pip [positive ]slippage)]
   string sType         = OperationTypeDescription(orders.pendingType[i]);
   string sPendingPrice = NumberToStr(orders.pendingPrice[i], PriceFormat);
   string comment       = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message       = "#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(sequence.unitsize, ".+") +" "+ Symbol() +" at "+ sPendingPrice +" (\""+ comment +"\") was filled";

   if (NE(orders.pendingPrice[i], orders.openPrice[i])) {
      double slippage = (orders.openPrice[i] - orders.pendingPrice[i])/Pip;
         if (orders.type[i] == OP_SELL)
            slippage = -slippage;
      string sSlippage;
      if (slippage > 0) sSlippage = DoubleToStr(slippage, Digits & 1) +" pip slippage";
      else              sSlippage = DoubleToStr(-slippage, Digits & 1) +" pip positive slippage";
      message = message +" at "+ NumberToStr(orders.openPrice[i], PriceFormat) +" ("+ sSlippage +")";
   }
   message = message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")";

   return(message);
}


/**
 * Compose a log message for a closed position.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.PositionCloseMsg(int i) {
   // #1 Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was closed at 1.5457'2[ (so: 47.7%/169.20/354.40)]
   string sType       = OperationTypeDescription(orders.type[i]);
   string sOpenPrice  = NumberToStr(orders.openPrice[i], PriceFormat);
   string sClosePrice = NumberToStr(orders.closePrice[i], PriceFormat);
   string comment     = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message     = "#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(sequence.unitsize, ".+") +" "+ Symbol() +" at "+ sOpenPrice +" (\""+ comment +"\") was closed at "+ sClosePrice;

   SelectTicket(orders.ticket[i], "UpdateStatus.PositionCloseMsg(1)", /*pushTicket=*/true);
   if (StrStartsWithI(OrderComment(), "so:"))
      message = message +" ("+ OrderComment() +")";
   OrderPop("UpdateStatus.PositionCloseMsg(2)");

   message = message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")";
   return(message);
}


/**
 * Compose a log message for an executed stoploss.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.StopLossMsg(int i) {
   // [magic ticket ]#1 Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17"), stoploss 1.5457'2 was executed[ at 1.5457'2 (0.3 pip [positive ]slippage)]
   string sMagic     = ifString(orders.ticket[i]==-1, "magic ticket ", "");
   string sType      = OperationTypeDescription(orders.type[i]);
   string sOpenPrice = NumberToStr(orders.openPrice[i], PriceFormat);
   string sStopLoss  = NumberToStr(orders.stopLoss[i], PriceFormat);
   string comment    = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message    = sMagic +"#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(sequence.unitsize, ".+") +" "+ Symbol() +" at "+ sOpenPrice +" (\""+ comment +"\"), stoploss "+ sStopLoss +" was executed";

   if (NE(orders.closePrice[i], orders.stopLoss[i])) {
      double slippage = (orders.stopLoss[i] - orders.closePrice[i])/Pip;
         if (orders.type[i] == OP_SELL)
            slippage = -slippage;
      string sSlippage;
      if (slippage > 0) sSlippage = DoubleToStr(slippage, Digits & 1) +" pip slippage";
      else              sSlippage = DoubleToStr(-slippage, Digits & 1) +" pip positive slippage";
      message = message +" at "+ NumberToStr(orders.closePrice[i], PriceFormat) +" ("+ sSlippage +")";
   }

   message = message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")";
   return(message);
}


/**
 * Whether a chart command was sent to the expert. If so, the command is retrieved and stored.
 *
 * @param  string commands[] - array to store received commands in
 *
 * @return bool
 */
bool EventListener_ChartCommand(string &commands[]) {
   if (!__CHART()) return(false);

   static string label, mutex; if (!StringLen(label)) {
      label = __NAME() +".command";
      mutex = "mutex."+ label;
   }

   // check non-synchronized (read-only) for a command to prevent aquiring the lock on each tick
   if (ObjectFind(label) == 0) {
      // aquire the lock for write-access if there's indeed a command
      if (!AquireLock(mutex, true)) return(false);

      ArrayPushString(commands, ObjectDescription(label));
      ObjectDelete(label);
      return(ReleaseLock(mutex));
   }
   return(false);
}


/**
 * Whether the currently selected order was closed by a stoploss.
 *
 * @return bool
 */
bool IsOrderClosedBySL() {
   bool isPosition = OrderType()==OP_BUY || OrderType()==OP_SELL;
   bool isClosed   = OrderCloseTime() != 0;
   bool closedBySL = false;

   if (isPosition) /*&&*/ if (isClosed) {
      if (StrEndsWithI(OrderComment(), "[sl]")) {
         closedBySL = true;
      }
      else if (StrStartsWithI(OrderComment(), "so:")) {
         closedBySL = false;
      }
      else {
         // manually check the close price against the SL
         int i = SearchIntArray(orders.ticket, OrderTicket());
         if (i == -1) return(!catch("IsOrderClosedBySL(1)  "+ sequence.longName +" closed position #"+ OrderTicket() +" not found in order arrays", ERR_ILLEGAL_STATE));

         if      (orders.closedBySL[i])   closedBySL = true;
         else if (OrderType() == OP_BUY ) closedBySL = LE(OrderClosePrice(), orders.stopLoss[i], Digits);
         else if (OrderType() == OP_SELL) closedBySL = GE(OrderClosePrice(), orders.stopLoss[i], Digits);
      }
   }
   return(closedBySL);
}


/**
 * Whether a start or resume condition is satisfied for a waiting sequence. Price and time conditions are "AND" combined.
 *
 * @param  _Out_ int signal - variable receiving the signal identifier of the fulfilled start condition
 *
 * @return bool
 */
bool IsStartSignal(int &signal) {
   signal = NULL;
   if (last_error || sequence.status!=STATUS_WAITING) return(false);
   string message;
   bool triggered, resuming = (sequence.maxLevel != 0);

   if (IsSessionBreak()) {
      // -- start.trend during sessionbreak: fulfilled on trend change in direction of the sequence -------------------------
      if (start.conditions && start.trend.condition) {
         if (IsBarOpenEvent(start.trend.timeframe)) {
            int trend = GetStartTrendValue(1);
            if ((sequence.direction==D_LONG && trend==1) || (sequence.direction==D_SHORT && trend==-1)) {
               if (__LOG()) log("IsStartSignal(1)  "+ sequence.longName +" queuing fulfilled "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.trend.description +"\"");
               sessionbreak.startSignal = SIGNAL_TREND;        // checked after sessionbreak in the regular trend check
            }
         }
      }
      return(false);
   }

   if (sessionbreak.waiting) {
      // -- after sessionbreak: wait for the stop price to be reached if not in level 0 -------------------------------------
      if (!sequence.level) {
         if (__LOG()) log("IsStartSignal(2)  "+ sequence.longName +" resume condition \"@sessionbreak in level 0\" fulfilled ("+ ifString(sequence.direction==D_LONG, "ask", "bid") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Ask, Bid), PriceFormat) +")");
         signal = SIGNAL_SESSIONBREAK;
         return(true);
      }
      double price = sequence.stop.price[ArraySize(sequence.stop.price)-1];
      if (sequence.direction == D_LONG) triggered = (Ask <= price);
      else                              triggered = (Bid >= price);
      if (triggered) {
         if (__LOG()) log("IsStartSignal(3)  "+ sequence.longName +" resume condition \"@sessionbreak price "+ NumberToStr(price, PriceFormat) +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "ask", "bid") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Ask, Bid), PriceFormat) +")");
         signal = SIGNAL_SESSIONBREAK;
         return(true);
      }
      return(false);                                           // ignore all other conditions for the time of the sessionbreak
   }

   if (start.conditions) {
      // -- start.time: fulfilled at the specified time and after -----------------------------------------------------------
      if (start.time.condition) {
         if (TimeCurrentEx("IsStartSignal(4)") < start.time.value)
            return(false);

         message = "IsStartSignal(5)  "+ sequence.longName +" "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.time.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         start.time.condition = false;                         // prevent permanent consecutive tests
         SS.StartStopConditions();
      }

      // -- start.price: fulfilled when price touches or crosses the limit --------------------------------------------------
      if (start.price.condition) {
         triggered = false;
         switch (start.price.type) {
            case PRICE_BID:    price =  Bid;        break;
            case PRICE_ASK:    price =  Ask;        break;
            case PRICE_MEDIAN: price = (Bid+Ask)/2; break;
         }
         if (start.price.lastValue != 0) {
            if (start.price.lastValue < start.price.value) triggered = (price >= start.price.value);  // price crossed upwards
            else                                           triggered = (price <= start.price.value);  // price crossed downwards
         }
         start.price.lastValue = price;
         if (!triggered) return(false);

         message = "IsStartSignal(6)  "+ sequence.longName +" "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.price.description +"\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         start.price.condition = false;                        // prevent permanent consecutive tests
         SS.StartStopConditions();
      }

      // -- start.trend: fulfilled on trend change in direction of the sequence ---------------------------------------------
      if (start.trend.condition) {
         if (IsBarOpenEvent(start.trend.timeframe)) {
            trend = GetStartTrendValue(1);

            if ((sequence.direction==D_LONG && trend==1) || (sequence.direction==D_SHORT && trend==-1)) {
               message = "IsStartSignal(7)  "+ sequence.longName +" "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.trend.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
               if (!IsTesting()) warn(message);
               else if (__LOG()) log(message);
               signal = SIGNAL_TREND;
               return(true);
            }
         }
         if (sessionbreak.startSignal == SIGNAL_TREND) {
            message = "IsStartSignal(8)  "+ sequence.longName +" "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.trend.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
            if (!IsTesting()) warn(message);
            else if (__LOG()) log(message);
            signal = SIGNAL_TREND;
            return(true);
         }
         return(false);
      }

      // -- price and/or time conditions are fulfilled ----------------------------------------------------------------------
      signal = SIGNAL_PRICETIME;
      return(true);
   }

   // no start condition is a valid start signal before first sequence start only
   if (!ArraySize(sequence.start.event)) {
      signal = NULL;
      return(true);
   }

   return(false);
}


/**
 * Whether a stop condition is satisfied for a waiting or a progressing sequence. All stop conditions are "OR" combined.
 *
 * @param  _Out_ int signal - variable receiving the signal identifier of the fulfilled stop condition
 *
 * @return bool
 */
bool IsStopSignal(int &signal) {
   signal = NULL;
   if (last_error || (sequence.status!=STATUS_WAITING && sequence.status!=STATUS_PROGRESSING)) return(false);
   if (!ArraySize(sequence.start.event))                                                       return(false);
   string message;

   // -- stop.trend: fulfilled on trend change against the direction of the sequence ----------------------------------------
   if (stop.trend.condition) {
      if (sequence.status==STATUS_PROGRESSING || sessionbreak.waiting) {
         if (IsBarOpenEvent(stop.trend.timeframe)) {
            int trend = GetStopTrendValue(1);

            if ((sequence.direction==D_LONG && trend==-1) || (sequence.direction==D_SHORT && trend==1)) {
               message = "IsStopSignal(1)  "+ sequence.longName +" stop condition \"@"+ stop.trend.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
               if (!IsTesting()) warn(message);
               else if (__LOG()) log(message);
               signal = SIGNAL_TREND;
               return(true);
            }
         }
      }
   }

   // -- stop.price: fulfilled when current price touches or crossses the limit----------------------------------------------
   if (stop.price.condition) {
      bool triggered = false;
      double price;
      switch (stop.price.type) {
         case PRICE_BID:    price =  Bid;        break;
         case PRICE_ASK:    price =  Ask;        break;
         case PRICE_MEDIAN: price = (Bid+Ask)/2; break;
      }
      if (stop.price.lastValue != 0) {
         if (stop.price.lastValue < stop.price.value) triggered = (price >= stop.price.value);  // price crossed upwards
         else                                         triggered = (price <= stop.price.value);  // price crossed downwards
      }
      stop.price.lastValue = price;

      if (triggered) {
         message = "IsStopSignal(2)  "+ sequence.longName +" stop condition \"@"+ stop.price.description +"\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         stop.price.condition = false;
         signal = SIGNAL_PRICETIME;
         return(true);
      }
   }

   // -- stop.time: fulfilled at the specified time and after ---------------------------------------------------------------
   if (stop.time.condition) {
      if (TimeCurrentEx("IsStopSignal(3)") >= stop.time.value) {
         message = "IsStopSignal(4)  "+ sequence.longName +" stop condition \"@"+ stop.time.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         stop.time.condition = false;
         signal = SIGNAL_PRICETIME;
         return(true);
      }
   }

   if (sequence.status == STATUS_PROGRESSING) {
      // -- stop.profitAbs: -------------------------------------------------------------------------------------------------
      if (stop.profitAbs.condition) {
         if (sequence.totalPL >= stop.profitAbs.value) {
            message = "IsStopSignal(5)  "+ sequence.longName +" stop condition \"@"+ stop.profitAbs.description +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
            if (!IsTesting()) warn(message);
            else if (__LOG()) log(message);
            stop.profitAbs.condition = false;
            signal = SIGNAL_TP;
            return(true);
         }
      }

      // -- stop.profitPct: -------------------------------------------------------------------------------------------------
      if (stop.profitPct.condition) {
         if (stop.profitPct.absValue == INT_MAX) {
            stop.profitPct.absValue = stop.profitPct.value/100 * sequence.startEquity;
         }
         if (sequence.totalPL >= stop.profitPct.absValue) {
            message = "IsStopSignal(6)  "+ sequence.longName +" stop condition \"@"+ stop.profitPct.description +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
            if (!IsTesting()) warn(message);
            else if (__LOG()) log(message);
            stop.profitPct.condition = false;
            signal = SIGNAL_TP;
            return(true);
         }
      }

      // -- stop.lossAbs: ---------------------------------------------------------------------------------------------------
      if (stop.lossAbs.condition) {
         if (sequence.totalPL <= stop.lossAbs.value) {
            message = "IsStopSignal(7)  "+ sequence.longName +" stop condition \"@"+ stop.lossAbs.description +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
            if (!IsTesting()) warn(message);
            else if (__LOG()) log(message);
            stop.lossAbs.condition = false;
            signal = SIGNAL_SL;
            return(true);
         }
      }

      // -- stop.lossPct: ---------------------------------------------------------------------------------------------------
      if (stop.lossPct.condition) {
         if (stop.lossPct.absValue == INT_MIN) {
            stop.lossPct.absValue = stop.lossPct.value/100 * sequence.startEquity;
         }
         if (sequence.totalPL <= stop.lossPct.absValue) {
            message = "IsStopSignal(8)  "+ sequence.longName +" stop condition \"@"+ stop.lossPct.description +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
            if (!IsTesting()) warn(message);
            else if (__LOG()) log(message);
            stop.lossPct.condition = false;
            signal = SIGNAL_SL;
            return(true);
         }
      }

      // -- session break ---------------------------------------------------------------------------------------------------
      if (IsSessionBreak()) {
         message = "IsStopSignal(9)  "+ sequence.longName +" stop condition \"sessionbreak from "+ GmtTimeFormat(sessionbreak.starttime, "%Y.%m.%d %H:%M:%S") +" to "+ GmtTimeFormat(sessionbreak.endtime, "%Y.%m.%d %H:%M:%S") +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
         if (__LOG()) log(message);
         signal = SIGNAL_SESSIONBREAK;
         return(true);
      }
   }
   return(false);
}


/**
 * Whether the current server time falls into a sessionbreak. After function return the global vars sessionbreak.starttime
 * and sessionbreak.endtime are up-to-date (sessionbreak.active is not modified).
 *
 * @return bool
 */
bool IsSessionBreak() {
   if (IsLastError()) return(false);

   datetime serverTime = Max(TimeCurrentEx(), TimeServer());

   // check whether to recalculate sessionbreak times
   if (serverTime >= sessionbreak.endtime) {
      int startOffset = Sessionbreak.StartTime % DAYS;            // sessionbreak start time in seconds since Midnight
      int endOffset   = Sessionbreak.EndTime % DAYS;              // sessionbreak end time in seconds since Midnight
      if (!startOffset && !endOffset)
         return(false);                                           // skip session breaks if both values are set to Midnight

      // calculate today's sessionbreak end time
      datetime fxtNow  = ServerToFxtTime(serverTime);
      datetime today   = fxtNow - fxtNow%DAYS;                    // today's Midnight in FXT
      datetime fxtTime = today + endOffset;                       // today's sessionbreak end time in FXT

      // determine the next regular sessionbreak end time
      int dow = TimeDayOfWeekFix(fxtTime);
      while (fxtTime <= fxtNow || dow==SATURDAY || dow==SUNDAY) {
         fxtTime += 1*DAY;
         dow = TimeDayOfWeekFix(fxtTime);
      }
      datetime fxtResumeTime = fxtTime;
      sessionbreak.endtime = FxtToServerTime(fxtResumeTime);

      // determine the corresponding sessionbreak start time
      datetime resumeDay = fxtResumeTime - fxtResumeTime%DAYS;    // resume day's Midnight in FXT
      fxtTime = resumeDay + startOffset;                          // resume day's sessionbreak start time in FXT

      dow = TimeDayOfWeekFix(fxtTime);
      while (fxtTime >= fxtResumeTime || dow==SATURDAY || dow==SUNDAY) {
         fxtTime -= 1*DAY;
         dow = TimeDayOfWeekFix(fxtTime);
      }
      sessionbreak.starttime = FxtToServerTime(fxtTime);

      if (__LOG()) log("IsSessionBreak(1)  "+ sequence.longName +" recalculated next sessionbreak: from "+ GmtTimeFormat(sessionbreak.starttime, "%a, %Y.%m.%d %H:%M:%S") +" to "+ GmtTimeFormat(sessionbreak.endtime, "%a, %Y.%m.%d %H:%M:%S"));
   }

   // perform the actual check
   return(serverTime >= sessionbreak.starttime);                  // here sessionbreak.endtime is always in the future
}


/**
 * Update all pending orders. Trail a first-level order or add new pending orders for all missing levels.
 *
 * @param  int saveStatusMode [optional] - status saving mode, one of
 *                                         SAVESTATUS_AUTO:    status is saved if order data changed
 *                                         SAVESTATUS_ENFORCE: status is always saved
 *                                         SAVESTATUS_SKIP:    status is never saved
 *                                         (default: SAVESTATUS_AUTO)
 * @return bool - success status
 */
bool UpdatePendingOrders(int saveStatusMode = SAVESTATUS_AUTO) {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdatePendingOrders(1)  "+ sequence.longName +" cannot update orders of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (saveStatusMode && saveStatusMode!=SAVESTATUS_ENFORCE && saveStatusMode!=SAVESTATUS_SKIP)
                                              return(!catch("UpdatePendingOrders(2)  "+ sequence.longName +" invalid parameter saveStatusMode: "+ saveStatusMode, ERR_INVALID_PARAMETER));
   /*
   Processing logic
   ----------------
   (1) iterate downwards starting at the current level and check all active levels
       - for each level an order must exist (open or closed) except when in StartSequence()
       - if an order is open:   check and adjust the SL of level 1 orders
       - if an order is closed: open a new one and store it directly after the closed one

   (2) iterate upwards starting at the current level and check any inactive levels
       - cancel and remove obsolete stop orders (possibly multiple)
       - if the next stop order is missing open it and store it at the end (top)

   (3) if in level 0 trail the next stop order (if required)
   */
   int level=sequence.level, levelStep=ifInt(sequence.direction==D_LONG, 1, -1), nextLevel=level+levelStep, newLimitOrders, sizeOfTickets=ArraySize(orders.ticket);
   int idxCurrentLevel=-1, idxNextStop=-1;
   double gridbase = GetGridbase();
   string sMissedLevels = "";
   bool saveStatus = false;

   // (1) iterate from the current level downward and check all active levels
   for (int i=sizeOfTickets-1; i >= 0; i--) {
      if (orders.level[i] == level) {
         if (idxCurrentLevel < 0) idxCurrentLevel = i;                     // remember the index of the current level

         if (!orders.closeTime[i]) {                                       // order is open, check the SL of level 1 orders
            if (Abs(level) == 1) {
               double stoploss = gridbase + (level-levelStep)*GridSize*Pips;
               if (NE(orders.stopLoss[i], stoploss, Digits)) {
                  int error = ModifyStopLoss(i, gridbase, stoploss);
                  if (error > 0)       return(false);
                  if (error == -1)     warn("UpdatePendingOrders(3)  "+ sequence.longName +" SL already being executed", ERR_NOT_IMPLEMENTED);
                  else if (error != 0) return(!catch("UpdatePendingOrders(4)->ModifyStopLoss()  "+ sequence.longName +" unexpected return value", error));
               }
            }
         }
         else {                                                            // order is closed, re-open it
            if (__LOG()) log("UpdatePendingOrders(5)  "+ sequence.longName +" re-opening closed level "+ level +" order...");
            int type = Grid.AddPendingOrder(level, i+1); if (!type) return(false);
            sizeOfTickets++;
            if (saveStatusMode != SAVESTATUS_SKIP) saveStatus = true;

            if (IsLimitOrderType(type)) {                                  // add limit order to missed levels
               newLimitOrders++;
               ArrayPushInt(sequence.missedLevels, level);
               sMissedLevels = sMissedLevels +", "+ level;
               idxCurrentLevel++;
            }
            else {                                                         // on a stop order decrease the sequence level
               if (__LOG()) log("UpdatePendingOrders(6)  "+ sequence.longName +" re-opened order is a stop order, decreasing sequence level...");
               nextLevel       = level;
               sequence.level  = level - levelStep; SS.SequenceName();
               idxCurrentLevel = -1;
            }
         }
         level -= levelStep;
         if (!level) break;
      }
      if (Abs(orders.level[i]) < Abs(level)) {
         if (idxCurrentLevel < 0) idxCurrentLevel = i;
         break;
      }
   }

   if (level != 0) {
      if (sizeOfTickets > 0) return(!catch("UpdatePendingOrders(7)  "+ sequence.longName +" order of level "+ level +" not found", ERR_ILLEGAL_STATE));

      level = levelStep;
      while (true) {                                                       // with a level but no orders we are in StartSequence() with a predefined sequence.level != 0
         type = Grid.AddPendingOrder(level); if (!type) return(false);
         sizeOfTickets++;
         if (saveStatusMode != SAVESTATUS_SKIP) saveStatus = true;

         if (IsLimitOrderType(type)) {                                     // add limit order to missed levels
            newLimitOrders++;
            ArrayPushInt(sequence.missedLevels, level);
            sMissedLevels   = sMissedLevels +", "+ level;
            idxCurrentLevel = sizeOfTickets-1;
         }
         else {                                                            // on a stop order decrease the sequence level
            if (__LOG()) log("UpdatePendingOrders(8)  "+ sequence.longName +" opened order is a stop order, decreasing sequence level...");
            sequence.level = level - levelStep; SS.SequenceName();
            nextLevel      = level;
            level          = sequence.level;
         }
         level += levelStep;
         if (level == nextLevel)
            break;
      }
   }

   // (2) iterate from the current level upward and check any inactive levels
   for (i=idxCurrentLevel+1; i < sizeOfTickets; i++) {
      if (orders.closeTime[i] != 0)                continue;               // process only open orders
      if (orders.type[i] != OP_UNDEFINED)          return(!catch("UpdatePendingOrders(9)  "+ sequence.longName +" orders out of sync: open position of level "+ orders.level[i] +" found (#"+ orders.ticket[i] +")", ERR_ILLEGAL_STATE));
      if (!IsStopOrderType(orders.pendingType[i])) return(!catch("UpdatePendingOrders(10)  "+ sequence.longName +" orders out of sync: limit order of level "+ orders.level[i] +" above the current level found (#"+ orders.ticket[i] +")", ERR_ILLEGAL_STATE));

      if (orders.level[i]==nextLevel && idxNextStop==-1) {                 // order is open and pending
         idxNextStop = i;
      }
      else {
         error = Grid.DeleteOrder(i);                                      // delete an obsolete old stop order
         if (error != 0) {
            if (saveStatusMode==SAVESTATUS_AUTO && saveStatus)
               saveStatusMode = SAVESTATUS_ENFORCE;
            return(UpdatePendingOrders.DeleteError(i, error, saveStatusMode));
         }
         sizeOfTickets--;
         i--;
         if (saveStatusMode != SAVESTATUS_SKIP) saveStatus = true;
      }
   }

   while (idxNextStop == -1) {                                             // open a missing next stop order
      type = Grid.AddPendingOrder(nextLevel); if (!type) return(false);
      sizeOfTickets++;
      if (saveStatusMode != SAVESTATUS_SKIP) saveStatus = true;

      if (IsStopOrderType(type)) {                                         // a stop order was opened
         idxNextStop = sizeOfTickets-1;
      }
      else {                                                               // on a limit order the sequence level increased
         if (__LOG()) log("UpdatePendingOrders(11)  "+ sequence.longName +" submitted order is a limit order, increasing sequence level...");
         idxCurrentLevel   = sizeOfTickets-1;
         sequence.level    = nextLevel; SS.SequenceName();
         sequence.maxLevel = Max(Abs(sequence.level), Abs(sequence.maxLevel)) * levelStep;
         nextLevel        += levelStep;
         newLimitOrders++;
         ArrayPushInt(sequence.missedLevels, sequence.level);
         sMissedLevels = sMissedLevels +", "+ sequence.level;
      }
   }

   // (3) if in level 0 trail the next stop order (if required)
   if (!sequence.level) {
      i = idxNextStop;
      if (NE(gridbase, orders.gridbase[i], Digits)) {
         static int lastTrailed = 0;

         if (/*IsTesting() ||*/Tick.Time-lastTrailed >= limitOrderTrailing) { // wait <x> seconds between requests to avoid ERR_TOO_MANY_REQUESTS
            type = Grid.TrailPendingOrder(i); if (!type) return(false);
            lastTrailed = Tick.Time;
            if (saveStatusMode != SAVESTATUS_SKIP) saveStatus = true;

            if (IsLimitOrderType(type)) {                                  // on a limit order the sequence level increased
               sequence.level    = nextLevel; SS.SequenceName();
               sequence.maxLevel = Max(Abs(sequence.level), Abs(sequence.maxLevel)) * levelStep;
               nextLevel        += levelStep;
               newLimitOrders++;
               ArrayPushInt(sequence.missedLevels, sequence.level);
               sMissedLevels = sMissedLevels +", "+ sequence.level;

               if (!UpdatePendingOrders(SAVESTATUS_SKIP)) return(false);   // handle the now missing next stop order recursively
               sizeOfTickets++;
               idxNextStop = sizeOfTickets-1;
            }
         }
      }
   }

   if (newLimitOrders > 0) {
      sMissedLevels = StrSubstr(sMissedLevels, 2); SS.MissedLevels();
      if (__LOG()) log("UpdatePendingOrders(12)  "+ sequence.longName +" opened "+ newLimitOrders +" limit order"+ Pluralize(newLimitOrders) +" for missed level"+ Pluralize(newLimitOrders) +" "+ sMissedLevels +" (all missed levels: "+ JoinInts(sequence.missedLevels) +")");
   }
   UpdateProfitTargets();
   ShowProfitTargets();
   SS.ProfitPerLevel();

   if (saveStatus || saveStatusMode==SAVESTATUS_ENFORCE)
      if (!SaveStatus()) return(false);
   return(!catch("UpdatePendingOrders(13)"));
}


/**
 * Handle an error returned by Grid.DeleteOrder() when called in UpdatePendingOrders():
 *
 * @param  int i              - array index of the stop order for which the error occurred
 * @param  int error          - the occurred error
 * @param  int saveStatusMode - status saving mode, one of
 *                              SAVESTATUS_AUTO:    status is saved if order data changed
 *                              SAVESTATUS_ENFORCE: status is always saved
 *                              SAVESTATUS_SKIP:    status is never saved
 *                              (default: SAVESTATUS_AUTO)
 * @return bool - success status
 */
bool UpdatePendingOrders.DeleteError(int i, int error, int saveStatusMode) {
   if (error == -1) {                                                   // the order was already executed
      if (__LOG()) log("UpdatePendingOrders.DeleteError(1)  "+ sequence.longName +" pending stop order for level "+ orders.level[i] +" was already executed (#"+ orders.ticket[i] +")");
      bool bNull;
      UpdateStatus(bNull);                                              // handle it recursively
      return(UpdatePendingOrders(saveStatusMode));
   }
   return(false);                                                       // any other error
}


/**
 * Set the gridbase to the specified value. All gridbase changes are stored in the gridbase history.
 *
 * @param  datetime time  - time of gridbase change
 * @param  double   value - new gridbase value
 *
 * @return double - the same gridbase value
 */
double SetGridbase(datetime time, double value) {
   /*
   Status changes and event order:
   +-----------------------+--------------------+--------------------+
   | StartSequence()       | STATUS_STARTING    | EV_SEQUENCE_START  |
   | ResetGridBase()       | STATUS_STARTING    | EV_GRIDBASE_CHANGE | gridbase event after start event
   | OpenStartLevel()      | STATUS_STARTING    | EV_POSITION_OPEN   |
   | AddPendingOrder()     | STATUS_PROGRESSING |                    |
   +-----------------------+--------------------+--------------------+
   | TrailPendingOrder()   | STATUS_PROGRESSING | EV_GRIDBASE_CHANGE |
   | TrailPendingOrder()   | STATUS_PROGRESSING | EV_GRIDBASE_CHANGE |
   | ...                   | STATUS_PROGRESSING | EV_GRIDBASE_CHANGE |
   +-----------------------+--------------------+--------------------+
   | StopSequence()        | STATUS_STOPPING    | EV_SEQUENCE_STOP   |
   |                       | STATUS_STOPPED     |                    |
   +-----------------------+--------------------+--------------------+
   | ResumeSequence()      | STATUS_STARTING    |                    |
   | SetGridBase()         | STATUS_STARTING    | EV_GRIDBASE_CHANGE | gridbase event before start event
   | RestoreOpenPosition() | STATUS_STARTING    | EV_POSITION_OPEN   |
   |                       | STATUS_STARTING    | EV_SEQUENCE_START  |
   |                       | STATUS_PROGRESSING |                    |
   +-----------------------+--------------------+--------------------+
   | TrailPendingOrder()   | STATUS_PROGRESSING | EV_GRIDBASE_CHANGE |
   | TrailPendingOrder()   | STATUS_PROGRESSING | EV_GRIDBASE_CHANGE |
   | ...                   | STATUS_PROGRESSING | EV_GRIDBASE_CHANGE |
   +-----------------------+--------------------+--------------------+
   - As long as no sequence level was triggered only the last gridbase trailing event is permanently stored.
   - After a sequence level was triggered only the last gridbase trailing event per minute is permanently stored.
   - Non-trailing gridbase events are always permanently stored.
   */
   value = NormalizeDouble(value, Digits);

   // determine whether the current event is a consecutive gridbase trail event
   int lastEvent = NULL,            lastMinute = -1,          lastStatus = STATUS_UNDEFINED;
   int thisEvent = CreateEventId(), thisMinute = time/MINUTE, thisStatus = sequence.status;

   int size = ArraySize(gridbase.event);
   if (size > 0) {
      lastEvent  = gridbase.event [size-1];
      lastMinute = gridbase.time  [size-1]/MINUTE;
      lastStatus = gridbase.status[size-1];
   }
   bool overwritten = false;

   if (lastStatus==STATUS_PROGRESSING && thisStatus==STATUS_PROGRESSING && lastEvent+1==thisEvent) {
      if (!sequence.maxLevel || thisMinute==lastMinute) {
         gridbase.event [size-1] = thisEvent;               // overwrite the previous gridbase event
         gridbase.time  [size-1] = time;
         gridbase.price [size-1] = value;
         gridbase.status[size-1] = thisStatus;
         overwritten = true;
      }
   }

   if (!overwritten) {                                      // append the event
      ArrayPushInt   (gridbase.event,  thisEvent );
      ArrayPushInt   (gridbase.time,   time      );
      ArrayPushDouble(gridbase.price,  value     );
      ArrayPushInt   (gridbase.status, thisStatus);
   }

   SS.GridBase();
   return(value);
}


/**
 * Delete all stored gridbase changes. If a new value is passed re-intialize the gridbase with the given value.
 *
 * @param  datetime time  [optional] - time of gridbase change (default: the current time)
 * @param  double   value [optional] - new gridbase value (default: none)
 *
 * @return double - new gridbase or NULL if the gridbase was not re-initialized with a new value
 */
double ResetGridbase(datetime time=NULL, double value=NULL) {
   ArrayResize(gridbase.event,  0);
   ArrayResize(gridbase.time,   0);
   ArrayResize(gridbase.price,  0);
   ArrayResize(gridbase.status, 0);

   if (!time) time = TimeCurrentEx("ResetGridbase(1)");

   if (time && value)
      return(SetGridbase(time, value));
   return(NULL);
}


/**
 * Open a pending entry order for the specified gridlevel and add it to the order arrays. Depending on the market a stop or
 * a limit order is opened.
 *
 * @param  int level             - gridlevel of the order to open: -n...1 | 1...+n
 * @param  int offset [optional] - order array position (index) to add the new order (default: append to the end)
 *
 * @return int - order type of the opened order (stop or limit) or NULL in case of errors
 */
int Grid.AddPendingOrder(int level, int offset=-1) {
   if (IsLastError())                                                           return(NULL);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(!catch("Grid.AddPendingOrder(1)  "+ sequence.longName +" cannot add order to "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int pendingType = ifInt(sequence.direction==D_LONG, OP_BUYSTOP, OP_SELLSTOP);

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.AddPendingOrder()", "Do you really want to submit a new "+ OperationTypeDescription(pendingType) +" order now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   double gridbase=GetGridbase(), price=gridbase + level*GridSize*Pips, bid=MarketInfo(Symbol(), MODE_BID), ask=MarketInfo(Symbol(), MODE_ASK);
   int counter, ticket, oe[];
   if (sequence.direction == D_LONG) pendingType = ifInt(GT(price, bid, Digits), OP_BUYSTOP, OP_BUYLIMIT);
   else                              pendingType = ifInt(LT(price, ask, Digits), OP_SELLSTOP, OP_SELLLIMIT);

   // loop until a pending order was opened or a non-fixable error occurred
   while (true) {
      if (IsStopOrderType(pendingType)) ticket = SubmitStopOrder(pendingType, level, oe);
      else                              ticket = SubmitLimitOrder(pendingType, level, oe);
      if (ticket > 0) break;

      int error = oe.Error(oe);
      if (error != ERR_INVALID_STOP) return(NULL);
      counter++;
      if (counter > 9)  return(!catch("Grid.AddPendingOrder(2)  "+ sequence.longName +" stopping trade request loop after "+ counter +" unsuccessful tries, last error", error));
                                                   // market violated: switch order type and ignore price, thus preventing
      if (ticket == -1) {                          // the same pending order type again and again caused by a stalled price feed
         if (__LOG()) log("Grid.AddPendingOrder(3)  "+ sequence.longName +" illegal price "+ OperationTypeDescription(pendingType) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +" (market "+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +"), opening "+ ifString(IsStopOrderType(pendingType), "limit", "stop") +" order instead", error);
         pendingType += ifInt(pendingType <= OP_SELLLIMIT, 2, -2);
         continue;
      }
      if (ticket == -2) return(!catch("Grid.AddPendingOrder(4)  "+ sequence.longName +" unsupported bucketshop account (stop distance is not zero)", error));

      return(!catch("Grid.AddPendingOrder(5)  "+ sequence.longName +" unknown "+ ifString(IsStopOrderType(pendingType), "SubmitStopOrder", "SubmitLimitOrder") +" return value "+ ticket, error));
   }

   // prepare dataset
   //int    ticket       = ...                     // use as is
   //int    level        = ...                     // ...
   //double gridbase     = ...                     // ...

   //int    pendingType  = ...                     // ...
   datetime pendingTime  = oe.OpenTime(oe); if (ticket < 0) pendingTime = TimeCurrentEx("Grid.AddPendingOrder(6)");
   double   pendingPrice = oe.OpenPrice(oe);

   int      openType     = OP_UNDEFINED;
   int      openEvent    = NULL;
   datetime openTime     = NULL;
   double   openPrice    = NULL;
   int      closeEvent   = NULL;
   datetime closeTime    = NULL;
   double   closePrice   = NULL;
   double   stopLoss     = oe.StopLoss(oe);
   bool     closedBySL   = false;

   double   swap         = NULL;
   double   commission   = NULL;
   double   profit       = NULL;

   // store dataset
   if (!Orders.AddRecord(ticket, level, gridbase, pendingType, pendingTime, pendingPrice, openType, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, closedBySL, swap, commission, profit, offset))
      return(NULL);

   if (last_error || catch("Grid.AddPendingOrder(7)"))
      return(NULL);
   return(pendingType);
}


/**
 * Open a market position for the specified gridlevel and add the order data to the order arrays.
 * Called only in RestorePositions().
 *
 * @param  int level - gridlevel of the position to open: -n...1 | 1...+n
 *
 * @return bool - success status
 */
bool Grid.AddPosition(int level) {
   if (IsLastError())                      return( false);
   if (sequence.status != STATUS_STARTING) return(_false(catch("Grid.AddPosition(1)  "+ sequence.longName +" cannot add position to "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (!level)                             return(_false(catch("Grid.AddPosition(2)  "+ sequence.longName +" illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   int oe[], orderType = ifInt(sequence.direction==D_LONG, OP_BUY, OP_SELL);

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.AddPosition()", "Do you really want to submit a Market "+ OperationTypeDescription(orderType) +" order now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   int ticket = SubmitMarketOrder(orderType, level, oe);

   if (ticket <= 0) {
      if (oe.Error(oe) != ERR_INVALID_STOP) return(false);
      if (ticket == -1) {
         // market violated                        // use #-1 as marker for a virtually triggered SL, the caller will decrease the gridlevel and "close" it with PL=0.00
         oe.setOpenTime(oe, TimeCurrentEx("Grid.AddPosition(3)"));
         if (__LOG()) log("Grid.AddPosition(4)  "+ sequence.longName +" new position at level "+ level +" would be immediately closed by SL="+ NumberToStr(oe.StopLoss(oe), PriceFormat) +", adding marker ticket #-1 (market: "+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +")");
      }
      else if (ticket == -2) {
         return(!catch("Grid.AddPosition(5)  "+ sequence.longName +" unsupported bucketshop account (stop distance is not zero)", oe.Error(oe)));
      }
      else {
         return(!catch("Grid.AddPosition(6)  "+ sequence.longName +" unexpected return value "+ ticket +" of SubmitMarketOrder()", oe.Error(oe)));
      }
   }

   // prepare dataset
   //int    ticket       = ...                     // use as is
   //int    level        = ...                     // ...
   double   gridbase     = GetGridbase();

   int      pendingType  = OP_UNDEFINED;
   datetime pendingTime  = NULL;
   double   pendingPrice = NULL;

   int      type         = orderType;
   int      openEvent    = CreateEventId();
   datetime openTime     = oe.OpenTime (oe);
   double   openPrice    = oe.OpenPrice(oe);
   int      closeEvent   = NULL;
   datetime closeTime    = NULL;
   double   closePrice   = NULL;
   double   stopLoss     = oe.StopLoss(oe);
   bool     closedBySL   = false;

   double   swap         = oe.Swap      (oe);      // for the theoretical case swap is already set on OrderOpen
   double   commission   = oe.Commission(oe);
   double   profit       = NULL;

   // store dataset
   if (!Orders.AddRecord(ticket, level, gridbase, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, closedBySL, swap, commission, profit))
      return(false);
   return(!catch("Grid.AddPosition(7)"));
}


/**
 * Trail pending open price and stoploss of the specified stop order. If the new open price is too close to the market the
 * stop order may be replaced by a limit order.
 *
 * @param  int i - pending order index
 *
 * @return int - order type of the resulting order (stop or limit) or NULL in case of errors
 */
int Grid.TrailPendingOrder(int i) {
   if (IsLastError())                         return(NULL);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("Grid.TrailPendingOrder(1)  "+ sequence.longName +" cannot trail order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (orders.type[i] != OP_UNDEFINED)        return(!catch("Grid.TrailPendingOrder(2)  "+ sequence.longName +" cannot trail "+ OperationTypeDescription(orders.type[i]) +" position #"+ orders.ticket[i], ERR_ILLEGAL_STATE));
   if (orders.closeTime[i] != 0)              return(!catch("Grid.TrailPendingOrder(3)  "+ sequence.longName +" cannot trail cancelled "+ OperationTypeDescription(orders.type[i]) +" order #"+ orders.ticket[i], ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.TrailPendingOrder()", "Do you really want to modify the "+ OperationTypeDescription(orders.pendingType[i]) +" order #"+ orders.ticket[i] +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   // calculate changing data
   int      ticket       = orders.ticket[i], oe[];
   int      level        = orders.level[i];
   double   gridbase     = GetGridbase();
   datetime pendingTime;
   double   pendingPrice = NormalizeDouble(gridbase +           level * GridSize * Pips, Digits);
   double   stopLoss     = NormalizeDouble(pendingPrice - Sign(level) * GridSize * Pips, Digits);

   if (!SelectTicket(ticket, "Grid.TrailPendingOrder(4)", true)) return(NULL);
   datetime prevPendingTime  = OrderOpenTime();
   double   prevPendingPrice = OrderOpenPrice();
   double   prevStoploss     = OrderStopLoss();
   OrderPop("Grid.TrailPendingOrder(5)");

   int error = ModifyStopOrder(ticket, pendingPrice, stopLoss, oe);
   pendingTime = oe.OpenTime(oe);

   if (IsError(error)) {
      if (oe.Error(oe) != ERR_INVALID_STOP) return(NULL);
      if (error == -1) {                                    // market violated: delete stop order and open a limit order instead
         error = Grid.DeleteOrder(i);
         if (!error) return(Grid.AddPendingOrder(level));

         if (error == -1) {                                 // deletion failed, the stop order was already executed
            if (__LOG()) log("Grid.TrailPendingOrder(6)  "+ sequence.longName +" pending #"+ orders.ticket[i] +" was already executed");
            pendingTime  = prevPendingTime;                 // restore the original values
            pendingPrice = prevPendingPrice;

            error = ModifyStopLoss(i, gridbase, stopLoss);  // modify stoploss of the now open position
            if (IsError(error)) {
               if (error != -1) return(NULL);               // another error
               warn("Grid.TrailPendingOrder(7)  "+ sequence.longName +" pending #"+ orders.ticket[i] +" entry limit and SL were already executed");
               stopLoss = prevStoploss;
            }
         }
         else return(NULL);                                 // another error
      }
      else if (error == -2) {
         return(!catch("Grid.TrailPendingOrder(8)  "+ sequence.longName +" unsupported bucketshop account (stop distance is not zero)", oe.Error(oe)));
      }
      else return(!catch("Grid.TrailPendingOrder(9)  "+ sequence.longName +" unknown ModifyStopOrder() return value "+ error, oe.Error(oe)));
   }

   // update changed data (ignore current ticket status which may be different)
   orders.gridbase    [i] = gridbase;
   orders.pendingTime [i] = pendingTime;
   orders.pendingPrice[i] = pendingPrice;
   orders.stopLoss    [i] = stopLoss;

   if (!catch("Grid.TrailPendingOrder(10)"))
      return(orders.pendingType[i]);
   return(NULL);
}


/**
 * Cancel the specified pending order and remove it from the order arrays.
 *
 * @param  int i - order index
 *
 * @return int - NULL on success or another value in case of errors, especially
 *               -1 if the order was already executed and is not pending anymore
 */
int Grid.DeleteOrder(int i) {
   if (IsLastError())                                                           return(last_error);
   if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING) return(catch("Grid.DeleteOrder(1)  "+ sequence.longName +" cannot delete order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (orders.type[i] != OP_UNDEFINED)                                          return(catch("Grid.DeleteOrder(2)  "+ sequence.longName +" cannot delete "+ ifString(orders.closeTime[i], "closed", "open") +" "+ OperationTypeDescription(orders.type[i]) +" order", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.DeleteOrder()", "Do you really want to cancel the "+ OperationTypeDescription(orders.pendingType[i]) +" order at level "+ orders.level[i] +" now?"))
      return(SetLastError(ERR_CANCELLED_BY_USER));

   if (orders.ticket[i] > 0) {
      int oe[], oeFlags  = F_ERR_INVALID_TRADE_PARAMETERS;     // accept the order already being executed
                oeFlags |= F_ERR_NO_CONNECTION;                // custom handling of recoverable network errors
                oeFlags |= F_ERR_TRADESERVER_GONE;
                oeFlags |= F_ERR_TRADE_DISABLED;
                oeFlags |= F_ERR_MARKET_CLOSED;

      bool success = OrderDeleteEx(orders.ticket[i], CLR_NONE, oeFlags, oe);
      if (success) {
         SetLastNetworkError(oe);
      }
      else {
         int error = oe.Error(oe);
         switch (error) {
            case ERR_INVALID_TRADE_PARAMETERS:
               return(-1);
            case ERR_NO_CONNECTION:
            case ERR_TRADESERVER_GONE:
            case ERR_TRADE_DISABLED:
            case ERR_MARKET_CLOSED:
               return(SetLastNetworkError(oe));
         }
         return(SetLastError(error));
      }
   }
   if (!Orders.RemoveRecord(i)) return(last_error);

   ArrayResize(oe, 0);
   return(catch("Grid.DeleteOrder(3)"));
}


/**
 * Cancel the exit limit of the specified order.
 *
 * @param  int i - order index
 *
 * @return int - NULL on success or another value in case of errors, especially
 *                -1 if the limit was already executed
 */
int Grid.DeleteLimit(int i) {
   if (IsLastError())                                                                   return(last_error);
   if (sequence.status != STATUS_STOPPING)                                              return(catch("Grid.DeleteLimit(1)  "+ sequence.longName +" cannot delete limit of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (i < 0 || i >= ArraySize(orders.ticket))                                          return(catch("Grid.DeleteLimit(2)  "+ sequence.longName +" invalid parameter i: "+ i +" (out of range)", ERR_INVALID_PARAMETER));
   if (orders.type[i]==OP_UNDEFINED || orders.type[i] > OP_SELL || orders.closeTime[i]) return(catch("Grid.DeleteLimit(3)  "+ sequence.longName +" cannot delete limit of "+ ifString(orders.closeTime[i], "closed", "open") +" "+ OperationTypeDescription(orders.type[i]) +" order", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.DeleteLimit()", "Do you really want to delete the limit of the position at level "+ orders.level[i] +" now?"))
      return(SetLastError(ERR_CANCELLED_BY_USER));

   int oe[], oeFlags  = F_ERR_INVALID_TRADE_PARAMETERS;     // accept the limit already being executed
             oeFlags |= F_ERR_NO_CONNECTION;                // custom handling of recoverable network errors
             oeFlags |= F_ERR_TRADESERVER_GONE;
             oeFlags |= F_ERR_TRADE_DISABLED;
             oeFlags |= F_ERR_MARKET_CLOSED;

   if (OrderModifyEx(orders.ticket[i], orders.openPrice[i], NULL, NULL, NULL, CLR_NONE, oeFlags, oe))
      return(_NULL(SetLastNetworkError(oe)));

   int error = oe.Error(oe);
   switch (error) {
      case ERR_INVALID_TRADE_PARAMETERS:
         return(-1);
      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
         return(SetLastNetworkError(oe));
   }
   return(SetLastError(error));
}


/**
 * Add an order record at the specified offset of the internal order arrays. Array size is increased and the record is
 * inserted, no data is overwritten.
 *
 * @param  int      ticket
 * @param  int      level
 * @param  double   gridBase
 *
 * @param  int      pendingType
 * @param  datetime pendingTime
 * @param  double   pendingPrice
 *
 * @param  int      type
 * @param  int      openEvent
 * @param  datetime openTime
 * @param  double   openPrice
 * @param  int      closeEvent
 * @param  datetime closeTime
 * @param  double   closePrice
 * @param  double   stopLoss
 * @param  bool     closedBySL
 *
 * @param  double   swap
 * @param  double   commission
 * @param  double   profit
 *
 * @param  int      offset [optional] - position (array index) to add the order record (default: append to the end)
 *
 * @return bool - success status
 */
bool Orders.AddRecord(int ticket, int level, double gridBase, int pendingType, datetime pendingTime, double pendingPrice, int type, int openEvent, datetime openTime, double openPrice, int closeEvent, datetime closeTime, double closePrice, double stopLoss, bool closedBySL, double swap, double commission, double profit, int offset = -1) {
   closedBySL = closedBySL!=0;

   int ordersSize = ArraySize(orders.ticket);
   if (offset < -1 || offset > ordersSize) return(!catch("Orders.AddRecord(1)  "+ sequence.longName +" illegal parameter offset: "+ offset +" (order array size: "+ ordersSize +")", ERR_INVALID_PARAMETER));

   if (offset == -1)
      offset = ordersSize;

   ArrayInsertInt   (orders.ticket,       offset, ticket                               );
   ArrayInsertInt   (orders.level,        offset, level                                );
   ArrayInsertDouble(orders.gridbase,     offset, NormalizeDouble(gridBase, Digits)    );

   ArrayInsertInt   (orders.pendingType,  offset, pendingType                          );
   ArrayInsertInt   (orders.pendingTime,  offset, pendingTime                          );
   ArrayInsertDouble(orders.pendingPrice, offset, NormalizeDouble(pendingPrice, Digits));

   ArrayInsertInt   (orders.type,         offset, type                                 );
   ArrayInsertInt   (orders.openEvent,    offset, openEvent                            );
   ArrayInsertInt   (orders.openTime,     offset, openTime                             );
   ArrayInsertDouble(orders.openPrice,    offset, NormalizeDouble(openPrice, Digits)   );
   ArrayInsertInt   (orders.closeEvent,   offset, closeEvent                           );
   ArrayInsertInt   (orders.closeTime,    offset, closeTime                            );
   ArrayInsertDouble(orders.closePrice,   offset, NormalizeDouble(closePrice, Digits)  );
   ArrayInsertDouble(orders.stopLoss,     offset, NormalizeDouble(stopLoss, Digits)    );
   ArrayInsertBool  (orders.closedBySL,   offset, closedBySL                           );

   ArrayInsertDouble(orders.swap,         offset, NormalizeDouble(swap,       2)       );
   ArrayInsertDouble(orders.commission,   offset, NormalizeDouble(commission, 2)       );
   ArrayInsertDouble(orders.profit,       offset, NormalizeDouble(profit,     2)       );

   return(!catch("Orders.AddRecord(2)"));
}


/**
 * Remove the order record at the specified offset from the internal order arrays. After removal the array size is decreased.
 *
 * @param  int offset - position (array index) of the record to remove
 *
 * @return bool - success status
 */
bool Orders.RemoveRecord(int offset) {
   if (offset < 0 || offset >= ArraySize(orders.ticket)) return(!catch("Orders.RemoveRecord(1)  "+ sequence.longName +" illegal parameter offset: "+ offset +" (order array size: "+ ArraySize(orders.ticket) +")", ERR_INVALID_PARAMETER));

   ArraySpliceInts   (orders.ticket,       offset, 1);
   ArraySpliceInts   (orders.level,        offset, 1);
   ArraySpliceDoubles(orders.gridbase,     offset, 1);

   ArraySpliceInts   (orders.pendingType,  offset, 1);
   ArraySpliceInts   (orders.pendingTime,  offset, 1);
   ArraySpliceDoubles(orders.pendingPrice, offset, 1);

   ArraySpliceInts   (orders.type,         offset, 1);
   ArraySpliceInts   (orders.openEvent,    offset, 1);
   ArraySpliceInts   (orders.openTime,     offset, 1);
   ArraySpliceDoubles(orders.openPrice,    offset, 1);
   ArraySpliceInts   (orders.closeEvent,   offset, 1);
   ArraySpliceInts   (orders.closeTime,    offset, 1);
   ArraySpliceDoubles(orders.closePrice,   offset, 1);
   ArraySpliceDoubles(orders.stopLoss,     offset, 1);
   ArraySpliceBools  (orders.closedBySL,   offset, 1);

   ArraySpliceDoubles(orders.swap,         offset, 1);
   ArraySpliceDoubles(orders.commission,   offset, 1);
   ArraySpliceDoubles(orders.profit,       offset, 1);

   return(!catch("Orders.RemoveRecord(2)"));
}


/**
 * Resize the order arrays.
 *
 * @param  int  size             - new order array size
 * @param  bool reset [optional] - whether to re-initialize all records (default: initialize only added records)
 *
 * @return int - new array size
 */
int Orders.ResizeArrays(int size, bool reset = false) {
   reset = reset!=0;

   int oldSize = ArraySize(orders.ticket);

   if (size != oldSize) {
      ArrayResize(orders.ticket,       size);
      ArrayResize(orders.level,        size);
      ArrayResize(orders.gridbase,     size);
      ArrayResize(orders.pendingType,  size);
      ArrayResize(orders.pendingTime,  size);
      ArrayResize(orders.pendingPrice, size);
      ArrayResize(orders.type,         size);
      ArrayResize(orders.openEvent,    size);
      ArrayResize(orders.openTime,     size);
      ArrayResize(orders.openPrice,    size);
      ArrayResize(orders.closeEvent,   size);
      ArrayResize(orders.closeTime,    size);
      ArrayResize(orders.closePrice,   size);
      ArrayResize(orders.stopLoss,     size);
      ArrayResize(orders.closedBySL,   size);
      ArrayResize(orders.swap,         size);
      ArrayResize(orders.commission,   size);
      ArrayResize(orders.profit,       size);
   }

   if (reset) {                                                      // re-initialize all fields
      if (size != 0) {
         ArrayInitialize(orders.ticket,                 0);
         ArrayInitialize(orders.level,                  0);
         ArrayInitialize(orders.gridbase,               0);
         ArrayInitialize(orders.pendingType, OP_UNDEFINED);
         ArrayInitialize(orders.pendingTime,            0);
         ArrayInitialize(orders.pendingPrice,           0);
         ArrayInitialize(orders.type,        OP_UNDEFINED);
         ArrayInitialize(orders.openEvent,              0);
         ArrayInitialize(orders.openTime,               0);
         ArrayInitialize(orders.openPrice,              0);
         ArrayInitialize(orders.closeEvent,             0);
         ArrayInitialize(orders.closeTime,              0);
         ArrayInitialize(orders.closePrice,             0);
         ArrayInitialize(orders.stopLoss,               0);
         ArrayInitialize(orders.closedBySL,         false);
         ArrayInitialize(orders.swap,                   0);
         ArrayInitialize(orders.commission,             0);
         ArrayInitialize(orders.profit,                 0);
      }
   }
   else {                                                            // initialize only added fields
      for (int i=oldSize; i < size; i++) {
         orders.pendingType[i] = OP_UNDEFINED;                       // always initialize pendingType and type to non-zero
         orders.type       [i] = OP_UNDEFINED;                       // as 0 is a valid value
      }
   }
   return(size);
}


/**
 * Find an open position of the specified level and return it's index in the order arrays. There can only be one open position
 * per level.
 *
 * @param  int level - gridlevel of the position to find
 *
 * @return int - order array index of the found position or EMPTY (-1) if no open position was found
 */
int Grid.FindOpenPosition(int level) {
   if (!level) return(_EMPTY(catch("Grid.FindOpenPosition(1)  "+ sequence.longName +" illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   int size = ArraySize(orders.ticket);
   for (int i=size-1; i >= 0; i--) {                                 // iterate backwards for performance
      if (orders.level[i] != level)       continue;                  // the gridlevel must match
      if (orders.type[i] == OP_UNDEFINED) continue;                  // the order must have been opened
      if (orders.closeTime[i] != 0)       continue;                  // the order must not have been closed
      return(i);
   }
   return(EMPTY);
}


/**
 * Open a position at current market price.
 *
 * @param  _In_  int type  - order type: OP_BUY | OP_SELL
 * @param  _In_  int level - order gridlevel
 * @param  _Out_ int oe[]  - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket (positive value) on success or another value in case of errors, especially
 *                -1 if the stoploss violates the current market or
 *                -2 if the stoploss violates the broker's stop distance
 */
int SubmitMarketOrder(int type, int level, int &oe[]) {
   if (IsLastError())                                                           return(0);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitMarketOrder(1)  "+ sequence.longName +" cannot submit market order for "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (type!=OP_BUY  && type!=OP_SELL)                                          return(_NULL(catch("SubmitMarketOrder(2)  "+ sequence.longName +" illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUY  && level<=0)                                               return(_NULL(catch("SubmitMarketOrder(3)  "+ sequence.longName +" illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELL && level>=0)                                               return(_NULL(catch("SubmitMarketOrder(4)  "+ sequence.longName +" illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   lots        = sequence.unitsize;
   double   price       = NULL;
   double   slippage    = 0.1;
   double   stopLoss    = GetGridbase() + (level-Sign(level))*GridSize*Pips;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = ifInt(level > 0, CLR_LONG, CLR_SHORT); if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = NULL;
            oeFlags    |= F_ERR_NO_CONNECTION;     // custom handling of recoverable network errors
            oeFlags    |= F_ERR_TRADESERVER_GONE;
            oeFlags    |= F_ERR_TRADE_DISABLED;
            oeFlags    |= F_ERR_MARKET_CLOSED;

   if (Abs(level) >= Abs(sequence.level))
      oeFlags |= F_ERR_INVALID_STOP;               // custom handling of ERR_INVALID_STOP for the last gridlevel only

   int ticket = OrderSendEx(Symbol(), type, lots, price, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) {
      SetLastNetworkError(oe);
      return(ticket);
   }

   int error = oe.Error(oe);
   switch (error) {
      case ERR_INVALID_STOP:                       // either the stoploss violates the market (-1) or the broker's stop distance (-2)
         if (!oeFlags & F_ERR_INVALID_STOP)
            break;
         bool insideSpread;
         if (!oe.StopDistance(oe)) insideSpread = true;
         else if (type == OP_BUY)  insideSpread = GE(oe.StopLoss(oe), oe.Bid(oe));
         else                      insideSpread = LE(oe.StopLoss(oe), oe.Ask(oe));
         return(ifInt(insideSpread, -1, -2));

      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
         return(_NULL(SetLastNetworkError(oe)));
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Open a pending stop order.
 *
 * @param  _In_  int type  - order type: OP_BUYSTOP | OP_SELLSTOP
 * @param  _In_  int level - order gridlevel
 * @param  _Out_ int oe[]  - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket (positive value) on success or another value in case of errors, especially
 *                -1 if the limit violates the current market or
 *                -2 if the limit violates the broker's stop distance
 */
int SubmitStopOrder(int type, int level, int &oe[]) {
   if (IsLastError())                                                           return(0);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitStopOrder(1)  "+ sequence.longName +" cannot submit stop order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (type!=OP_BUYSTOP  && type!=OP_SELLSTOP)                                  return(_NULL(catch("SubmitStopOrder(2)  "+ sequence.longName +" illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUYSTOP  && level <= 0)                                         return(_NULL(catch("SubmitStopOrder(3)  "+ sequence.longName +" illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELLSTOP && level >= 0)                                         return(_NULL(catch("SubmitStopOrder(4)  "+ sequence.longName +" illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   lots        = sequence.unitsize;
   double   stopPrice   = GetGridbase() + level*GridSize*Pips;
   double   slippage    = NULL;
   double   stopLoss    = stopPrice - Sign(level)*GridSize*Pips;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = CLR_PENDING; if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = F_ERR_INVALID_STOP;         // custom handling of ERR_INVALID_STOP
            oeFlags    |= F_ERR_NO_CONNECTION;        // custom handling of recoverable network errors
            oeFlags    |= F_ERR_TRADESERVER_GONE;
            oeFlags    |= F_ERR_TRADE_DISABLED;
            oeFlags    |= F_ERR_MARKET_CLOSED;

   int ticket = OrderSendEx(Symbol(), type, lots, stopPrice, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) {
      SetLastNetworkError(oe);
      return(ticket);
   }

   int error = oe.Error(oe);
   switch (error) {
      case ERR_INVALID_STOP:                          // either the entry limit violates the market (-1) or the broker's stop distance (-2)
         bool violatedMarket;
         if (!oe.StopDistance(oe))    violatedMarket = true;
         else if (type == OP_BUYSTOP) violatedMarket = LE(oe.OpenPrice(oe), oe.Ask(oe));
         else                         violatedMarket = GE(oe.OpenPrice(oe), oe.Bid(oe));
         return(ifInt(violatedMarket, -1, -2));

      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
         return(_NULL(SetLastNetworkError(oe)));
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Open a pending limit order.
 *
 * @param  _In_  int type  - order type: OP_BUYLIMIT | OP_SELLLIMIT
 * @param  _In_  int level - order gridlevel
 * @param  _Out_ int oe[]  - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket (positive value) on success or another value in case of errors, especially
 *                -1 if the limit violates the current market or
 *                -2 the limit violates the broker's stop distance
 */
int SubmitLimitOrder(int type, int level, int &oe[]) {
   if (IsLastError())                                                           return(0);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitLimitOrder(1)  "+ sequence.longName +" cannot submit limit order for "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (type!=OP_BUYLIMIT  && type!=OP_SELLLIMIT)                                return(_NULL(catch("SubmitLimitOrder(2)  "+ sequence.longName +" illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUYLIMIT  && level <= 0)                                        return(_NULL(catch("SubmitLimitOrder(3)  "+ sequence.longName +" illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELLLIMIT && level >= 0)                                        return(_NULL(catch("SubmitLimitOrder(4)  "+ sequence.longName +" illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   lots        = sequence.unitsize;
   double   limitPrice  = GetGridbase() + level*GridSize*Pips;
   double   slippage    = NULL;
   double   stopLoss    = limitPrice - Sign(level)*GridSize*Pips;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = CLR_PENDING; if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = F_ERR_INVALID_STOP;         // custom handling of ERR_INVALID_STOP
            oeFlags    |= F_ERR_NO_CONNECTION;        // custom handling of recoverable network errors
            oeFlags    |= F_ERR_TRADESERVER_GONE;
            oeFlags    |= F_ERR_TRADE_DISABLED;
            oeFlags    |= F_ERR_MARKET_CLOSED;

   int ticket = OrderSendEx(Symbol(), type, lots, limitPrice, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) {
      SetLastNetworkError(oe);
      return(ticket);
   }

   int error = oe.Error(oe);
   switch (error) {
      case ERR_INVALID_STOP:                          // either the entry limit violates the market (-1) or the broker's stop distance (-2)
         bool violatedMarket;
         if (!oe.StopDistance(oe))     violatedMarket = true;
         else if (type == OP_BUYLIMIT) violatedMarket = GE(oe.OpenPrice(oe), oe.Ask(oe));
         else                          violatedMarket = LE(oe.OpenPrice(oe), oe.Bid(oe));
         return(ifInt(violatedMarket, -1, -2));

      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
         return(_NULL(SetLastNetworkError(oe)));
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Modify entry and stoploss price of a pending order (i.e. trail a first level order).
 *
 * @param  _In_  int    ticket
 * @param  _In_  double price
 * @param  _In_  double stopLoss
 * @param  _Out_ int    oe[] - order execution details (struct ORDER_EXECUTION)
 *
 * @return int - error status: NULL on success or another value in case of errors, especially
 *                -1 if the new entry price violates the current market
 *                -2 if the new entry price violates the broker's stop distance
 */
int ModifyStopOrder(int ticket, double price, double stopLoss, int &oe[]) {
   if (IsLastError())                         return(last_error);
   if (sequence.status != STATUS_PROGRESSING) return(catch("ModifyStopOrder(1)  "+ sequence.longName +" cannot modify order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int oeFlags  = F_ERR_INVALID_STOP;           // custom handling of ERR_INVALID_STOP
       oeFlags |= F_ERR_NO_CONNECTION;          // custom handling of recoverable network errors
       oeFlags |= F_ERR_TRADESERVER_GONE;
       oeFlags |= F_ERR_TRADE_DISABLED;
       oeFlags |= F_ERR_MARKET_CLOSED;

   bool success = OrderModifyEx(ticket, price, stopLoss, NULL, NULL, CLR_PENDING, oeFlags, oe);
   if (success) {
      SetLastNetworkError(oe);
      return(NO_ERROR);
   }

   int error = oe.Error(oe);
   switch (error) {
      case ERR_INVALID_STOP:                    // either the entry price violates the market (-1) or it violates the broker's stop distance (-2)
         bool violatedMarket;
         if (!oe.StopDistance(oe))           violatedMarket = true;
         else if (oe.Type(oe) == OP_BUYSTOP) violatedMarket = GE(oe.Ask(oe), price);
         else                                violatedMarket = LE(oe.Bid(oe), price);
         return(ifInt(violatedMarket, -1, -2));

      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
         return(SetLastNetworkError(oe));
   }
   return(SetLastError(error));
}


/**
 * Modify gridbase and stoploss of an open position.
 *
 * @param  int    i        - order array index of the position to modify
 * @param  double gridbase - new gridbase
 * @param  double stoploss - new stoploss
 *
 * @return int - NULL on success or another value in case of errors, especially
 *               -1 if the position was already closed
 */
int ModifyStopLoss(int i, double gridbase, double stoploss) {
   if (IsLastError())                                                              return(last_error);
   if (sequence.status != STATUS_PROGRESSING)                                      return(catch("ModifyStopLoss(1)  "+ sequence.longName +" cannot modify order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (i < 0 || i >= ArraySize(orders.ticket))                                     return(catch("ModifyStopLoss(2)  "+ sequence.longName +" invalid parameter i: "+ i +" (out of range)", ERR_INVALID_PARAMETER));
   if ((orders.type[i]!=OP_BUY && orders.type[i]!=OP_SELL) || orders.closeTime[i]) return(catch("ModifyStopLoss(3)  "+ sequence.longName +" cannot change stoploss of "+ ifString(orders.closeTime[i], "closed", "open") +" "+ OperationTypeDescription(orders.type[i]) +" order", ERR_ILLEGAL_STATE));

   gridbase = NormalizeDouble(gridbase, Digits);
   stoploss = NormalizeDouble(stoploss, Digits);

   int oe[], oeFlags  = F_ERR_INVALID_TRADE_PARAMETERS;     // accept the position already being closed
             oeFlags |= F_ERR_NO_CONNECTION;                // custom handling of recoverable network errors
             oeFlags |= F_ERR_TRADESERVER_GONE;
             oeFlags |= F_ERR_TRADE_DISABLED;
             oeFlags |= F_ERR_MARKET_CLOSED;

   if (OrderModifyEx(orders.ticket[i], NULL, stoploss, NULL, NULL, CLR_NONE, oeFlags, oe)) {
      orders.gridbase[i] = gridbase;
      orders.stopLoss[i] = stoploss;
      return(_NULL(SetLastNetworkError(oe)));
   }

   int error = oe.Error(oe);
   switch (error) {
      case ERR_INVALID_TRADE_PARAMETERS:
         orders.gridbase[i] = gridbase;
         return(-1);
      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
         return(SetLastNetworkError(oe));
   }
   return(SetLastError(error));
}


/**
 * Manually execute a triggered StopLoss of an open position. Called only by UpdateStatus() to work around a terminal bug.
 *
 * @param  int ticket
 *
 * @return bool - whether the position was successfully closed was already closed by the broker
 *
 * @see    https://github.com/rosasurfer/mt4-mql/issues/10
 */
bool UpdateStatus.ExecuteStopLoss(int ticket) {
   if (IsLastError())                         return(!last_error);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdateStatus.ExecuteStopLoss(1)  "+ sequence.longName +" cannot execute stoploss of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int oe[], oeFlags  = F_ERR_INVALID_TRADE_PARAMETERS;     // accept the position already being closed
             oeFlags |= F_ERR_NO_CONNECTION;                // custom handling of recoverable network errors
             oeFlags |= F_ERR_TRADESERVER_GONE;
             oeFlags |= F_ERR_TRADE_DISABLED;
             oeFlags |= F_ERR_MARKET_CLOSED;

   bool success = OrderCloseEx(ticket, NULL, NULL, CLR_NONE, oeFlags, oe);
   if (success)
      return(_true(SetLastNetworkError(oe)));

   int error = oe.Error(oe);
   switch (error) {
      case ERR_INVALID_TRADE_PARAMETERS:                    // position already closed
         return(true);

      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
         return(!SetLastNetworkError(oe));
   }
   return(!SetLastError(error));
}


/**
 * Generiert f�r den angegebenen Gridlevel eine MagicNumber.
 *
 * @param  int level - Gridlevel
 *
 * @return int - MagicNumber oder -1 (EMPTY), falls ein Fehler auftrat
 */
int CreateMagicNumber(int level) {
   if (sequence.id < SID_MIN) return(_EMPTY(catch("CreateMagicNumber(1)  "+ sequence.longName +" illegal sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR)));
   if (!level)                return(_EMPTY(catch("CreateMagicNumber(2)  "+ sequence.longName +" illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   // F�r bessere Obfuscation ist die Reihenfolge der Werte [ea,level,sequence] und nicht [ea,sequence,level], was aufeinander folgende Werte w�ren.
   int ea       = STRATEGY_ID & 0x3FF << 22;                         // 10 bit (Bits gr��er 10 l�schen und auf 32 Bit erweitern)  | Position in MagicNumber: Bits 23-32
       level    = Abs(level);                                        // der Level in MagicNumber ist immer positiv                |
       level    = level & 0xFF << 14;                                //  8 bit (Bits gr��er 8 l�schen und auf 22 Bit erweitern)   | Position in MagicNumber: Bits 15-22
   int sequence = sequence.id & 0x3FFF;                              // 14 bit (Bits gr��er 14 l�schen                            | Position in MagicNumber: Bits  1-14

   return(ea + level + sequence);
}


/**
 * Display the current runtime status.
 *
 * @param  int error [optional] - error to display (default: none)
 *
 * @return int - the same error or the current error status if no error was passed
 */
int ShowStatus(int error = NO_ERROR) {
   if (!__CHART()) return(error);

   string msg, sError;

   if      (__STATUS_INVALID_INPUT) sError = StringConcatenate("  [",                 ErrorDescription(ERR_INVALID_INPUT_PARAMETER), "]");
   else if (__STATUS_OFF          ) sError = StringConcatenate("  [switched off => ", ErrorDescription(__STATUS_OFF.reason        ), "]");

   switch (sequence.status) {
      case STATUS_UNDEFINED:   msg = " not initialized"; break;
      case STATUS_WAITING:     msg = StringConcatenate("     ", sSequenceDirection, " ", Sequence.ID, " waiting at level ",     sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      case STATUS_STARTING:    msg = StringConcatenate("     ", sSequenceDirection, " ", Sequence.ID, " starting at level ",    sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      case STATUS_PROGRESSING: msg = StringConcatenate("     ", sSequenceDirection, " ", Sequence.ID, " progressing at level ", sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      case STATUS_STOPPING:    msg = StringConcatenate("     ", sSequenceDirection, " ", Sequence.ID, " stopping at level ",    sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      case STATUS_STOPPED:     msg = StringConcatenate("     ", sSequenceDirection, " ", Sequence.ID, " stopped at level ",     sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      default:
         return(catch("ShowStatus(1)  "+ sequence.longName +" illegal sequence status = "+ sequence.status, ERR_ILLEGAL_STATE));
   }
   msg = StringConcatenate(__NAME(), msg, sError,                                    NL,
                                                                                     NL,
                           "Grid:              ", GridSize, " pip", sGridBase,       NL,
                           "LotSize:          ",  sLotSize, sSequenceProfitPerLevel, NL,
                           "Start:             ", sStartConditions,                  NL,
                           "Stop:              ", sStopConditions,                   NL,
                           sAutoRestart,                 // if set the var ends with NL,
                           "Stops:             ", sSequenceStops, sSequenceStopsPL,  NL,
                           "Profit/Loss:    ",   sSequenceTotalPL, sSequencePlStats, NL,
                           sStartStopStats,              // if set the var ends with NL,
                           sRestartStats
   );

   // 4 lines margin-top for instrument and indicator legends
   Comment(NL, NL, NL, NL, msg);
   if (__WHEREAMI__ == CF_INIT)
      WindowRedraw();

   // f�r Fernbedienung: versteckten Status im Chart speichern
   string label = "SnowRoller.status";
   if (ObjectFind(label) != 0) {
      if (!ObjectCreate(label, OBJ_LABEL, 0, 0, 0))
         return(catch("ShowStatus(2)"));
      ObjectSet(label, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   }
   if (sequence.status == STATUS_UNDEFINED) ObjectDelete(label);
   else                                     ObjectSetText(label, StringConcatenate(Sequence.ID, "|", sequence.status), 1);

   if (!catch("ShowStatus(3)"))
      return(error);
   return(last_error);
}


/**
 * Ob die aktuell selektierte Order zu dieser Strategie geh�rt. Wird eine Sequenz-ID angegeben, wird zus�tzlich �berpr�ft,
 * ob die Order zur angegebenen Sequenz geh�rt.
 *
 * @param  int sequenceId - ID einer Sequenz (default: NULL)
 *
 * @return bool
 */
bool IsMyOrder(int sequenceId = NULL) {
   if (OrderSymbol() == Symbol()) {
      if (OrderMagicNumber() >> 22 == STRATEGY_ID) {
         if (sequenceId == NULL)
            return(true);
         return(sequenceId == OrderMagicNumber() & 0x3FFF);          // 14 Bits (Bits 1-14) => sequence.id
      }
   }
   return(false);
}


/**
 * Generate and return a new event id.
 *
 * @return int - new event id
 */
int CreateEventId() {
   lastEventId++;
   return(lastEventId);
}


/**
 * Write the current sequence status to a file. The sequence can be reloaded from the file.
 *
 * @return bool - success status
 */
bool SaveStatus() {
   if (IsLastError())                             return(false);
   if (!sequence.id)                              return(!catch("SaveStatus(1)  "+ sequence.longName +" illegal value of sequence.id = "+ sequence.id, ERR_ILLEGAL_STATE));
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(true);

   // In tester skip updating the status file on most calls; except at the first one, after sequence stop and at test end.
   if (IsTesting() && tester.reduceStatusWrites) {
      static bool saved = false;
      if (saved && sequence.status!=STATUS_STOPPED && __WHEREAMI__!=CF_DEINIT) {
         return(true);
      }
      saved = true;
   }

   string sCycle         = StrPadLeft(sequence.cycle, 3, "0");
   string sGridDirection = StrCapitalize(TradeDirectionDescription(sequence.direction));
   string sStarts        = SaveStatus.StartStopToStr(sequence.start.event, sequence.start.time, sequence.start.price, sequence.start.profit);
   string sStops         = SaveStatus.StartStopToStr(sequence.stop.event, sequence.stop.time, sequence.stop.price, sequence.stop.profit);
   string sGridBase      = SaveStatus.GridBaseToStr();
   string sActiveStartConditions="", sActiveStopConditions="";
   SaveStatus.ConditionsToStr(sActiveStartConditions, sActiveStopConditions);

   string file = GetStatusFileName();

   string section = "Common";
   WriteIniString(file, section, "Account",                  ShortAccountCompany() +":"+ GetAccountNumber());
   WriteIniString(file, section, "Symbol",                   Symbol());
   WriteIniString(file, section, "Sequence.ID",              Sequence.ID);
   WriteIniString(file, section, "GridDirection",            sGridDirection);
   WriteIniString(file, section, "ShowProfitInPercent",      ShowProfitInPercent);

   section = "SnowRoller-"+ sCycle;
   // The number of order records to store decreases if StopSequence() cancels an already stored pending order. To prevent
   // the status file containing orphaned order records cycle sections need to be emptied before writing to them.
   EmptyIniSectionA(file, section);

   WriteIniString(file, section, "Created",                  sequence.created +" ("+ GmtTimeFormat(sequence.created, "%a, %Y.%m.%d %H:%M:%S") +")");
   WriteIniString(file, section, "GridSize",                 GridSize);
   WriteIniString(file, section, "UnitSize",                 UnitSize);
   WriteIniString(file, section, "StartConditions",          sActiveStartConditions);
   WriteIniString(file, section, "StopConditions",           sActiveStopConditions);
   WriteIniString(file, section, "AutoRestart",              AutoRestart);
   WriteIniString(file, section, "StartLevel",               StartLevel);
   WriteIniString(file, section, "Sessionbreak.StartTime",   Sessionbreak.StartTime);
   WriteIniString(file, section, "Sessionbreak.EndTime",     Sessionbreak.EndTime);

   WriteIniString(file, section, "rt.sessionbreak.waiting",  sessionbreak.waiting);
   WriteIniString(file, section, "rt.sequence.startEquity",  DoubleToStr(sequence.startEquity, 2));
   WriteIniString(file, section, "rt.sequence.unitsize",     DoubleToStr(sequence.unitsize, 2));
   WriteIniString(file, section, "rt.sequence.maxProfit",    DoubleToStr(sequence.maxProfit, 2));
   WriteIniString(file, section, "rt.sequence.maxDrawdown",  DoubleToStr(sequence.maxDrawdown, 2));
   WriteIniString(file, section, "rt.sequence.starts",       sStarts);
   WriteIniString(file, section, "rt.sequence.stops",        sStops);
   WriteIniString(file, section, "rt.gridbase",              sGridBase);
   WriteIniString(file, section, "rt.sequence.missedLevels", JoinInts(sequence.missedLevels));
   WriteIniString(file, section, "rt.ignorePendingOrders",   JoinInts(ignorePendingOrders));
   WriteIniString(file, section, "rt.ignoreOpenPositions",   JoinInts(ignoreOpenPositions));
   WriteIniString(file, section, "rt.ignoreClosedPositions", JoinInts(ignoreClosedPositions));

   int size = ArraySize(orders.ticket);
   for (int i=0; i < size; i++) {
      WriteIniString(file, section, "rt.order."+ StrPadLeft(i, 4, "0"), SaveStatus.OrderToStr(i));
   }
   return(!catch("SaveStatus(2)"));
}


/**
 * Return a string representation of active start and stop conditions for SaveStatus(). The returned values don't contain
 * inactive conditions.
 *
 * @param  _Out_ string &startConditions - variable to receive active start conditions
 * @param  _Out_ string &stopConditions  - variable to receive active stop conditions
 */
void SaveStatus.ConditionsToStr(string &startConditions, string &stopConditions) {
   string sValue = "";

   // active start conditions (order: trend, time, price)
   if (start.conditions) {
      if (start.time.condition) {
         sValue = "@"+ start.time.description;
      }
      if (start.price.condition) {
         sValue = sValue + ifString(sValue=="", "", " && ") +"@"+ start.price.description;
      }
      if (start.trend.condition) {
         if (start.time.condition && start.price.condition) {
            sValue = "("+ sValue +")";
         }
         if (start.time.condition || start.price.condition) {
            sValue = " || "+ sValue;
         }
         sValue = "@"+ start.trend.description + sValue;
      }
   }
   startConditions = sValue;

   // active stop conditions (order: trend, time, price, profit, loss)
   sValue = "";
   if (stop.trend.condition) {
      sValue = "@"+ stop.trend.description;
   }
   if (stop.time.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.time.description;
   }
   if (stop.price.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.price.description;
   }
   if (stop.profitAbs.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.profitAbs.description;
   }
   if (stop.profitPct.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.profitPct.description;
   }
   if (stop.lossAbs.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.lossAbs.description;
   }
   if (stop.lossPct.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.lossPct.description;
   }
   stopConditions = sValue;
}


/**
 * Return a string representation of sequence starts or stops as stored by SaveStatus().
 *
 * @param  int      events [] - sequence start or stop event ids
 * @param  datetime times  [] - sequence start or stop times
 * @param  double   prices [] - sequence start or stop prices
 * @param  double   profits[] - sequence start or stop profit amounts
 *
 * @return string
 */
string SaveStatus.StartStopToStr(int events[], datetime times[], double prices[], double profits[]) {
   string values[]; ArrayResize(values, 0);
   int size = ArraySize(events);

   for (int i=0; i < size; i++) {
      ArrayPushString(values, StringConcatenate(events[i], "|", times[i], "|", DoubleToStr(prices[i], Digits), "|", DoubleToStr(profits[i], 2)));
   }
   if (!size) ArrayPushString(values, "0|0|0|0");

   string result = JoinStrings(values);
   ArrayResize(values, 0);
   return(result);
}


/**
 * Return a string representation of the gridbase history as stored by SaveStatus().
 *
 * @return string
 */
string SaveStatus.GridBaseToStr() {
   string values[]; ArrayResize(values, 0);
   int size = ArraySize(gridbase.event);

   for (int i=0; i < size; i++) {
      ArrayPushString(values, StringConcatenate(gridbase.event[i], "|", gridbase.time[i], "|", DoubleToStr(gridbase.price[i], Digits)));
   }
   if (!size) ArrayPushString(values, "0|0|0");

   string result = JoinStrings(values);
   ArrayResize(values, 0);
   return(result);
}


/**
 * Return a string representation of an order record as stored by SaveStatus().
 *
 * @param int index - index of the order record
 *
 * @return string
 */
string SaveStatus.OrderToStr(int index) {
   /*
   rt.order.{i}={ticket},{level},{gridbase},{pendingType},{pendingTime},{pendingPrice},{type},{openEvent},{openTime},{openPrice},{closeEvent},{closeTime},{closePrice},{stopLoss},{closedBySL},{swap},{commission},{profit}
   rt.order.0=292836120,-1,1477.94,5,1575468000,1476.84,1,67,1575469086,1476.84,68,1575470978,1477.94,1477.94,1,0.00,-0.22,-3.97
   */
   int      ticket       = orders.ticket      [index];
   int      level        = orders.level       [index];
   double   gridbase     = orders.gridbase    [index];
   int      pendingType  = orders.pendingType [index];
   datetime pendingTime  = orders.pendingTime [index];
   double   pendingPrice = orders.pendingPrice[index];
   int      orderType    = orders.type        [index];
   int      openEvent    = orders.openEvent   [index];
   datetime openTime     = orders.openTime    [index];
   double   openPrice    = orders.openPrice   [index];
   int      closeEvent   = orders.closeEvent  [index];
   datetime closeTime    = orders.closeTime   [index];
   double   closePrice   = orders.closePrice  [index];
   double   stopLoss     = orders.stopLoss    [index];
   bool     closedBySL   = orders.closedBySL  [index];
   double   swap         = orders.swap        [index];
   double   commission   = orders.commission  [index];
   double   profit       = orders.profit      [index];

   return(StringConcatenate(ticket, ",", level, ",", DoubleToStr(gridbase, Digits), ",", pendingType, ",", pendingTime, ",", DoubleToStr(pendingPrice, Digits), ",", orderType, ",", openEvent, ",", openTime, ",", DoubleToStr(openPrice, Digits), ",", closeEvent, ",", closeTime, ",", DoubleToStr(closePrice, Digits), ",", DoubleToStr(stopLoss, Digits), ",", closedBySL, ",", DoubleToStr(swap, 2), ",", DoubleToStr(commission, 2), ",", DoubleToStr(profit, 2)));
}


/**
 * Restore the internal state of the EA from the current sequence's status file.
 *
 * @param  bool interactive - whether input parameters have been entered through the input dialog
 *
 * @return bool - success status
 */
bool RestoreSequence(bool interactive) {
   interactive = interactive!=0;
   if (IsLastError())                return(false);
   if (!ReadStatus())                return(false);      // read the status file
   if (!ValidateInputs(interactive)) return(false);      // validate restored input parameters
   if (!SynchronizeStatus())         return(false);      // synchronize restored state with the trade server
   return(true);
}


/**
 * Read the status file of the current sequence and restore all internal variables. Part of RestoreSequence().
 *
 * @return bool - success status
 */
bool ReadStatus() {
   if (IsLastError())  return(false);
   if (!sequence.id)   return(!catch("ReadStatus(1)  illegal value of sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR));

   string file = GetStatusFileName();
   if (!IsFileA(file)) return(!catch("ReadStatus(2)  status file "+ DoubleQuoteStr(file) +" not found", ERR_FILE_NOT_FOUND));

   // [Common]
   string section = "Common";
   string sAccount             = GetIniStringA(file, section, "Account",             "");
   string sSymbol              = GetIniStringA(file, section, "Symbol",              "");
   string sSequenceId          = GetIniStringA(file, section, "Sequence.ID",         "");
   string sGridDirection       = GetIniStringA(file, section, "GridDirection",       "");
   string sShowProfitInPercent = GetIniStringA(file, section, "ShowProfitInPercent", "");

   string sAccountRequired = ShortAccountCompany() +":"+ GetAccountNumber();
   if (sAccount != sAccountRequired) return(!catch("ReadStatus(3)  account mis-match "+ DoubleQuoteStr(sAccount) +"/"+ DoubleQuoteStr(sAccountRequired) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (sSymbol  != Symbol())         return(!catch("ReadStatus(4)  symbol mis-match "+ DoubleQuoteStr(sSymbol) +"/"+ DoubleQuoteStr(Symbol()) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   string sValue = sSequenceId;
   if (StrLeft(sValue, 1) == "T") {
      sequence.isTest = true;
      sValue = StrSubstr(sValue, 1);
   }
   if (sValue != ""+ sequence.id)    return(!catch("ReadStatus(5)  invalid or missing Sequence.ID "+ DoubleQuoteStr(sSequenceId) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   Sequence.ID = sSequenceId;
   if (sGridDirection == "")         return(!catch("ReadStatus(6)  invalid or missing GridDirection "+ DoubleQuoteStr(sGridDirection) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   GridDirection = sGridDirection;
   ShowProfitInPercent = StrToBool(sShowProfitInPercent);

   string sections[];
   int size = ReadStatusSections(file, sections); if (!size) return(false);

   // [SnowRoller-xxx]              // finished cycles: read profits only
   for (int i=0; i < size-1; i++) {
      section = sections[i];
      sequence.cycle++;
      double dStartEquity = StrToDouble(GetIniStringA(file, section, "rt.sequence.startEquity", ""));

      string sPL = GetIniStringA(file, section, "rt.sequence.stops", "");
      double dPL = StrToDouble(StrTrim(StrRightFrom(sPL, "|", -1)));
      if (ShowProfitInPercent) sPL = NumberToStr(MathDiv(dPL, dStartEquity) * 100, "+.2") +"%";
      else                     sPL = NumberToStr(dPL, "+.2");

      double dMaxPL = StrToDouble(GetIniStringA(file, section, "rt.sequence.maxProfit", ""));
      double dMinPL = StrToDouble(GetIniStringA(file, section, "rt.sequence.maxDrawdown", ""));
      if (ShowProfitInPercent) string sMaxPL = NumberToStr(MathDiv(dMaxPL, dStartEquity) * 100, "+.2") +"%";
      else                            sMaxPL = NumberToStr(dMaxPL, "+.2");
      if (ShowProfitInPercent) string sMinPL = NumberToStr(MathDiv(dMinPL, dStartEquity) * 100, "+.2") +"%";
      else                            sMinPL = NumberToStr(dMinPL, "+.2");
      string sPlStats = "  ("+ sMaxPL +"/"+ sMinPL +")";

      sRestartStats = " ----------------------------------------------------"+ NL
                     +" "+ sequence.cycle +":  "+ sPL + sPlStats + StrRightFrom(sRestartStats, "--", -1);
   }

   // [SnowRoller-xxx]              // last cycle: read everything
   section = sections[size-1];
   string sCreated               = GetIniStringA(file, section, "Created",                "");     // string   Created=Tue, 2019.09.24 01:00:00
   string sGridSize              = GetIniStringA(file, section, "GridSize",               "");     // int      GridSize=20
   string sUnitSize              = GetIniStringA(file, section, "UnitSize",               "");     // string   UnitSize=auto
   string sStartConditions       = GetIniStringA(file, section, "StartConditions",        "");     // string   StartConditions=@trend(HalfTrend:H1:3)
   string sStopConditions        = GetIniStringA(file, section, "StopConditions",         "");     // string   StopConditions=@trend(HalfTrend:H1:3) || @profit(2%)
   string sAutoRestart           = GetIniStringA(file, section, "AutoRestart",            "");     // string   AutoRestart=Continue
   string sStartLevel            = GetIniStringA(file, section, "StartLevel",             "");     // int      StartLevel=0
   string sSessionbreakStartTime = GetIniStringA(file, section, "Sessionbreak.StartTime", "");     // datetime Sessionbreak.StartTime=86160
   string sSessionbreakEndTime   = GetIniStringA(file, section, "Sessionbreak.EndTime",   "");     // datetime Sessionbreak.EndTime=3730

   sequence.cycle++;
   sValue = StrTrim(StrLeftTo(sCreated, "("));
   if (!StrIsDigit(sValue))                 return(!catch("ReadStatus(7)  invalid or missing creation timestamp "+ DoubleQuoteStr(sCreated) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   sequence.created = StrToInteger(sValue);
   if (!sequence.created)                   return(!catch("ReadStatus(8)  invalid creation timestamp "+ DoubleQuoteStr(sCreated) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (!StrIsDigit(sGridSize))              return(!catch("ReadStatus(9)  invalid or missing GridSize "+ DoubleQuoteStr(sGridSize) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   GridSize = StrToInteger(sGridSize);
   if (!StringLen(sUnitSize))               return(!catch("ReadStatus(10)  invalid or missing UnitSize "+ DoubleQuoteStr(sUnitSize) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   UnitSize = sUnitSize;
   if (!StrIsDigit(sStartLevel))            return(!catch("ReadStatus(11)  invalid or missing StartLevel "+ DoubleQuoteStr(sStartLevel) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   StartConditions = sStartConditions;
   StopConditions  = sStopConditions;
   AutoRestart     = sAutoRestart;
   StartLevel      = StrToInteger(sStartLevel);
   if (!StrIsDigit(sSessionbreakStartTime)) return(!catch("ReadStatus(12)  invalid or missing Sessionbreak.StartTime "+ DoubleQuoteStr(sSessionbreakStartTime) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   Sessionbreak.StartTime = StrToInteger(sSessionbreakStartTime);    // TODO: convert input to string and validate
   if (!StrIsDigit(sSessionbreakEndTime))   return(!catch("ReadStatus(13)  invalid or missing Sessionbreak.EndTime "+ DoubleQuoteStr(sSessionbreakEndTime) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   Sessionbreak.EndTime = StrToInteger(sSessionbreakEndTime);        // TODO: convert input to string and validate

   string sSessionbreakWaiting = GetIniStringA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string sStartEquity         = GetIniStringA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
          sUnitSize            = GetIniStringA(file, section, "rt.sequence.unitsize",     "");     // double  rt.sequence.unitsize=0.04
   string sMaxProfit           = GetIniStringA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string sMaxDrawdown         = GetIniStringA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string sStarts              = GetIniStringA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string sStops               = GetIniStringA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string sGridBase            = GetIniStringA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string sMissedLevels        = GetIniStringA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string sPendingOrders       = GetIniStringA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string sOpenPositions       = GetIniStringA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string sClosedPositions     = GetIniStringA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   sessionbreak.waiting = StrToBool(sSessionbreakWaiting);

   if (!StrIsNumeric(sStartEquity))         return(!catch("ReadStatus(14)  invalid or missing sequence.startEquity "+ DoubleQuoteStr(sStartEquity) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   sequence.startEquity = StrToDouble(sStartEquity);
   if (LT(sequence.startEquity, 0))         return(!catch("ReadStatus(15)  illegal sequence.startEquity "+ DoubleQuoteStr(sStartEquity) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (!StrIsNumeric(sUnitSize))            return(!catch("ReadStatus(16)  invalid or missing sequence.unitsize "+ DoubleQuoteStr(sUnitSize) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   sequence.unitsize = StrToDouble(sUnitSize);
   if (LT(sequence.unitsize, 0))            return(!catch("ReadStatus(17)  illegal sequence.unitsize "+ DoubleQuoteStr(sUnitSize) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (!StrIsNumeric(sMaxProfit))           return(!catch("ReadStatus(18)  invalid or missing sequence.maxProfit "+ DoubleQuoteStr(sMaxProfit) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   sequence.maxProfit = StrToDouble(sMaxProfit);
   if (!StrIsNumeric(sMaxDrawdown))         return(!catch("ReadStatus(19)  invalid or missing sequence.maxDrawdown "+ DoubleQuoteStr(sMaxDrawdown) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   sequence.maxDrawdown = StrToDouble(sMaxDrawdown);
   bool success = ReadStatus.ParseStartStop(sStarts, sequence.start.event, sequence.start.time, sequence.start.price, sequence.start.profit);
   if (!success)                            return(!catch("ReadStatus(20)  invalid or missing sequence.starts "+ DoubleQuoteStr(sStarts) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   success = ReadStatus.ParseStartStop(sStops, sequence.stop.event, sequence.stop.time, sequence.stop.price, sequence.stop.profit);
   if (!success)                            return(!catch("ReadStatus(21)  invalid or missing sequence.stops "+ DoubleQuoteStr(sStops) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (ArraySize(sequence.start.event) != ArraySize(sequence.stop.event))
                                            return(!catch("ReadStatus(22)  sizeOf(sequence.starts)="+ ArraySize(sequence.start.event) +"/sizeOf(sequence.stops)="+ ArraySize(sequence.stop.event) +" mis-match in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (!sequence.start.event[0]) {
      if (sequence.stop.event[0] != 0)      return(!catch("ReadStatus(23)  sequence.start.event[0]="+ sequence.start.event[0] +"/sequence.stop.event[0]="+ sequence.stop.event[0] +" mis-match in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
      ArrayResize(sequence.start.event,  0); ArrayResize(sequence.stop.event,  0);
      ArrayResize(sequence.start.time,   0); ArrayResize(sequence.stop.time,   0);
      ArrayResize(sequence.start.price,  0); ArrayResize(sequence.stop.price,  0);
      ArrayResize(sequence.start.profit, 0); ArrayResize(sequence.stop.profit, 0);
   }
   success = ReadStatus.ParseGridBase(sGridBase);
   if (!success)                            return(!catch("ReadStatus(24)  invalid or missing gridbase history "+ DoubleQuoteStr(sGridBase) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (_bool(ArraySize(gridbase.event)) != _bool(ArraySize(sequence.start.event)))
                                            return(!catch("ReadStatus(25)  sizeOf(gridbase)="+ ArraySize(gridbase.event) +"/sizeOf(sequence.starts)="+ ArraySize(sequence.start.event) +" mis-match in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   success = ReadStatus.ParseMissedLevels(sMissedLevels);
   if (!success)                            return(!catch("ReadStatus(26)  invalid missed gridlevels "+ DoubleQuoteStr(sMissedLevels) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   success = ReadStatus.ParseTickets(sPendingOrders, ignorePendingOrders);
   if (!success)                            return(!catch("ReadStatus(27)  invalid ignored pending orders "+ DoubleQuoteStr(sPendingOrders) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   success = ReadStatus.ParseTickets(sOpenPositions, ignoreOpenPositions);
   if (!success)                            return(!catch("ReadStatus(28)  invalid ignored open positions "+ DoubleQuoteStr(sOpenPositions) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   success = ReadStatus.ParseTickets(sClosedPositions, ignoreClosedPositions);
   if (!success)                            return(!catch("ReadStatus(29)  invalid ignored closed positions "+ DoubleQuoteStr(sClosedPositions) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));

   string orderKeys[], sOrder;
   size = ReadStatusOrders(file, section, orderKeys); if (size < 0) return(false);
   Orders.ResizeArrays(0);
   for (i=0; i < size; i++) {
      sOrder = GetIniStringA(file, section, orderKeys[i], "");    // mixed[] rt.order.123=292836120,-1,1477.94,5,1575468000,1476.84,1,67,1575469086,1476.84,68,1575470978,1477.94,1477.94,1,0.00,-0.22,-3.97
      success = ReadStatus.ParseOrder(sOrder);
      if (!success) return(!catch("ReadStatus(30)  invalid order record in status file "+ DoubleQuoteStr(file) + NL + orderKeys[i] +"="+ sOrder, ERR_INVALID_FILE_FORMAT));
   }
   return(!catch("ReadStatus(31)"));
}


/**
 * Return the "SnowRoller-xxx" cycle section names found in the specified status file, sorted in ascending order.
 *
 * @param  _In_  string file    - status filename
 * @param  _Out_ string names[] - array receiving the found section names
 *
 * @return int - number of found section names (minimum 1) or NULL in case of errors
 */
int ReadStatusSections(string file, string &names[]) {
   int size = GetIniSections(file, names);
   if (!size) return(NULL);

   string prefix = "SnowRoller-";

   for (int i=size-1; i >= 0; i--) {
      if (StrStartsWithI(names[i], prefix)) {
         if (StrIsDigit(StrRightFrom(names[i], prefix)))
            continue;
      }
      ArraySpliceStrings(names, i, 1);                // drop all sections not matching '/SnowRoller-[0-9]+/i'
      size--;
   }
   if (!size)               return(!catch("ReadStatusSections(1)  invalid status file "+ DoubleQuoteStr(file) +" (no \"SnowRoller\" sections found)", ERR_INVALID_FILE_FORMAT));
   if (!SortStrings(names)) return(NULL);             // TODO: implement natural sorting

   return(size);
}


/**
 * Return the order keys ("rt.order.xxx") found in the specified status file section, sorted in ascending order.
 *
 * @param  _In_  string file    - status filename
 * @param  _In_  string section - status section
 * @param  _Out_ string keys[]  - array receiving the found order keys
 *
 * @return int - number of found order keys or EMPTY (-1) in case of errors
 */
int ReadStatusOrders(string file, string section, string &keys[]) {
   int size = GetIniKeys(file, section, keys);
   if (size < 0) return(EMPTY);

   string prefix = "rt.order.";

   for (int i=size-1; i >= 0; i--) {
      if (StrStartsWithI(keys[i], prefix)) {
         if (StrIsDigit(StrRightFrom(keys[i], prefix)))
            continue;
      }
      ArraySpliceStrings(keys, i, 1);                 // drop all keys not matching '/rt\.order\.[0-9]+/i'
      size--;
   }
   if (!SortStrings(keys)) return(EMPTY);             // TODO: implement natural sorting
   return(size);
}


/**
 * Parse and store the string representation of sequence start/stop data.
 *
 * @param  _In_  string   value     - string to parse
 * @param  _Out_ int      events [] - array receiving the start/stop events
 * @param  _Out_ datetime times  [] - array receiving the start/stop times
 * @param  _Out_ double   prices [] - array receiving the start/stop prices
 * @param  _Out_ double   profits[] - array receiving the start/stop PL amounts
 *
 * @return bool - success status
 */
bool ReadStatus.ParseStartStop(string value, int &events[], datetime &times[], double &prices[], double &profits[]) {
   if (IsLastError()) return(false);
   int      event;  ArrayResize(events,  0);
   datetime time;   ArrayResize(times,   0);
   double   price;  ArrayResize(prices,  0);     // rt.sequence.starts: 1|1328701713|1.32677|1000.00,  3|1329999999|1.33215|1200.00
   double   profit; ArrayResize(profits, 0);     // rt.sequence.stops:  2|1328701999|1.32734|1200.00,  0|0|0.00000|0.00

   string records[], record, data[], sValue;
   int sizeOfRecords = Explode(value, ",", records, NULL);

   for (int i=0; i < sizeOfRecords; i++) {
      record = StrTrim(records[i]);
      if (Explode(record, "|", data, NULL) != 4) return(!catch("ReadStatus.ParseStartStop(1)  invalid number of fields in sequence start/stop record "+ DoubleQuoteStr(record) +" (not 4)", ERR_INVALID_FILE_FORMAT));

      // event
      sValue = StrTrim(data[0]);
      if (!StrIsDigit(sValue))                   return(!catch("ReadStatus.ParseStartStop(2)  invalid start/stop event in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      event = StrToInteger(sValue);

      // time
      sValue = StrTrim(data[1]);
      if (!StrIsDigit(sValue))                   return(!catch("ReadStatus.ParseStartStop(3)  invalid start/stop time in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      time = StrToInteger(sValue);

      // price
      sValue = StrTrim(data[2]);
      if (!StrIsNumeric(sValue))                 return(!catch("ReadStatus.ParseStartStop(4)  invalid start/stop price in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      price = StrToDouble(sValue);
      if (LT(price, 0))                          return(!catch("ReadStatus.ParseStartStop(5)  invalid start/stop price in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));

      // profit
      sValue = StrTrim(data[3]);
      if (!StrIsNumeric(sValue))                 return(!catch("ReadStatus.ParseStartStop(6)  invalid start/stop profit in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      profit = StrToDouble(sValue);

      if (!event && (time  || price))            return(!catch("ReadStatus.ParseStartStop(7)  invalid start/stop event in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      if (!time  && (event || price))            return(!catch("ReadStatus.ParseStartStop(8)  invalid start/stop time in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      if (!price && (event || time ))            return(!catch("ReadStatus.ParseStartStop(9)  invalid start/stop price in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      if (!event && i < sizeOfRecords-1)         return(!catch("ReadStatus.ParseStartStop(10)  illegal start/stop record at position "+ (i+1) +": "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));

      ArrayPushInt   (events,  event );
      ArrayPushInt   (times,   time  );
      ArrayPushDouble(prices,  price );
      ArrayPushDouble(profits, profit);
      lastEventId = Max(lastEventId, event);
   }

   return(!catch("ReadStatus.ParseStartStop(11)"));
}


/**
 * Parse and store the string representation of the gridbase history.
 *
 * @param  string value - string to parse
 *
 * @return bool - success status
 */
bool ReadStatus.ParseGridBase(string value) {
   if (IsLastError()) return(false);

   ResetGridbase();
   int      event;
   datetime time;
   double   price;                                    // rt.gridbase=1|1331710960|1.56743, 2|1331711010|1.56714

   string records[], record, data[], sValue;
   int lastEvent, sizeOfRecords=Explode(value, ",", records, NULL);

   for (int i=0; i < sizeOfRecords; i++) {
      record = StrTrim(records[i]);
      if (Explode(record, "|", data, NULL) != 3) return(!catch("ReadStatus.ParseGridBase(1)  invalid number of fields in gridbase record "+ DoubleQuoteStr(record) +" (not 3)", ERR_INVALID_FILE_FORMAT));

      // event
      sValue = StrTrim(data[0]);
      if (!StrIsDigit(sValue))                   return(!catch("ReadStatus.ParseGridBase(2)  invalid gridbase event in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      event = StrToInteger(sValue);

      // time
      sValue = StrTrim(data[1]);
      if (!StrIsDigit(sValue))                   return(!catch("ReadStatus.ParseGridBase(3)  invalid gridbase time in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      time = StrToInteger(sValue);

      // price
      sValue = StrTrim(data[2]);
      if (!StrIsNumeric(sValue))                 return(!catch("ReadStatus.ParseGridBase(4)  invalid gridbase price in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      price = StrToDouble(sValue);
      if (LT(price, 0))                          return(!catch("ReadStatus.ParseGridBase(5)  invalid gridbase price in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));

      if (!event && (time  || price))            return(!catch("ReadStatus.ParseGridBase(6)  invalid gridbase event in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      if (!time  && (event || price))            return(!catch("ReadStatus.ParseGridBase(7)  invalid gridbase time in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      if (!price && (event || time ))            return(!catch("ReadStatus.ParseGridBase(8)  invalid gridbase price in record "+ DoubleQuoteStr(record), ERR_INVALID_FILE_FORMAT));
      if (!event && i > 0)                       return(!catch("ReadStatus.ParseGridBase(9)  illegal gridbase record at position "+ (i+1) +": "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
      if (event < lastEvent)                     return(!catch("ReadStatus.ParseGridBase(10)  invalid gridbase event order in "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
      lastEvent = event;

      // store data but skip empty records ("0|0|0")
      if (event != 0) {
         ArrayPushInt   (gridbase.event,  event);
         ArrayPushInt   (gridbase.time,   time );
         ArrayPushDouble(gridbase.price,  price);
         ArrayPushInt   (gridbase.status, NULL );     // that's STATUS_UNDEFINED (actual value doesn't matter)
         lastEventId = Max(lastEventId, event);
      }
   }
   return(!catch("ReadStatus.ParseGridBase(11)"));
}


/**
 * Parse and store the string representation of missed gridlevels.
 *
 * @param  string value - string to parse
 *
 * @return bool - success status
 */
bool ReadStatus.ParseMissedLevels(string value) {
   if (IsLastError()) return(false);
   ArrayResize(sequence.missedLevels, 0);             // rt.sequence.missedLevels=-6,-7,-8,-14

   if (StringLen(value) > 0) {
      string values[], sValue;
      int sizeOfValues=Explode(value, ",", values, NULL), level, lastLevel, sign, lastSign;

      for (int i=0; i < sizeOfValues; i++) {
         sValue = StrTrim(values[i]);
         if (!StrIsInteger(sValue))        return(!catch("ReadStatus.ParseMissedLevels(1)  invalid missed gridlevel in "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
         level = StrToInteger(sValue);
         if (!level)                       return(!catch("ReadStatus.ParseMissedLevels(2)  illegal missed gridlevel in "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
         sign = Sign(level);
         if (lastSign && sign!=lastSign)   return(!catch("ReadStatus.ParseMissedLevels(3)  illegal missed gridlevel in "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
         if (Abs(level) <= Abs(lastLevel)) return(!catch("ReadStatus.ParseMissedLevels(4)  illegal missed gridlevel in "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
         lastSign  = sign;
         lastLevel = level;

         ArrayPushInt(sequence.missedLevels, level);
      }
   }
   return(!catch("ReadStatus.ParseMissedLevels(5)"));
}


/**
 * Parse and store the string representation of order tickets.
 *
 * @param  _In_  string value     - string to parse
 * @param  _Out_ int    tickets[] - array receiving the parsed ticket ids
 *
 * @return bool - success status
 */
bool ReadStatus.ParseTickets(string value, int &tickets[]) {
   if (IsLastError()) return(false);
   ArrayResize(tickets, 0);                           // rt.ignorePendingOrders=66064890,66064891,66064892
                                                      // rt.ignoreOpenPositions=66064890,66064891,66064892
   if (StringLen(value) > 0) {                        // rt.ignoreClosedPositions=66064890,66064891,66064892
      string values[], sValue;
      int ticket, sizeOfValues=Explode(value, ",", values, NULL);

      for (int i=0; i < sizeOfValues; i++) {
         sValue = StrTrim(values[i]);
         if (!StrIsDigit(sValue)) return(!catch("ReadStatus.ParseTickets(1)  invalid ticket "+ DoubleQuoteStr(sValue) +" in "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
         ticket = StrToInteger(sValue);
         if (!ticket)             return(!catch("ReadStatus.ParseTickets(2)  illegal ticket #"+ ticket +" in "+ DoubleQuoteStr(value), ERR_INVALID_FILE_FORMAT));
         ArrayPushInt(tickets, ticket);
      }
   }
   return(!catch("ReadStatus.ParseTickets(3)"));
}


/**
 * Parse and store the string representation of an order.
 *
 * @param  string value - string to parse
 *
 * @return bool - success status
 */
bool ReadStatus.ParseOrder(string value) {
   if (IsLastError()) return(false);
   /*
   rt.order.0=292836120,-1,1477.94,5,1575468000,1476.84,1,67,1575469086,1476.84,68,1575470978,1477.94,1477.94,1,0.00,-0.22,-3.97
   rt.order.{i}={ticket},{level},{gridbase},{pendingType},{pendingTime},{pendingPrice},{type},{openEvent},{openTime},{openPrice},{closeEvent},{closeTime},{closePrice},{stopLoss},{closedBySL},{swap},{commission},{profit}
   ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
   int      ticket       = values[ 0];
   int      level        = values[ 1];
   double   gridbase     = values[ 2];
   int      pendingType  = values[ 3];
   datetime pendingTime  = values[ 4];
   double   pendingPrice = values[ 5];
   int      type         = values[ 6];
   int      openEvent    = values[ 7];
   datetime openTime     = values[ 8];
   double   openPrice    = values[ 9];
   int      closeEvent   = values[10];
   datetime closeTime    = values[11];
   double   closePrice   = values[12];
   double   stopLoss     = values[13];
   bool     closedBySL   = values[14];
   double   swap         = values[15];
   double   commission   = values[16];
   double   profit       = values[17];
   */
   string values[];
   if (Explode(value, ",", values, NULL) != 18)                          return(!catch("ReadStatus.ParseOrder(1)  illegal number of order details ("+ ArraySize(values) +") in order record", ERR_INVALID_FILE_FORMAT));

   // ticket
   string sTicket = StrTrim(values[0]);
   if (!StrIsDigit(sTicket))                                             return(!catch("ReadStatus.ParseOrder(2)  illegal ticket "+ DoubleQuoteStr(sTicket) +" in order record", ERR_INVALID_FILE_FORMAT));
   int ticket = StrToInteger(sTicket);
   if (!ticket)                                                          return(!catch("ReadStatus.ParseOrder(3)  illegal ticket #"+ ticket +" in order record", ERR_INVALID_FILE_FORMAT));
   if (IntInArray(orders.ticket, ticket))                                return(!catch("ReadStatus.ParseOrder(4)  duplicate ticket #"+ ticket +" in order record", ERR_INVALID_FILE_FORMAT));

   // level
   string sLevel = StrTrim(values[1]);
   if (!StrIsInteger(sLevel))                                            return(!catch("ReadStatus.ParseOrder(5)  illegal gridlevel "+ DoubleQuoteStr(sLevel) +" in order record", ERR_INVALID_FILE_FORMAT));
   int level = StrToInteger(sLevel);
   if (!level)                                                           return(!catch("ReadStatus.ParseOrder(6)  illegal gridlevel "+ level +" in order record", ERR_INVALID_FILE_FORMAT));

   // gridbase
   string sGridbase = StrTrim(values[2]);
   if (!StrIsNumeric(sGridbase))                                         return(!catch("ReadStatus.ParseOrder(7)  illegal order gridbase "+ DoubleQuoteStr(sGridbase) +" in order record", ERR_INVALID_FILE_FORMAT));
   double gridbase = StrToDouble(sGridbase);
   if (LE(gridbase, 0))                                                  return(!catch("ReadStatus.ParseOrder(8)  illegal order gridbase "+ NumberToStr(gridbase, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));

   // pendingType
   string sPendingType = StrTrim(values[3]);
   if (!StrIsInteger(sPendingType))                                      return(!catch("ReadStatus.ParseOrder(9)  illegal pending order type "+ DoubleQuoteStr(sPendingType) +" in order record", ERR_INVALID_FILE_FORMAT));
   int pendingType = StrToInteger(sPendingType);
   if (pendingType!=OP_UNDEFINED && !IsPendingOrderType(pendingType))    return(!catch("ReadStatus.ParseOrder(10)  illegal pending order type "+ DoubleQuoteStr(sPendingType) +" in order record", ERR_INVALID_FILE_FORMAT));

   // pendingTime
   string sPendingTime = StrTrim(values[4]);
   if (!StrIsDigit(sPendingTime))                                        return(!catch("ReadStatus.ParseOrder(11)  illegal pending order time "+ DoubleQuoteStr(sPendingTime) +" in order record", ERR_INVALID_FILE_FORMAT));
   datetime pendingTime = StrToInteger(sPendingTime);
   if (pendingType==OP_UNDEFINED && pendingTime!=0)                      return(!catch("ReadStatus.ParseOrder(12)  pending order type/time mis-match "+ OperationTypeToStr(pendingType) +"/'"+ TimeToStr(pendingTime, TIME_FULL) +"' in order record", ERR_INVALID_FILE_FORMAT));
   if (pendingType!=OP_UNDEFINED && !pendingTime)                        return(!catch("ReadStatus.ParseOrder(13)  pending order type/time mis-match "+ OperationTypeToStr(pendingType) +"/"+ pendingTime +" in order record", ERR_INVALID_FILE_FORMAT));

   // pendingPrice
   string sPendingPrice = StrTrim(values[5]);
   if (!StrIsNumeric(sPendingPrice))                                     return(!catch("ReadStatus.ParseOrder(14)  illegal pending order price "+ DoubleQuoteStr(sPendingPrice) +" in order record", ERR_INVALID_FILE_FORMAT));
   double pendingPrice = StrToDouble(sPendingPrice);
   if (LT(pendingPrice, 0))                                              return(!catch("ReadStatus.ParseOrder(15)  illegal pending order price "+ NumberToStr(pendingPrice, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));
   if (pendingType==OP_UNDEFINED && NE(pendingPrice, 0))                 return(!catch("ReadStatus.ParseOrder(16)  pending order type/price mis-match "+ OperationTypeToStr(pendingType) +"/"+ NumberToStr(pendingPrice, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));
   if (pendingType!=OP_UNDEFINED) {
      if (EQ(pendingPrice, 0))                                           return(!catch("ReadStatus.ParseOrder(17)  pending order type/price mis-match "+ OperationTypeToStr(pendingType) +"/"+ NumberToStr(pendingPrice, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));
      if (NE(pendingPrice, gridbase+level*GridSize*Pips, Digits))        return(!catch("ReadStatus.ParseOrder(18)  gridbase/pending order price mis-match "+ NumberToStr(gridbase, PriceFormat) +"/"+ NumberToStr(pendingPrice, PriceFormat) +" (level "+ level +") in order record", ERR_INVALID_FILE_FORMAT));
   }

   // type
   string sType = StrTrim(values[6]);
   if (!StrIsInteger(sType))                                             return(!catch("ReadStatus.ParseOrder(19)  illegal order type "+ DoubleQuoteStr(sType) +" in order record", ERR_INVALID_FILE_FORMAT));
   int type = StrToInteger(sType);
   if (type!=OP_UNDEFINED && !IsOrderType(type))                         return(!catch("ReadStatus.ParseOrder(20)  illegal order type "+ DoubleQuoteStr(sType) +" in order record", ERR_INVALID_FILE_FORMAT));
   if (pendingType == OP_UNDEFINED) {
      if (type == OP_UNDEFINED)                                          return(!catch("ReadStatus.ParseOrder(21)  pending order type/open order type mis-match "+ OperationTypeToStr(pendingType) +"/"+ OperationTypeToStr(type) +" in order record", ERR_INVALID_FILE_FORMAT));
   }
   else if (type != OP_UNDEFINED) {
      if (IsLongOrderType(pendingType)!=IsLongOrderType(type))           return(!catch("ReadStatus.ParseOrder(22)  pending order type/open order type mis-match "+ OperationTypeToStr(pendingType) +"/"+ OperationTypeToStr(type) +" in order record", ERR_INVALID_FILE_FORMAT));
   }

   // openEvent
   string sOpenEvent = StrTrim(values[7]);
   if (!StrIsDigit(sOpenEvent))                                          return(!catch("ReadStatus.ParseOrder(23)  illegal order open event "+ DoubleQuoteStr(sOpenEvent) +" in order record", ERR_INVALID_FILE_FORMAT));
   int openEvent = StrToInteger(sOpenEvent);
   if (type!=OP_UNDEFINED && !openEvent)                                 return(!catch("ReadStatus.ParseOrder(24)  illegal order open event "+ openEvent +" in order record", ERR_INVALID_FILE_FORMAT));

   // openTime
   string sOpenTime = StrTrim(values[8]);
   if (!StrIsDigit(sOpenTime))                                           return(!catch("ReadStatus.ParseOrder(25)  illegal order open time "+ DoubleQuoteStr(sOpenTime) +" in order record", ERR_INVALID_FILE_FORMAT));
   datetime openTime = StrToInteger(sOpenTime);
   if (type==OP_UNDEFINED && openTime!=0)                                return(!catch("ReadStatus.ParseOrder(26)  order type/time mis-match "+ OperationTypeToStr(type) +"/'"+ TimeToStr(openTime, TIME_FULL) +"' in order record", ERR_INVALID_FILE_FORMAT));
   if (type!=OP_UNDEFINED && !openTime)                                  return(!catch("ReadStatus.ParseOrder(27)  order type/time mis-match "+ OperationTypeToStr(type) +"/"+ openTime +" in order record", ERR_INVALID_FILE_FORMAT));

   // openPrice
   string sOpenPrice = StrTrim(values[9]);
   if (!StrIsNumeric(sOpenPrice))                                        return(!catch("ReadStatus.ParseOrder(28)  illegal order open price "+ DoubleQuoteStr(sOpenPrice) +" in order record", ERR_INVALID_FILE_FORMAT));
   double openPrice = StrToDouble(sOpenPrice);
   if (LT(openPrice, 0))                                                 return(!catch("ReadStatus.ParseOrder(29)  illegal order open price "+ NumberToStr(openPrice, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));
   if (type==OP_UNDEFINED && NE(openPrice, 0))                           return(!catch("ReadStatus.ParseOrder(30)  order type/price mis-match "+ OperationTypeToStr(type) +"/"+ NumberToStr(openPrice, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));
   if (type!=OP_UNDEFINED && EQ(openPrice, 0))                           return(!catch("ReadStatus.ParseOrder(31)  order type/price mis-match "+ OperationTypeToStr(type) +"/"+ NumberToStr(openPrice, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));

   // closeEvent
   string sCloseEvent = StrTrim(values[10]);
   if (!StrIsDigit(sCloseEvent))                                         return(!catch("ReadStatus.ParseOrder(32)  illegal order close event "+ DoubleQuoteStr(sCloseEvent) +" in order record", ERR_INVALID_FILE_FORMAT));
   int closeEvent = StrToInteger(sCloseEvent);

   // closeTime
   string sCloseTime = StrTrim(values[11]);
   if (!StrIsDigit(sCloseTime))                                          return(!catch("ReadStatus.ParseOrder(33)  illegal order close time "+ DoubleQuoteStr(sCloseTime) +" in order record", ERR_INVALID_FILE_FORMAT));
   datetime closeTime = StrToInteger(sCloseTime);
   if (closeTime != 0) {
      if (closeTime < pendingTime)                                       return(!catch("ReadStatus.ParseOrder(34)  pending order time/delete time mis-match '"+ TimeToStr(pendingTime, TIME_FULL) +"'/'"+ TimeToStr(closeTime, TIME_FULL) +"' in order record", ERR_INVALID_FILE_FORMAT));
      if (closeTime < openTime)                                          return(!catch("ReadStatus.ParseOrder(35)  order open/close time mis-match '"+ TimeToStr(openTime, TIME_FULL) +"'/'"+ TimeToStr(closeTime, TIME_FULL) +"' in order record", ERR_INVALID_FILE_FORMAT));
   }
   if (closeTime!=0 && !closeEvent)                                      return(!catch("ReadStatus.ParseOrder(36)  illegal order close event "+ closeEvent +" in order record", ERR_INVALID_FILE_FORMAT));

   // closePrice
   string sClosePrice = StrTrim(values[12]);
   if (!StrIsNumeric(sClosePrice))                                       return(!catch("ReadStatus.ParseOrder(37)  illegal order close price "+ DoubleQuoteStr(sClosePrice) +" in order record", ERR_INVALID_FILE_FORMAT));
   double closePrice = StrToDouble(sClosePrice);
   if (LT(closePrice, 0))                                                return(!catch("ReadStatus.ParseOrder(38)  illegal order close price "+ NumberToStr(closePrice, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));

   // stopLoss
   string sStopLoss = StrTrim(values[13]);
   if (!StrIsNumeric(sStopLoss))                                         return(!catch("ReadStatus.ParseOrder(39)  illegal order stoploss "+ DoubleQuoteStr(sStopLoss) +" in order record", ERR_INVALID_FILE_FORMAT));
   double stopLoss = StrToDouble(sStopLoss);
   if (LE(stopLoss, 0))                                                  return(!catch("ReadStatus.ParseOrder(40)  illegal order stoploss "+ NumberToStr(stopLoss, PriceFormat) +" in order record", ERR_INVALID_FILE_FORMAT));
   if (NE(stopLoss, gridbase+(level-Sign(level))*GridSize*Pips, Digits)) return(!catch("ReadStatus.ParseOrder(41)  gridbase/stoploss mis-match "+ NumberToStr(gridbase, PriceFormat) +"/"+ NumberToStr(stopLoss, PriceFormat) +" (level "+ level +") in order record", ERR_INVALID_FILE_FORMAT));

   // closedBySL
   string sClosedBySL = StrTrim(values[14]);
   if (!StrIsDigit(sClosedBySL))                                         return(!catch("ReadStatus.ParseOrder(42)  illegal closedBySL value "+ DoubleQuoteStr(sClosedBySL) +" in order record", ERR_INVALID_FILE_FORMAT));
   bool closedBySL = StrToBool(sClosedBySL);

   // swap
   string sSwap = StrTrim(values[15]);
   if (!StrIsNumeric(sSwap))                                             return(!catch("ReadStatus.ParseOrder(43)  illegal order swap "+ DoubleQuoteStr(sSwap) +" in order record", ERR_INVALID_FILE_FORMAT));
   double swap = StrToDouble(sSwap);
   if (type==OP_UNDEFINED && NE(swap, 0))                                return(!catch("ReadStatus.ParseOrder(44)  pending order/swap mis-match "+ OperationTypeToStr(pendingType) +"/"+ DoubleToStr(swap, 2) +" in order record", ERR_INVALID_FILE_FORMAT));

   // commission
   string sCommission = StrTrim(values[16]);
   if (!StrIsNumeric(sCommission))                                       return(!catch("ReadStatus.ParseOrder(45)  illegal order commission "+ DoubleQuoteStr(sCommission) +" in order record", ERR_INVALID_FILE_FORMAT));
   double commission = StrToDouble(sCommission);
   if (type==OP_UNDEFINED && NE(commission, 0))                          return(!catch("ReadStatus.ParseOrder(46)  pending order/commission mis-match "+ OperationTypeToStr(pendingType) +"/"+ DoubleToStr(commission, 2) +" in order record", ERR_INVALID_FILE_FORMAT));

   // profit
   string sProfit = StrTrim(values[17]);
   if (!StrIsNumeric(sProfit))                                           return(!catch("ReadStatus.ParseOrder(47)  illegal order profit "+ DoubleQuoteStr(sProfit) +" in order record", ERR_INVALID_FILE_FORMAT));
   double profit = StrToDouble(sProfit);
   if (type==OP_UNDEFINED && NE(profit, 0))                              return(!catch("ReadStatus.ParseOrder(48)  pending order/profit mis-match "+ OperationTypeToStr(pendingType) +"/"+ DoubleToStr(profit, 2) +" in order record", ERR_INVALID_FILE_FORMAT));

   // store all data in the order arrays
   Orders.AddRecord(ticket, level, gridbase, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, closedBySL, swap, commission, profit);
   lastEventId = Max(lastEventId, openEvent, closeEvent);

   ArrayResize(values, 0);
   return(!catch("ReadStatus.ParseOrder(49)"));
}


/**
 * Synchronize restored internal state with the trade server. Part of RestoreSequence().
 *
 * @return bool - success status
 */
bool SynchronizeStatus() {
   if (IsLastError()) return(false);

   bool permanentStatusChange, permanentTicketChange, pendingOrder, openPosition;

   int orphanedPendingOrders  []; ArrayResize(orphanedPendingOrders,   0);
   int orphanedOpenPositions  []; ArrayResize(orphanedOpenPositions,   0);
   int orphanedClosedPositions[]; ArrayResize(orphanedClosedPositions, 0);

   int closed[][2], close[2], sizeOfTickets=ArraySize(orders.ticket); ArrayResize(closed, 0);


   // (1.1) alle offenen Tickets in Datenarrays synchronisieren, gestrichene PendingOrders l�schen
   for (int i=0; i < sizeOfTickets; i++) {
      if (!IsTestSequence() || !IsTesting()) {                             // keine Synchronization f�r abgeschlossene Tests
         if (orders.closeTime[i] == 0) {
            if (!IsTicket(orders.ticket[i])) {                             // bei fehlender History zur Erweiterung auffordern
               PlaySoundEx("Windows Notify.wav");
               int button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", "Ticket #"+ orders.ticket[i] +" not found.\nPlease expand the available trade history.", MB_ICONERROR|MB_RETRYCANCEL);
               if (button != IDRETRY)
                  return(!SetLastError(ERR_CANCELLED_BY_USER));
               return(SynchronizeStatus());
            }
            if (!SelectTicket(orders.ticket[i], "SynchronizeStatus(1)  cannot synchronize "+ OperationTypeDescription(ifInt(orders.type[i]==OP_UNDEFINED, orders.pendingType[i], orders.type[i])) +" order (#"+ orders.ticket[i] +" not found)"))
               return(false);
            if (!Sync.UpdateOrder(i, permanentTicketChange))
               return(false);
            permanentStatusChange = permanentStatusChange || permanentTicketChange;
         }
      }

      if (orders.closeTime[i] != 0) {
         if (orders.type[i] == OP_UNDEFINED) {
            if (!Orders.RemoveRecord(i))                                   // geschlossene PendingOrders l�schen
               return(false);
            sizeOfTickets--; i--;
            permanentStatusChange = true;
         }
         else if (!orders.closedBySL[i]) /*&&*/ if (!orders.closeEvent[i]) {
            close[0] = orders.closeTime[i];                                // bei StopSequence() geschlossene Position: Ticket zur sp�teren Vergabe der Event-ID zwichenspeichern
            close[1] = orders.ticket   [i];
            ArrayPushInts(closed, close);
         }
      }
   }

   // (1.2) Event-IDs geschlossener Positionen setzen (IDs f�r ausgestoppte Positionen wurden vorher in Sync.UpdateOrder() vergeben)
   int sizeOfClosed = ArrayRange(closed, 0);
   if (sizeOfClosed > 0) {
      ArraySort(closed);
      for (i=0; i < sizeOfClosed; i++) {
         int n = SearchIntArray(orders.ticket, closed[i][1]);
         if (n == -1)
            return(!catch("SynchronizeStatus(2)  closed ticket #"+ closed[i][1] +" not found in order arrays", ERR_RUNTIME_ERROR));
         orders.closeEvent[n] = CreateEventId();
      }
      ArrayResize(closed, 0);
      ArrayResize(close,  0);
   }

   // (1.3) alle erreichbaren Tickets der Sequenz auf lokale Referenz �berpr�fen (au�er f�r abgeschlossene Tests)
   if (!IsTestSequence() || IsTesting()) {
      for (i=OrdersTotal()-1; i >= 0; i--) {                               // offene Tickets
         if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))                  // FALSE: w�hrend des Auslesens wurde in einem anderen Thread eine offene Order entfernt
            continue;
         if (IsMyOrder(sequence.id)) /*&&*/ if (!IntInArray(orders.ticket, OrderTicket())) {
            pendingOrder = IsPendingOrderType(OrderType());                // kann PendingOrder oder offene Position sein
            openPosition = !pendingOrder;
            if (pendingOrder) /*&&*/ if (!IntInArray(ignorePendingOrders, OrderTicket())) ArrayPushInt(orphanedPendingOrders, OrderTicket());
            if (openPosition) /*&&*/ if (!IntInArray(ignoreOpenPositions, OrderTicket())) ArrayPushInt(orphanedOpenPositions, OrderTicket());
         }
      }
      for (i=OrdersHistoryTotal()-1; i >= 0; i--) {                        // geschlossene Tickets
         if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))                 // FALSE: w�hrend des Auslesens wurde der Anzeigezeitraum der History verk�rzt
            continue;
         if (OrderCloseTime() <= sequence.created)                         // skip tickets not belonging to the current cycle
            continue;
         if (IsPendingOrderType(OrderType()))                              // skip deleted pending orders
            continue;
         if (IsMyOrder(sequence.id)) /*&&*/ if (!IntInArray(orders.ticket, OrderTicket())) {
            if (!IntInArray(ignoreClosedPositions, OrderTicket())) {
               ArrayPushInt(orphanedClosedPositions, OrderTicket());
            }
         }
      }
   }

   // (1.4) Vorgehensweise f�r verwaiste Tickets erfragen
   int size = ArraySize(orphanedPendingOrders);                            // Ignorieren nicht m�glich. Wenn die Tickets �bernommen werden sollen, m��ten sie korrekt einsortiert werden.
   if (size > 0) return(!catch("SynchronizeStatus(3)  "+ sequence.longName +" unknown pending orders found: #"+ JoinInts(orphanedPendingOrders, ", #"), ERR_RUNTIME_ERROR));
   size = ArraySize(orphanedOpenPositions);                                // Ignorieren nicht m�glich. Wenn die Tickets �bernommen werden sollen, m��ten sie korrekt einsortiert werden.
   if (size > 0) return(!catch("SynchronizeStatus(5)  "+ sequence.longName +" unknown open positions found: #"+ JoinInts(orphanedOpenPositions, ", #"), ERR_RUNTIME_ERROR));
   size = ArraySize(orphanedClosedPositions);
   if (size > 0) {
      ArraySort(orphanedClosedPositions);
      PlaySoundEx("Windows Notify.wav");
      button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Sequence "+ sequence.name +" orphaned closed position"+ Pluralize(size) +" found: #"+ JoinInts(orphanedClosedPositions, ", #") +"\nDo you want to ignore "+ ifString(size==1, "it", "them") +"?", MB_ICONWARNING|MB_OKCANCEL);
      if (button != IDOK) return(!SetLastError(ERR_CANCELLED_BY_USER));

      MergeIntArrays(ignoreClosedPositions, orphanedClosedPositions, ignoreClosedPositions);
      ArraySort(ignoreClosedPositions);
      permanentStatusChange = true;
      ArrayResize(orphanedClosedPositions, 0);
   }

   if (ArraySize(sequence.start.event) > 0) /*&&*/ if (ArraySize(gridbase.event)==0)
      return(!catch("SynchronizeStatus(8)  "+ sequence.longName +" illegal number of gridbase events = "+ 0, ERR_RUNTIME_ERROR));

   // Status und Variablen synchronisieren
   /*int   */ lastEventId         = 0;
   /*int   */ sequence.status     = STATUS_WAITING;
   /*int   */ sequence.level      = 0; SS.SequenceName();
   /*int   */ sequence.maxLevel   = 0;
   /*int   */ sequence.stops      = 0;
   /*double*/ sequence.stopsPL    = 0;
   /*double*/ sequence.closedPL   = 0;
   /*double*/ sequence.floatingPL = 0;
   /*double*/ sequence.totalPL    = 0;

   datetime   stopTime;
   double     stopPrice;

   if (!Sync.ProcessEvents(stopTime, stopPrice))
      return(false);

   // Wurde die Sequenz au�erhalb gestoppt, EV_SEQUENCE_STOP erzeugen
   if (sequence.status == STATUS_STOPPING) {
      i = ArraySize(sequence.stop.event) - 1;
      if (sequence.stop.time[i] != 0)
         return(!catch("SynchronizeStatus(9)  "+ sequence.longName +" unexpected sequence.stop.time = "+ IntsToStr(sequence.stop.time, NULL), ERR_RUNTIME_ERROR));

      sequence.stop.event [i] = CreateEventId();
      sequence.stop.time  [i] = stopTime;
      sequence.stop.price [i] = NormalizeDouble(stopPrice, Digits);
      sequence.stop.profit[i] = sequence.totalPL;

      sequence.status       = STATUS_STOPPED;
      permanentStatusChange = true;
   }

   // update status
   if (sequence.status == STATUS_STOPPED) {
      if (start.conditions) sequence.status = STATUS_WAITING;
   }
   if (sessionbreak.waiting) {
      if (sequence.status == STATUS_STOPPED) sequence.status = STATUS_WAITING;
      if (sequence.status != STATUS_WAITING) return(!catch("SynchronizeStatus(10)  "+ sequence.longName +" sessionbreak.waiting="+ sessionbreak.waiting +" / sequence.status="+ StatusToStr(sequence.status)+ " mis-match", ERR_RUNTIME_ERROR));
   }

   // store status changes
   if (permanentStatusChange)
      if (!SaveStatus()) return(false);

   // update chart displays, ShowStatus() is called at the end of EA::init()
   RedrawStartStop();
   RedrawOrders();

   return(!catch("SynchronizeStatus(11)"));
}


/**
 * Aktualisiert die Daten des lokal als offen markierten Tickets mit dem Online-Status. Part of SynchronizeStatus().
 *
 * @param  int   i                 - Ticketindex
 * @param  bool &lpPermanentChange - Zeiger auf Variable, die anzeigt, ob dauerhafte Ticket�nderungen vorliegen
 *
 * @return bool - success status
 */
bool Sync.UpdateOrder(int i, bool &lpPermanentChange) {
   lpPermanentChange = lpPermanentChange!=0;

   if (i < 0 || i > ArraySize(orders.ticket)-1) return(!catch("Sync.UpdateOrder(1)  "+ sequence.longName +" illegal parameter i = "+ i, ERR_INVALID_PARAMETER));
   if (orders.closeTime[i] != 0)                return(!catch("Sync.UpdateOrder(2)  "+ sequence.longName +" cannot update ticket #"+ orders.ticket[i] +" (marked as closed in grid arrays)", ERR_ILLEGAL_STATE));

   // das Ticket ist selektiert
   bool   wasPending = orders.type[i] == OP_UNDEFINED;               // vormals PendingOrder
   bool   wasOpen    = !wasPending;                                  // vormals offene Position
   bool   isPending  = IsPendingOrderType(OrderType());              // jetzt PendingOrder
   bool   isClosed   = OrderCloseTime() != 0;                        // jetzt geschlossen oder gestrichen
   bool   isOpen     = !isPending && !isClosed;                      // jetzt offene Position
   double lastSwap   = orders.swap[i];

   // Ticketdaten aktualisieren
   //orders.ticket       [i]                                         // unver�ndert
   //orders.level        [i]                                         // unver�ndert
   //orders.gridBase     [i]                                         // unver�ndert

   if (isPending) {
    //orders.pendingType [i]                                         // unver�ndert
    //orders.pendingTime [i]                                         // unver�ndert
      orders.pendingPrice[i] = OrderOpenPrice();
   }
   else if (wasPending) {
      orders.type        [i] = OrderType();
      orders.openEvent   [i] = CreateEventId();
      orders.openTime    [i] = OrderOpenTime();
      orders.openPrice   [i] = OrderOpenPrice();
   }

   //orders.stopLoss     [i]                                         // unver�ndert

   if (isClosed) {
      orders.closeTime   [i] = OrderCloseTime();
      orders.closePrice  [i] = OrderClosePrice();
      orders.closedBySL  [i] = IsOrderClosedBySL();
      if (orders.closedBySL[i])
         orders.closeEvent[i] = CreateEventId();                     // Event-IDs f�r ausgestoppte Positionen werden sofort, f�r geschlossene Positionen erst sp�ter vergeben.
   }

   if (!isPending) {
      orders.swap        [i] = OrderSwap();
      orders.commission  [i] = OrderCommission(); sequence.commission = OrderCommission();
      orders.profit      [i] = OrderProfit();
   }

   // lpPermanentChange aktualisieren
   if      (wasPending) lpPermanentChange = lpPermanentChange || isOpen || isClosed;
   else if (  isClosed) lpPermanentChange = true;
   else                 lpPermanentChange = lpPermanentChange || NE(lastSwap, OrderSwap());

   return(!catch("Sync.UpdateOrder(3)"));
}


/**
 * F�gt den Breakeven-relevanten Events ein weiteres hinzu.
 *
 * @param  double   events[] - Event-Array
 * @param  int      id       - Event-ID
 * @param  datetime time     - Zeitpunkt des Events
 * @param  int      type     - Event-Typ
 * @param  double   gridBase - Gridbasis des Events
 * @param  int      index    - Index des origin�ren Datensatzes innerhalb des entsprechenden Arrays
 */
void Sync.PushEvent(double &events[][], int id, datetime time, int type, double gridBase, int index) {
   if (type==EV_SEQUENCE_STOP) /*&&*/ if (!time)
      return;                                                        // nicht initialisierte Sequenz-Stops ignorieren (ggf. immer der letzte Stop)

   int size = ArrayRange(events, 0);
   ArrayResize(events, size+1);

   events[size][0] = id;
   events[size][1] = time;
   events[size][2] = type;
   events[size][3] = gridBase;
   events[size][4] = index;
}


/**
 *
 * @param  datetime &sequenceStopTime  - Variable, die die Sequenz-StopTime aufnimmt (falls die Stopdaten fehlen)
 * @param  double   &sequenceStopPrice - Variable, die den Sequenz-StopPrice aufnimmt (falls die Stopdaten fehlen)
 *
 * @return bool - success status
 */
bool Sync.ProcessEvents(datetime &sequenceStopTime, double &sequenceStopPrice) {
   int    sizeOfTickets = ArraySize(orders.ticket);
   int    openLevels[]; ArrayResize(openLevels, 0);
   double events[][5];  ArrayResize(events,     0);
   bool   pendingOrder, openPosition, closedPosition, closedBySL;


   // (1) Breakeven-relevante Events zusammenstellen
   // (1.1) Sequenzstarts und -stops
   int sizeOfStarts = ArraySize(sequence.start.event);
   for (int i=0; i < sizeOfStarts; i++) {
    //Sync.PushEvent(events, id, time, type, gridBase, index);
      Sync.PushEvent(events, sequence.start.event[i], sequence.start.time[i], EV_SEQUENCE_START, NULL, i);
      Sync.PushEvent(events, sequence.stop.event [i], sequence.stop.time [i], EV_SEQUENCE_STOP,  NULL, i);
   }

   // (1.2) GridBase-�nderungen
   int sizeOfGridBase = ArraySize(gridbase.event);
   for (i=0; i < sizeOfGridBase; i++) {
      Sync.PushEvent(events, gridbase.event[i], gridbase.time[i], EV_GRIDBASE_CHANGE, gridbase.price[i], i);
   }

   // (1.3) Tickets
   for (i=0; i < sizeOfTickets; i++) {
      pendingOrder   = orders.type[i]  == OP_UNDEFINED;
      openPosition   = !pendingOrder   && orders.closeTime[i]==0;
      closedPosition = !pendingOrder   && !openPosition;
      closedBySL     =  closedPosition && orders.closedBySL[i];

      // nach offenen Levels darf keine geschlossene Position folgen
      if (closedPosition && !closedBySL)
         if (ArraySize(openLevels) > 0)                  return(_false(catch("Sync.ProcessEvents(1)  "+ sequence.longName +" illegal sequence status, both open (#?) and closed (#"+ orders.ticket[i] +") positions found", ERR_RUNTIME_ERROR)));

      if (!pendingOrder) {
         Sync.PushEvent(events, orders.openEvent[i], orders.openTime[i], EV_POSITION_OPEN, NULL, i);

         if (openPosition) {
            if (IntInArray(openLevels, orders.level[i])) return(_false(catch("Sync.ProcessEvents(2)  "+ sequence.longName +" duplicate order level "+ orders.level[i] +" of open position #"+ orders.ticket[i], ERR_RUNTIME_ERROR)));
            ArrayPushInt(openLevels, orders.level[i]);
            sequence.floatingPL = NormalizeDouble(sequence.floatingPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
         }
         else if (closedBySL) {
            Sync.PushEvent(events, orders.closeEvent[i], orders.closeTime[i], EV_POSITION_STOPOUT, NULL, i);
         }
         else /*(closed)*/ {
            Sync.PushEvent(events, orders.closeEvent[i], orders.closeTime[i], EV_POSITION_CLOSE, NULL, i);
         }
      }
      if (IsLastError()) return(false);
   }
   if (ArraySize(openLevels) != 0) {
      int min = openLevels[ArrayMinimum(openLevels)];
      int max = openLevels[ArrayMaximum(openLevels)];
      int maxLevel = Max(Abs(min), Abs(max));
      if (ArraySize(openLevels) != maxLevel) return(_false(catch("Sync.ProcessEvents(3)  "+ sequence.longName +" illegal sequence status, missing one or more open positions", ERR_RUNTIME_ERROR)));
      ArrayResize(openLevels, 0);
   }


   // (2) Laufzeitvariablen restaurieren
   int      id, lastId, nextId, minute, lastMinute, type, lastType, nextType, index, nextIndex, iPositionMax, ticket, lastTicket, nextTicket, closedPositions, reopenedPositions;
   datetime time, lastTime, nextTime;
   double   gridBase;
   int      orderEvents[] = {EV_POSITION_OPEN, EV_POSITION_STOPOUT, EV_POSITION_CLOSE};
   int      sizeOfEvents = ArrayRange(events, 0);

   // (2.1) Events sortieren
   if (sizeOfEvents > 0) {
      ArraySort(events);
      int firstType = MathRound(events[0][2]);
      if (firstType != EV_SEQUENCE_START) return(_false(catch("Sync.ProcessEvents(4)  "+ sequence.longName +" illegal first event "+ StatusEventToStr(firstType) +" (id="+ Round(events[0][0]) +"   time='"+ TimeToStr(events[0][1], TIME_FULL) +"')", ERR_RUNTIME_ERROR)));
   }

   for (i=0; i < sizeOfEvents; i++) {
      id       = events[i][0];
      time     = events[i][1];
      type     = events[i][2];
      gridBase = events[i][3];
      index    = events[i][4];

      ticket     = 0; if (IntInArray(orderEvents, type)) { ticket = orders.ticket[index]; iPositionMax = Max(iPositionMax, index); }
      nextTicket = 0;
      if (i < sizeOfEvents-1) { nextId = events[i+1][0]; nextTime = events[i+1][1]; nextType = events[i+1][2]; nextIndex = events[i+1][4]; if (IntInArray(orderEvents, nextType)) nextTicket = orders.ticket[nextIndex]; }
      else                    { nextId = 0;              nextTime = 0;              nextType = 0;                                                                                               nextTicket = 0;                        }

      // (2.2) Events auswerten
      // -- EV_SEQUENCE_START --------------
      if (type == EV_SEQUENCE_START) {
         if (i && sequence.status!=STATUS_STARTING && sequence.status!=STATUS_STOPPED)   return(_false(catch("Sync.ProcessEvents(5)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (sequence.status==STATUS_STARTING && reopenedPositions!=Abs(sequence.level)) return(_false(catch("Sync.ProcessEvents(6)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") and before "+ StatusEventToStr(nextType) +" ("+ nextId +", "+ ifString(nextTicket, "#"+ nextTicket +", ", "") +"time="+ nextTime +", "+ TimeToStr(nextTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         reopenedPositions = 0;
         sequence.status   = STATUS_PROGRESSING;
         sequence.start.event[index] = id;
      }
      // -- EV_GRIDBASE_CHANGE -------------
      else if (type == EV_GRIDBASE_CHANGE) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPED)     return(_false(catch("Sync.ProcessEvents(7)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (sequence.status == STATUS_PROGRESSING) {
            if (sequence.level != 0)                                                     return(_false(catch("Sync.ProcessEvents(8)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         }
         else { // STATUS_STOPPED
            reopenedPositions = 0;
            sequence.status   = STATUS_STARTING;
         }
         gridbase.event[index] = id;
      }
      // -- EV_POSITION_OPEN ---------------
      else if (type == EV_POSITION_OPEN) {
         if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING)    return(_false(catch("Sync.ProcessEvents(9)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (sequence.status == STATUS_PROGRESSING) {                                    // nicht bei PositionReopen
            sequence.level   += Sign(orders.level[index]); SS.SequenceName();
            sequence.maxLevel = ifInt(sequence.direction==D_LONG, Max(sequence.level, sequence.maxLevel), Min(sequence.level, sequence.maxLevel));
         }
         else {
            reopenedPositions++;
         }
         orders.openEvent[index] = id;
      }
      // -- EV_POSITION_STOPOUT ------------
      else if (type == EV_POSITION_STOPOUT) {
         if (sequence.status != STATUS_PROGRESSING)                                      return(_false(catch("Sync.ProcessEvents(10)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         sequence.level  -= Sign(orders.level[index]); SS.SequenceName();
         sequence.stops++;
         sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[index] + orders.commission[index] + orders.profit[index], 2);
         orders.closeEvent[index] = id;
      }
      // -- EV_POSITION_CLOSE --------------
      else if (type == EV_POSITION_CLOSE) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING)    return(_false(catch("Sync.ProcessEvents(11)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         sequence.closedPL = NormalizeDouble(sequence.closedPL + orders.swap[index] + orders.commission[index] + orders.profit[index], 2);
         if (sequence.status == STATUS_PROGRESSING)
            closedPositions = 0;
         closedPositions++;
         sequence.status = STATUS_STOPPING;
         orders.closeEvent[index] = id;
      }
      // -- EV_SEQUENCE_STOP ---------------
      else if (type == EV_SEQUENCE_STOP) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING)    return(_false(catch("Sync.ProcessEvents(12)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (closedPositions != Abs(sequence.level))                                     return(_false(catch("Sync.ProcessEvents(13)  "+ sequence.longName +" illegal event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") and before "+ StatusEventToStr(nextType) +" ("+ nextId +", "+ ifString(nextTicket, "#"+ nextTicket +", ", "") +"time="+ nextTime +", "+ TimeToStr(nextTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         closedPositions = 0;
         sequence.status = STATUS_STOPPED;
         sequence.stop.event[index] = id;
      }
      // -----------------------------------
      sequence.totalPL = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2);

      lastId     = id;
      lastTime   = time;
      lastType   = type;
      lastTicket = ticket;
   }
   lastEventId = id;


   // (4) Wurde die Sequenz au�erhalb gestoppt, fehlende Stop-Daten ermitteln
   if (sequence.status == STATUS_STOPPING) {
      if (closedPositions != Abs(sequence.level)) return(_false(catch("Sync.ProcessEvents(14)  "+ sequence.longName +" unexpected number of closed positions in "+ StatusDescription(sequence.status) +" sequence", ERR_RUNTIME_ERROR)));

      // (4.1) Stopdaten ermitteln
      int level = Abs(sequence.level);
      double stopPrice;
      for (i=sizeOfEvents-level; i < sizeOfEvents; i++) {
         time  = events[i][1];
         type  = events[i][2];
         index = events[i][4];
         if (type != EV_POSITION_CLOSE)
            return(_false(catch("Sync.ProcessEvents(15)  "+ sequence.longName +" unexpected "+ StatusEventToStr(type) +" at index "+ i, ERR_RUNTIME_ERROR)));
         stopPrice += orders.closePrice[index];
      }
      stopPrice /= level;

      // (4.2) Stopdaten zur�ckgeben
      sequenceStopTime  = time;
      sequenceStopPrice = NormalizeDouble(stopPrice, Digits);
   }

   ArrayResize(events,      0);
   ArrayResize(orderEvents, 0);
   return(!catch("Sync.ProcessEvents(16)"));
}


/**
 * Return the number of positions of the sequence closed by a stoploss.
 *
 * @return int
 */
int CountStoppedOutPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.closedBySL[i])
         count++;
   }
   return(count);
}


/**
 * Return the number of positions of the sequence closed by StopSequence().
 *
 * @return int
 */
int CountClosedPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]!=OP_UNDEFINED) /*&&*/ if (orders.closeTime[i]!=0) /*&&*/ if (!orders.closedBySL[i])
         count++;
   }
   return(count);
}


/**
 * Return a readable version of a status event identifier.
 *
 * @param  int event
 *
 * @return string
 */
string StatusEventToStr(int event) {
   switch (event) {
      case EV_SEQUENCE_START  : return("EV_SEQUENCE_START"  );
      case EV_SEQUENCE_STOP   : return("EV_SEQUENCE_STOP"   );
      case EV_GRIDBASE_CHANGE : return("EV_GRIDBASE_CHANGE" );
      case EV_POSITION_OPEN   : return("EV_POSITION_OPEN"   );
      case EV_POSITION_STOPOUT: return("EV_POSITION_STOPOUT");
      case EV_POSITION_CLOSE  : return("EV_POSITION_CLOSE"  );
   }
   return(_EMPTY_STR(catch("StatusEventToStr(1)  "+ sequence.longName +" illegal parameter event = "+ event, ERR_INVALID_PARAMETER)));
}


/**
 * Read the trade session configuration for the specified server time and copy it to the passed array.
 *
 * @param  _In_  datetime  time       - server time
 * @param  _Out_ datetime &config[][] - array receiving the trade session configuration
 *
 * @return bool - success status
 */
bool ReadTradeSessions(datetime time, datetime &config[][2]) {
   string section  = "TradeSessions";
   string symbol   = Symbol();
   string sDate    = TimeToStr(time, TIME_DATE);
   string sWeekday = GmtTimeFormat(time, "%A");
   string value;

   if      (IsConfigKey(section, symbol +"."+ sDate))    value = GetConfigString(section, symbol +"."+ sDate);
   else if (IsConfigKey(section, sDate))                 value = GetConfigString(section, sDate);
   else if (IsConfigKey(section, symbol +"."+ sWeekday)) value = GetConfigString(section, symbol +"."+ sWeekday);
   else if (IsConfigKey(section, sWeekday))              value = GetConfigString(section, sWeekday);
   else                                                  return(_false(debug("ReadTradeSessions(1)  "+ sequence.longName +" no trade session configuration found")));

   // Monday    =                                  // no trade session
   // Tuesday   = 00:00-24:00                      // a full trade session
   // Wednesday = 01:02-20:00                      // a limited trade session
   // Thursday  = 03:00-12:10, 13:30-19:00         // multiple trade sessions

   ArrayResize(config, 0);
   if (value == "")
      return(true);

   string values[], sTimes[], sSession, sSessionStart, sSessionEnd;
   int sizeOfValues = Explode(value, ",", values, NULL);
   for (int i=0; i < sizeOfValues; i++) {
      sSession = StrTrim(values[i]);
      if (Explode(sSession, "-", sTimes, NULL) != 2) return(_false(catch("ReadTradeSessions(2)  "+ sequence.longName +" illegal trade session configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sSessionStart = StrTrim(sTimes[0]);
      sSessionEnd   = StrTrim(sTimes[1]);
      debug("ReadTradeSessions(3)  start="+ sSessionStart +"  end="+ sSessionEnd);
   }
   return(true);
}


/**
 * Read the SnowRoller session break configuration for the specified server time and copy it to the passed array. SnowRoller
 * session breaks are symbol-specific. The configured times are applied session times, i.e. a session break will be enforced
 * if the current time is not in the configured time window.
 *
 * @param  _In_  datetime  time       - server time
 * @param  _Out_ datetime &config[][] - array receiving the session break configuration
 *
 * @return bool - success status
 */
bool ReadSessionBreaks(datetime time, datetime &config[][2]) {
   string section  = "SnowRoller.SessionBreaks";
   string symbol   = Symbol();
   string sDate    = TimeToStr(time, TIME_DATE);
   string sWeekday = GmtTimeFormat(time, "%A");
   string value;

   if      (IsConfigKey(section, symbol +"."+ sDate))    value = GetConfigString(section, symbol +"."+ sDate);
   else if (IsConfigKey(section, symbol +"."+ sWeekday)) value = GetConfigString(section, symbol +"."+ sWeekday);
   else                                                  return(_false(debug("ReadSessionBreaks(1)  "+ sequence.longName +" no session break configuration found"))); // TODO: fall-back to auto-adjusted trade sessions

   // Tuesday   = 00:00-24:00                      // a full trade session:    no session breaks
   // Wednesday = 01:02-19:57                      // a limited trade session: session breaks before and after
   // Thursday  = 03:00-12:10, 13:30-19:00         // multiple trade sessions: session breaks before, after and in between
   // Saturday  =                                  // no trade session:        a 24 h session break
   // Sunday    =                                  //

   ArrayResize(config, 0);
   if (value == "")
      return(true);                                // TODO: fall-back to auto-adjusted trade sessions

   string   values[], sTimes[], sTime, sHours, sMinutes, sSession, sStartTime, sEndTime;
   datetime dStartTime, dEndTime, dSessionStart, dSessionEnd;
   int      sizeOfValues = Explode(value, ",", values, NULL), iHours, iMinutes;

   for (int i=0; i < sizeOfValues; i++) {
      sSession = StrTrim(values[i]);
      if (Explode(sSession, "-", sTimes, NULL) != 2) return(_false(catch("ReadSessionBreaks(2)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));

      sTime = StrTrim(sTimes[0]);
      if (StringLen(sTime) != 5)                     return(_false(catch("ReadSessionBreaks(3)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      if (StringGetChar(sTime, 2) != ':')            return(_false(catch("ReadSessionBreaks(4)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sHours = StringSubstr(sTime, 0, 2);
      if (!StrIsDigit(sHours))                       return(_false(catch("ReadSessionBreaks(5)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iHours = StrToInteger(sHours);
      if (iHours > 24)                               return(_false(catch("ReadSessionBreaks(6)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sMinutes = StringSubstr(sTime, 3, 2);
      if (!StrIsDigit(sMinutes))                     return(_false(catch("ReadSessionBreaks(7)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iMinutes = StrToInteger(sMinutes);
      if (iMinutes > 59)                             return(_false(catch("ReadSessionBreaks(8)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      dStartTime = DateTime(1970, 1, 1, iHours, iMinutes);

      sTime = StrTrim(sTimes[1]);
      if (StringLen(sTime) != 5)                     return(_false(catch("ReadSessionBreaks(9)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      if (StringGetChar(sTime, 2) != ':')            return(_false(catch("ReadSessionBreaks(10)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sHours = StringSubstr(sTime, 0, 2);
      if (!StrIsDigit(sHours))                       return(_false(catch("ReadSessionBreaks(11)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iHours = StrToInteger(sHours);
      if (iHours > 24)                               return(_false(catch("ReadSessionBreaks(12)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sMinutes = StringSubstr(sTime, 3, 2);
      if (!StrIsDigit(sMinutes))                     return(_false(catch("ReadSessionBreaks(13)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iMinutes = StrToInteger(sMinutes);
      if (iMinutes > 59)                             return(_false(catch("ReadSessionBreaks(14)  "+ sequence.longName +" illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      dEndTime = DateTime(1970, 1, 1, iHours, iMinutes);

      debug("ReadSessionBreaks(15)  start="+ TimeToStr(dStartTime, TIME_FULL) +"  end="+ TimeToStr(dEndTime, TIME_FULL));
   }
   return(true);
}


/**
 * Update breakeven and profit targets.
 *
 * @return bool - success status
 */
bool UpdateProfitTargets() {
   if (IsLastError())                        return(false);
   if (IsTesting() && !tester.showBreakeven) return(true);
   // 7bit:
   // double loss = currentPL - PotentialProfit(gridbaseDistance);
   // double be   = gridbase + RequiredDistance(loss);

   // calculate breakeven price (profit = losses)
   double gridbase         = GetGridbase();
   double price            = ifDouble(sequence.direction==D_LONG, Bid, Ask);
   double gridbaseDistance = MathAbs(price - gridbase)/Pip;
   double potentialProfit  = PotentialProfit(gridbaseDistance);
   double losses           = sequence.totalPL - potentialProfit;
   double beDistance       = RequiredDistance(MathAbs(losses));
   double bePrice          = gridbase + ifDouble(sequence.direction==D_LONG, beDistance, -beDistance)*Pip;
   sequence.breakeven      = NormalizeDouble(bePrice, Digits);
   //debug("UpdateProfitTargets(1)  level="+ sequence.level +"  gridbaseDist="+ DoubleToStr(gridbaseDistance, 1) +"  potential="+ DoubleToStr(potentialProfit, 2) +"  beDist="+ DoubleToStr(beDistance, 1) +" => "+ NumberToStr(bePrice, PriceFormat));

   // calculate TP price
   return(!catch("UpdateProfitTargets(2)"));
}


/**
 * Show the current profit targets.
 *
 * @return bool - success status
 */
bool ShowProfitTargets() {
   if (IsLastError())       return(false);
   if (!sequence.breakeven) return(true);       // BE is not calculated if tester.showBreakeven = Off

   datetime time = TimeCurrent(); time -= time % MINUTES;
   string label = "arrow_"+ time;
   double price = sequence.breakeven;

   if (ObjectFind(label) < 0) {
      ObjectCreate(label, OBJ_ARROW, 0, time, price);
   }
   else {
      ObjectSet(label, OBJPROP_TIME1,  time);
      ObjectSet(label, OBJPROP_PRICE1, price);
   }
   ObjectSet(label, OBJPROP_ARROWCODE, 4);
   ObjectSet(label, OBJPROP_SCALE,     1);
   ObjectSet(label, OBJPROP_COLOR,  Blue);
   ObjectSet(label, OBJPROP_BACK,   true);

   return(!catch("ShowProfitTargets(1)"));
}


/**
 * Calculate the theoretically possible maximum profit at the specified distance away from the gridbase. The calculation
 * assumes a perfect grid. It considers commissions but disregards missed gridlevels and slippage.
 *
 * @param  double distance - distance from the gridbase in pip
 *
 * @return double - profit value
 */
double PotentialProfit(double distance) {
   // P = L * (L-1)/2 + partialP
   distance            = NormalizeDouble(distance, 1);
   int    level        = distance/GridSize;
   double partialLevel = MathModFix(distance/GridSize, 1);
   double units        = (level-1)/2.*level + partialLevel*level;
   double unitSize     = GridSize * PipValue(sequence.unitsize) + sequence.commission;
   double maxProfit    = units * unitSize;
   if (partialLevel > 0) {
      maxProfit += (1-partialLevel)*level*sequence.commission;    // a partial level pays full commission
   }
   return(NormalizeDouble(maxProfit, 2));
}


/**
 * Calculate the minimum distance price has to move away from the gridbase to theoretically generate the specified floating
 * profit. The calculation assumes a perfect grid. It considers commissions but disregards missed gridlevels and slippage.
 *
 * @param  double profit
 *
 * @return double - distance in pip
 */
double RequiredDistance(double profit) {
   // L = -0.5 + (0.25 + 2*units) ^ 1/2                           // quadratic equation solved with pq-formula
   double unitSize = GridSize * PipValue(sequence.unitsize) + sequence.commission;
   double units    = MathAbs(profit)/unitSize;
   double level    = MathPow(2*units + 0.25, 0.5) - 0.5;
   double distance = level * GridSize;
   return(RoundCeil(distance, 1));
}


/**
 * Return the trend value of a start condition's trend indicator.
 *
 * @param  int bar - bar index of the value to return
 *
 * @return int - trend value or NULL in case of errors
 */
int GetStartTrendValue(int bar) {
   if (start.trend.indicator == "alma"         ) return(GetALMA         (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "ema"          ) return(GetEMA          (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "halftrend"    ) return(GetHalfTrend    (start.trend.timeframe, start.trend.params, HalfTrend.MODE_TREND,     bar));
   if (start.trend.indicator == "jma"          ) return(GetJMA          (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "lwma"         ) return(GetLWMA         (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "nonlagma"     ) return(GetNonLagMA     (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "satl"         ) return(GetSATL         (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "sma"          ) return(GetSMA          (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "supersmoother") return(GetSuperSmoother(start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "supertrend"   ) return(GetSuperTrend   (start.trend.timeframe, start.trend.params, SuperTrend.MODE_TREND,    bar));
   if (start.trend.indicator == "triema"       ) return(GetTriEMA       (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));

   return(!catch("GetStartTrendValue(1)  "+ sequence.longName +" unsupported trend indicator "+ DoubleQuoteStr(start.trend.indicator), ERR_INVALID_CONFIG_VALUE));
}


/**
 * Return the trend value of a stop condition's trend indicator.
 *
 * @param  int bar - bar index of the value to return
 *
 * @return int - trend value or NULL in case of errors
 */
int GetStopTrendValue(int bar) {
   if (stop.trend.indicator == "alma"         ) return(GetALMA         (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "ema"          ) return(GetEMA          (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "halftrend"    ) return(GetHalfTrend    (stop.trend.timeframe, stop.trend.params, HalfTrend.MODE_TREND,     bar));
   if (stop.trend.indicator == "jma"          ) return(GetJMA          (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "lwma"         ) return(GetLWMA         (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "nonlagma"     ) return(GetNonLagMA     (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "satl"         ) return(GetSATL         (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "sma"          ) return(GetSMA          (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "supersmoother") return(GetSuperSmoother(stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "supertrend"   ) return(GetSuperTrend   (stop.trend.timeframe, stop.trend.params, SuperTrend.MODE_TREND,    bar));
   if (stop.trend.indicator == "triema"       ) return(GetTriEMA       (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));

   return(!catch("GetStopTrendValue(1)  "+ sequence.longName +" unsupported trend indicator "+ DoubleQuoteStr(stop.trend.indicator), ERR_INVALID_CONFIG_VALUE));
}


/**
 * Return an ALMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetALMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetALMA(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    maPeriods;
   static string maAppliedPrice;
   static double distributionOffset;
   static double distributionSigma;
   static string lastParams = "";

   if (params != lastParams) {
      maAppliedPrice     = "Close";
      distributionOffset = 0.85;
      distributionSigma  = 6.0;

      // "<periods>,<price>,<offset>,<sigma>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (!size)                    return(!catch("GetALMA(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<periods>"
      if (size > 0) {
         sValue = StrTrim(elems[0]);
         if (!StrIsDigit(sValue))   return(!catch("GetALMA(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         maPeriods = StrToInteger(sValue);
      }

      // "...,<price>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StringLen(sValue))    return(!catch("GetALMA(4)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         maAppliedPrice = sValue;
      }

      // "...,...,<offset>"
      if (size > 2) {
         sValue = StrTrim(elems[2]);
         if (!StrIsNumeric(sValue)) return(!catch("GetALMA(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         distributionOffset = StrToDouble(sValue);
      }

      // "...,...,...,<sigma>"
      if (size > 3) {
         sValue = StrTrim(elems[3]);
         if (!StrIsNumeric(sValue)) return(!catch("GetALMA(6)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         distributionSigma = StrToDouble(sValue);
      }

      if (size > 4)                 return(!catch("GetALMA(7)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iALMA(timeframe, maPeriods, maAppliedPrice, distributionOffset, distributionSigma, iBuffer, iBar));
}


/**
 * Return an EMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetEMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetEMA(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string appliedPrice;
   static string lastParams = "";

   if (params != lastParams) {
      appliedPrice = "Close";

      // "<periods>,<price>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (size < 1)              return(!catch("GetEMA(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<periods>"
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))   return(!catch("GetEMA(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);

      // "...,<price>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StringLen(sValue)) return(!catch("GetEMA(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         appliedPrice = sValue;
      }

      if (size > 2)              return(!catch("GetEMA(6)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iMovingAverage(timeframe, periods, "EMA", appliedPrice, iBuffer, iBar));
}


/**
 * Return a HalfTrend indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetHalfTrend(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetHalfTrend(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string lastParams = "";

   if (params != lastParams) {
      if (!StrIsDigit(params)) return(!catch("GetHalfTrend(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods    = StrToInteger(params);
      lastParams = params;
   }
   return(iHalfTrend(timeframe, periods, iBuffer, iBar));
}


/**
 * Return an JMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetJMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetJMA(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static int    phase;
   static string appliedPrice;
   static string lastParams = "";

   if (params != lastParams) {
      phase        = 0;
      appliedPrice = "Close";

      // "<periods>,<phase>,<price>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (!size)                    return(!catch("GetJMA(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<periods>"
      if (size > 0) {
         sValue = StrTrim(elems[0]);
         if (!StrIsDigit(sValue))   return(!catch("GetJMA(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         periods = StrToInteger(sValue);
      }

      // "...,<phase>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StrIsInteger(sValue)) return(!catch("GetJMA(4)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         phase = StrToInteger(sValue);
      }

      // "...,...,<price>"
      if (size > 2) {
         sValue = StrTrim(elems[2]);
         if (!StringLen(sValue))    return(!catch("GetJMA(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         appliedPrice = sValue;
      }

      if (size > 3)                 return(!catch("GetJMA(6)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iJMA(timeframe, periods, phase, appliedPrice, iBuffer, iBar));
}


/**
 * Return an LWMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetLWMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetLWMA(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string appliedPrice;
   static string lastParams = "";

   if (params != lastParams) {
      appliedPrice = "Close";

      // "<periods>,<price>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (size < 1)              return(!catch("GetLWMA(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<periods>"
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))   return(!catch("GetLWMA(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);

      // "...,<price>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StringLen(sValue)) return(!catch("GetLWMA(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         appliedPrice = sValue;
      }

      if (size > 2)              return(!catch("GetLWMA(6)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iMovingAverage(timeframe, periods, "LWMA", appliedPrice, iBuffer, iBar));
}


/**
 * Return a NonLagMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetNonLagMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetNonLagMA(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    cycleLength;
   static string appliedPrice;
   static string lastParams = "";

   if (params != lastParams) {
      appliedPrice = "Close";

      // "<cycleLength>,<price>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (size < 1)              return(!catch("GetNonLagMA(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<cycleLength>"
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))   return(!catch("GetNonLagMA(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      cycleLength = StrToInteger(sValue);

      // "...,<price>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StringLen(sValue)) return(!catch("GetNonLagMA(4)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         appliedPrice = sValue;
      }

      if (size > 2)              return(!catch("GetNonLagMA(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iNonLagMA(timeframe, cycleLength, appliedPrice, iBuffer, iBar));
}


/**
 * Return a SATL indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetSATL(int timeframe, string params, int iBuffer, int iBar) {
   if (StringLen(params) != 0) return(!catch("GetSATL(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   return(iSATL(timeframe, iBuffer, iBar));
}


/**
 * Return an SMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetSMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetSMA(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string appliedPrice;
   static string lastParams = "";

   if (params != lastParams) {
      appliedPrice = "Close";

      // "<periods>,<price>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (size < 1)              return(!catch("GetSMA(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<periods>"
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))   return(!catch("GetSMA(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);

      // "...,<price>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StringLen(sValue)) return(!catch("GetSMA(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         appliedPrice = sValue;
      }

      if (size > 2)              return(!catch("GetSMA(6)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iMovingAverage(timeframe, periods, "SMA", appliedPrice, iBuffer, iBar));
}


/**
 * Return an indicator value from "Ehler's 2-Pole-SuperSmoother Filter".
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetSuperSmoother(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetSuperSmoother(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string appliedPrice;
   static string lastParams = "";

   if (params != lastParams) {
      appliedPrice = "Close";

      // "<periods>,<price>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (size < 1)              return(!catch("GetSuperSmoother(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<periods>"
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))   return(!catch("GetSuperSmoother(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);

      // "...,<price>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StringLen(sValue)) return(!catch("GetSuperSmoother(4)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         appliedPrice = sValue;
      }

      if (size > 2)              return(!catch("GetSuperSmoother(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iSuperSmoother(timeframe, periods, appliedPrice, iBuffer, iBar));
}


/**
 * Return a SuperTrend indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetSuperTrend(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetSuperTrend(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    atrPeriods;
   static int    smaPeriods;
   static string lastParams = "";

   if (params != lastParams) {
      // "<atrPeriods>,<smaPeriods>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (size != 2)           return(!catch("GetSuperTrend(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<atrPeriods>"
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue)) return(!catch("GetSuperTrend(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      atrPeriods = StrToInteger(sValue);

      // "<smaPeriods>"
      sValue = StrTrim(elems[1]);
      if (!StrIsDigit(sValue)) return(!catch("GetSuperTrend(4)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      smaPeriods = StrToInteger(sValue);

      lastParams = params;
   }
   return(iSuperTrend(timeframe, atrPeriods, smaPeriods, iBuffer, iBar));
}


/**
 * Return a TriEMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetTriEMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetTriEMA(1)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string appliedPrice;
   static string lastParams = "";

   if (params != lastParams) {
      appliedPrice = "Close";

      // "<periods>,<price>"
      string sValue, elems[];
      int size = Explode(params, ",", elems, NULL);
      if (size < 1)              return(!catch("GetTriEMA(2)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

      // "<periods>"
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))   return(!catch("GetTriEMA(3)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);

      // "...,<price>"
      if (size > 1) {
         sValue = StrTrim(elems[1]);
         if (!StringLen(sValue)) return(!catch("GetTriEMA(4)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
         appliedPrice = sValue;
      }

      if (size > 2)              return(!catch("GetTriEMA(5)  "+ sequence.longName +" invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      lastParams = params;
   }
   return(iTriEMA(timeframe, periods, appliedPrice, iBuffer, iBar));
}


/**
 * Store the last occurred network error and update the time of the next trade request retry.
 *
 * @param  int oe[] - one or multiple order execution details (struct ORDER_EXECUTION)
 *
 * @return int - the error passed in the struct ORDER_EXECUTION
 */
int SetLastNetworkError(int oe[]) {
   bool singleOE = ArrayDimension(oe)==1;                         // whether a single or multiple ORDER_EXECUTIONs were passed

   int error, duration;
   if (singleOE) { error = oe.Error(oe);     duration = oe.Duration(oe);     }
   else          { error = oes.Error(oe, 0); duration = oes.Duration(oe, 0); }

   if (lastNetworkError && !error) {
      warn("SetLastNetworkError(1)  "+ sequence.longName +" network conditions after "+ ErrorToStr(lastNetworkError) +" successfully restored");
   }
   lastNetworkError = error;

   if (!error) {
      nextRetry = 0;
      retries = 0;
   }
   else {
      datetime now = Tick.Time + Ceil(duration/1000.);            // assumed current server time (may lag real time)
      int pauses[6]; if (!pauses[0]) {
         pauses[0] =  5*SECONDS;
         pauses[1] = 30*SECONDS;
         pauses[2] =  1*MINUTE;
         pauses[3] =  2*MINUTES;
         pauses[4] =  5*MINUTES;
         pauses[5] = 10*MINUTES;
      }
      nextRetry = now + pauses[Min(retries, 5)];
      if (__LOG()) log("SetLastNetworkError(2)  "+ sequence.longName +" networkError "+ ErrorToStr(lastNetworkError) +", next trade request not before "+ TimeToStr(nextRetry, TIME_FULL));
   }
   return(error);
}


/**
 * Whether the current market triggers the specified stoploss price.
 *
 * @param  int    type  - order type: OP_BUY | OP_SELL
 * @param  double price - stoploss price
 *
 * @return bool
 */
bool IsStopLossTriggered(int type, double price) {
   if (type == OP_BUY ) return(LE(Bid, price, Digits));
   if (type == OP_SELL) return(GE(Ask, price, Digits));

   return(!catch("IsStopLossTriggered(1)  "+ sequence.longName +" illegal parameter type: "+ type, ERR_INVALID_PARAMETER));

   // prevent compiler warnings
   int iNulls[];
   ReadTradeSessions(NULL, iNulls);
   ReadSessionBreaks(NULL, iNulls);
}
