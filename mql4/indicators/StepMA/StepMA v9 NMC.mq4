//+------------------------------------------------------------------+
//|                                                    StepMA_v9.mq4 |
//|                             Copyright © 2007-13, TrendLaboratory |
//|            http://finance.groups.yahoo.com/group/TrendLaboratory |
//|                                   E-mail: igorad2003@yahoo.co.uk |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2007-13, TrendLaboratory"
#property link      "http://finance.groups.yahoo.com/group/TrendLaboratory"

#property indicator_chart_window
#property indicator_buffers 3
#property indicator_color1  OrangeRed
#property indicator_width1  2
#property indicator_color2  DeepSkyBlue
#property indicator_width2  2
#property indicator_color3  DeepSkyBlue
#property indicator_width3  2



//---- input parameters
extern int     TimeFrame         =     0;    //TimeFrame in min
extern int     Price             =     0;    //Apply to Price(0-Close;1-Open;2-High;3-Low;4-Median;5-Typical;6-Weighted)
extern int     Length            =     5;    //Length of evaluation
extern double  StepSize          =     0;    //Constant Step Size in pips
extern double  Multiplier        =     2;    //Volatility's Factor or Multiplier
extern double  MinStep           =     0;    //Min Step in pips
extern int     Displace          =     0;    //DispLace or Shift in bars
extern int     ColorMode         =     0;    //Switch of Color mode (1-color)
extern int     StepMAMode        =     0;    //StepMA Mode: 0-new,1-old

extern string  alerts            = "--- Alerts & E-Mails ---";
extern int     AlertMode         =     0;    //Alert mode: 0-off,1-on
extern int     SoundsNumber      =     5;    //Number of sounds after Signal
extern int     SoundsPause       =     5;    //Pause in sec between sounds
extern string  UpSound           = "alert.wav";
extern string  DnSound           = "alert2.wav";
extern int     EmailMode         =     0;    //0-on,1-off
extern int     EmailsNumber      =     1;    //0-on,1-off


//---- indicator buffers
double Line[];
double upTrend1[];
double upTrend2[];
double trend[];

