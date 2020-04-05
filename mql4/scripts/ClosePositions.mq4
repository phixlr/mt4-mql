/**
 * Schlie�t die angegebenen Positionen. Ohne zus�tzliche Parameter werden alle offenen Positionen geschlossen.
 */
#include <stddefines.mqh>
int   __INIT_FLAGS__[] = {INIT_NO_BARS_REQUIRED};
int __DEINIT_FLAGS__[];

#property show_inputs

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string Close.Symbols      = "";                               // Symbole:      kommagetrennt
extern string Close.Direction    = "";                               // (B)uy|(L)ong|(S)ell|(S)hort
extern string Close.Tickets      = "";                               // Tickets:      kommagetrennt, mit oder ohne f�hrendem "#"
extern string Close.MagicNumbers = "";                               // MagicNumbers: kommagetrennt
extern string Close.Comments     = "";                               // Kommentare:   kommagetrennt, Pr�fung per OrderComment().StrStartsWithI(value)

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/script.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>


string orderSymbols [];
int    orderType = OP_UNDEFINED;
int    orderTickets [];
int    orderMagics  [];
string orderComments[];


/**
 * Initialisierung
 *
 * @return int - Fehlerstatus
 */
int onInit() {
   // Parametervalidierung
   // Close.Symbols
   string values[], sValue;
   int size = Explode(StrToUpper(Close.Symbols), ",", values, NULL);
   for (int i=0; i < size; i++) {
      sValue = StrTrim(values[i]);
      if (StringLen(sValue) > 0)
         ArrayPushString(orderSymbols, sValue);
   }

   // Close.Direction
   string direction = StrToUpper(StrTrim(Close.Direction));
   if (StringLen(direction) > 0) {
      switch (StringGetChar(direction, 0)) {
         case 'B':
         case 'L': orderType = OP_BUY;  Close.Direction = "long";  break;
         case 'S': orderType = OP_SELL; Close.Direction = "short"; break;
         default:
            return(HandleScriptError("onInit(1)", "Invalid parameter Close.Direction = \""+ Close.Direction +"\"", ERR_INVALID_INPUT_PARAMETER));
      }
   }

   // Close.Tickets
   size = Explode(Close.Tickets, ",", values, NULL);
   for (i=0; i < size; i++) {
      sValue = StrTrim(values[i]);
      if (StringLen(sValue) > 0) {
         if (StrStartsWith(sValue, "#"))
            sValue = StrTrim(StrSubstr(sValue, 1));
         if (!StrIsDigit(sValue))
            return(HandleScriptError("onInit(2)", "Invalid parameter in Close.Tickets = \""+ values[i] +"\"", ERR_INVALID_INPUT_PARAMETER));
         int iValue = StrToInteger(sValue);
         if (iValue <= 0)
            return(HandleScriptError("onInit(3)", "Invalid parameter in Close.Tickets = \""+ values[i] +"\"", ERR_INVALID_INPUT_PARAMETER));
         ArrayPushInt(orderTickets, iValue);
      }
   }

   // Close.MagicNumbers
   size = Explode(Close.MagicNumbers, ",", values, NULL);
   for (i=0; i < size; i++) {
      sValue = StrTrim(values[i]);
      if (StringLen(sValue) > 0) {
         if (!StrIsDigit(sValue))
            return(HandleScriptError("onInit(4)", "Invalid parameter Close.MagicNumbers = \""+ Close.MagicNumbers +"\"", ERR_INVALID_INPUT_PARAMETER));
         iValue = StrToInteger(sValue);
         if (iValue <= 0)
            return(HandleScriptError("onInit(5)", "Invalid parameter Close.MagicNumbers = \""+ Close.MagicNumbers +"\"", ERR_INVALID_INPUT_PARAMETER));
         ArrayPushInt(orderMagics, iValue);
      }
   }

   // Close.Comments
   size = Explode(Close.Comments, ",", values, NULL);
   for (i=0; i < size; i++) {
      sValue = StrTrim(values[i]);
      if (StringLen(sValue) > 0)
         ArrayPushString(orderComments, sValue);
   }

   return(catch("onInit(6)"));
}


/**
 * Main-Funktion
 *
 * @return int - Fehlerstatus
 */
int onStart() {
   int orders = OrdersTotal();
   int tickets[]; ArrayResize(tickets, 0);


   // zu schlie�ende Positionen selektieren
   for (int i=0; i < orders; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))               // FALSE: w�hrend des Auslesens wurde in einem anderen Thread eine Order geschlossen oder gestrichen
         break;
      if (OrderType() > OP_SELL)                                     // Nicht-Positionen �berspringen
         continue;

      bool close = true;
      if (close) close = (ArraySize(orderSymbols)== 0            || StringInArray(orderSymbols, OrderSymbol()));
      if (close) close = (orderType              == OP_UNDEFINED || OrderType() == orderType);
      if (close) close = (ArraySize(orderTickets)== 0            || IntInArray(orderTickets, OrderTicket()));
      if (close) close = (ArraySize(orderMagics) == 0            || IntInArray(orderMagics, OrderMagicNumber()));
      if (close) {
         int commentsSize = ArraySize(orderComments);
         for (int n=0; n < commentsSize; n++) {
            if (StrStartsWithI(OrderComment(), orderComments[n]))
               break;
         }
         if (commentsSize != 0)                                      // Comments angegeben
            close = (n < commentsSize);                              // Order pa�t, wenn break getriggert
      }
      if (close) /*&&*/ if (!IntInArray(tickets, OrderTicket()))
         ArrayPushInt(tickets, OrderTicket());
   }
   bool isInput = (ArraySize(orderSymbols) + ArraySize(orderTickets) + ArraySize(orderMagics) + ArraySize(orderComments) + (orderType!=OP_UNDEFINED)) != 0;


   // Positionen schlie�en
   int selected = ArraySize(tickets);
   if (selected > 0) {
      PlaySoundEx("Windows Notify.wav");
      int button = MessageBox(ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Do you really want to close "+ ifString(isInput, "the specified "+ selected, "all "+ selected +" open") +" position"+ Pluralize(selected) +"?", __NAME(), MB_ICONQUESTION|MB_OKCANCEL);
      if (button == IDOK) {
         int oeFlags = NULL;
         int oes[][ORDER_EXECUTION.intSize];
         if (!OrdersClose(tickets, 0.1, Orange, oeFlags, oes)) return(ERR_RUNTIME_ERROR);
         ArrayResize(oes, 0);
      }
   }
   else {
      PlaySoundEx("Windows Notify.wav");
      MessageBox("No "+ ifString(isInput, "matching", "open") +" positions found.", __NAME(), MB_ICONEXCLAMATION|MB_OK);
   }

   return(last_error);
}
