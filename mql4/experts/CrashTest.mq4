/**
 *
 */
//roperty stacksize 262144       // 256kb
#property stacksize 1048576      // 1MB

#include <stddefines.mqh>


int   __INIT_FLAGS__[];
int __DEINIT_FLAGS__[];

#define __lpSuperContext NULL
int     __WHEREAMI__   = NULL;

double rates[][6];


/**
 * @return int
 */
int init() {
   ec_SetDllError(__ExecutionContext, SetLastError(NO_ERROR));
   onInitUser();
   return(last_error);
}


/**
 * @return int
 */
int start() {
   return(0);
}


/**
 * @return int
 */
int deinit() {
   return(0);
}


/**
 * @return bool
 */
bool IsExpert() {
   return(true);
}


/**
 * @return bool
 */
bool IsLibrary() {
   return(false);
}


/**
 * Check/update the program's error status and activate the flag __STATUS_OFF accordingly. Call ShowStatus() if the flag was
 * activated.
 *
 * @param  string location - location of the check
 * @param  int    setError - error to enforce
 *
 * @return bool - whether the flag __STATUS_OFF is set
 */
bool CheckErrors(string location, int setError = NULL) {
   // check and signal DLL errors
   int dll_error = __ExecutionContext[EC.dllError];                  // TODO: signal DLL errors
   if (dll_error && 1) {
      __STATUS_OFF        = true;                                    // all DLL errors are terminating errors
      __STATUS_OFF.reason = dll_error;
   }

   // check MQL errors
   int mql_error = __ExecutionContext[EC.mqlError];
   switch (mql_error) {
      case NO_ERROR:
      case ERS_HISTORY_UPDATE:
      case ERS_TERMINAL_NOT_YET_READY:
      case ERS_EXECUTION_STOPPING:
         break;
      default:
         __STATUS_OFF        = true;
         __STATUS_OFF.reason = mql_error;                            // MQL errors have higher severity than DLL errors
   }

   // check last_error
   switch (last_error) {
      case NO_ERROR:
      case ERS_HISTORY_UPDATE:
      case ERS_TERMINAL_NOT_YET_READY:
      case ERS_EXECUTION_STOPPING:
         break;
      default:
         __STATUS_OFF        = true;
         __STATUS_OFF.reason = last_error;                           // local errors have higher severity than library errors
   }

   // check uncatched errors
   if (!setError) setError = GetLastError();
   if (setError != NO_ERROR)
      catch(location, setError);                                     // catch() calls SetLastError(error) which calls CheckErrors(error)
                                                                     // which updates __STATUS_OFF accordingly
   // update the variable last_error
   if (__STATUS_OFF) /*&&*/ if (!last_error)
      last_error = __STATUS_OFF.reason;

   if (__STATUS_OFF)
      ShowStatus(last_error);                                        // always show status if an error occurred
   return(__STATUS_OFF);
}


#import "rsfLib1.ex4"
   bool IntInArray(int haystack[], int needle);

#import "rsfExpander.dll"
   int  ec_SetDllError           (/*EXECUTION_CONTEXT*/int ec[], int error       );
   bool ec_SetLogging            (/*EXECUTION_CONTEXT*/int ec[], int status      );
   int  ec_SetProgramCoreFunction(/*EXECUTION_CONTEXT*/int ec[], int coreFunction);

   int  AyncMainContext_init  (int ec[], int programType, string programName, int uninitReason, int initFlags, int deinitFlags, string symbol, int timeframe, int digits, double point, int extReporting, int recordEquity, int isTesting, int isVisualMode, int isOptimization, int lpSec, int hChart, int droppedOnChart, int droppedOnPosX, int droppedOnPosY);
   int  AyncMainContext_start (int ec[], double rates[][], int bars, int changedBars, int ticks, datetime time, double bid, double ask);
   int  AyncMainContext_deinit(int ec[], int uninitReason);
#import


// --------------------------------------------------------------------------------------------------------------------------


#include <rsfExpander.mqh>


/**
 * Send a message to the system debugger.
 *
 * @param  string message          - message
 * @param  int    error [optional] - error code
 *
 * @return int - the same error
 *
 * Notes:
 *  - No part of this function must load additional EX4 libaries.
 *  - The terminal must run with Administrator rights for OutputDebugString() to transport debug messages.
 */
int debug(string message, int error = NO_ERROR) {
   if (error != NO_ERROR) message = StringConcatenate(message, "  [", ErrorToStr(error), "]");

   if (This.IsTesting()) string application = StringConcatenate(GmtTimeFormat(MarketInfo(Symbol(), MODE_TIME), "%d.%m.%Y %H:%M:%S"), " Tester::");
   else                         application = "MetaTrader::";

   OutputDebugStringA(StringConcatenate(application, Symbol(), ",", PeriodDescription(Period()), "::", __NAME(), "::", StrReplace(StrReplaceR(message, NL+NL, NL), NL, " ")));
   return(error);
}


/**
 * Check if an error occurred and signal it (debug output console, visual, audible, if configured by email, if configured by
 * text message). The error is stored in the global var "last_error". After the function returned the internal MQL error code
 * as read by GetLastError() is always reset.
 *
 * @param  string location - the error's location identifier incl. an optional message
 * @param  int    error    [optional] - enforces a specific error (default: none)
 * @param  bool   orderPop [optional] - whether an order context stored on the order context stack should be restored
 *                                      (default: no)
 *
 * @return int - the occurred or enforced error
 */
int catch(string location, int error=NO_ERROR, bool orderPop=false) {
   orderPop = orderPop!=0;

   if      (!error                  ) { error  =                      GetLastError(); }
   else if (error == ERR_WIN32_ERROR) { error += GetLastWin32Error(); GetLastError(); }
   else                               {                               GetLastError(); }

   static bool recursive = false;

   if (error != NO_ERROR) {
      if (recursive)                                                          // prevent recursive errors
         return(debug("catch(1)  recursive error: "+ location, error));
      recursive = true;

      // send the error to the debug output console
      debug("ERROR: "+ location, error);

      // extend the program name by an instance id (if any)
      string name=__NAME(), nameInstanceId;
      int logId = 0;//GetCustomLogID();                                       // TODO: GetCustomLogID() must be moved from the library
      if (!logId) nameInstanceId = name;
      else {
         int pos = StringFind(name, "::");
         if (pos == -1) nameInstanceId = StringConcatenate(        name,       "(", logId, ")");
         else           nameInstanceId = StringConcatenate(StrLeft(name, pos), "(", logId, ")", StrSubstr(name, pos));
      }

      // log the error
      string message = StringConcatenate(location, "  [", ErrorToStr(error), "]");
      bool logged, alerted;
      if (!logged) {
         Alert("ERROR:   ", Symbol(), ",", PeriodDescription(Period()), "  ", nameInstanceId, "::", message);  // standard log: with instance id (if any)
         logged  = true;
         alerted = alerted || !IsExpert() || !IsTesting();
      }
      message = StringConcatenate(nameInstanceId, "::", message);

      // display the error
      message = StringConcatenate("ERROR:   ", Symbol(), ",", PeriodDescription(Period()), "  ", message);
      if (!alerted) {
         Alert(message);
         alerted = true;
      }

      // set var last_error
      SetLastError(error, NULL);
      recursive = false;
   }

   if (orderPop)
      OrderPop(location);
   return(error);
}


/**
 * Set the last error code of the module. If called in a library the error will bubble up to the library's main module.
 * If called in an indicator loaded by iCustom() the error will bubble up to the loading program. The error code NO_ERROR
 * will never bubble up.
 *
 * @param  int error - error code
 * @param  int param - ignored, any other value (default: none)
 *
 * @return int - the same error code (for chaining)
 */
int SetLastError(int error, int param = NULL) {
   last_error = ec_SetMqlError(__ExecutionContext, error);

   if (error != NO_ERROR) /*&&*/ if (IsExpert())
      CheckErrors("SetLastError(1)");                                // update __STATUS_OFF in experts
   return(error);
}


/**
 * Ersetzt in einem String alle Vorkommen eines Substrings durch einen anderen String (kein rekursives Ersetzen).
 *
 * @param  string value   - Ausgangsstring
 * @param  string search  - Suchstring
 * @param  string replace - Ersatzstring
 *
 * @return string - modifizierter String
 */
string StrReplace(string value, string search, string replace) {
   if (!StringLen(value))  return(value);
   if (!StringLen(search)) return(value);
   if (search == replace)  return(value);

   int from=0, found=StringFind(value, search);
   if (found == -1)
      return(value);

   string result = "";

   while (found > -1) {
      result = StringConcatenate(result, StrSubstr(value, from, found-from), replace);
      from   = found + StringLen(search);
      found  = StringFind(value, search, from);
   }
   result = StringConcatenate(result, StringSubstr(value, from));

   return(result);
}


/**
 * Ersetzt in einem String alle Vorkommen eines Substrings rekursiv durch einen anderen String. Die Funktion prüft nicht,
 * ob durch Such- und Ersatzstring eine Endlosschleife ausgelöst wird.
 *
 * @param  string value   - Ausgangsstring
 * @param  string search  - Suchstring
 * @param  string replace - Ersatzstring
 *
 * @return string - rekursiv modifizierter String
 */
string StrReplaceR(string value, string search, string replace) {
   if (!StringLen(value)) return(value);

   string lastResult="", result=value;

   while (result != lastResult) {
      lastResult = result;
      result     = StrReplace(result, search, replace);
   }
   return(lastResult);
}


/**
 * Drop-in replacement for the flawed built-in function StringSubstr()
 *
 * Bugfix für den Fall StringSubstr(string, start, length=0), in dem die MQL-Funktion Unfug zurückgibt.
 * Ermöglicht zusätzlich die Angabe negativer Werte für start und length.
 *
 * @param  string str
 * @param  int    start  - wenn negativ, Startindex vom Ende des Strings
 * @param  int    length - wenn negativ, Anzahl der zurückzugebenden Zeichen links vom Startindex
 *
 * @return string
 */
string StrSubstr(string str, int start, int length = INT_MAX) {
   if (length == 0)
      return("");

   if (start < 0)
      start = Max(0, start + StringLen(str));

   if (length < 0) {
      start += 1 + length;
      length = Abs(length);
   }

   if (length == INT_MAX) {
      length = INT_MAX - start;        // start + length must not be larger than INT_MAX
   }

   return(StringSubstr(str, start, length));
}


/**
 * Select a ticket.
 *
 * @param  int    ticket                      - ticket id
 * @param  string label                       - label for potential error message
 * @param  bool   pushTicket       [optional] - whether to push the selection onto the order selection stack (default: no)
 * @param  bool   onErrorPopTicket [optional] - whether to restore the previously selected ticket in case of errors
 *                                              (default: yes on pushTicket=TRUE, no on pushTicket=FALSE)
 * @return bool - success status
 */
bool SelectTicket(int ticket, string label, bool pushTicket=false, bool onErrorPopTicket=false) {
   pushTicket       = pushTicket!=0;
   onErrorPopTicket = onErrorPopTicket!=0;

   if (pushTicket) {
      if (!OrderPush(label)) return(false);
      onErrorPopTicket = true;
   }

   if (OrderSelect(ticket, SELECT_BY_TICKET))
      return(true);                             // success

   if (onErrorPopTicket)                        // error
      if (!OrderPop(label)) return(false);

   int error = GetLastError();
   if (!error)
      error = ERR_INVALID_TICKET;
   return(!catch(label +"->SelectTicket()   ticket="+ ticket, error));
}


/**
 * Schiebt den aktuellen Orderkontext auf den Kontextstack (fügt ihn ans Ende an).
 *
 * @param  string location - Bezeichner für eine evt. Fehlermeldung
 *
 * @return bool - success status
 */
bool OrderPush(string location) {
   int ticket = OrderTicket();

   int error = GetLastError();
   if (error && error!=ERR_NO_TICKET_SELECTED)
      return(!catch(location +"->OrderPush(1)", error));

   ArrayPushInt(stack.OrderSelect, ticket);
   return(true);
}


/**
 * Entfernt den letzten Orderkontext vom Ende des Kontextstacks und restauriert ihn.
 *
 * @param  string location - Bezeichner für eine evt. Fehlermeldung
 *
 * @return bool - success status
 */
bool OrderPop(string location) {
   int ticket = ArrayPopInt(stack.OrderSelect);

   if (ticket > 0)
      return(SelectTicket(ticket, location +"->OrderPop(1)"));

   OrderSelect(0, SELECT_BY_TICKET);

   int error = GetLastError();
   if (error && error!=ERR_NO_TICKET_SELECTED)
      return(!catch(location +"->OrderPop(2)", error));

   return(true);
}


/**
 * Pseudo-Funktion, die nichts weiter tut, als die Konstante EMPTY_VALUE (0x7FFFFFFF = 2147483647 = INT_MAX) zurückzugeben.
 * Kann zur Verbesserung der Übersichtlichkeit und Lesbarkeit verwendet werden.
 *
 * @param  beliebige Parameter (werden ignoriert)
 *
 * @return int - EMPTY_VALUE
 */
int _EMPTY_VALUE(int param1=NULL, int param2=NULL, int param3=NULL, int param4=NULL, int param5=NULL, int param6=NULL, int param7=NULL, int param8=NULL) {
   return(EMPTY_VALUE);
}


/**
 * Ob der angegebene Wert die Konstante EMPTY_VALUE darstellt.
 *
 * @param  double value
 *
 * @return bool
 */
bool IsEmptyValue(double value) {
   return(value == EMPTY_VALUE);
}


/**
 * Pseudo-Funktion, die nichts weiter tut, als einen Leerstring ("") zurückzugeben. Kann zur Verbesserung der
 * Übersichtlichkeit und Lesbarkeit verwendet werden.
 *
 * @param  beliebige Parameter (werden ignoriert)
 *
 * @return string - Leerstring
 */
string _EMPTY_STR(int param1=NULL, int param2=NULL, int param3=NULL, int param4=NULL, int param5=NULL, int param6=NULL, int param7=NULL, int param8=NULL) {
   return("");
}


/**
 * Ob der angegebene Wert einen Leerstring darstellt (keinen NULL-Pointer).
 *
 * @param  string value
 *
 * @return bool
 */
bool IsEmptyString(string value) {
   if (StrIsNull(value))
      return(false);
   return(value == "");
}


/**
 * Pseudo-Funktion, die die Konstante NaT (Not-A-Time: 0x80000000 = -2147483648 = INT_MIN = D'1901-12-13 20:45:52')
 * zurückgibt. Kann zur Verbesserung der Übersichtlichkeit und Lesbarkeit verwendet werden.
 *
 * @param  beliebige Parameter (werden ignoriert)
 *
 * @return datetime - NaT (Not-A-Time)
 */
datetime _NaT(int param1=NULL, int param2=NULL, int param3=NULL, int param4=NULL, int param5=NULL, int param6=NULL, int param7=NULL, int param8=NULL) {
   return(NaT);
}


/**
 * Ob der angegebene Wert die Konstante NaT (Not-A-Time) darstellt.
 *
 * @param  datetime value
 *
 * @return bool
 */
bool IsNaT(datetime value) {
   return(value == NaT);
}


/**
 * Pseudo-Funktion, die nichts weiter tut, als den ersten Parameter zurückzugeben. Kann zur Verbesserung der
 * Übersichtlichkeit und Lesbarkeit verwendet werden.
 *
 * @param  bool param1 - Boolean
 * @param  ...         - beliebige weitere Parameter (werden ignoriert)
 *
 * @return bool - der erste Parameter
 */
