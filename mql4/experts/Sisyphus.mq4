/**
 * Sisyphus - a reverse SnowRoller
 *
 *
 * Note: Case study, not yet ready for testing or trading.
 */
#include <stddefines.mqh>
#include <app/snowroller/defines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string   Sequence.ID            = "";                            // instance id, affects magic number and status/logfile names
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


#define STRATEGY_ID  104                           // unique strategy identifier


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


#include <app/snowroller/sisyphus-1-init.mqh>
#include <app/snowroller/sisyphus-2-deinit.mqh>
#include <app/snowroller/functions.mqh>


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   return(last_error);
}
