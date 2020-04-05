/**
 * RosaTrend - a simplistic trend following strategy
 *
 *
 * Note: Work in progress, not yet ready for testing or trading.
 */
#include <stddefines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string UnitSize            = "[L]{double} | auto*";     // fixed (double), compounding (L{double}) or pre-configured (auto) unitsize
extern string StartConditions     = "";                        //
extern string StopConditions      = "";                        //
extern bool   ShowProfitInPercent = true;                      // whether PL is displayed in absolute or percentage terms

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
   return(StringConcatenate("UnitSize=",            DoubleQuoteStr(UnitSize),        ";", NL,
                            "StartConditions=",     DoubleQuoteStr(StartConditions), ";", NL,
                            "StopConditions=",      DoubleQuoteStr(StopConditions),  ";", NL,
                            "ShowProfitInPercent=", BoolToStr(ShowProfitInPercent),  ";")
   );
}