bool _bool(bool param1, int param2=NULL, int param3=NULL, int param4=NULL, int param5=NULL, int param6=NULL, int param7=NULL, int param8=NULL) {
   return(param1 != 0);
}


/**
 * Pseudo-Funktion, die nichts weiter tut, als den ersten Parameter zurückzugeben. Kann zur Verbesserung der
 * Übersichtlichkeit und Lesbarkeit verwendet werden.
 *
 * @param  int param1 - Integer
 * @param  ...        - beliebige weitere Parameter (werden ignoriert)
 *
 * @return int - der erste Parameter
 */
int _int(int param1, int param2=NULL, int param3=NULL, int param4=NULL, int param5=NULL, int param6=NULL, int param7=NULL, int param8=NULL) {
   return(param1);
}


/**
 * Pseudo-Funktion, die nichts weiter tut, als den ersten Parameter zurückzugeben. Kann zur Verbesserung der
 * Übersichtlichkeit und Lesbarkeit verwendet werden.
 *
 * @param  double param1 - Double
 * @param  ...           - beliebige weitere Parameter (werden ignoriert)
 *
 * @return double - der erste Parameter
 */
double _double(double param1, int param2=NULL, int param3=NULL, int param4=NULL, int param5=NULL, int param6=NULL, int param7=NULL, int param8=NULL) {
   return(param1);
}


/**
 * Pseudo-Funktion, die nichts weiter tut, als den ersten Parameter zurückzugeben. Kann zur Verbesserung der
 * Übersichtlichkeit und Lesbarkeit verwendet werden.
 *
 * @param  string param1 - String
 * @param  ...           - beliebige weitere Parameter (werden ignoriert)
 *
 * @return string - der erste Parameter
 */
string _string(string param1, int param2=NULL, int param3=NULL, int param4=NULL, int param5=NULL, int param6=NULL, int param7=NULL, int param8=NULL) {
   return(param1);
}


/**
 * Whether the current program runs on a visible chart. Can be FALSE only during testing if "VisualMode=Off" or
 * "Optimization=On".
 *
 * @return bool
 */
bool __CHART() {
   return(__ExecutionContext[EC.hChart] != 0);
}


/**
 * Whether logging is configured for the current program. Without a configuration the following default settings apply:
 *
 * In tester:     off
 * Not in tester: on
 *
 * @return bool
 */
bool __LOG() {
   return(__ExecutionContext[EC.logging] != 0);
}


/**
 * Return the current program's full name. For MQL main modules this value matches the return value of WindowExpertName().
 * For libraries this value includes the name of the main module, e.g. "{expert-name}::{library-name}".
 *
 * @return string
 */
string __NAME() {
   static string name = ""; if (!StringLen(name)) {
      string program = ec_ProgramName(__ExecutionContext);
      string module  = ec_ModuleName (__ExecutionContext);

      if (StringLen(program) && StringLen(module)) {
         name = program;
         if (IsLibrary()) name = StringConcatenate(name, "::", module);
      }
      else if (IsLibrary()) {
         if (!StringLen(program)) program = "???";
         if (!StringLen(module))  module = WindowExpertName();
         return(StringConcatenate(program, "::", module));
      }
      else {
         return(WindowExpertName());
      }
   }
   return(name);
}


/**
 * Integer-Version von MathMin()
 *
 * Ermittelt die kleinere mehrerer Ganzzahlen.
 *
 * @param  int value1
 * @param  int value2
 * @param      ...    - Insgesamt bis zu 8 Werte mit INT_MAX als Argumentbegrenzer. Kann einer der Werte selbst INT_MAX sein,
 *                      muß er innerhalb der ersten drei Argumente aufgeführt sein.
 * @return int
 */
int Min(int value1, int value2, int value3=INT_MAX, int value4=INT_MAX, int value5=INT_MAX, int value6=INT_MAX, int value7=INT_MAX, int value8=INT_MAX) {
   int result = value1;
   while (true) {
      if (value2 < result) result = value2;
      if (value3 < result) result = value3; if (value3 == INT_MAX) break;
      if (value4 < result) result = value4; if (value4 == INT_MAX) break;
      if (value5 < result) result = value5; if (value5 == INT_MAX) break;
      if (value6 < result) result = value6; if (value6 == INT_MAX) break;
      if (value7 < result) result = value7; if (value7 == INT_MAX) break;
      if (value8 < result) result = value8;
      break;
   }
   return(result);
}


/**
 * Integer-Version von MathMax()
 *
 * Ermittelt die größere mehrerer Ganzzahlen.
 *
 * @param  int value1
 * @param  int value2
 * @param      ...    - Insgesamt bis zu 8 Werte mit INT_MIN als Argumentbegrenzer. Kann einer der Werte selbst INT_MIN sein,
 *                      muß er innerhalb der ersten drei Argumente aufgeführt sein.
 * @return int
 */
int Max(int value1, int value2, int value3=INT_MIN, int value4=INT_MIN, int value5=INT_MIN, int value6=INT_MIN, int value7=INT_MIN, int value8=INT_MIN) {
   int result = value1;
   while (true) {
      if (value2 > result) result = value2;
      if (value3 > result) result = value3; if (value3 == INT_MIN) break;
      if (value4 > result) result = value4; if (value4 == INT_MIN) break;
      if (value5 > result) result = value5; if (value5 == INT_MIN) break;
      if (value6 > result) result = value6; if (value6 == INT_MIN) break;
      if (value7 > result) result = value7; if (value7 == INT_MIN) break;
      if (value8 > result) result = value8;
      break;
   }
   return(result);
}


/**
 * Integer-Version von MathAbs()
 *
 * Ermittelt den Absolutwert einer Ganzzahl.
 *
 * @param  int  value
 *
 * @return int
 */
int Abs(int value) {
   if (value < 0)
      return(-value);
   return(value);
}


/**
 * Integer version of MathRound()
 *
 * @param  double value
 *
 * @return int
 */
int Round(double value) {
   return(MathRound(value));
}


/**
 * Integer version of MathFloor()
 *
 * @param  double value
 *
 * @return int
 */
int Floor(double value) {
   return(MathFloor(value));
}


/**
 * Integer version of MathCeil()
 *
 * @param  double value
 *
 * @return int
 */
int Ceil(double value) {
   return(MathCeil(value));
}


/**
 * Extended version of MathRound(). Rounds to the specified amount of digits before or after the decimal separator.
 *
 * Examples:
 *  RoundEx(1234.5678,  3) => 1234.568
 *  RoundEx(1234.5678,  2) => 1234.57
 *  RoundEx(1234.5678,  1) => 1234.6
 *  RoundEx(1234.5678,  0) => 1235
 *  RoundEx(1234.5678, -1) => 1230
 *  RoundEx(1234.5678, -2) => 1200
 *  RoundEx(1234.5678, -3) => 1000
 *
 * @param  double number
 * @param  int    decimals [optional] - (default: 0)
 *
 * @return double - rounded value
 */
double RoundEx(double number, int decimals = 0) {
   if (decimals > 0) return(NormalizeDouble(number, decimals));
   if (!decimals)    return(      MathRound(number));

   // decimals < 0
   double factor = MathPow(10, decimals);
          number = MathRound(number * factor) / factor;
          number = MathRound(number);
   return(number);
}


/**
 * Extended version of MathFloor(). Rounds to the specified amount of digits before or after the decimal separator down.
 * That's the direction to zero.
 *
 * Examples:
 *  RoundFloor(1234.5678,  3) => 1234.567
 *  RoundFloor(1234.5678,  2) => 1234.56
 *  RoundFloor(1234.5678,  1) => 1234.5
 *  RoundFloor(1234.5678,  0) => 1234
 *  RoundFloor(1234.5678, -1) => 1230
 *  RoundFloor(1234.5678, -2) => 1200
 *  RoundFloor(1234.5678, -3) => 1000
 *
 * @param  double number
 * @param  int    decimals [optional] - (default: 0)
 *
 * @return double - rounded value
 */
double RoundFloor(double number, int decimals = 0) {
   if (decimals > 0) {
      double factor = MathPow(10, decimals);
             number = MathFloor(number * factor) / factor;
             number = NormalizeDouble(number, decimals);
      return(number);
   }

   if (decimals == 0)
      return(MathFloor(number));

   // decimals < 0
   factor = MathPow(10, decimals);
   number = MathFloor(number * factor) / factor;
   number = MathRound(number);
   return(number);
}


/**
 * Extended version of MathCeil(). Rounds to the specified amount of digits before or after the decimal separator up.
 * That's the direction from zero away.
 *
 * Examples:
 *  RoundCeil(1234.5678,  3) => 1234.568
 *  RoundCeil(1234.5678,  2) => 1234.57
 *  RoundCeil(1234.5678,  1) => 1234.6
 *  RoundCeil(1234.5678,  0) => 1235
 *  RoundCeil(1234.5678, -1) => 1240
 *  RoundCeil(1234.5678, -2) => 1300
 *  RoundCeil(1234.5678, -3) => 2000
 *
 * @param  double number
 * @param  int    decimals [optional] - (default: 0)
 *
 * @return double - rounded value
 */
double RoundCeil(double number, int decimals = 0) {
   if (decimals > 0) {
      double factor = MathPow(10, decimals);
             number = MathCeil(number * factor) / factor;
             number = NormalizeDouble(number, decimals);
      return(number);
   }

   if (decimals == 0)
      return(MathCeil(number));

   // decimals < 0
   factor = MathPow(10, decimals);
   number = MathCeil(number * factor) / factor;
   number = MathRound(number);
   return(number);
}


/**
 * Dividiert zwei Doubles und fängt dabei eine Division durch 0 ab.
 *
 * @param  double a                 - Divident
 * @param  double b                 - Divisor
 * @param  double onZero [optional] - Ergebnis für den Fall, daß der Divisor 0 ist (default: 0)
 *
 * @return double
 */
double MathDiv(double a, double b, double onZero = 0) {
   if (!b)
      return(onZero);
   return(a/b);
}


/**
 * Integer-Version von MathDiv(). Dividiert zwei Integers und fängt dabei eine Division durch 0 ab.
 *
 * @param  int a      - Divident
 * @param  int b      - Divisor
 * @param  int onZero - Ergebnis für den Fall, daß der Divisor 0 ist (default: 0)
 *
 * @return int
 */
int Div(int a, int b, int onZero=0) {
   if (!b)
      return(onZero);
   return(a/b);
}


/**
 * Gibt die Anzahl der Dezimal- bzw. Nachkommastellen eines Zahlenwertes zurück.
 *
 * @param  double number
 *
 * @return int - Anzahl der Nachkommastellen, höchstens jedoch 8
 */
int CountDecimals(double number) {
   string str = number;
   int dot    = StringFind(str, ".");

   for (int i=StringLen(str)-1; i > dot; i--) {
      if (StringGetChar(str, i) != '0')
         break;
   }
   return(i - dot);
}


/**
 * Gibt einen linken Teilstring eines Strings zurück.
 *
 * Ist N positiv, gibt StrLeft() die N am meisten links stehenden Zeichen des Strings zurück.
 *    z.B.  StrLeft("ABCDEFG",  2)  =>  "AB"
 *
 * Ist N negativ, gibt StrLeft() alle außer den N am meisten rechts stehenden Zeichen des Strings zurück.
 *    z.B.  StrLeft("ABCDEFG", -2)  =>  "ABCDE"
 *
 * @param  string value
 * @param  int    n
 *
 * @return string
 */
string StrLeft(string value, int n) {
   if (n > 0) return(StrSubstr(value, 0, n                 ));
   if (n < 0) return(StrSubstr(value, 0, StringLen(value)+n));
   return("");
}


/**
 * Gibt den linken Teil eines Strings bis zum Auftreten eines Teilstrings zurück. Das Ergebnis enthält den begrenzenden
 * Teilstring nicht.
 *
 * @param  string value     - Ausgangsstring
 * @param  string substring - der das Ergebnis begrenzende Teilstring
 * @param  int    count     - Anzahl der Teilstrings, deren Auftreten das Ergebnis begrenzt (default: das erste Auftreten)
 *                            Wenn größer als die Anzahl der im String existierenden Teilstrings, wird der gesamte String
 *                            zurückgegeben.
 *                            Wenn 0, wird ein Leerstring zurückgegeben.
 *                            Wenn negativ, wird mit dem Zählen statt von links von rechts begonnen.
 * @return string
 */
string StrLeftTo(string value, string substring, int count = 1) {
   int start=0, pos=-1;

   // positive Anzahl: von vorn zählen
   if (count > 0) {
      while (count > 0) {
         pos = StringFind(value, substring, pos+1);
         if (pos == -1)
            return(value);
         count--;
      }
      return(StrLeft(value, pos));
   }

   // negative Anzahl: von hinten zählen
   if (count < 0) {
      /*
      while(count < 0) {
         pos = StringFind(value, substring, 0);
         if (pos == -1)
            return("");
         count++;
      }
      */
      pos = StringFind(value, substring, 0);
      if (pos == -1)
         return(value);

      if (count == -1) {
         while (pos != -1) {
            start = pos+1;
            pos   = StringFind(value, substring, start);
         }
         return(StrLeft(value, start-1));
      }
      return(_EMPTY_STR(catch("StrLeftTo(1)->StringFindEx()", ERR_NOT_IMPLEMENTED)));

      //pos = StringFindEx(value, substring, count);
      //return(StrLeft(value, pos));
   }

   // Anzahl == 0
   return("");
}


/**
 * Gibt einen rechten Teilstring eines Strings zurück.
 *
 * Ist N positiv, gibt StrRight() die N am meisten rechts stehenden Zeichen des Strings zurück.
 *    z.B.  StrRight("ABCDEFG",  2)  =>  "FG"
 *
 * Ist N negativ, gibt StrRight() alle außer den N am meisten links stehenden Zeichen des Strings zurück.
 *    z.B.  StrRight("ABCDEFG", -2)  =>  "CDEFG"
 *
 * @param  string value
 * @param  int    n
 *
 * @return string
 */
string StrRight(string value, int n) {
   if (n > 0) return(StringSubstr(value, StringLen(value)-n));
   if (n < 0) return(StringSubstr(value, -n                ));
   return("");
}


/**
 * Gibt den rechten Teil eines Strings ab dem Auftreten eines Teilstrings zurück. Das Ergebnis enthält den begrenzenden
 * Teilstring nicht.
 *
 * @param  string value     - Ausgangsstring
 * @param  string substring - der das Ergebnis begrenzende Teilstring
 * @param  int    count     - Anzahl der Teilstrings, deren Auftreten das Ergebnis begrenzt (default: das erste Auftreten)
 *                            Wenn 0 oder größer als die Anzahl der im String existierenden Teilstrings, wird ein Leerstring
 *                            zurückgegeben.
 *                            Wenn negativ, wird mit dem Zählen statt von links von rechts begonnen.
 *                            Wenn negativ und absolut größer als die Anzahl der im String existierenden Teilstrings, wird
 *                            der gesamte String zurückgegeben.
 * @return string
 */
