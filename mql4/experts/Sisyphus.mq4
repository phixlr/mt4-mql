/**
 * Sisyphus - a reverse SnowRoller
 *
 * Work in progress
 */
#include <stddefines.mqh>
#include <app/Sisyphus/defines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE, INIT_CUSTOMLOG};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string   Sequence.ID            = "";                            // instance id, affects magic number and status/logfile names
extern string   GridDirection          = "Long | Short";                //
extern int      GridSize               = 20;                            //
extern string   UnitSize               = "{double} | auto*";            // whether to use a fixed or a computed and compounding unitsize
extern int      StartLevel             = 0;                             //
extern string   StartConditions        = "";                            // @trend(<indicator>:<timeframe>:<params>) | @price(double) | @time(datetime)
extern string   StopConditions         = "";                            // @trend(<indicator>:<timeframe>:<params>) | @price(double) | @time(datetime) | @profit(double[%])
extern string   AutoRestart            = "Off* | Continue | Restart";   // whether to continue trading or restart a sequence after StopSequence(SIGNAL_TP)
extern bool     ShowProfitInPercent    = true;                          // whether PL values are displayed in absolute or percentage terms
extern datetime Sessionbreak.StartTime = D'1970.01.01 23:56:00';        // in FXT, the date part is ignored
extern datetime Sessionbreak.EndTime   = D'1970.01.01 01:02:10';        // in FXT, the date part is ignored

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   return(last_error);
}


/**
 * Return a string representation of the input parameters (for logging purposes).
 *
 * @return string
 */
string InputsToStr() {
   return(StringConcatenate("Sequence.ID=",            DoubleQuoteStr(Sequence.ID),                  ";", NL,
                            "GridDirection=",          DoubleQuoteStr(GridDirection),                ";", NL,
                            "GridSize=",               GridSize,                                     ";", NL,
                            "UnitSize=",               DoubleQuoteStr(UnitSize),                     ";", NL,
                            "StartLevel=",             StartLevel,                                   ";", NL,
                            "StartConditions=",        DoubleQuoteStr(StartConditions),              ";", NL,
                            "StopConditions=",         DoubleQuoteStr(StopConditions),               ";", NL,
                            "AutoRestart=",            DoubleQuoteStr(AutoRestart),                  ";", NL,
                            "ShowProfitInPercent=",    BoolToStr(ShowProfitInPercent),               ";", NL,
                            "Sessionbreak.StartTime=", TimeToStr(Sessionbreak.StartTime, TIME_FULL), ";", NL,
                            "Sessionbreak.EndTime=",   TimeToStr(Sessionbreak.EndTime, TIME_FULL),   ";")
   );
}