int      draw_begin;
double   __Point, atrmax[2], atrmin[2];
string   short_name, IndicatorName, TF, prevmess, prevemail;
datetime prevtime, pTime, preTime, ptime;
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
  int init()
  {
   if(TimeFrame <= Period()) TimeFrame = Period();
   TF = tf(TimeFrame);
   if(TF  == "Unknown timeframe") TimeFrame = Period();

   IndicatorDigits(MarketInfo(Symbol(),MODE_DIGITS));
//---- indicator line
   IndicatorBuffers(4);

   SetIndexBuffer(0,    Line); SetIndexStyle(0,DRAW_LINE);
   SetIndexBuffer(1,upTrend1); SetIndexStyle(1,DRAW_LINE);
   SetIndexBuffer(2,upTrend2); SetIndexStyle(2,DRAW_LINE);
   SetIndexBuffer(3,   trend);

//---- name for DataWindow and indicator subwindow label
   IndicatorName = WindowExpertName();
   short_name    = IndicatorName + "["+TF+"]("+Price+","+Length+","+DoubleToStr(Multiplier,2)+")";
   IndicatorShortName(short_name);
   SetIndexLabel(0,short_name);
   SetIndexLabel(1,"UpTrend");
   SetIndexLabel(2,"UpTrend");
//----
   SetIndexShift(0,Displace);
   SetIndexShift(1,Displace);
   SetIndexShift(2,Displace);

   SetIndexDrawBegin(0,Length);
   SetIndexDrawBegin(1,Length);
   SetIndexDrawBegin(2,Length);

   __Point = MarketInfo(Symbol(),MODE_POINT)*MathPow(10,Digits%2);
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
//| StepMA_v9                                                        |
//+------------------------------------------------------------------+
int start()
  {
   int i, shift, limit, counted_bars=IndicatorCounted();

   if (counted_bars > 0) limit = Bars - counted_bars - 1;
   if (counted_bars < 0) return(0);
   if (counted_bars < 1)
   {
   limit = Bars - 1;
      for(i=0;i<Bars;i++)
      {
      Line[i]     = EMPTY_VALUE;
      upTrend1[i] = EMPTY_VALUE;
      upTrend2[i] = EMPTY_VALUE;
      }
   }

   if(TimeFrame != Period())
   {
   limit = MathMax(limit,TimeFrame/Period());

      for(shift = 0;shift < limit;shift++)
      {
      int y = iBarShift(NULL,TimeFrame,Time[shift]);

      double line       = iCustom(NULL,TimeFrame,IndicatorName,0,Price,Length,StepSize,Multiplier,MinStep,Displace,ColorMode,StepMAMode,"",AlertMode,SoundsNumber,SoundsPause,UpSound,DnSound,EmailMode,EmailsNumber,0,y);
      double tsteptrend = iCustom(NULL,TimeFrame,IndicatorName,0,Price,Length,StepSize,Multiplier,MinStep,Displace,ColorMode,StepMAMode,"",AlertMode,SoundsNumber,SoundsPause,UpSound,DnSound,EmailMode,EmailsNumber,3,y);

      Line[shift]     = line;
      upTrend1[shift] = EMPTY_VALUE;
      upTrend2[shift] = EMPTY_VALUE;

      if(tsteptrend > 0) upTrend1[shift] = line;
      }

      for(shift = limit;shift >= 0;shift--)
      {
         if(Line[shift] > Line[shift+1] && TimeFrame > Period())
         {
         upTrend2[shift]   = Line[shift];
         upTrend2[shift+1] = Line[shift+1];
         }
      }

   return(0);
   }
   else
   for(shift=limit;shift>=0;shift--)
   {
      if(StepMAMode == 0) Line[shift] = StepMA(Price,Length,StepSize,Multiplier,shift);
      else
      Line[shift] = StepMA_old(Price,Length,StepSize,Multiplier,shift);

   if(MathAbs(Line[shift] - Line[shift+1]) < MinStep*__Point) Line[shift] = Line[shift+1];

      if (ColorMode > 0)
      {
      upTrend1[shift] = EMPTY_VALUE; upTrend2[shift] = EMPTY_VALUE;

      trend[shift] = trend[shift+1];
      if(Line[shift] > Line[shift+1]) trend[shift] = 1;
      if(Line[shift] < Line[shift+1]) trend[shift] =-1;

         if(trend[shift] > 0)
         {
            if(upTrend1[shift+1] == EMPTY_VALUE)
            {
               if(upTrend1[shift+2] == EMPTY_VALUE)
               {
               upTrend1[shift]   = Line[shift];
               upTrend1[shift+1] = Line[shift+1];
               upTrend2[shift]   = EMPTY_VALUE;
               }
               else
               {
               upTrend2[shift]   = Line[shift];
               upTrend2[shift+1] = Line[shift+1];
               upTrend1[shift]   = EMPTY_VALUE;
               }
            }
            else
            {
            upTrend1[shift]  = Line[shift];
            upTrend2[shift]  = EMPTY_VALUE;
            }
         }
      }
   }
//----------
   if(AlertMode > 0)
   {
   bool uptrend = trend[1] > 0 && trend[2] < 0;
   bool dntrend = trend[1] < 0 && trend[2] > 0;

      if(uptrend || dntrend)
      {

         if(isNewBar(TimeFrame))
         {
         BoxAlert(uptrend," : BUY Signal, Open: "+DoubleToStr(Open[0],Digits));
         BoxAlert(dntrend," : SELL Signal, Open: "+DoubleToStr(Open[0],Digits));
         }

      WarningSound(uptrend,SoundsNumber,SoundsPause,UpSound,Time[1]);
      WarningSound(dntrend,SoundsNumber,SoundsPause,DnSound,Time[1]);

         if(EmailMode > 0)
         {
         EmailAlert(uptrend,"BUY","  : BUY Signal, Open: "+DoubleToStr(Open[0],Digits),EmailsNumber);
         EmailAlert(dntrend,"SELL"," : SELL Signal, Open: "+DoubleToStr(Open[0],Digits),EmailsNumber);
         }
      }
   }

   return(0);
}


// StepMA
int    prevbars, steptrend[2];
double smax[2], smin[2];

double StepMA(int pPrice,int length,double size,double mult,int bar)
{

   if(prevtime != Time[bar])
   {
   smin[1]      = smin[0];
   smax[1]      = smax[0];
   steptrend[1] = steptrend[0];
   prevtime     = Time[bar];
   }

   if(bar > Bars - length - 1) return(pPrice);

   double price0 = iMA(NULL,0,1,0,0,pPrice,bar);
   double price1 = iMA(NULL,0,1,0,0,pPrice,bar+1);

      if(length > 0)
      {
      double Sum = 0;

         for (int i=0; i<length; i++)
         {
         double Range = MathAbs(iMA(NULL,0,1,0,0,pPrice,bar+i)-iMA(NULL,0,1,0,0,pPrice,bar+i+1));
         Sum += Range;
         }
      double volty = MathMax(size*__Point,mult*Sum/length);
      }
      else volty = size*__Point;

   smax[0]      = smax[1];
   smin[0]      = smin[1];
   steptrend[0] = steptrend[1];

   if(price0  - smax[1] > 0) steptrend[0] = 1;
   if(-price0 + smin[1] > 0) steptrend[0] =-1;

      if(steptrend[0] > 0)
      {
      smax[0] = MathMax(smax[1],MathMax(price0,price1));
      if(smax[0] < smax[1]) smax[0] = smax[1];
      smin[0] = NormalizeDouble(smax[0] - volty,Digits);
      if(smin[0] < smin[1]) smin[0] = smin[1];
      if(smin[0] > smin[1] && smax[0] == smax[1]) smin[0] = smin[1];
      }
      else
      if(steptrend[0] < 0)
      {
      smin[0] = MathMin(smin[1],MathMin(price0,price1));
      if(smin[0] > smin[1]) smin[0] = smin[1];
      smax[0] = NormalizeDouble(smin[0] + volty,Digits);
      if(smax[0] > smax[1]) smax[0] = smax[1];
      if(smax[0] < smax[1] && smin[0] == smin[1]) smax[0] = smax[1];
      }

   return((smin[0] + smax[0])/2);
}

// StepMA (old version)
double StepMA_old(int price,int length,double size,double mult,int bar)
{
   if(prevtime != Time[bar])
   {
   steptrend[1] = steptrend[0];
   smax[1]      = smax[0];
   smin[1]      = smin[0];
   atrmax[1]    = atrmax[0];
   atrmin[1]    = atrmin[0];
   prevtime     = Time[bar];
   }


   if(bar > Bars - length - 1) return(price);

   double stepma;

   atrmax[0] = atrmax[1];
   atrmin[0] = atrmin[1];
   steptrend[0] = steptrend[1];

      if(length > 0)
      {
      atrmax[0] = MathMax(iATR(NULL,0,length,bar),atrmax[0]);
      atrmin[0] = MathMin(iATR(NULL,0,length,bar),atrmin[0]);

      double volty = MathMax(size*__Point,mult*(atrmax[0] + atrmin[0]));
      }
      else volty = 2*mult*size*__Point;

      if(Price == 0)
      {
      smin[0] = NormalizeDouble(Close[bar] - volty,Digits);
      smax[0] = NormalizeDouble(Close[bar] + volty,Digits);
      }
      else
      {
      smin[0] = NormalizeDouble(High[bar] - volty,Digits);
      smax[0] = NormalizeDouble(Low[bar]  + volty,Digits);
      }

   if(Close[bar] > smax[1]) steptrend[0] = 1;
   if(Close[bar] < smin[1]) steptrend[0] =-1;

      if(steptrend[0] > 0)
      {
      if(smin[0] < smin[1]) smin[0] = smin[1];
      stepma = smin[0] + 0.5 * volty;
      }
      else
      if(steptrend[0] < 0)
      {
      if(smax[0] > smax[1]) smax[0]=smax[1];
      stepma = smax[0] - 0.5 * volty;
      }

   return(stepma);
}

bool isNewBar(int tf)
{
   static datetime tTime;
   bool res=false;

   if(tf >= 0)
   {
      if (iTime(NULL,tf,0)!= tTime)
      {
      res=true;
      tTime=iTime(NULL,tf,0);
      }
   }
   else res = true;

   return(res);
}

bool BoxAlert(bool cond,string text)
{
   string mess = " "+Symbol()+" "+TF + ":" + " " + short_name + text;

   if (cond && mess != prevmess)
   {
   Alert (mess);
   prevmess = mess;
   return(true);
   }

   return(false);
}

bool Pause(int sec)
{
   if(TimeCurrent() >= preTime + sec) {preTime = TimeCurrent(); return(true);}

   return(false);
}

void WarningSound(bool cond,int num,int sec,string sound,datetime ctime)
{
   static int i;

   if(cond)
   {
   if(ctime != ptime) i = 0;
   if(i < num && Pause(sec)) {PlaySound(sound); ptime = ctime; i++;}
   }
}

bool EmailAlert(bool cond,string text1,string text2,int num)
{
   string subj = "New " + text1 +" Signal from " + short_name + "!!!";
   string mess = " "+Symbol()+" "+TF + ":" + " " + short_name + text2;

   if (cond && mess != prevemail)
   {
   if(subj != "" && mess != "") for(int i=0;i<num;i++) SendMail(subj, mess);
   prevemail = mess;
   return(true);
   }

   return(false);
}

string tf(int timeframe)
{
   switch(timeframe)
   {
   case PERIOD_M1:   return("M1");
   case PERIOD_M5:   return("M5");
   case PERIOD_M15:  return("M15");
   case PERIOD_M30:  return("M30");
   case PERIOD_H1:   return("H1");
   case PERIOD_H4:   return("H4");
   case PERIOD_D1:   return("D1");
   case PERIOD_W1:   return("W1");
   case PERIOD_MN1:  return("MN1");
   default:          return("Unknown timeframe");
   }
}