string StrRightFrom(string value, string substring, int count=1) {
   int start=0, pos=-1;


   // (1) positive Anzahl: von vorn zählen
   if (count > 0) {
      while (count > 0) {
         pos = StringFind(value, substring, pos+1);
         if (pos == -1)
            return("");
         count--;
      }
      return(StrSubstr(value, pos+StringLen(substring)));
   }


   // (2) negative Anzahl: von hinten zählen
   if (count < 0) {
      /*
      while(count < 0) {
         pos = StringFind(value, substring, 0);
         if (pos == -1)
            return("");
         count++;
      }
      */
      pos = StringFind(value, substring, 0);
      if (pos == -1)
         return(value);

      if (count == -1) {
         while (pos != -1) {
            start = pos+1;
            pos   = StringFind(value, substring, start);
         }
         return(StrSubstr(value, start-1 + StringLen(substring)));
      }

      return(_EMPTY_STR(catch("StringRightTo(1)->StringFindEx()", ERR_NOT_IMPLEMENTED)));
      //pos = StringFindEx(value, substring, count);
      //return(StrSubstr(value, pos + StringLen(substring)));
   }

   // Anzahl == 0
   return("");
}


/**
 * Ob ein String mit dem angegebenen Teilstring beginnt. Groß-/Kleinschreibung wird nicht beachtet.
 *
 * @param  string value  - zu prüfender String
 * @param  string prefix - Substring
 *
 * @return bool
 */
bool StrStartsWithI(string value, string prefix) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING) {
         if (StrIsNull(value))  return(false);
         if (StrIsNull(prefix)) return(!catch("StrStartsWithI(1)  invalid parameter prefix: (NULL)", error));
      }
      catch("StrStartsWithI(2)", error);
   }
   if (!StringLen(prefix))      return(!catch("StrStartsWithI(3)  illegal parameter prefix = \"\"", ERR_INVALID_PARAMETER));

   return(StringFind(StrToUpper(value), StrToUpper(prefix)) == 0);
}


/**
 * Ob ein String mit dem angegebenen Teilstring endet. Groß-/Kleinschreibung wird nicht beachtet.
 *
 * @param  string value  - zu prüfender String
 * @param  string suffix - Substring
 *
 * @return bool
 */
bool StrEndsWithI(string value, string suffix) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING) {
         if (StrIsNull(value))  return(false);
         if (StrIsNull(suffix)) return(!catch("StrEndsWithI(1)  invalid parameter suffix: (NULL)", error));
      }
      catch("StrEndsWithI(2)", error);
   }

   int lenValue = StringLen(value);
   int lenSuffix = StringLen(suffix);

   if (lenSuffix == 0)          return(!catch("StrEndsWithI(3)  illegal parameter suffix: \"\"", ERR_INVALID_PARAMETER));

   if (lenValue < lenSuffix)
      return(false);

   value = StrToUpper(value);
   suffix = StrToUpper(suffix);

   if (lenValue == lenSuffix)
      return(value == suffix);

   int start = lenValue-lenSuffix;
   return(StringFind(value, suffix, start) == start);
}


/**
 * Prüft, ob ein String nur Ziffern enthält.
 *
 * @param  string value - zu prüfender String
 *
 * @return bool
 */
bool StrIsDigit(string value) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING) {
         if (StrIsNull(value)) return(false);
      }
      catch("StrIsDigit(1)", error);
   }

   int chr, len=StringLen(value);

   if (len == 0)
      return(false);

   for (int i=0; i < len; i++) {
      chr = StringGetChar(value, i);
      if (chr < '0') return(false);
      if (chr > '9') return(false);
   }
   return(true);
}


/**
 * Prüft, ob ein String einen gültigen Integer darstellt.
 *
 * @param  string value - zu prüfender String
 *
 * @return bool
 */
bool StrIsInteger(string value) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING) {
         if (StrIsNull(value)) return(false);
      }
      catch("StrIsInteger(1)", error);
   }
   return(value == StringConcatenate("", StrToInteger(value)));
}


/**
 * Whether a string represents a valid numeric value (integer or float, characters "0123456789.+-").
 *
 * @param  string value - the string to check
 *
 * @return bool
 */
bool StrIsNumeric(string value) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING)
         if (StrIsNull(value)) return(false);
      catch("StrIsNumeric(1)", error);
   }

   int len = StringLen(value);
   if (!len)
      return(false);

   bool period = false;

   for (int i=0; i < len; i++) {
      int chr = StringGetChar(value, i);

      if (i == 0) {
         if (chr == '+') continue;
         if (chr == '-') continue;
      }
      if (chr == '.') {
         if (period) return(false);
         period = true;
         continue;
      }
      if (chr < '0') return(false);
      if (chr > '9') return(false);
   }
   return(true);
}


/**
 * Ob ein String eine gültige E-Mailadresse darstellt.
 *
 * @param  string value - zu prüfender String
 *
 * @return bool
 */
bool StrIsEmailAddress(string value) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING) {
         if (StrIsNull(value)) return(false);
      }
      catch("StrIsEmailAddress(1)", error);
   }

   string s = StrTrim(value);

   // Validierung noch nicht implementiert
   return(StringLen(s) > 0);
}


/**
 * Ob ein String eine gültige Telefonnummer darstellt.
 *
 * @param  string value - zu prüfender String
 *
 * @return bool
 */
bool StrIsPhoneNumber(string value) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING) {
         if (StrIsNull(value)) return(false);
      }
      catch("StrIsPhoneNumber(1)", error);
   }

   string s = StrReplace(StrTrim(value), " ", "");
   int char, length=StringLen(s);

   // Enthält die Nummer Bindestriche "-", müssen davor und danach Ziffern stehen.
   int pos = StringFind(s, "-");
   while (pos != -1) {
      if (pos   == 0     ) return(false);
      if (pos+1 == length) return(false);

      char = StringGetChar(s, pos-1);           // left char
      if (char < '0') return(false);
      if (char > '9') return(false);

      char = StringGetChar(s, pos+1);           // right char
      if (char < '0') return(false);
      if (char > '9') return(false);

      pos = StringFind(s, "-", pos+1);
   }
   if (char != 0) s = StrReplace(s, "-", "");

   // Beginnt eine internationale Nummer mit "+", darf danach keine 0 folgen.
   if (StrStartsWith(s, "+" )) {
      s = StrSubstr(s, 1);
      if (StrStartsWith(s, "0")) return(false);
   }

   return(StrIsDigit(s));
}


/**
 * Fix für fehlerhafte interne Funktion TimeDay()
 *
 *
 * Gibt den Tag des Monats eines Zeitpunkts zurück (1-31).
 *
 * @param  datetime time
 *
 * @return int
 */
int TimeDayFix(datetime time) {
   if (!time)
      return(1);
   return(TimeDay(time));           // Fehler: 0 statt 1 für D'1970.01.01 00:00:00'
}


/**
 * Fix für fehlerhafte interne Funktion TimeDayOfWeek()
 *
 *
 * Gibt den Wochentag eines Zeitpunkts zurück (0=Sunday ... 6=Saturday).
 *
 * @param  datetime time
 *
 * @return int
 */
int TimeDayOfWeekFix(datetime time) {
   if (!time)
      return(3);
   return(TimeDayOfWeek(time));     // Fehler: 0 (Sunday) statt 3 (Thursday) für D'1970.01.01 00:00:00'
}


/**
 * Fix für fehlerhafte interne Funktion TimeYear()
 *
 *
 * Gibt das Jahr eines Zeitpunkts zurück (1970-2037).
 *
 * @param  datetime time
 *
 * @return int
 */
int TimeYearFix(datetime time) {
   if (!time)
      return(1970);
   return(TimeYear(time));          // Fehler: 1900 statt 1970 für D'1970.01.01 00:00:00'
}


/**
 * Kopiert einen Speicherbereich. Als MoveMemory() implementiert, die betroffenen Speicherblöcke können sich also überlappen.
 *
 * @param  int destination - Zieladresse
 * @param  int source      - Quelladdrese
 * @param  int bytes       - Anzahl zu kopierender Bytes
 *
 * @return int - Fehlerstatus
 */
void CopyMemory(int destination, int source, int bytes) {
   if (destination>=0 && destination<MIN_VALID_POINTER) return(catch("CopyMemory(1)  invalid parameter destination = 0x"+ IntToHexStr(destination) +" (not a valid pointer)", ERR_INVALID_POINTER));
   if (source     >=0 && source    < MIN_VALID_POINTER) return(catch("CopyMemory(2)  invalid parameter source = 0x"+ IntToHexStr(source) +" (not a valid pointer)", ERR_INVALID_POINTER));

   RtlMoveMemory(destination, source, bytes);
   return(NO_ERROR);
}


/**
 * Erweitert einen String mit einem anderen String linksseitig auf eine gewünschte Mindestlänge.
 *
 * @param  string input     - Ausgangsstring
 * @param  int    padLength - gewünschte Mindestlänge
 * @param  string padString - zum Erweitern zu verwendender String (default: Leerzeichen)
 *
 * @return string
 */
string StrPadLeft(string input, int padLength, string padString=" ") {
   while (StringLen(input) < padLength) {
      input = StringConcatenate(padString, input);
   }
   return(input);
}


/**
 * Alias
 */
string StrLeftPad(string input, int padLength, string padString=" ") {
   return(StrPadLeft(input, padLength, padString));
}


/**
 * Erweitert einen String mit einem anderen String rechtsseitig auf eine gewünschte Mindestlänge.
 *
 * @param  string input     - Ausgangsstring
 * @param  int    padLength - gewünschte Mindestlänge
 * @param  string padString - zum Erweitern zu verwendender String (default: Leerzeichen)
 *
 * @return string
 */
string StrPadRight(string input, int padLength, string padString=" ") {
   while (StringLen(input) < padLength) {
      input = StringConcatenate(input, padString);
   }
   return(input);
}


/**
 * Alias
 */
string StrRightPad(string input, int padLength, string padString=" ") {
   return(StrPadRight(input, padLength, padString));
}


/**
 * Whether the current program is executed in the Tester or on a Tester chart.
 *
 * @return bool
 */
bool This.IsTesting() {
   static bool result, resolved;
   if (!resolved) {
      if (IsTesting()) result = true;
      else             result = __ExecutionContext[EC.testing] != 0;
      resolved = true;
   }
   return(result);
}


/**
 * Whether the current program runs on a demo account. Works around a bug in builds <= 509 where IsDemo() returns
 * FALSE in Tester.
 *
 * @return bool
 */
bool IsDemoFix() {
   static bool result, resolved;
   if (!resolved) {
      if (IsDemo()) result = true;
      else          result = This.IsTesting();
      resolved = true;
   }
   return(result);
}


/**
 * Konvertiert einen String in einen Boolean.
 *
 * Ist der Parameter strict = TRUE, werden die Strings "1" und "0", "on" und "off", "true" und "false", "yes" and "no" ohne
 * Beachtung von Groß-/Kleinschreibung konvertiert und alle anderen Werte lösen einen Fehler aus.
 *
 * Ist der Parameter strict = FALSE (default), werden unscharfe Rechtschreibfehler automatisch korrigiert (z.B. Ziffer 0 statt
 * großem Buchstaben O und umgekehrt), numerische Werte ungleich "1" und "0" entsprechend interpretiert und alle Werte, die
 * nicht als TRUE interpretiert werden können, als FALSE interpretiert.
 *
 * Leading/trailing White-Space wird in allen Fällen ignoriert.
 *
 * @param  string value             - der zu konvertierende String
 * @param  bool   strict [optional] - default: inaktiv
 *
 * @return bool
 */
bool StrToBool(string value, bool strict = false) {
   strict = strict!=0;

   value = StrTrim(value);
   string lValue = StrToLower(value);

   if (value  == "1"    ) return(true );
   if (value  == "0"    ) return(false);
   if (lValue == "on"   ) return(true );
   if (lValue == "off"  ) return(false);
   if (lValue == "true" ) return(true );
   if (lValue == "false") return(false);
   if (lValue == "yes"  ) return(true );
   if (lValue == "no"   ) return(false);

   if (strict) return(!catch("StrToBool(1)  cannot convert string "+ DoubleQuoteStr(value) +" to boolean (strict mode enabled)", ERR_INVALID_PARAMETER));

   if (value  == ""   ) return(false);
   if (value  == "O"  ) return(false);
   if (lValue == "0n" ) return(true );
   if (lValue == "0ff") return(false);
   if (lValue == "n0" ) return(false);

   if (StrIsNumeric(value))
      return(StrToDouble(value) != 0);
   return(false);
}


/**
 * Konvertiert die Großbuchstaben eines String zu Kleinbuchstaben (code-page: ANSI westlich).
 *
 * @param  string value
 *
 * @return string
 */
string StrToLower(string value) {
   string result = value;
   int char, len=StringLen(value);

   for (int i=0; i < len; i++) {
      char = StringGetChar(value, i);
      //logische Version
      //if      ( 65 <= char && char <=  90) result = StringSetChar(result, i, char+32);  // A-Z->a-z
      //else if (192 <= char && char <= 214) result = StringSetChar(result, i, char+32);  // À-Ö->à-ö
      //else if (216 <= char && char <= 222) result = StringSetChar(result, i, char+32);  // Ø-Þ->ø-þ
      //else if (char == 138)                result = StringSetChar(result, i, 154);      // Š->š
      //else if (char == 140)                result = StringSetChar(result, i, 156);      // Œ->œ
      //else if (char == 142)                result = StringSetChar(result, i, 158);      // Ž->ž
      //else if (char == 159)                result = StringSetChar(result, i, 255);      // Ÿ->ÿ

      // für MQL optimierte Version
      if (char > 64) {
         if (char < 91) {
            result = StringSetChar(result, i, char+32);                 // A-Z->a-z
         }
         else if (char > 191) {
            if (char < 223) {
               if (char != 215)
                  result = StringSetChar(result, i, char+32);           // À-Ö->à-ö, Ø-Þ->ø-þ
            }
         }
         else if (char == 138) result = StringSetChar(result, i, 154);  // Š->š
         else if (char == 140) result = StringSetChar(result, i, 156);  // Œ->œ
         else if (char == 142) result = StringSetChar(result, i, 158);  // Ž->ž
         else if (char == 159) result = StringSetChar(result, i, 255);  // Ÿ->ÿ
      }
   }
   return(result);
}


/**
 * Konvertiert einen String in Großschreibweise.
 *
 * @param  string value
 *
 * @return string
 */
string StrToUpper(string value) {
   string result = value;
   int char, len=StringLen(value);

   for (int i=0; i < len; i++) {
      char = StringGetChar(value, i);
      //logische Version
      //if      (96 < char && char < 123)             result = StringSetChar(result, i, char-32);
      //else if (char==154 || char==156 || char==158) result = StringSetChar(result, i, char-16);
      //else if (char==255)                           result = StringSetChar(result, i,     159);  // ÿ -> Ÿ
      //else if (char > 223)                          result = StringSetChar(result, i, char-32);

      // für MQL optimierte Version
      if      (char == 255)                 result = StringSetChar(result, i,     159);            // ÿ -> Ÿ
      else if (char  > 223)                 result = StringSetChar(result, i, char-32);
      else if (char == 158)                 result = StringSetChar(result, i, char-16);
      else if (char == 156)                 result = StringSetChar(result, i, char-16);
      else if (char == 154)                 result = StringSetChar(result, i, char-16);
      else if (char  >  96) if (char < 123) result = StringSetChar(result, i, char-32);
   }
   return(result);
}


/**
 * Trimmt einen String beidseitig.
 *
 * @param  string value
 *
 * @return string
 */
