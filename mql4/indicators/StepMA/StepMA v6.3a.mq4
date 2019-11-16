//+------------------------------------------------------------------+
//| StepMA_v6.1mq4 |
//| Copyright ? 2005, TrendLaboratory Ltd. |
//| E-mail: igorad2004@list.ru |
//| Updated By: Johnsun Ye
//+------------------------------------------------------------------+
#property copyright "Copyright ? 2005, TrendLaboratory Ltd."
#property link "E-mail: igorad2004@list.ru"

#property indicator_chart_window
#property indicator_buffers 1

#property indicator_color1 Yellow
#property  indicator_width1  2

//---- input parameters
extern int Length=10; // ATR Length
extern double Kv=1.0; // Sensivity Factor
extern int MA_Period=5;
extern string Note = "Deviations set from 0.05 to 0.15" ;
extern double Deviations=0.12; //0.05~0.15
extern int StepSize=0; // Constant Step Size (if need)
extern int Advance=0; // Offset
extern bool HighLow=false; // High/Low Mode Switch (more sensitive)

//---- indicator buffers
double LineBuffer[];
double smin[];
double smax[];
//+------------------------------------------------------------------+
//| Custom indicator initialization function |
//+------------------------------------------------------------------+
int init()
{
string short_name;
//---- indicator line
IndicatorBuffers(3);

SetIndexStyle(0,DRAW_LINE,STYLE_SOLID,2);
SetIndexShift(0,Advance);
SetIndexBuffer(0,LineBuffer);

SetIndexBuffer(1,smin);

SetIndexBuffer(2,smax);

IndicatorDigits(MarketInfo(Symbol(),MODE_DIGITS));
//---- name for DataWindow and indicator subwindow label
short_name="StepMA("+StepSize+","+Kv+","+StepSize+ ")";
IndicatorShortName(short_name);
//SetIndexLabel(0,short_name);
SetIndexLabel(1,"UpTrend");
SetIndexLabel(2,"DownTrend");
//----
SetIndexEmptyValue(0,0.0);
SetIndexEmptyValue(1,0.0);
SetIndexEmptyValue(2,0.0);

//SetIndexDrawBegin(0,Length);
//SetIndexDrawBegin(1,Length);
//SetIndexDrawBegin(2,Length);
//----
return(0);
}

//+------------------------------------------------------------------+
//| StepMA_v6 |
//+------------------------------------------------------------------+
int start()
{
int i,shift,trend,Step;
double ATRmin=10000,ATRmax=0,AvgRange,ATR0;


for(shift=Bars-Length-1;shift>=0;shift--)
{

if( StepSize==0 )
{
AvgRange=0;
for (i=Length-1;i>=0;i--)
{
AvgRange+= (High[shift+i]-Low[shift+i]);
}
ATR0 = AvgRange/Length;

if (ATR0>ATRmax) ATRmax=ATR0;
if (ATR0<ATRmin) ATRmin=ATR0;

Step=0.5*Kv*(ATRmax+ATRmin)/Point;
}
else
{Step=Kv*StepSize;}

Comment (" StepSize= ", Step);


if (HighLow)
{
   //smax[shift]=Low[shift]+2.0*Step*Point;
   //smin[shift]=High[shift]-2.0*Step*Point;

   smax[shift] = iEnvelopes(NULL,0,MA_Period,MODE_SMA,0,PRICE_HIGH,Deviations,MODE_UPPER,shift);
   smin[shift] = iEnvelopes(NULL,0,MA_Period,MODE_SMA,0,PRICE_LOW,Deviations,MODE_LOWER,shift);

}
else
{
 //smax[shift]=Close[shift]+2.0*Step*Point;
  //smin[shift]=Close[shift]-2.0*Step*Point;

  smax[shift] = iEnvelopes(NULL,0,MA_Period,MODE_SMA,0,PRICE_CLOSE,Deviations,MODE_UPPER,shift);
  smin[shift] = iEnvelopes(NULL,0,MA_Period,MODE_SMA,0,PRICE_CLOSE,Deviations,MODE_LOWER,shift);
  double MID= NormalizeDouble((smax[shift]+smin[shift])/2.0,Digits);
}



//------------------------------------------
if (Close[shift]>smax[shift+1]) trend=1;
if (Close[shift]<smin[shift+1]) trend=-1;

if(trend>0)
{
  if(smin[shift]<smin[shift+1]) smin[shift]=smin[shift+1];
   LineBuffer[shift]=smin[shift]+2.0*Step*Point;

}
else
{
   if(smax[shift]>smax[shift+1]) smax[shift]=smax[shift+1];
   LineBuffer[shift]=smax[shift]-2.0*Step*Point;

}

}
return(0);
}
