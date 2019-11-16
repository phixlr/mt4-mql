//+------------------------------------------------------------------+
//|                                                       StepMA.mq4 |
//|                              Copyright © 2010, Farshad Saremifar |
//|                                      Farshad.Saremifar@gmail.com |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2010, Farshad Saremifar"
#property link      "Farshad.Saremifar@gmail.com"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_color1 White
#property indicator_color2 Blue
#property indicator_color3 Red

//---- input parameters
extern int MAPeriod1=0;
extern int MAPeriod2=21;
extern int MAPeriod3=220;
extern int     Length      = 10;      // Volty Length
extern double  Kv          = 0.75;     // Sensivity Factor
extern int     StepSize    = 2000;       // Constant Step Size (if need)
extern int     MA_Mode     = 0;       // Volty MA Mode : 0-SMA, 1-LWMA
extern int     Advance     = 0;       // Offset
extern double  Percentage  = 0;       // Percentage of Up/Down Moving
extern bool    HighLow     = false;   // High/Low Mode Switch (more sensitive)
extern int     ColorMode   = 0;       // Color Mode Switch
extern int     BarsNumber  = 0;

//---- indicator buffers
double LineBuffer[];
double UpBuffer[];
double DnBuffer[];
double smin[];
double smax[];
double trend[];
double Step[];
double StepMA=0, ATR0=0,ATRmax=-100000,ATRmin=1000000;
int limit;

//---- StepSize Calculation

   double StepSizeCalc ( int Len, double Km, int Size, int k)
   {

   double result;
   if( Size==0 )
   {
        double AvgRange=0;
        for (int i=Len-1;i>=0;i--)
        {
            if(MA_Mode==0) double alfa= 1.0; else alfa= 1.0+1.0*(Len-i)/Len;
            AvgRange+= alfa*(High[k+i]-Low[k+i]);
        }
        ATR0 = AvgRange/Len;

   if (ATR0>ATRmax) ATRmax=ATR0;
   if (ATR0<ATRmin) ATRmin=ATR0;

   result=MathRound(0.5*Km*(ATRmax+ATRmin)/Point);
   }
   else
   result=Km*StepSize;

   return(result);
   }

//---- StepMA Calculation

   double StepMACalc (bool HL, double Size, int k)
   {
   int counted_bars=IndicatorCounted();
   double result;

   if (HL)
     {
     smax[k]=Low[k]+2.0*Size*Point;
     smin[k]=High[k]-2.0*Size*Point;
     }
   else
     {
     smax[k]=Close[k]+2.0*Size*Point;
     smin[k]=Close[k]-2.0*Size*Point;
     }
     if (counted_bars==0){smax[limit+1]=smax[limit];smin[limit+1]=smin[limit];trend[limit+1]=0;}

     trend[k]=trend[k+1];

     if (Close[k]>smax[k+1]) trend[k]=1;

     if (Close[k]<smin[k+1]) trend[k]=-1;

     if(trend[k]>0)
     {
     if(smin[k]<smin[k+1]) smin[k]=smin[k+1];
     result=smin[k]+Size*Point;
     }
     else
     {
     if(smax[k]>smax[k+1]) smax[k]=smax[k+1];
     result=smax[k]-Size*Point;
     }
     //Print (" k=",k," trend=",trend[k], " res=",result," Smax=", smax[k], " Smin=", smin[k]);


     return(result);
     }
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
  int init()
  {
   string short_name;
//---- indicator line
   IndicatorBuffers(7);

   SetIndexStyle(0,DRAW_LINE,STYLE_SOLID,2);
   SetIndexStyle(1,DRAW_LINE);
   SetIndexStyle(2,DRAW_LINE);

   SetIndexArrow(1,159);
   SetIndexArrow(2,159);

   SetIndexBuffer(0,LineBuffer);
   SetIndexBuffer(1,UpBuffer);
   SetIndexBuffer(2,DnBuffer);

   SetIndexShift(0,Advance);
   SetIndexShift(1,Advance);
   SetIndexShift(2,Advance);

   SetIndexBuffer(3,smin);
   SetIndexBuffer(4,smax);
   SetIndexBuffer(5,trend);
   SetIndexBuffer(6,Step);

//---- name for DataWindow and indicator subwindow label
   short_name="StepMA("+Length+","+Kv+","+StepSize+")";
   IndicatorShortName(short_name);
   SetIndexLabel(0,short_name);
   SetIndexLabel(1,"UpTrend");
   SetIndexLabel(2,"DownTrend");
//----
   SetIndexDrawBegin(0,Length);
   SetIndexDrawBegin(1,Length);
   SetIndexDrawBegin(2,Length);
//----
   return(0);
   }
//+------------------------------------------------------------------+
//| Custor indicator deinitialization function                       |
//+------------------------------------------------------------------+
int deinit()
  {
//----

//----
   return(0);
  }
//+------------------------------------------------------------------+
//| StepMA_v7                                                        |
//+------------------------------------------------------------------+
int start()
  {
   int shift, counted_bars=IndicatorCounted();

   if ( BarsNumber > 0 ) int Nbars=BarsNumber; else Nbars=Bars;
   if ( counted_bars > 0 )  limit=Nbars-counted_bars;
   if ( counted_bars < 0 )  return(0);
   if ( counted_bars ==0 )  limit=Nbars-Length-1;

   for(shift=limit;shift>=0;shift--)
   {

    Step[shift] = StepSizeCalc( Length, Kv, StepSize, shift);

   Comment (" StepSize= ", Step[shift]);

   StepMA = StepMACalc ( HighLow, Step[shift], shift)+Percentage/100.0*Step[shift]*Point;
   double ma,mv;
   if (MAPeriod1>0) {
   mv = (iMA(NULL,0,MAPeriod1,0,MODE_SMA,PRICE_CLOSE,shift)+iMA(NULL,0,MAPeriod2,0,MODE_SMA,PRICE_CLOSE,shift)+iMA(NULL,0,MAPeriod3,0,MODE_SMA,PRICE_CLOSE,shift))/3;
   ma =(mv+StepMA)/2;
   }
   else ma=StepMA;
   LineBuffer[shift]=ma;


UpBuffer[shift]=StepMA-Step[shift]*Point;
DnBuffer[shift]=StepMA+Step[shift]*Point;


   }
   return(0);
 }