string StrTrim(string value) {
   return(StringTrimLeft(StringTrimRight(value)));
}


/**
 * URL-kodiert einen String.  Leerzeichen werden als "+"-Zeichen kodiert.
 *
 * @param  string value
 *
 * @return string - URL-kodierter String
 */
string UrlEncode(string value) {
   string strChar, result="";
   int    char, len=StringLen(value);

   for (int i=0; i < len; i++) {
      strChar = StringSubstr(value, i, 1);
      char    = StringGetChar(strChar, 0);

      if      (47 < char && char <  58) result = StringConcatenate(result, strChar);                  // 0-9
      else if (64 < char && char <  91) result = StringConcatenate(result, strChar);                  // A-Z
      else if (96 < char && char < 123) result = StringConcatenate(result, strChar);                  // a-z
      else if (char == ' ')             result = StringConcatenate(result, "+");
      else                              result = StringConcatenate(result, "%", CharToHexStr(char));
   }

   if (!catch("UrlEncode(1)"))
      return(result);
   return("");
}


/**
 * Whether the specified directory exists in the MQL "files\" directory.
 *
 * @param  string dirname - Directory name relative to "files/", may be a symbolic link or a junction. Supported directory
 *                          separators are forward and backward slash.
 * @return bool
 */
bool MQL.IsDirectory(string dirname) {
   // TODO: Prüfen, ob Scripte und Indikatoren im Tester tatsächlich auf "{terminal-directory}\tester\" zugreifen.

   string filesDirectory = GetMqlFilesPath();
   if (!StringLen(filesDirectory))
      return(false);
   return(IsDirectoryA(StringConcatenate(filesDirectory, "\\", dirname)));
}


/**
 * Whether the specified file exists in the MQL "files/" directory.
 *
 * @param  string filename - Filename relative to "files/", may be a symbolic link. Supported directory separators are
 *                           forward and backward slash.
 * @return bool
 */
bool MQL.IsFile(string filename) {
   // TODO: Prüfen, ob Scripte und Indikatoren im Tester tatsächlich auf "{terminal-directory}\tester\" zugreifen.

   string filesDirectory = GetMqlFilesPath();
   if (!StringLen(filesDirectory))
      return(false);
   return(IsFileA(StringConcatenate(filesDirectory, "\\", filename)));
}


/**
 * Return the full path of the MQL "files" directory. This is the directory accessible to MQL file functions.
 *
 * @return string - directory path not ending with a slash or an empty string in case of errors
 */
string GetMqlFilesPath() {
   static string filesDir;

   if (!StringLen(filesDir)) {
      if (IsTesting()) {
         string dataDirectory = GetTerminalDataPathA();
         if (!StringLen(dataDirectory))
            return(EMPTY_STR);
         filesDir = dataDirectory +"\\tester\\files";
      }
      else {
         string mqlDirectory = GetMqlDirectoryA();
         if (!StringLen(mqlDirectory))
            return(EMPTY_STR);
         filesDir = mqlDirectory  +"\\files";
      }
   }
   return(filesDir);
}


/**
 * Gibt die hexadezimale Repräsentation eines Strings zurück.
 *
 * @param  string value - Ausgangswert
 *
 * @return string - Hex-String
 */
string StrToHexStr(string value) {
   if (StrIsNull(value))
      return("(NULL)");

   string result = "";
   int len = StringLen(value);

   for (int i=0; i < len; i++) {
      result = StringConcatenate(result, CharToHexStr(StringGetChar(value, i)));
   }

   return(result);
}


/**
 * Konvertiert das erste Zeichen eines Strings in Großschreibweise.
 *
 * @param  string value
 *
 * @return string
 */
string StrCapitalize(string value) {
   if (!StringLen(value))
      return(value);
   return(StringConcatenate(StrToUpper(StrLeft(value, 1)), StrSubstr(value, 1)));
}


/**
 * Schickt dem aktuellen Chart eine Nachricht zum Öffnen des EA-Input-Dialogs.
 *
 * @return int - Fehlerstatus
 *
 *
 * NOTE: Es wird nicht überprüft, ob zur Zeit des Aufrufs ein EA läuft.
 */
int Chart.Expert.Properties() {
   if (This.IsTesting()) return(catch("Chart.Expert.Properties(1)", ERR_FUNC_NOT_ALLOWED_IN_TESTER));

   int hWnd = __ExecutionContext[EC.hChart];

   if (!PostMessageA(hWnd, WM_COMMAND, ID_CHART_EXPERT_PROPERTIES, 0))
      return(catch("Chart.Expert.Properties(3)->user32::PostMessageA() failed", ERR_WIN32_ERROR));

   return(NO_ERROR);
}


/**
 * Ruft den Hauptmenü-Befehl Charts->Objects-Unselect All auf.
 *
 * @return int - Fehlerstatus
 */
int Chart.Objects.UnselectAll() {
   int hWnd = __ExecutionContext[EC.hChart];
   PostMessageA(hWnd, WM_COMMAND, ID_CHART_OBJECTS_UNSELECTALL, 0);
   return(NO_ERROR);
}


/**
 * Ruft den Kontextmenü-Befehl Chart->Refresh auf.
 *
 * @return int - Fehlerstatus
 */
int Chart.Refresh() {
   int hWnd = __ExecutionContext[EC.hChart];
   PostMessageA(hWnd, WM_COMMAND, ID_CHART_REFRESH, 0);
   return(NO_ERROR);
}


/**
 * Store a boolean value under the specified key in the chart.
 *
 * @param  string key   - unique value identifier with a maximum length of 63 characters
 * @param  bool   value - boolean value to store
 *
 * @return bool - success status
 */
