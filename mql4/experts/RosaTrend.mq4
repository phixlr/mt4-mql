/**
 * RosaTrend - a simplistic trend follower
 *
 *
 * Note: This strategy is in early development stage and in no way ready for trading. Once it is merged to "master" it will
 *       be ready for testing.
 */
#include <stddefines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE, INIT_CUSTOMLOG};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string UnitSize            = "[L]{double} | auto*";     // fixed (double), compounding (L{double}) or pre-configured (auto) unitsize
extern string StartConditions     = "";                        //
extern string StopConditions      = "";                        //
extern bool   ShowProfitInPercent = true;                      // whether PL is displayed in absolute or percentage values

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
