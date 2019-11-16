//+------------------------------------------------------------------+
//|                                              StepMA_Color_v2.mq4 |
//|                           Copyright © 2005, TrendLaboratory Ltd. |
//|                                       E-mail: igorad2004@list.ru |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2005, TrendLaboratory Ltd."
#property link      "E-mail: igorad2004@list.ru"

#property indicator_chart_window
#property indicator_buffers 2
#property indicator_color1  Blue
#property indicator_color2  Red

// input parameters
extern int    PeriodWATR = 100;
extern double Kwatr      = 1;
extern int    HighLow    = 0;

// indicator buffers
double UpBuffer[];
double DownBuffer[];


/**
 *
 */
int init() {
   SetIndexBuffer(0, UpBuffer);
   SetIndexBuffer(1, DownBuffer);

   SetIndexStyle(0, DRAW_LINE); SetIndexArrow(0, 159);
   SetIndexStyle(1, DRAW_LINE); SetIndexArrow(1, 159);

   SetIndexDrawBegin(0, PeriodWATR);
   SetIndexDrawBegin(1, PeriodWATR);

   IndicatorShortName("StepMA("+ PeriodWATR +")");
   SetIndexLabel(0, "UpTrendStepMA");
   SetIndexLabel(1, "DownTrendStepMA");

   IndicatorDigits(Digits);
   return(0);
}


/**
 * StepMA_v2
 */
int start() {
   double dK, AvgRange = 0;
   for (int i=PeriodWATR-1; i >= 0; i--) {
       dK = 1+(PeriodWATR-i)/PeriodWATR;
       AvgRange = AvgRange + dK*MathAbs(High[i]-Low[i]);
   }
   double WATR = AvgRange/PeriodWATR;
   int StepSize = Kwatr*WATR/Point;
   Comment(" StepSize = ", StepSize, " point");

   int trend;
   double smin0, smax0, smin1, smax1;

   for (int shift=Bars-1; shift >= 0; shift--) {
      if (HighLow == 0) {
         smax0 = Close[shift] + 2*StepSize*Point;
         smin0 = Close[shift] - 2*StepSize*Point;
      }
      else if (HighLow > 0) {
         smax0 =  Low[shift] + 2*StepSize*Point;
         smin0 = High[shift] - 2*StepSize*Point;
      }
      if (Close[shift] > smax1) trend = +1;
      if (Close[shift] < smin1) trend = -1;

      if (trend > 0 && smin0 < smin1) smin0 = smin1;
      if (trend < 0 && smax0 > smax1) smax0 = smax1;

      if (trend > 0) {
         UpBuffer  [shift] = smin0 + StepSize*Point;
         DownBuffer[shift] = -1.0;
      }
      if (trend < 0) {
         UpBuffer  [shift] = -1.0;
         DownBuffer[shift] = smax0 - StepSize*Point;
      }

      smin1 = smin0;
      smax1 = smax0;
   }
   return(0);
}