bool Chart.StoreBool(string key, bool value) {
   value = value!=0;
   if (!__CHART())  return(!catch("Chart.StoreBool(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)     return(!catch("Chart.StoreBool(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63) return(!catch("Chart.StoreBool(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0)
      ObjectDelete(key);
   ObjectCreate (key, OBJ_LABEL, 0, 0, 0);
   ObjectSet    (key, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   ObjectSetText(key, ""+ value);                                 // (string)(int) bool

   return(!catch("Chart.StoreBool(4)"));
}


/**
 * Store an integer value under the specified key in the chart.
 *
 * @param  string key   - unique value identifier with a maximum length of 63 characters
 * @param  int    value - integer value to store
 *
 * @return bool - success status
 */
bool Chart.StoreInt(string key, int value) {
   if (!__CHART())  return(!catch("Chart.StoreInt(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)     return(!catch("Chart.StoreInt(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63) return(!catch("Chart.StoreInt(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0)
      ObjectDelete(key);
   ObjectCreate (key, OBJ_LABEL, 0, 0, 0);
   ObjectSet    (key, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   ObjectSetText(key, ""+ value);                                 // (string) int

   return(!catch("Chart.StoreInt(4)"));
}


/**
 * Store a color value under the specified key in the chart.
 *
 * @param  string key   - unique value identifier with a maximum length of 63 characters
 * @param  color  value - color value to store
 *
 * @return bool - success status
 */
bool Chart.StoreColor(string key, color value) {
   if (!__CHART())  return(!catch("Chart.StoreColor(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)     return(!catch("Chart.StoreColor(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63) return(!catch("Chart.StoreColor(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0)
      ObjectDelete(key);
   ObjectCreate (key, OBJ_LABEL, 0, 0, 0);
   ObjectSet    (key, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   ObjectSetText(key, ""+ value);                                 // (string) color

   return(!catch("Chart.StoreColor(4)"));
}


/**
 * Store a double value under the specified key in the chart.
 *
 * @param  string key   - unique value identifier with a maximum length of 63 characters
 * @param  double value - double value to store
 *
 * @return bool - success status
 */
bool Chart.StoreDouble(string key, double value) {
   if (!__CHART())  return(!catch("Chart.StoreDouble(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)     return(!catch("Chart.StoreDouble(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63) return(!catch("Chart.StoreDouble(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0)
      ObjectDelete(key);
   ObjectCreate (key, OBJ_LABEL, 0, 0, 0);
   ObjectSet    (key, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   ObjectSetText(key, DoubleToStr(value, 8));                     // (string) double

   return(!catch("Chart.StoreDouble(4)"));
}


/**
 * Store a string value under the specified key in the chart.
 *
 * @param  string key   - unique value identifier with a maximum length of 63 characters
 * @param  string value - string value to store
 *
 * @return bool - success status
 */
bool Chart.StoreString(string key, string value) {
   if (!__CHART())    return(!catch("Chart.StoreString(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)       return(!catch("Chart.StoreString(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63)   return(!catch("Chart.StoreString(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   int valueLen = StringLen(value);
   if (valueLen > 63) return(!catch("Chart.StoreString(4)  invalid parameter value: "+ DoubleQuoteStr(value) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (!valueLen) {                                               // mark empty strings as the terminal fails to restore them
      value = "…(empty)…";                                        // that's 0x85
   }

   if (ObjectFind(key) == 0)
      ObjectDelete(key);
   ObjectCreate (key, OBJ_LABEL, 0, 0, 0);
   ObjectSet    (key, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   ObjectSetText(key, value);                                     // string

   return(!catch("Chart.StoreString(5)"));
}


/**
 * Restore the value of a boolean variable from the chart. If no stored value is found the function does nothing.
 *
 * @param  _In_  string key - unique variable identifier with a maximum length of 63 characters
 * @param  _Out_ bool  &var - variable to restore
 *
 * @return bool - success status
 */
bool Chart.RestoreBool(string key, bool &var) {
   if (!__CHART())             return(!catch("Chart.RestoreBool(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)                return(!catch("Chart.RestoreBool(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63)            return(!catch("Chart.RestoreBool(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0) {
      string sValue = StrTrim(ObjectDescription(key));
      if (!StrIsDigit(sValue)) return(!catch("Chart.RestoreBool(4)  illegal chart value "+ DoubleQuoteStr(key) +" = "+ DoubleQuoteStr(ObjectDescription(key)), ERR_RUNTIME_ERROR));
      int iValue = StrToInteger(sValue);
      if (iValue > 1)          return(!catch("Chart.RestoreBool(5)  illegal chart value "+ DoubleQuoteStr(key) +" = "+ DoubleQuoteStr(ObjectDescription(key)), ERR_RUNTIME_ERROR));
      ObjectDelete(key);
      var = (iValue!=0);                                          // (bool)(int)string
   }
   return(!catch("Chart.RestoreBool(6)"));
}


/**
 * Restore the value of an integer variale from the chart. If no stored value is found the function does nothing.
 *
 * @param  _In_  string key - unique variable identifier with a maximum length of 63 characters
 * @param  _Out_ int   &var - variable to restore
 *
 * @return bool - success status
 */
bool Chart.RestoreInt(string key, int &var) {
   if (!__CHART())             return(!catch("Chart.RestoreInt(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)                return(!catch("Chart.RestoreInt(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63)            return(!catch("Chart.RestoreInt(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0) {
      string sValue = StrTrim(ObjectDescription(key));
      if (!StrIsDigit(sValue)) return(!catch("Chart.RestoreInt(4)  illegal chart value "+ DoubleQuoteStr(key) +" = "+ DoubleQuoteStr(ObjectDescription(key)), ERR_RUNTIME_ERROR));
      ObjectDelete(key);
      var = StrToInteger(sValue);                                 // (int)string
   }
   return(!catch("Chart.RestoreInt(5)"));
}


/**
 * Restore the value of a color variable from the chart. If no stored value is found the function does nothing.
 *
 * @param  _In_  string key - unique variable identifier with a maximum length of 63 characters
 * @param  _Out_ color &var - variable to restore
 *
 * @return bool - success status
 */
bool Chart.RestoreColor(string key, color &var) {
   if (!__CHART())               return(!catch("Chart.RestoreColor(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)                  return(!catch("Chart.RestoreColor(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63)              return(!catch("Chart.RestoreColor(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0) {
      string sValue = StrTrim(ObjectDescription(key));
      if (!StrIsInteger(sValue)) return(!catch("Chart.RestoreColor(4)  illegal chart value "+ DoubleQuoteStr(key) +" = "+ DoubleQuoteStr(ObjectDescription(key)), ERR_RUNTIME_ERROR));
      int iValue = StrToInteger(sValue);
      if (iValue < CLR_NONE || iValue > C'255,255,255')
                                 return(!catch("Chart.RestoreColor(5)  illegal chart value "+ DoubleQuoteStr(key) +" = "+ DoubleQuoteStr(ObjectDescription(key)) +" (0x"+ IntToHexStr(iValue) +")", ERR_RUNTIME_ERROR));
      ObjectDelete(key);
      var = iValue;                                               // (color)(int)string
   }
   return(!catch("Chart.RestoreColor(6)"));
}


/**
 * Restore the value of a double variable from the chart. If no stored value is found the function does nothing.
 *
 * @param  _In_  string  key - unique variable identifier with a maximum length of 63 characters
 * @param  _Out_ double &var - variable to restore
 *
 * @return bool - success status
 */
bool Chart.RestoreDouble(string key, double &var) {
   if (!__CHART())               return(!catch("Chart.RestoreDouble(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)                  return(!catch("Chart.RestoreDouble(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63)              return(!catch("Chart.RestoreDouble(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0) {
      string sValue = StrTrim(ObjectDescription(key));
      if (!StrIsNumeric(sValue)) return(!catch("Chart.RestoreDouble(4)  illegal chart value "+ DoubleQuoteStr(key) +" = "+ DoubleQuoteStr(ObjectDescription(key)), ERR_RUNTIME_ERROR));
      ObjectDelete(key);
      var = StrToDouble(sValue);                                  // (double)string
   }
   return(!catch("Chart.RestoreDouble(5)"));
}


/**
 * Restore the value of a string variable from the chart. If no stored value is found the function does nothing.
 *
 * @param  _In_  string  key - unique variable identifier with a maximum length of 63 characters
 * @param  _Out_ string &var - variable to restore
 *
 * @return bool - success status
 */
bool Chart.RestoreString(string key, string &var) {
   if (!__CHART())  return(!catch("Chart.RestoreString(1)  illegal function call in the current context (no chart)", ERR_FUNC_NOT_ALLOWED));

   int keyLen = StringLen(key);
   if (!keyLen)     return(!catch("Chart.RestoreString(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63) return(!catch("Chart.RestoreString(3)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) == 0) {
      string sValue = ObjectDescription(key);
      ObjectDelete(key);

      if (sValue == "…(empty)…") var = "";         // restore marked empty strings as the terminal deserializes "" to the value "Text"
      else                       var = sValue;     // string
   }
   return(!catch("Chart.RestoreString(4)"));
}


/**
 * Delete the chart value stored under the specified key.
 *
 * @param  string key - chart object identifier with a maximum length of 63 characters
 *
 * @return bool - success status
 */
bool Chart.DeleteValue(string key) {
   if (!__CHART())  return(true);

   int keyLen = StringLen(key);
   if (!keyLen)     return(!catch("Chart.DeleteValue(1)  invalid parameter key: "+ DoubleQuoteStr(key) +" (not a chart object identifier)", ERR_INVALID_PARAMETER));
   if (keyLen > 63) return(!catch("Chart.DeleteValue(2)  invalid parameter key: "+ DoubleQuoteStr(key) +" (more than 63 characters)", ERR_INVALID_PARAMETER));

   if (ObjectFind(key) >= 0) {
      ObjectDelete(key);
   }
   return(!catch("Chart.DeleteValue(3)"));
}


/**
 * Erzeugt einen neuen String der gewünschten Länge.
 *
 * @param  int length - Länge
 *
 * @return string
 */
string CreateString(int length) {
   if (length < 0)        return(_EMPTY_STR(catch("CreateString(1)  invalid parameter length = "+ length, ERR_INVALID_PARAMETER)));
   if (length == INT_MAX) return(_EMPTY_STR(catch("CreateString(2)  too large parameter length: INT_MAX", ERR_INVALID_PARAMETER)));

   if (!length) return(StringConcatenate("", ""));                   // Um immer einen neuen String zu erhalten (MT4-Zeigerproblematik), darf Ausgangsbasis kein Literal sein.
                                                                     // Daher wird auch beim Initialisieren der string-Variable StringConcatenate() verwendet (siehe MQL.doc).
   string newStr = StringConcatenate(MAX_STRING_LITERAL, "");
   int    strLen = StringLen(newStr);

   while (strLen < length) {
      newStr = StringConcatenate(newStr, MAX_STRING_LITERAL);
      strLen = StringLen(newStr);
   }

   if (strLen != length)
      newStr = StringSubstr(newStr, 0, length);
   return(newStr);
}


/**
 * Aktiviert bzw. deaktiviert den Aufruf der start()-Funktion von Expert Advisern bei Eintreffen von Ticks.
 * Wird üblicherweise aus der init()-Funktion aufgerufen.
 *
 * @param  bool enable - gewünschter Status: On/Off
 *
 * @return int - Fehlerstatus
 */
int Toolbar.Experts(bool enable) {
   enable = enable!=0;

   if (This.IsTesting()) return(debug("Toolbar.Experts(1)  skipping in Tester", NO_ERROR));

   // TODO: Lock implementieren, damit mehrere gleichzeitige Aufrufe sich nicht gegenseitig überschreiben
   // TODO: Vermutlich Deadlock bei IsStopped()=TRUE, dann PostMessage() verwenden

   int hWnd = GetTerminalMainWindow();
   if (!hWnd)
      return(last_error);

   if (enable) {
      if (!IsExpertEnabled())
         SendMessageA(hWnd, WM_COMMAND, ID_EXPERTS_ONOFF, 0);
   }
   else /*disable*/ {
      if (IsExpertEnabled())
         SendMessageA(hWnd, WM_COMMAND, ID_EXPERTS_ONOFF, 0);
   }
   return(NO_ERROR);
}


/**
 * Ruft den Kontextmenü-Befehl MarketWatch->Symbols auf.
 *
 * @return int - Fehlerstatus
 */
int MarketWatch.Symbols() {
   int hWnd = GetTerminalMainWindow();
   if (!hWnd)
      return(last_error);

   PostMessageA(hWnd, WM_COMMAND, ID_MARKETWATCH_SYMBOLS, 0);
   return(NO_ERROR);
}


/**
 * Prüft, ob der aktuelle Tick ein neuer Tick ist.
 *
 * @return bool - Ergebnis
 */
bool EventListener.NewTick() {
   int vol = Volume[0];
   if (!vol)                                                         // Tick ungültig (z.B. Symbol noch nicht subscribed)
      return(false);

   static bool lastResult;
   static int  lastTick, lastVol;

   // Mehrfachaufrufe während desselben Ticks erkennen
   if (Tick == lastTick)
      return(lastResult);

   // Es reicht immer, den Tick nur anhand des Volumens des aktuellen Timeframes zu bestimmen.
   bool result = (lastVol && vol!=lastVol);                          // wenn der letzte Tick gültig war und sich das aktuelle Volumen geändert hat
                                                                     // (Optimierung unnötig, da im Normalfall immer beide Bedingungen zutreffen)
   lastVol    = vol;
   lastResult = result;
   return(result);
}


/**
 * Gibt die aktuelle FXT-Zeit des Systems zurück (auch im Tester).
 *
 * @return datetime - FXT-Zeit oder NULL, falls ein Fehler auftrat
 */
datetime GetFxtTime() {
   datetime gmt = GetGmtTime();      if (!gmt)       return(NULL);
   datetime fxt = GmtToFxtTime(gmt); if (fxt == NaT) return(NULL);
   return(fxt);
}


/**
 * Gibt die aktuelle Serverzeit zurück (auch im Tester). Dies ist nicht der Zeitpunkt des letzten eingetroffenen Ticks wie
 * von TimeCurrent() zurückgegeben, sondern die auf dem Server tatsächlich gültige Zeit (in seiner Zeitzone).
 *
 * @return datetime - Serverzeit oder NULL, falls ein Fehler auftrat
 */
datetime GetServerTime() {
   datetime gmt  = GetGmtTime();         if (!gmt)        return(NULL);
   datetime time = GmtToServerTime(gmt); if (time == NaT) return(NULL);
   return(time);
}


/**
 * Return a readable version of a module type flag.
 *
 * @param  int fType - combination of one or more module type flags
 *
 * @return string
 */
string ModuleTypesToStr(int fType) {
   string result = "";

   if (fType & MT_EXPERT    && 1) result = StringConcatenate(result, "|MT_EXPERT"   );
   if (fType & MT_SCRIPT    && 1) result = StringConcatenate(result, "|MT_SCRIPT"   );
   if (fType & MT_INDICATOR && 1) result = StringConcatenate(result, "|MT_INDICATOR");
   if (fType & MT_LIBRARY   && 1) result = StringConcatenate(result, "|MT_LIBRARY"  );

   if (!StringLen(result)) result = "(unknown module type "+ fType +")";
   else                    result = StringSubstr(result, 1);
   return(result);
}


/**
 * Gibt die Beschreibung eines UninitializeReason-Codes zurück (siehe UninitializeReason()).
 *
 * @param  int reason - Code
 *
 * @return string
 */
string UninitializeReasonDescription(int reason) {
   switch (reason) {
      case UR_UNDEFINED  : return("undefined"                          );
      case UR_REMOVE     : return("program removed from chart"         );
      case UR_RECOMPILE  : return("program recompiled"                 );
      case UR_CHARTCHANGE: return("chart symbol or timeframe changed"  );
      case UR_CHARTCLOSE : return("chart closed"                       );
      case UR_PARAMETERS : return("input parameters changed"           );
      case UR_ACCOUNT    : return("account or account settings changed");
      // ab Build > 509
      case UR_TEMPLATE   : return("template changed"                   );
      case UR_INITFAILED : return("OnInit() failed"                    );
      case UR_CLOSE      : return("terminal closed"                    );
   }
   return(_EMPTY_STR(catch("UninitializeReasonDescription()  invalid parameter reason = "+ reason, ERR_INVALID_PARAMETER)));
}


/**
 * Return the program's current init() reason code.
 *
 * @return int
 */
int ProgramInitReason() {
   return(__ExecutionContext[EC.programInitReason]);
}


/**
 * Gibt die Beschreibung eines InitReason-Codes zurück.
 *
 * @param  int reason - Code
 *
 * @return string
 */
string InitReasonDescription(int reason) {
   switch (reason) {
      case INITREASON_USER             : return("program loaded by user"    );
      case INITREASON_TEMPLATE         : return("program loaded by template");
      case INITREASON_PROGRAM          : return("program loaded by program" );
      case INITREASON_PROGRAM_AFTERTEST: return("program loaded after test" );
      case INITREASON_PARAMETERS       : return("input parameters changed"  );
      case INITREASON_TIMEFRAMECHANGE  : return("chart timeframe changed"   );
      case INITREASON_SYMBOLCHANGE     : return("chart symbol changed"      );
      case INITREASON_RECOMPILE        : return("program recompiled"        );
      case INITREASON_TERMINAL_FAILURE : return("terminal failure"          );
   }
   return(_EMPTY_STR(catch("InitReasonDescription(1)  invalid parameter reason: "+ reason, ERR_INVALID_PARAMETER)));
}


/**
 * Ermittelt den Kurznamen der Firma des aktuellen Accounts. Der Name wird vom Namen des Trade-Servers abgeleitet, nicht vom
 * Rückgabewert von AccountCompany().
 *
 * @return string - Kurzname oder Leerstring, falls ein Fehler auftrat
 */
string _ShortAccountCompany() {
   // Da bei Accountwechsel der Rückgabewert von AccountServer() bereits wechselt, obwohl der aktuell verarbeitete Tick noch
   // auf Daten des alten Account-Servers arbeitet, kann die Funktion AccountServer() nicht direkt verwendet werden. Statt
   // dessen muß immer der Umweg über GetServerName() gegangen werden. Die Funktion gibt erst dann einen geänderten Servernamen
   // zurück, wenn tatsächlich ein Tick des neuen Servers verarbeitet wird.
   //
   string server = GetServerName(); if (!StringLen(server)) return("");
   string name = StrLeftTo(server, "-"), lName = StrToLower(name);

   if (lName == "alpari"            ) return(AC.Alpari          );
   if (lName == "alparibroker"      ) return(AC.Alpari          );
   if (lName == "alpariuk"          ) return(AC.Alpari          );
   if (lName == "alparius"          ) return(AC.Alpari          );
   if (lName == "apbgtrading"       ) return(AC.APBG            );
   if (lName == "atcbrokers"        ) return(AC.ATCBrokers      );
   if (lName == "atcbrokersest"     ) return(AC.ATCBrokers      );
   if (lName == "atcbrokersliq1"    ) return(AC.ATCBrokers      );
   if (lName == "axitrader"         ) return(AC.AxiTrader       );
   if (lName == "axitraderusa"      ) return(AC.AxiTrader       );
   if (lName == "broco"             ) return(AC.BroCo           );
   if (lName == "brocoinvestments"  ) return(AC.BroCo           );
   if (lName == "cmap"              ) return(AC.ICMarkets       );     // demo
   if (lName == "collectivefx"      ) return(AC.CollectiveFX    );
   if (lName == "dukascopy"         ) return(AC.Dukascopy       );
   if (lName == "easyforex"         ) return(AC.EasyForex       );
   if (lName == "finfx"             ) return(AC.FinFX           );
   if (lName == "forex"             ) return(AC.ForexLtd        );
   if (lName == "forexbaltic"       ) return(AC.FBCapital       );
   if (lName == "fxopen"            ) return(AC.FXOpen          );
   if (lName == "fxprimus"          ) return(AC.FXPrimus        );
   if (lName == "fxpro.com"         ) return(AC.FxPro           );
   if (lName == "fxdd"              ) return(AC.FXDD            );
   if (lName == "gci"               ) return(AC.GCI             );
   if (lName == "gcmfx"             ) return(AC.Gallant         );
   if (lName == "gftforex"          ) return(AC.GFT             );
   if (lName == "globalprime"       ) return(AC.GlobalPrime     );
   if (lName == "icmarkets"         ) return(AC.ICMarkets       );
   if (lName == "inovatrade"        ) return(AC.InovaTrade      );
   if (lName == "integral"          ) return(AC.GlobalPrime     );     // demo
   if (lName == "investorseurope"   ) return(AC.InvestorsEurope );
   if (lName == "jfd"               ) return(AC.JFDBrokers      );
   if (lName == "liteforex"         ) return(AC.LiteForex       );
   if (lName == "londoncapitalgr"   ) return(AC.LondonCapital   );
   if (lName == "londoncapitalgroup") return(AC.LondonCapital   );
   if (lName == "mbtrading"         ) return(AC.MBTrading       );
   if (lName == "metaquotes"        ) return(AC.MetaQuotes      );
   if (lName == "migbank"           ) return(AC.MIG             );
   if (lName == "oanda"             ) return(AC.Oanda           );
   if (lName == "pepperstone"       ) return(AC.Pepperstone     );
   if (lName == "primexm"           ) return(AC.PrimeXM         );
   if (lName == "sig"               ) return(AC.LiteForex       );
   if (lName == "sts"               ) return(AC.STS             );
   if (lName == "teletrade"         ) return(AC.TeleTrade       );
   if (lName == "teletradecy"       ) return(AC.TeleTrade       );
   if (lName == "tickmill"          ) return(AC.TickMill        );
   if (lName == "xtrade"            ) return(AC.XTrade          );

   debug("ShortAccountCompany(1)  unknown server name \""+ server +"\", using \""+ name +"\"");
   return(name);
}


/**
 * Gibt die ID einer Account-Company zurück.
 *
 * @param string shortName - Kurzname der Account-Company
 *
 * @return int - Company-ID oder NULL, falls der übergebene Wert keine bekannte Account-Company ist
 */
int AccountCompanyId(string shortName) {
   if (!StringLen(shortName))
      return(NULL);

   shortName = StrToUpper(shortName);

   switch (StringGetChar(shortName, 0)) {
      case 'A': if (shortName == StrToUpper(AC.Alpari         )) return(AC_ID.Alpari         );
                if (shortName == StrToUpper(AC.APBG           )) return(AC_ID.APBG           );
                if (shortName == StrToUpper(AC.ATCBrokers     )) return(AC_ID.ATCBrokers     );
                if (shortName == StrToUpper(AC.AxiTrader      )) return(AC_ID.AxiTrader      );
                break;

      case 'B': if (shortName == StrToUpper(AC.BroCo          )) return(AC_ID.BroCo          );
                break;

      case 'C': if (shortName == StrToUpper(AC.CollectiveFX   )) return(AC_ID.CollectiveFX   );
                break;

      case 'D': if (shortName == StrToUpper(AC.Dukascopy      )) return(AC_ID.Dukascopy      );
                break;

      case 'E': if (shortName == StrToUpper(AC.EasyForex      )) return(AC_ID.EasyForex      );
                break;

      case 'F': if (shortName == StrToUpper(AC.FBCapital      )) return(AC_ID.FBCapital      );
                if (shortName == StrToUpper(AC.FinFX          )) return(AC_ID.FinFX          );
                if (shortName == StrToUpper(AC.ForexLtd       )) return(AC_ID.ForexLtd       );
                if (shortName == StrToUpper(AC.FXPrimus       )) return(AC_ID.FXPrimus       );
                if (shortName == StrToUpper(AC.FXDD           )) return(AC_ID.FXDD           );
                if (shortName == StrToUpper(AC.FXOpen         )) return(AC_ID.FXOpen         );
                if (shortName == StrToUpper(AC.FxPro          )) return(AC_ID.FxPro          );
                break;

      case 'G': if (shortName == StrToUpper(AC.Gallant        )) return(AC_ID.Gallant        );
                if (shortName == StrToUpper(AC.GCI            )) return(AC_ID.GCI            );
                if (shortName == StrToUpper(AC.GFT            )) return(AC_ID.GFT            );
                if (shortName == StrToUpper(AC.GlobalPrime    )) return(AC_ID.GlobalPrime    );
                break;

      case 'H': break;

      case 'I': if (shortName == StrToUpper(AC.ICMarkets      )) return(AC_ID.ICMarkets      );
                if (shortName == StrToUpper(AC.InovaTrade     )) return(AC_ID.InovaTrade     );
                if (shortName == StrToUpper(AC.InvestorsEurope)) return(AC_ID.InvestorsEurope);
                break;

      case 'J': if (shortName == StrToUpper(AC.JFDBrokers     )) return(AC_ID.JFDBrokers     );
                break;

      case 'K': break;

      case 'L': if (shortName == StrToUpper(AC.LiteForex      )) return(AC_ID.LiteForex      );
                if (shortName == StrToUpper(AC.LondonCapital  )) return(AC_ID.LondonCapital  );
                break;

      case 'M': if (shortName == StrToUpper(AC.MBTrading      )) return(AC_ID.MBTrading      );
                if (shortName == StrToUpper(AC.MetaQuotes     )) return(AC_ID.MetaQuotes     );
                if (shortName == StrToUpper(AC.MIG            )) return(AC_ID.MIG            );
                break;

      case 'N': break;

      case 'O': if (shortName == StrToUpper(AC.Oanda          )) return(AC_ID.Oanda          );
                break;

      case 'P': if (shortName == StrToUpper(AC.Pepperstone    )) return(AC_ID.Pepperstone    );
                if (shortName == StrToUpper(AC.PrimeXM        )) return(AC_ID.PrimeXM        );
                break;

      case 'Q': break;
      case 'R': break;

      case 'S': if (shortName == StrToUpper(AC.SimpleTrader   )) return(AC_ID.SimpleTrader   );
                if (shortName == StrToUpper(AC.STS            )) return(AC_ID.STS            );
                break;

      case 'T': if (shortName == StrToUpper(AC.TeleTrade      )) return(AC_ID.TeleTrade      );
                if (shortName == StrToUpper(AC.TickMill       )) return(AC_ID.TickMill       );
                break;

      case 'U': break;
      case 'V': break;
      case 'W': break;

      case 'X': if (shortName == StrToUpper(AC.XTrade         )) return(AC_ID.XTrade         );
                break;

      case 'Y': break;
      case 'Z': break;
   }

   return(NULL);
}


/**
 * Vergleicht zwei Strings ohne Berücksichtigung von Groß-/Kleinschreibung.
 *
 * @param  string string1
 * @param  string string2
 *
 * @return bool
 */
bool StrCompareI(string string1, string string2) {
   int error = GetLastError();
   if (error != NO_ERROR) {
      if (error == ERR_NOT_INITIALIZED_STRING) {
         if (StrIsNull(string1)) return(StrIsNull(string2));
         if (StrIsNull(string2)) return(false);
      }
      catch("StrCompareI(1)", error);
   }
   return(StrToUpper(string1) == StrToUpper(string2));
}


/**
 * Prüft, ob ein String einen Substring enthält. Groß-/Kleinschreibung wird beachtet.
 *
 * @param  string value     - zu durchsuchender String
 * @param  string substring - zu suchender Substring
 *
 * @return bool
 */
bool StrContains(string value, string substring) {
   if (!StringLen(substring))
      return(!catch("StrContains()  illegal parameter substring = "+ DoubleQuoteStr(substring), ERR_INVALID_PARAMETER));
   return(StringFind(value, substring) != -1);
}


/**
 * Prüft, ob ein String einen Substring enthält. Groß-/Kleinschreibung wird nicht beachtet.
 *
 * @param  string value     - zu durchsuchender String
 * @param  string substring - zu suchender Substring
 *
 * @return bool
 */
bool StrContainsI(string value, string substring) {
   if (!StringLen(substring))
      return(!catch("StrContainsI()  illegal parameter substring = "+ DoubleQuoteStr(substring), ERR_INVALID_PARAMETER));
   return(StringFind(StrToUpper(value), StrToUpper(substring)) != -1);
}


/**
 * Durchsucht einen String vom Ende aus nach einem Substring und gibt dessen Position zurück.
 *
 * @param  string value  - zu durchsuchender String
 * @param  string search - zu suchender Substring
 *
 * @return int - letzte Position des Substrings oder -1, wenn der Substring nicht gefunden wurde
 */
int StrFindR(string value, string search) {
   int lenValue  = StringLen(value),
       lastFound = -1,
       result    =  0;

   for (int i=0; i < lenValue; i++) {
      result = StringFind(value, search, i);
      if (result == -1)
         break;
      lastFound = result;
   }
   return(lastFound);
}


/**
 * Konvertiert eine Farbe in ihre HTML-Repräsentation.
 *
 * @param  color value
 *
 * @return string - HTML-Farbwert
 *
 * Beispiel: ColorToHtmlStr(C'255,255,255') => "#FFFFFF"
 */
string ColorToHtmlStr(color value) {
   int red   = value & 0x0000FF;
   int green = value & 0x00FF00;
   int blue  = value & 0xFF0000;

   int iValue = red<<16 + green + blue>>16;   // rot und blau vertauschen, um IntToHexStr() benutzen zu können

   return(StringConcatenate("#", StrRight(IntToHexStr(iValue), 6)));
}


/**
 * Konvertiert eine Farbe in ihre MQL-String-Repräsentation, z.B. "Red" oder "0,255,255".
 *
 * @param  color value
 *
 * @return string - MQL-Farbcode oder RGB-String, falls der übergebene Wert kein bekannter MQL-Farbcode ist.
 */
string ColorToStr(color value) {
   if (value == 0xFF000000)                                          // aus CLR_NONE = 0xFFFFFFFF macht das Terminal nach Recompilation oder Deserialisierung
      value = CLR_NONE;                                              // u.U. 0xFF000000 (entspricht Schwarz)
   if (value < CLR_NONE || value > C'255,255,255')
      return(_EMPTY_STR(catch("ColorToStr(1)  invalid parameter value: "+ value +" (not a color)", ERR_INVALID_PARAMETER)));

   if (value == CLR_NONE) return("CLR_NONE"         );
   if (value == 0xFFF8F0) return("AliceBlue"        );
   if (value == 0xD7EBFA) return("AntiqueWhite"     );
   if (value == 0xFFFF00) return("Aqua"             );
   if (value == 0xD4FF7F) return("Aquamarine"       );
   if (value == 0xDCF5F5) return("Beige"            );
   if (value == 0xC4E4FF) return("Bisque"           );
   if (value == 0x000000) return("Black"            );
   if (value == 0xCDEBFF) return("BlanchedAlmond"   );
   if (value == 0xFF0000) return("Blue"             );
   if (value == 0xE22B8A) return("BlueViolet"       );
   if (value == 0x2A2AA5) return("Brown"            );
   if (value == 0x87B8DE) return("BurlyWood"        );
   if (value == 0xA09E5F) return("CadetBlue"        );
   if (value == 0x00FF7F) return("Chartreuse"       );
   if (value == 0x1E69D2) return("Chocolate"        );
   if (value == 0x507FFF) return("Coral"            );
   if (value == 0xED9564) return("CornflowerBlue"   );
   if (value == 0xDCF8FF) return("Cornsilk"         );
   if (value == 0x3C14DC) return("Crimson"          );
   if (value == 0x8B0000) return("DarkBlue"         );
   if (value == 0x0B86B8) return("DarkGoldenrod"    );
   if (value == 0xA9A9A9) return("DarkGray"         );
   if (value == 0x006400) return("DarkGreen"        );
   if (value == 0x6BB7BD) return("DarkKhaki"        );
   if (value == 0x2F6B55) return("DarkOliveGreen"   );
   if (value == 0x008CFF) return("DarkOrange"       );
   if (value == 0xCC3299) return("DarkOrchid"       );
   if (value == 0x7A96E9) return("DarkSalmon"       );
   if (value == 0x8BBC8F) return("DarkSeaGreen"     );
   if (value == 0x8B3D48) return("DarkSlateBlue"    );
   if (value == 0x4F4F2F) return("DarkSlateGray"    );
   if (value == 0xD1CE00) return("DarkTurquoise"    );
   if (value == 0xD30094) return("DarkViolet"       );
   if (value == 0x9314FF) return("DeepPink"         );
   if (value == 0xFFBF00) return("DeepSkyBlue"      );
   if (value == 0x696969) return("DimGray"          );
   if (value == 0xFF901E) return("DodgerBlue"       );
   if (value == 0x2222B2) return("FireBrick"        );
   if (value == 0x228B22) return("ForestGreen"      );
   if (value == 0xDCDCDC) return("Gainsboro"        );
   if (value == 0x00D7FF) return("Gold"             );
   if (value == 0x20A5DA) return("Goldenrod"        );
   if (value == 0x808080) return("Gray"             );
   if (value == 0x008000) return("Green"            );
   if (value == 0x2FFFAD) return("GreenYellow"      );
   if (value == 0xF0FFF0) return("Honeydew"         );
   if (value == 0xB469FF) return("HotPink"          );
   if (value == 0x5C5CCD) return("IndianRed"        );
   if (value == 0x82004B) return("Indigo"           );
   if (value == 0xF0FFFF) return("Ivory"            );
   if (value == 0x8CE6F0) return("Khaki"            );
   if (value == 0xFAE6E6) return("Lavender"         );
   if (value == 0xF5F0FF) return("LavenderBlush"    );
   if (value == 0x00FC7C) return("LawnGreen"        );
   if (value == 0xCDFAFF) return("LemonChiffon"     );
   if (value == 0xE6D8AD) return("LightBlue"        );
   if (value == 0x8080F0) return("LightCoral"       );
   if (value == 0xFFFFE0) return("LightCyan"        );
   if (value == 0xD2FAFA) return("LightGoldenrod"   );
   if (value == 0xD3D3D3) return("LightGray"        );
   if (value == 0x90EE90) return("LightGreen"       );
   if (value == 0xC1B6FF) return("LightPink"        );
   if (value == 0x7AA0FF) return("LightSalmon"      );
   if (value == 0xAAB220) return("LightSeaGreen"    );
   if (value == 0xFACE87) return("LightSkyBlue"     );
   if (value == 0x998877) return("LightSlateGray"   );
   if (value == 0xDEC4B0) return("LightSteelBlue"   );
   if (value == 0xE0FFFF) return("LightYellow"      );
   if (value == 0x00FF00) return("Lime"             );
   if (value == 0x32CD32) return("LimeGreen"        );
   if (value == 0xE6F0FA) return("Linen"            );
   if (value == 0xFF00FF) return("Magenta"          );
   if (value == 0x000080) return("Maroon"           );
   if (value == 0xAACD66) return("MediumAquamarine" );
   if (value == 0xCD0000) return("MediumBlue"       );
   if (value == 0xD355BA) return("MediumOrchid"     );
   if (value == 0xDB7093) return("MediumPurple"     );
   if (value == 0x71B33C) return("MediumSeaGreen"   );
   if (value == 0xEE687B) return("MediumSlateBlue"  );
   if (value == 0x9AFA00) return("MediumSpringGreen");
   if (value == 0xCCD148) return("MediumTurquoise"  );
   if (value == 0x8515C7) return("MediumVioletRed"  );
   if (value == 0x701919) return("MidnightBlue"     );
   if (value == 0xFAFFF5) return("MintCream"        );
   if (value == 0xE1E4FF) return("MistyRose"        );
   if (value == 0xB5E4FF) return("Moccasin"         );
   if (value == 0xADDEFF) return("NavajoWhite"      );
   if (value == 0x800000) return("Navy"             );
   if (value == 0xE6F5FD) return("OldLace"          );
   if (value == 0x008080) return("Olive"            );
   if (value == 0x238E6B) return("OliveDrab"        );
   if (value == 0x00A5FF) return("Orange"           );
   if (value == 0x0045FF) return("OrangeRed"        );
   if (value == 0xD670DA) return("Orchid"           );
   if (value == 0xAAE8EE) return("PaleGoldenrod"    );
   if (value == 0x98FB98) return("PaleGreen"        );
   if (value == 0xEEEEAF) return("PaleTurquoise"    );
   if (value == 0x9370DB) return("PaleVioletRed"    );
   if (value == 0xD5EFFF) return("PapayaWhip"       );
   if (value == 0xB9DAFF) return("PeachPuff"        );
   if (value == 0x3F85CD) return("Peru"             );
   if (value == 0xCBC0FF) return("Pink"             );
   if (value == 0xDDA0DD) return("Plum"             );
   if (value == 0xE6E0B0) return("PowderBlue"       );
   if (value == 0x800080) return("Purple"           );
   if (value == 0x0000FF) return("Red"              );
   if (value == 0x8F8FBC) return("RosyBrown"        );
   if (value == 0xE16941) return("RoyalBlue"        );
   if (value == 0x13458B) return("SaddleBrown"      );
   if (value == 0x7280FA) return("Salmon"           );
   if (value == 0x60A4F4) return("SandyBrown"       );
   if (value == 0x578B2E) return("SeaGreen"         );
   if (value == 0xEEF5FF) return("Seashell"         );
   if (value == 0x2D52A0) return("Sienna"           );
   if (value == 0xC0C0C0) return("Silver"           );
   if (value == 0xEBCE87) return("SkyBlue"          );
   if (value == 0xCD5A6A) return("SlateBlue"        );
   if (value == 0x908070) return("SlateGray"        );
   if (value == 0xFAFAFF) return("Snow"             );
   if (value == 0x7FFF00) return("SpringGreen"      );
   if (value == 0xB48246) return("SteelBlue"        );
   if (value == 0x8CB4D2) return("Tan"              );
   if (value == 0x808000) return("Teal"             );
   if (value == 0xD8BFD8) return("Thistle"          );
   if (value == 0x4763FF) return("Tomato"           );
   if (value == 0xD0E040) return("Turquoise"        );
   if (value == 0xEE82EE) return("Violet"           );
   if (value == 0xB3DEF5) return("Wheat"            );
   if (value == 0xFFFFFF) return("White"            );
   if (value == 0xF5F5F5) return("WhiteSmoke"       );
   if (value == 0x00FFFF) return("Yellow"           );
   if (value == 0x32CD9A) return("YellowGreen"      );

   return(ColorToRGBStr(value));
}


/**
 * Convert a MQL color value to its RGB string representation.
 *
 * @param  color value
 *
 * @return string
 */
string ColorToRGBStr(color value) {
   int red   = value       & 0xFF;
   int green = value >>  8 & 0xFF;
   int blue  = value >> 16 & 0xFF;
   return(StringConcatenate(red, ",", green, ",", blue));
}


/**
 * Convert a RGB color triplet to a numeric color value.
 *
 * @param  string value - RGB color triplet, e.g. "100,150,225"
 *
 * @return color - color or NaC (Not-a-Color) in case of errors
 */
color RGBStrToColor(string value) {
   if (!StringLen(value))
      return(NaC);

   string sValues[];
   if (Explode(value, ",", sValues, NULL) != 3)
      return(NaC);

   sValues[0] = StrTrim(sValues[0]); if (!StrIsDigit(sValues[0])) return(NaC);
   sValues[1] = StrTrim(sValues[1]); if (!StrIsDigit(sValues[1])) return(NaC);
   sValues[2] = StrTrim(sValues[2]); if (!StrIsDigit(sValues[2])) return(NaC);

   int r = StrToInteger(sValues[0]); if (r & 0xFFFF00 && 1) return(NaC);
   int g = StrToInteger(sValues[1]); if (g & 0xFFFF00 && 1) return(NaC);
   int b = StrToInteger(sValues[2]); if (b & 0xFFFF00 && 1) return(NaC);

   return(r + (g<<8) + (b<<16));
}


/**
 * Convert a web color name to a numeric color value.
 *
 * @param  string name - web color name
 *
 * @return color - color value or NaC (Not-a-Color) in case of errors
 */
color NameToColor(string name) {
   if (!StringLen(name))
      return(NaC);

   name = StrToLower(name);
   if (StrStartsWith(name, "clr"))
      name = StrSubstr(name, 3);

   if (name == "none"             ) return(CLR_NONE         );
   if (name == "aliceblue"        ) return(AliceBlue        );
   if (name == "antiquewhite"     ) return(AntiqueWhite     );
   if (name == "aqua"             ) return(Aqua             );
   if (name == "aquamarine"       ) return(Aquamarine       );
   if (name == "beige"            ) return(Beige            );
   if (name == "bisque"           ) return(Bisque           );
   if (name == "black"            ) return(Black            );
   if (name == "blanchedalmond"   ) return(BlanchedAlmond   );
   if (name == "blue"             ) return(Blue             );
   if (name == "blueviolet"       ) return(BlueViolet       );
   if (name == "brown"            ) return(Brown            );
   if (name == "burlywood"        ) return(BurlyWood        );
   if (name == "cadetblue"        ) return(CadetBlue        );
   if (name == "chartreuse"       ) return(Chartreuse       );
   if (name == "chocolate"        ) return(Chocolate        );
   if (name == "coral"            ) return(Coral            );
   if (name == "cornflowerblue"   ) return(CornflowerBlue   );
   if (name == "cornsilk"         ) return(Cornsilk         );
   if (name == "crimson"          ) return(Crimson          );
   if (name == "darkblue"         ) return(DarkBlue         );
   if (name == "darkgoldenrod"    ) return(DarkGoldenrod    );
   if (name == "darkgray"         ) return(DarkGray         );
   if (name == "darkgreen"        ) return(DarkGreen        );
   if (name == "darkkhaki"        ) return(DarkKhaki        );
   if (name == "darkolivegreen"   ) return(DarkOliveGreen   );
   if (name == "darkorange"       ) return(DarkOrange       );
   if (name == "darkorchid"       ) return(DarkOrchid       );
   if (name == "darksalmon"       ) return(DarkSalmon       );
   if (name == "darkseagreen"     ) return(DarkSeaGreen     );
   if (name == "darkslateblue"    ) return(DarkSlateBlue    );
   if (name == "darkslategray"    ) return(DarkSlateGray    );
   if (name == "darkturquoise"    ) return(DarkTurquoise    );
   if (name == "darkviolet"       ) return(DarkViolet       );
   if (name == "deeppink"         ) return(DeepPink         );
   if (name == "deepskyblue"      ) return(DeepSkyBlue      );
   if (name == "dimgray"          ) return(DimGray          );
   if (name == "dodgerblue"       ) return(DodgerBlue       );
   if (name == "firebrick"        ) return(FireBrick        );
   if (name == "forestgreen"      ) return(ForestGreen      );
   if (name == "gainsboro"        ) return(Gainsboro        );
   if (name == "gold"             ) return(Gold             );
   if (name == "goldenrod"        ) return(Goldenrod        );
   if (name == "gray"             ) return(Gray             );
   if (name == "green"            ) return(Green            );
   if (name == "greenyellow"      ) return(GreenYellow      );
   if (name == "honeydew"         ) return(Honeydew         );
   if (name == "hotpink"          ) return(HotPink          );
   if (name == "indianred"        ) return(IndianRed        );
   if (name == "indigo"           ) return(Indigo           );
   if (name == "ivory"            ) return(Ivory            );
   if (name == "khaki"            ) return(Khaki            );
   if (name == "lavender"         ) return(Lavender         );
   if (name == "lavenderblush"    ) return(LavenderBlush    );
   if (name == "lawngreen"        ) return(LawnGreen        );
   if (name == "lemonchiffon"     ) return(LemonChiffon     );
   if (name == "lightblue"        ) return(LightBlue        );
   if (name == "lightcoral"       ) return(LightCoral       );
   if (name == "lightcyan"        ) return(LightCyan        );
   if (name == "lightgoldenrod"   ) return(LightGoldenrod   );
   if (name == "lightgray"        ) return(LightGray        );
   if (name == "lightgreen"       ) return(LightGreen       );
   if (name == "lightpink"        ) return(LightPink        );
   if (name == "lightsalmon"      ) return(LightSalmon      );
   if (name == "lightseagreen"    ) return(LightSeaGreen    );
   if (name == "lightskyblue"     ) return(LightSkyBlue     );
   if (name == "lightslategray"   ) return(LightSlateGray   );
   if (name == "lightsteelblue"   ) return(LightSteelBlue   );
   if (name == "lightyellow"      ) return(LightYellow      );
   if (name == "lime"             ) return(Lime             );
   if (name == "limegreen"        ) return(LimeGreen        );
   if (name == "linen"            ) return(Linen            );
   if (name == "magenta"          ) return(Magenta          );
   if (name == "maroon"           ) return(Maroon           );
   if (name == "mediumaquamarine" ) return(MediumAquamarine );
   if (name == "mediumblue"       ) return(MediumBlue       );
   if (name == "mediumorchid"     ) return(MediumOrchid     );
   if (name == "mediumpurple"     ) return(MediumPurple     );
   if (name == "mediumseagreen"   ) return(MediumSeaGreen   );
   if (name == "mediumslateblue"  ) return(MediumSlateBlue  );
   if (name == "mediumspringgreen") return(MediumSpringGreen);
   if (name == "mediumturquoise"  ) return(MediumTurquoise  );
   if (name == "mediumvioletred"  ) return(MediumVioletRed  );
   if (name == "midnightblue"     ) return(MidnightBlue     );
   if (name == "mintcream"        ) return(MintCream        );
   if (name == "mistyrose"        ) return(MistyRose        );
   if (name == "moccasin"         ) return(Moccasin         );
   if (name == "navajowhite"      ) return(NavajoWhite      );
   if (name == "navy"             ) return(Navy             );
   if (name == "oldlace"          ) return(OldLace          );
   if (name == "olive"            ) return(Olive            );
   if (name == "olivedrab"        ) return(OliveDrab        );
   if (name == "orange"           ) return(Orange           );
   if (name == "orangered"        ) return(OrangeRed        );
   if (name == "orchid"           ) return(Orchid           );
   if (name == "palegoldenrod"    ) return(PaleGoldenrod    );
   if (name == "palegreen"        ) return(PaleGreen        );
   if (name == "paleturquoise"    ) return(PaleTurquoise    );
   if (name == "palevioletred"    ) return(PaleVioletRed    );
   if (name == "papayawhip"       ) return(PapayaWhip       );
   if (name == "peachpuff"        ) return(PeachPuff        );
   if (name == "peru"             ) return(Peru             );
   if (name == "pink"             ) return(Pink             );
   if (name == "plum"             ) return(Plum             );
   if (name == "powderblue"       ) return(PowderBlue       );
   if (name == "purple"           ) return(Purple           );
   if (name == "red"              ) return(Red              );
   if (name == "rosybrown"        ) return(RosyBrown        );
   if (name == "royalblue"        ) return(RoyalBlue        );
   if (name == "saddlebrown"      ) return(SaddleBrown      );
   if (name == "salmon"           ) return(Salmon           );
   if (name == "sandybrown"       ) return(SandyBrown       );
   if (name == "seagreen"         ) return(SeaGreen         );
   if (name == "seashell"         ) return(Seashell         );
   if (name == "sienna"           ) return(Sienna           );
   if (name == "silver"           ) return(Silver           );
   if (name == "skyblue"          ) return(SkyBlue          );
   if (name == "slateblue"        ) return(SlateBlue        );
   if (name == "slategray"        ) return(SlateGray        );
   if (name == "snow"             ) return(Snow             );
   if (name == "springgreen"      ) return(SpringGreen      );
   if (name == "steelblue"        ) return(SteelBlue        );
   if (name == "tan"              ) return(Tan              );
   if (name == "teal"             ) return(Teal             );
   if (name == "thistle"          ) return(Thistle          );
   if (name == "tomato"           ) return(Tomato           );
   if (name == "turquoise"        ) return(Turquoise        );
   if (name == "violet"           ) return(Violet           );
   if (name == "wheat"            ) return(Wheat            );
   if (name == "white"            ) return(White            );
   if (name == "whitesmoke"       ) return(WhiteSmoke       );
   if (name == "yellow"           ) return(Yellow           );
   if (name == "yellowgreen"      ) return(YellowGreen      );

   return(NaC);
}


/**
 * Repeats a string.
 *
 * @param  string input - The string to be repeated.
 * @param  int    times - Number of times the input string should be repeated.
 *
 * @return string - the repeated string
 */
string StrRepeat(string input, int times) {
   if (times < 0)
      return(_EMPTY_STR(catch("StrRepeat(1)  invalid parameter times = "+ times, ERR_INVALID_PARAMETER)));

   if (times ==  0)       return("");
   if (!StringLen(input)) return("");

   string output = input;
   for (int i=1; i < times; i++) {
      output = StringConcatenate(output, input);
   }
   return(output);
}


/**
 * Whether the specified value is an order type.
 *
 * @param  int value
 *
 * @return bool
 */
bool IsOrderType(int value) {
   switch (value) {
      case OP_BUY      :
      case OP_SELL     :
      case OP_BUYLIMIT :
      case OP_SELLLIMIT:
      case OP_BUYSTOP  :
      case OP_SELLSTOP :
         return(true);
   }
   return(false);
}


/**
 * Whether the specified value is a pendingg order type.
 *
 * @param  int value
 *
 * @return bool
 */
bool IsPendingOrderType(int value) {
   switch (value) {
      case OP_BUYLIMIT :
      case OP_SELLLIMIT:
      case OP_BUYSTOP  :
      case OP_SELLSTOP :
         return(true);
   }
   return(false);
}


/**
 * Whether the specified value is a long order type.
 *
 * @param  int value
 *
 * @return bool
 */
bool IsLongOrderType(int value) {
   switch (value) {
      case OP_BUY     :
      case OP_BUYLIMIT:
      case OP_BUYSTOP :
         return(true);
   }
   return(false);
}


/**
 * Whether the specified value is a short order type.
 *
 * @param  int value
 *
 * @return bool
 */
bool IsShortOrderType(int value) {
   switch (value) {
      case OP_SELL     :
      case OP_SELLLIMIT:
      case OP_SELLSTOP :
         return(true);
   }
   return(false);
}


/**
 * Whether the specified value is a stop order type.
 *
 * @param  int value
 *
 * @return bool
 */
bool IsStopOrderType(int value) {
   return(value==OP_BUYSTOP || value==OP_SELLSTOP);
}


/**
 * Whether the specified value is a limit order type.
 *
 * @param  int value
 *
 * @return bool
 */
bool IsLimitOrderType(int value) {
   return(value==OP_BUYLIMIT || value==OP_SELLLIMIT);
}


/**
 * Return a human-readable form of a MessageBox push button id.
 *
 * @param  int id - button id
 *
 * @return string
 */
string MessageBoxButtonToStr(int id) {
   switch (id) {
      case IDABORT   : return("IDABORT"   );
      case IDCANCEL  : return("IDCANCEL"  );
      case IDCONTINUE: return("IDCONTINUE");
      case IDIGNORE  : return("IDIGNORE"  );
      case IDNO      : return("IDNO"      );
      case IDOK      : return("IDOK"      );
      case IDRETRY   : return("IDRETRY"   );
      case IDTRYAGAIN: return("IDTRYAGAIN");
      case IDYES     : return("IDYES"     );
      case IDCLOSE   : return("IDCLOSE"   );
      case IDHELP    : return("IDHELP"    );
   }
   return(_EMPTY_STR(catch("MessageBoxButtonToStr(1)  unknown message box button = "+ id, ERR_RUNTIME_ERROR)));
}


/**
 * Formatiert einen numerischen Wert im angegebenen Format und gibt den resultierenden String zurück.
 * The basic mask is "n" or "n.d" where n is the number of digits to the left and d is the number of digits to the right of
 * the decimal point.
 *
 * Mask parameters:
 *
 *   n        = number of digits to the left of the decimal point, e.g. NumberToStr(123.456, "5") => "123"
 *   n.d      = number of left and right digits, e.g. NumberToStr(123.456, "5.2") => "123.45"
 *   n.       = number of left and all right digits, e.g. NumberToStr(123.456, "2.") => "23.456"
 *    .d      = all left and number of right digits, e.g. NumberToStr(123.456, ".2") => "123.45"
 *    .d'     = all left and number of right digits plus 1 additional subpip digit,
 *              e.g. NumberToStr(123.45678, ".4'") => "123.4567'8"
 *    .d+     = + anywhere right of .d in mask: all left and minimum number of right digits,
 *              e.g. NumberToStr(123.456, ".2+") => "123.456"
 *  +n.d      = + anywhere left of n. in mask: plus sign for positive values
 *    R       = round result in the last displayed digit,
 *              e.g. NumberToStr(123.456, "R3.2") => "123.46" or NumberToStr(123.7, "R3") => "124"
 *    ;       = Separatoren tauschen (Europäisches Format), e.g. NumberToStr(123456.789, "6.2;") => "123456,78"
 *    ,       = Tausender-Separatoren einfügen, e.g. NumberToStr(123456.789, "6.2,") => "123,456.78"
 *    ,<char> = Tausender-Separatoren einfügen und auf <char> setzen, e.g. NumberToStr(123456.789, ", 6.2") => "123 456.78"
 *
 * @param  double value
 * @param  string mask
 *
 * @return string - formatierter Wert
 */
string NumberToStr(double value, string mask) {
   string sNumber = value;
   if (StringGetChar(sNumber, 3) == '#')                             // "-1.#IND0000" => NaN
      return(sNumber);                                               // "-1.#INF0000" => Infinite


   // --- Beginn Maske parsen -------------------------
   int maskLen = StringLen(mask);

   // zu allererst Separatorenformat erkennen
   bool swapSeparators = (StringFind(mask, ";") > -1);
      string sepThousand=",", sepDecimal=".";
      if (swapSeparators) {
         sepThousand = ".";
         sepDecimal  = ",";
      }
      int sepPos = StringFind(mask, ",");
   bool separators = (sepPos > -1);
      if (separators) /*&&*/ if (sepPos+1 < maskLen) {
         sepThousand = StringSubstr(mask, sepPos+1, 1);  // user-spezifischen 1000-Separator auslesen und aus Maske löschen
         mask        = StringConcatenate(StringSubstr(mask, 0, sepPos+1), StringSubstr(mask, sepPos+2));
      }

   // white space entfernen
   mask    = StrReplace(mask, " ", "");
   maskLen = StringLen(mask);

   // Position des Dezimalpunktes
   int  dotPos   = StringFind(mask, ".");
   bool dotGiven = (dotPos > -1);
   if (!dotGiven)
      dotPos = maskLen;

   // Anzahl der linken Stellen
   int char, nLeft;
   bool nDigit;
   for (int i=0; i < dotPos; i++) {
      char = StringGetChar(mask, i);
      if ('0' <= char) /*&&*/ if (char <= '9') {
         nLeft = 10*nLeft + char-'0';
         nDigit = true;
      }
   }
   if (!nDigit) nLeft = -1;

   // Anzahl der rechten Stellen
   int nRight, nSubpip;
   if (dotGiven) {
      nDigit = false;
      for (i=dotPos+1; i < maskLen; i++) {
         char = StringGetChar(mask, i);
         if ('0' <= char && char <= '9') {
            nRight = 10*nRight + char-'0';
            nDigit = true;
         }
         else if (nDigit && char==39) {      // 39 => '
            nSubpip = nRight;
            continue;
         }
         else {
            if  (char == '+') nRight = Max(nRight + (nSubpip>0), CountDecimals(value));   // (int) bool
            else if (!nDigit) nRight = CountDecimals(value);
            break;
         }
      }
      if (nDigit) {
         if (nSubpip >  0) nRight++;
         if (nSubpip == 8) nSubpip = 0;
         nRight = Min(nRight, 8);
      }
   }

   // Vorzeichen
   string leadSign = "";
   if (value < 0) {
      leadSign = "-";
   }
   else if (value > 0) {
      int pos = StringFind(mask, "+");
      if (-1 < pos) /*&&*/ if (pos < dotPos)
         leadSign = "+";
   }

   // übrige Modifier
   bool round = (StringFind(mask, "R") > -1);
   // --- Ende Maske parsen ---------------------------


   // --- Beginn Wertverarbeitung ---------------------
   // runden
   if (round)
      value = RoundEx(value, nRight);
   string outStr = value;

   // negatives Vorzeichen entfernen (ist in leadSign gespeichert)
   if (value < 0)
      outStr = StringSubstr(outStr, 1);

   // auf angegebene Länge kürzen
   int dLeft = StringFind(outStr, ".");
   if (nLeft == -1) nLeft = dLeft;
   else             nLeft = Min(nLeft, dLeft);
   outStr = StrSubstr(outStr, StringLen(outStr)-9-nLeft, nLeft+(nRight>0)+nRight);

   // Dezimal-Separator anpassen
   if (swapSeparators)
      outStr = StringSetChar(outStr, nLeft, StringGetChar(sepDecimal, 0));

   // 1000er-Separatoren einfügen
   if (separators) {
      string out1;
      i = nLeft;
      while (i > 3) {
         out1 = StrSubstr(outStr, 0, i-3);
         if (StringGetChar(out1, i-4) == ' ')
            break;
         outStr = StringConcatenate(out1, sepThousand, StringSubstr(outStr, i-3));
         i -= 3;
      }
   }

   // Subpip-Separator einfügen
   if (nSubpip > 0)
      outStr = StringConcatenate(StrLeft(outStr, nSubpip-nRight), "'", StrSubstr(outStr, nSubpip-nRight));

   // Vorzeichen etc. anfügen
   outStr = StringConcatenate(leadSign, outStr);

   //debug("NumberToStr(double="+ DoubleToStr(value, 8) +", mask="+ mask +")    nLeft="+ nLeft +"    dLeft="+ dLeft +"    nRight="+ nRight +"    nSubpip="+ nSubpip +"    outStr=\""+ outStr +"\"");
   catch("NumberToStr(1)");
   return(outStr);
}


/**
 * Gibt die lesbare Version ein oder mehrerer Timeframe-Flags zurück.
 *
 * @param  int flags - Kombination verschiedener Timeframe-Flags
 *
 * @return string
 */
string PeriodFlagsToStr(int flags) {
   string result = "";

   if (!flags)                    result = StringConcatenate(result, "|NULL");
   if (flags & F_PERIOD_M1  && 1) result = StringConcatenate(result, "|M1"  );
   if (flags & F_PERIOD_M5  && 1) result = StringConcatenate(result, "|M5"  );
   if (flags & F_PERIOD_M15 && 1) result = StringConcatenate(result, "|M15" );
   if (flags & F_PERIOD_M30 && 1) result = StringConcatenate(result, "|M30" );
   if (flags & F_PERIOD_H1  && 1) result = StringConcatenate(result, "|H1"  );
   if (flags & F_PERIOD_H4  && 1) result = StringConcatenate(result, "|H4"  );
   if (flags & F_PERIOD_D1  && 1) result = StringConcatenate(result, "|D1"  );
   if (flags & F_PERIOD_W1  && 1) result = StringConcatenate(result, "|W1"  );
   if (flags & F_PERIOD_MN1 && 1) result = StringConcatenate(result, "|MN1" );
   if (flags & F_PERIOD_Q1  && 1) result = StringConcatenate(result, "|Q1"  );

   if (StringLen(result) > 0)
      result = StrSubstr(result, 1);
   return(result);
}


/**
 * Gibt die lesbare Version ein oder mehrerer History-Flags zurück.
 *
 * @param  int flags - Kombination verschiedener History-Flags
 *
 * @return string
 */
string HistoryFlagsToStr(int flags) {
   string result = "";

   if (!flags)                                result = StringConcatenate(result, "|NULL"                    );
   if (flags & HST_BUFFER_TICKS         && 1) result = StringConcatenate(result, "|HST_BUFFER_TICKS"        );
   if (flags & HST_SKIP_DUPLICATE_TICKS && 1) result = StringConcatenate(result, "|HST_SKIP_DUPLICATE_TICKS");
   if (flags & HST_FILL_GAPS            && 1) result = StringConcatenate(result, "|HST_FILL_GAPS"           );
   if (flags & HST_TIME_IS_OPENTIME     && 1) result = StringConcatenate(result, "|HST_TIME_IS_OPENTIME"    );

   if (StringLen(result) > 0)
      result = StrSubstr(result, 1);
   return(result);
}


/**
 * Whether the current program is executed by another one.
 *
 * @return bool
 */
bool IsSuperContext() {
   return(__lpSuperContext != 0);
}


// --------------------------------------------------------------------------------------------------------------------------------------------------


#import "rsfLib1.ex4"
   bool     onBarOpen();
   bool     onCommand(string data[]);

   bool     AquireLock(string mutexName, bool wait);
   int      ArrayPopInt(int array[]);
   int      ArrayPushInt(int array[], int value);
   int      ArrayPushString(string array[], string value);
   string   CharToHexStr(int char);
   string   CreateTempFile(string path, string prefix);
   string   DoubleToStrEx(double value, int digits);
   int      Explode(string input, string separator, string results[], int limit);
   int      GetAccountNumber();
   int      GetCustomLogID();
   string   GetHostName();
   int      GetIniKeys(string fileName, string section, string keys[]);
   string   GetServerName();
   string   GetServerTimezone();
   string   GetWindowText(int hWnd);
   datetime GmtToFxtTime(datetime gmtTime);
   datetime GmtToServerTime(datetime gmtTime);
   int      InitializeStringBuffer(string buffer[], int length);
   bool     ReleaseLock(string mutexName);
   bool     ReverseStringArray(string array[]);
   datetime ServerToGmtTime(datetime serverTime);
   string   StdSymbol();

#import "rsfExpander.dll"
   bool     ec_CustomLogging(int ec[]);
   string   ec_ModuleName(int ec[]);
   string   ec_ProgramName(int ec[]);
   int      ec_SetMqlError(int ec[], int lastError);
   string   EXECUTION_CONTEXT_toStr(int ec[], int outputDebug);
   int      LeaveContext(int ec[]);

#import "kernel32.dll"
   int      GetCurrentProcessId();
   int      GetCurrentThreadId();
   int      GetPrivateProfileIntA(string lpSection, string lpKey, int nDefault, string lpFileName);
   void     OutputDebugStringA(string lpMessage);
   void     RtlMoveMemory(int destAddress, int srcAddress, int bytes);
   int      WinExec(string lpCmdLine, int cmdShow);
   bool     WritePrivateProfileStringA(string lpSection, string lpKey, string lpValue, string lpFileName);

#import "user32.dll"
   int      GetAncestor(int hWnd, int cmd);
   int      GetClassNameA(int hWnd, string lpBuffer, int bufferSize);
   int      GetDlgCtrlID(int hWndCtl);
   int      GetDlgItem(int hDlg, int itemId);
   int      GetParent(int hWnd);
   int      GetTopWindow(int hWnd);
   int      GetWindow(int hWnd, int cmd);
   int      GetWindowThreadProcessId(int hWnd, int lpProcessId[]);
   bool     IsWindow(int hWnd);
   int      MessageBoxA(int hWnd, string lpText, string lpCaption, int style);
   bool     PostMessageA(int hWnd, int msg, int wParam, int lParam);
   int      RegisterWindowMessageA(string lpString);
   int      SendMessageA(int hWnd, int msg, int wParam, int lParam);

#import "winmm.dll"
   bool     PlaySoundA(string lpSound, int hMod, int fSound);
#import


int orders[];


/**
 * @return int
 */
int onInitUser() {
   OutputDebugStringA("onInitUser(0.1)->ReadStatus()...");
   ReadStatus();
   OutputDebugStringA("onInitUser(0.2)  OK");
   return(last_error);
}



/**
 * @return bool
 */
bool ReadStatus() {
   string file = "F:\\Projects\\mt4\\mql\\mql4\\files\\presets\\xauusd.SR.5462.set";

   string sAccount               = GetString(file);
   string sSymbol                = GetString(file);
   string sSequenceId            = GetString(file);
   string sGridDirection         = GetString(file);

   string sCreated               = GetString(file);
   string sGridSize              = GetString(file);
   string sLotSize               = GetString(file);
   string sStartLevel            = GetString(file);
   string sStartConditions       = GetString(file);
   string sStopConditions        = GetString(file);
   string sAutoResume            = GetString(file);
   string sAutoRestart           = GetString(file);
   string sShowProfitInPercent   = GetString(file);
   string sSessionbreakStartTime = GetString(file);
   string sSessionbreakEndTime   = GetString(file);

   string sSessionbreakWaiting   = GetString(file);
   string sStartEquity           = GetString(file);
   string sMaxProfit             = GetString(file);
   string sMaxDrawdown           = GetString(file);
   string sStarts                = GetString(file);
   string sStops                 = GetString(file);
   string sGridBase              = GetString(file);
   string sMissedLevels          = GetString(file);
   string sPendingOrders         = GetString(file);
   string sOpenPositions         = GetString(file);
   string sClosedOrders          = GetString(file);

   string s2SessionbreakWaiting  = GetString(file);
   string s2StartEquity          = GetString(file);
   string s2MaxProfit            = GetString(file);
   string s2MaxDrawdown          = GetString(file);
   string s2Starts               = GetString(file);
   string s2Stops                = GetString(file);
   string s2GridBase             = GetString(file);
   string s2MissedLevels         = GetString(file);
   string s2PendingOrders        = GetString(file);
   string s2OpenPositions        = GetString(file);
   string s2ClosedOrders         = GetString(file);

   string s3SessionbreakWaiting  = GetString(file);
   string s3StartEquity          = GetString(file);
   string s3MaxProfit            = GetString(file);
   string s3MaxDrawdown          = GetString(file);
   string s3Starts               = GetString(file);
   string s3Stops                = GetString(file);
   string s3GridBase             = GetString(file);
   string s3MissedLevels         = GetString(file);
   string s3PendingOrders        = GetString(file);
   string s3OpenPositions        = GetString(file);
   string s3ClosedOrders         = GetString(file);

   string s4SessionbreakWaiting  = GetString(file);
   string s4StartEquity          = GetString(file);
   string s4MaxProfit            = GetString(file);
   string s4MaxDrawdown          = GetString(file);
   string s4Starts               = GetString(file);
   string s4Stops                = GetString(file);
   string s4GridBase             = GetString(file);
   string s4MissedLevels         = GetString(file);
   string s4PendingOrders        = GetString(file);
   string s4OpenPositions        = GetString(file);
   string s4ClosedOrders         = GetString(file);

   string s5SessionbreakWaiting  = GetString(file);
   string s5StartEquity          = GetString(file);
   string s5MaxProfit            = GetString(file);
   string s5MaxDrawdown          = GetString(file);
   string s5Starts               = GetString(file);
   string s5Stops                = GetString(file);
   string s5GridBase             = GetString(file);
   string s5MissedLevels         = GetString(file);
   string s5PendingOrders        = GetString(file);
   string s5OpenPositions        = GetString(file);
   string s5ClosedOrders         = GetString(file);

   string s6SessionbreakWaiting  = GetString(file);
   string s6StartEquity          = GetString(file);
   string s6MaxProfit            = GetString(file);
   string s6MaxDrawdown          = GetString(file);
   string s6Starts               = GetString(file);
   string s6Stops                = GetString(file);
   string s6GridBase             = GetString(file);
   string s6MissedLevels         = GetString(file);
   string s6PendingOrders        = GetString(file);
   string s6OpenPositions        = GetString(file);
   string s6ClosedOrders         = GetString(file);

   string s7SessionbreakWaiting  = GetString(file);
   string s7StartEquity          = GetString(file);
   string s7MaxProfit            = GetString(file);
   string s7MaxDrawdown          = GetString(file);
   string s7Starts               = GetString(file);
   string s7Stops                = GetString(file);
   string s7GridBase             = GetString(file);
   string s7MissedLevels         = GetString(file);
   string s7PendingOrders        = GetString(file);
   string s7OpenPositions        = GetString(file);
   string s7ClosedOrders         = GetString(file);

   string s8SessionbreakWaiting  = GetString(file);
   string s8StartEquity          = GetString(file);
   string s8MaxProfit            = GetString(file);
   string s8MaxDrawdown          = GetString(file);
   string s8Starts               = GetString(file);
   string s8Stops                = GetString(file);
   string s8GridBase             = GetString(file);
   string s8MissedLevels         = GetString(file);
   string s8PendingOrders        = GetString(file);
   string s8OpenPositions        = GetString(file);
   string s8ClosedOrders         = GetString(file);

   string s9SessionbreakWaiting  = GetString(file);
   string s9StartEquity          = GetString(file);
   string s9MaxProfit            = GetString(file);
   string s9MaxDrawdown          = GetString(file);
   string s9Starts               = GetString(file);
   string s9Stops                = GetString(file);
   string s9GridBase             = GetString(file);
   string s9MissedLevels         = GetString(file);
   string s9PendingOrders        = GetString(file);
   string s9OpenPositions        = GetString(file);
   string s9ClosedOrders         = GetString(file);

   string s10SessionbreakWaiting = GetString(file);
   string s10StartEquity         = GetString(file);
   string s10MaxProfit           = GetString(file);
   string s10MaxDrawdown         = GetString(file);
   string s10Starts              = GetString(file);
   string s10Stops               = GetString(file);
   string s10GridBase            = GetString(file);
   string s10MissedLevels        = GetString(file);
   string s10PendingOrders       = GetString(file);
   string s10OpenPositions       = GetString(file);
   string s10ClosedOrders        = GetString(file);

   string s11SessionbreakWaiting = GetString(file);
   string s11StartEquity         = GetString(file);
   string s11MaxProfit           = GetString(file);
   string s11MaxDrawdown         = GetString(file);
   string s11Starts              = GetString(file);
   string s11Stops               = GetString(file);
   string s11GridBase            = GetString(file);
   string s11MissedLevels        = GetString(file);
   string s11PendingOrders       = GetString(file);
   string s11OpenPositions       = GetString(file);
   string s11ClosedOrders        = GetString(file);

   string s12SessionbreakWaiting = GetString(file);
   string s12StartEquity         = GetString(file);
   string s12MaxProfit           = GetString(file);
   string s12MaxDrawdown         = GetString(file);
   string s12Starts              = GetString(file);
   string s12Stops               = GetString(file);
   string s12GridBase            = GetString(file);
   string s12MissedLevels        = GetString(file);
   string s12PendingOrders       = GetString(file);
   string s12OpenPositions       = GetString(file);
   string s12ClosedOrders        = GetString(file);


   OutputDebugStringA("ReadStatus(0.1)  leave");
   return(true);

   ReadStatus.Runtime();
   if (IntInArray(orders, 0)) return(false);
   return(!catch("ReadStatus(20)"));
}


/**
 *
 */
void ReadStatus.Runtime() {
}


/**
 * @param  string s
 *
 * @return string
 */
string GetString(string s) {
   return(s);
}
