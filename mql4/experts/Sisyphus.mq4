/**
 * Sisyphus - a reverse SnowRoller
 *
 *
 * Note: Work in progress, not yet ready for testing or trading.
 */
#include <stddefines.mqh>
#include <app/snowroller/defines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string   Sequence.ID            = "";                            // instance id in format /T?[0-9]{4,}/, affects magic number and status/logfile names
extern string   GridDirection          = "Long | Short";                //
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
#include <rsfLibs.mqh>
#include <functions/JoinInts.mqh>
#include <functions/JoinStrings.mqh>


#define STRATEGY_ID  104                           // unique strategy identifier
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
      if (IsStopSignal(signal))                StopSequence(signal);
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

   return(!catch("StartSequence(2)", ERR_NOT_IMPLEMENTED));
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

   return(!catch("StopSequence(2)", ERR_NOT_IMPLEMENTED));
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

   return(!catch("ResumeSequence(2)", ERR_NOT_IMPLEMENTED));
}


/**
 * Update internal order and PL status according to current market data.
 *
 * @param  _InOut_ bool gridChanged - whether the current gridbase or the gridlevel changed
 *
 * @return bool - success status
 */
bool UpdateStatus(bool &gridChanged) {
   gridChanged = gridChanged!=0;
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdateStatus(1)  "+ sequence.longName +" cannot update order status of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   return(!catch("UpdateStatus(2)", ERR_NOT_IMPLEMENTED));
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
   return(!catch("UpdatePendingOrders(3)", ERR_NOT_IMPLEMENTED));
}


/**
 * Return the number of positions of the sequence closed by a stoploss.
 *
 * @return int
 */
int CountStoppedOutPositions() {
   return(!catch("CountStoppedOutPositions(1)", ERR_NOT_IMPLEMENTED));
}


/**
 * Return the number of positions of the sequence closed by StopSequence().
 *
 * @return int
 */
int CountClosedPositions() {
   return(!catch("CountClosedPositions(1)", ERR_NOT_IMPLEMENTED));
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

   return(!catch("IsStartSignal(1)", ERR_NOT_IMPLEMENTED));
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

   return(!catch("IsStopSignal(1)", ERR_NOT_IMPLEMENTED));
}


/**
 * Restore the internal state of the EA from the current sequence's status file.
 *
 * @param  bool interactive - whether input parameters have been entered through the input dialog
 *
 * @return bool - success status
 */
bool RestoreSequence(bool interactive) {
   return(!catch("RestoreSequence(1)", ERR_NOT_IMPLEMENTED));
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

   return(!catch("SaveStatus(2)", ERR_NOT_IMPLEMENTED));
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

   Comment(NL, NL, NL, NL, "ShowStatus()  not implemented");
   return(error);
}
