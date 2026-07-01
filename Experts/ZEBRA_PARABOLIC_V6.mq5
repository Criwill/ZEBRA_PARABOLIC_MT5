//+------------------------------------------------------------------+
//| ZEBRA PARABOLIC V6.00                                           |
//| Project : ZEBRA_PARABOLIC_MT5                                   |
//| Logic   : Parabolic SAR managed / forgotten stop-reverse engine  |
//+------------------------------------------------------------------+
#property strict
#property version   "6.00"
#property description "ZEBRA PARABOLIC V6.00 - Parabolic SAR managed/forgotten engine"

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// INPUTS
//==================================================================
input group "=== Parabolic SAR ==="
input double InpSARStep       = 0.02;
input double InpSARMaximum    = 0.20;
input bool   InpShowSARDots   = true;

input group "=== Trade ==="
input double InpLotSize       = 0.22;
input ulong  InpMagicNumber   = 26062026;
input int    InpDeviationPts  = 30;

input group "=== Partial Profit ==="
input double InpTargetMoney   = 5.00;
input double InpClosePercent  = 90.90;

input group "=== Panel ==="
input bool   InpShowPanel     = true;

//==================================================================
// ENUMS / STRUCTS
//==================================================================
enum ZP_DIRECTION
{
   ZP_DIR_NONE = 0,
   ZP_DIR_BUY  = 1,
   ZP_DIR_SELL = 2
};

enum ZP_TRADE_STATE
{
   ZP_STATE_NONE      = 0,
   ZP_STATE_MANAGED   = 1,
   ZP_STATE_FORGOTTEN = 2
};

struct ZP_SAR_DATA
{
   double       current;
   double       previous;
   ZP_DIRECTION direction;
};

struct ZP_MANAGED_TRADE
{
   ulong             ticket;
   ZP_TRADE_STATE    state;
   ENUM_POSITION_TYPE type;
   bool              partialDone;
   double            initialLot;
   double            currentLot;
   double            entryPrice;
   double            lastSL;
};

//==================================================================
// GLOBALS
//==================================================================
int              g_sarHandle = INVALID_HANDLE;
double           g_sarBuffer[];
ZP_SAR_DATA      g_sar;
ZP_MANAGED_TRADE g_managed;
datetime         g_lastBarTime = 0;
bool             g_isNewBar = false;
string           g_lastAction = "INIT";
int              g_forgottenCount = 0;

//==================================================================
// TEXT HELPERS
//==================================================================
string DirectionToString(const ZP_DIRECTION dir)
{
   if(dir == ZP_DIR_BUY)  return "BUY";
   if(dir == ZP_DIR_SELL) return "SELL";
   return "NONE";
}

string StateToString(const ZP_TRADE_STATE state)
{
   if(state == ZP_STATE_MANAGED)   return "MANAGED";
   if(state == ZP_STATE_FORGOTTEN) return "FORGOTTEN";
   return "NONE";
}

string PositionTypeToString(const ENUM_POSITION_TYPE type)
{
   if(type == POSITION_TYPE_BUY)  return "BUY";
   if(type == POSITION_TYPE_SELL) return "SELL";
   return "UNKNOWN";
}

//==================================================================
// BASIC HELPERS
//==================================================================
double NormalizePrice(const double price)
{
   return NormalizeDouble(price, _Digits);
}

void ResetManagedTrade()
{
   g_managed.ticket      = 0;
   g_managed.state       = ZP_STATE_NONE;
   g_managed.type        = POSITION_TYPE_BUY;
   g_managed.partialDone = false;
   g_managed.initialLot  = 0.0;
   g_managed.currentLot  = 0.0;
   g_managed.entryPrice  = 0.0;
   g_managed.lastSL      = 0.0;
}

void UpdateNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      g_isNewBar = true;
   }
   else
   {
      g_isNewBar = false;
   }
}

//==================================================================
// VOLUME HELPERS
//==================================================================
double VolumeMin()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
}

double VolumeMax()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
}

double VolumeStep()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
}

int VolumeDigits()
{
   double step = VolumeStep();
   int digits = 0;

   while(step > 0.0 && step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }

   return digits;
}

double NormalizeVolumeDown(double lot)
{
   double minLot = VolumeMin();
   double maxLot = VolumeMax();
   double step   = VolumeStep();

   if(lot < minLot)
      return 0.0;

   if(lot > maxLot)
      lot = maxLot;

   if(step <= 0.0)
      return NormalizeDouble(lot, 2);

   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(lot, VolumeDigits());
}

double NormalizeVolumeNearest(double lot)
{
   double minLot = VolumeMin();
   double maxLot = VolumeMax();
   double step   = VolumeStep();

   if(lot < minLot)
      lot = minLot;

   if(lot > maxLot)
      lot = maxLot;

   if(step <= 0.0)
      return NormalizeDouble(lot, 2);

   lot = MathRound(lot / step) * step;
   return NormalizeDouble(lot, VolumeDigits());
}

double CalculatePartialCloseLot(const double currentVolume)
{
   if(InpClosePercent <= 0.0 || InpClosePercent >= 100.0)
      return 0.0;

   double minLot   = VolumeMin();
   double rawClose = currentVolume * InpClosePercent / 100.0;
   double closeLot = NormalizeVolumeDown(rawClose);

   // Keep at least broker minimum volume alive after partial.
   if((currentVolume - closeLot) < minLot)
      closeLot = NormalizeVolumeDown(currentVolume - minLot);

   if(closeLot < minLot)
      return 0.0;

   return closeLot;
}

//==================================================================
// SAR ENGINE
//==================================================================
bool UpdateSAR()
{
   if(g_sarHandle == INVALID_HANDLE)
      return false;

   ArraySetAsSeries(g_sarBuffer, true);
   int copied = CopyBuffer(g_sarHandle, 0, 0, 3, g_sarBuffer);
   if(copied < 3)
      return false;

   g_sar.current  = NormalizePrice(g_sarBuffer[0]);
   g_sar.previous = NormalizePrice(g_sarBuffer[1]);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_sar.current < bid)
      g_sar.direction = ZP_DIR_BUY;
   else if(g_sar.current > ask)
      g_sar.direction = ZP_DIR_SELL;
   else
      g_sar.direction = ZP_DIR_NONE;

   return true;
}

ZP_DIRECTION PositionDirection(const ENUM_POSITION_TYPE type)
{
   if(type == POSITION_TYPE_BUY)
      return ZP_DIR_BUY;

   if(type == POSITION_TYPE_SELL)
      return ZP_DIR_SELL;

   return ZP_DIR_NONE;
}

bool IsFlipAgainstManaged()
{
   if(g_managed.state != ZP_STATE_MANAGED)
      return false;

   ZP_DIRECTION posDir = PositionDirection(g_managed.type);
   if(posDir == ZP_DIR_NONE || g_sar.direction == ZP_DIR_NONE)
      return false;

   return (posDir != g_sar.direction);
}

//==================================================================
// POSITION HELPERS
//==================================================================
bool IsMyPositionSelected()
{
   string symbol = PositionGetString(POSITION_SYMBOL);
   long magic    = PositionGetInteger(POSITION_MAGIC);
   return (symbol == _Symbol && magic == (long)InpMagicNumber);
}

int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket) && IsMyPositionSelected())
         count++;
   }

   return count;
}

bool SelectManagedPosition()
{
   if(g_managed.ticket == 0)
      return false;

   if(!PositionSelectByTicket(g_managed.ticket))
      return false;

   if(!IsMyPositionSelected())
      return false;

   return true;
}

void LoadManagedFromSelected()
{
   g_managed.ticket     = (ulong)PositionGetInteger(POSITION_TICKET);
   g_managed.type       = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   g_managed.state      = ZP_STATE_MANAGED;
   g_managed.currentLot = PositionGetDouble(POSITION_VOLUME);
   g_managed.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   g_managed.lastSL     = PositionGetDouble(POSITION_SL);

   if(g_managed.initialLot <= 0.0)
      g_managed.initialLot = g_managed.currentLot;
}

bool RestoreAnyMyPositionAsManaged()
{
   if(g_managed.state == ZP_STATE_MANAGED && SelectManagedPosition())
      return true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket) && IsMyPositionSelected())
      {
         ResetManagedTrade();
         LoadManagedFromSelected();
         g_lastAction = "RESTORED MANAGED " + IntegerToString((int)ticket);
         return true;
      }
   }

   return false;
}

void SyncManagedState()
{
   if(g_managed.state != ZP_STATE_MANAGED)
      return;

   if(SelectManagedPosition())
   {
      LoadManagedFromSelected();
      return;
   }

   // Managed position disappeared. This usually means SL hit or manual close.
   ResetManagedTrade();
   g_lastAction = "MANAGED CLOSED - NEW CYCLE READY";
}

//==================================================================
// ORDER ENGINE
//==================================================================
bool OpenManagedTrade(const ZP_DIRECTION dir, const string reason)
{
   if(dir == ZP_DIR_NONE)
      return false;

   double lot = NormalizeVolumeNearest(InpLotSize);
   if(lot < VolumeMin())
   {
      g_lastAction = "OPEN FAILED: LOT BELOW MIN";
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPts);

   double sl = NormalizePrice(g_sar.current);
   bool result = false;

   if(dir == ZP_DIR_BUY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(sl >= ask)
      {
         g_lastAction = "BUY BLOCKED: SAR SL NOT BELOW ASK";
         return false;
      }

      result = trade.Buy(lot, _Symbol, ask, sl, 0.0, "ZP6_MANAGED_BUY");
   }
   else if(dir == ZP_DIR_SELL)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(sl <= bid)
      {
         g_lastAction = "SELL BLOCKED: SAR SL NOT ABOVE BID";
         return false;
      }

      result = trade.Sell(lot, _Symbol, bid, sl, 0.0, "ZP6_MANAGED_SELL");
   }

   if(!result)
   {
      g_lastAction = "OPEN FAILED: " + trade.ResultRetcodeDescription();
      Print(g_lastAction, " retcode=", trade.ResultRetcode());
      return false;
   }

   ResetManagedTrade();

   // Locate newly opened position.
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket) && IsMyPositionSelected())
      {
         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         if((dir == ZP_DIR_BUY  && ptype == POSITION_TYPE_BUY) ||
            (dir == ZP_DIR_SELL && ptype == POSITION_TYPE_SELL))
         {
            g_managed.ticket      = ticket;
            g_managed.type        = ptype;
            g_managed.state       = ZP_STATE_MANAGED;
            g_managed.partialDone = false;
            g_managed.initialLot  = PositionGetDouble(POSITION_VOLUME);
            g_managed.currentLot  = PositionGetDouble(POSITION_VOLUME);
            g_managed.entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
            g_managed.lastSL      = PositionGetDouble(POSITION_SL);
            break;
         }
      }
   }

   g_lastAction = reason + " -> OPEN " + DirectionToString(dir);
   Print(g_lastAction, " ticket=", g_managed.ticket, " SL=", DoubleToString(sl, _Digits));
   return true;
}

void TryOpenNewCycle()
{
   if(g_managed.state == ZP_STATE_MANAGED)
      return;

   if(g_sar.direction == ZP_DIR_NONE)
      return;

   // Forgotten positions do not block the next managed cycle.
   OpenManagedTrade(g_sar.direction, "NEW CYCLE");
}

//==================================================================
// TRAILING ENGINE
//==================================================================
void ManageTrailingSAR()
{
   if(!SelectManagedPosition())
      return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double tp        = PositionGetDouble(POSITION_TP);
   double newSL     = NormalizePrice(g_sar.current);

   if(g_managed.type == POSITION_TYPE_BUY)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(newSL <= 0.0 || newSL >= bid)
         return;

      // BUY SL only moves up.
      if(currentSL <= 0.0 || newSL > currentSL)
      {
         if(trade.PositionModify(g_managed.ticket, newSL, tp))
         {
            g_managed.lastSL = newSL;
            g_lastAction = "TRAIL BUY SL -> " + DoubleToString(newSL, _Digits);
         }
      }
   }
   else if(g_managed.type == POSITION_TYPE_SELL)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(newSL <= ask)
         return;

      // SELL SL only moves down.
      if(currentSL <= 0.0 || newSL < currentSL)
      {
         if(trade.PositionModify(g_managed.ticket, newSL, tp))
         {
            g_managed.lastSL = newSL;
            g_lastAction = "TRAIL SELL SL -> " + DoubleToString(newSL, _Digits);
         }
      }
   }
}

//==================================================================
// PARTIAL ENGINE
//==================================================================
void CheckPartialProfit()
{
   if(InpTargetMoney <= 0.0)
      return;

   if(g_managed.partialDone)
      return;

   if(!SelectManagedPosition())
      return;

   double profit = PositionGetDouble(POSITION_PROFIT);
   if(profit < InpTargetMoney)
      return;

   double volume = PositionGetDouble(POSITION_VOLUME);
   double closeLot = CalculatePartialCloseLot(volume);

   if(closeLot < VolumeMin())
   {
      g_lastAction = "PARTIAL SKIPPED: CLOSE LOT TOO SMALL";
      return;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPts);

   if(trade.PositionClosePartial(g_managed.ticket, closeLot))
   {
      g_managed.partialDone = true;

      if(PositionSelectByTicket(g_managed.ticket))
         g_managed.currentLot = PositionGetDouble(POSITION_VOLUME);

      g_lastAction = "PARTIAL CLOSE " + DoubleToString(closeLot, VolumeDigits()) + " LOT";
      Print(g_lastAction, " profit=", DoubleToString(profit, 2));
   }
   else
   {
      g_lastAction = "PARTIAL FAILED: " + trade.ResultRetcodeDescription();
      Print(g_lastAction, " retcode=", trade.ResultRetcode());
   }
}

//==================================================================
// FORGET / FLIP ENGINE
//==================================================================
void ForgetManagedPosition()
{
   if(g_managed.state != ZP_STATE_MANAGED)
      return;

   g_forgottenCount++;

   string oldDir = PositionTypeToString(g_managed.type);
   ulong oldTicket = g_managed.ticket;

   ResetManagedTrade();

   g_lastAction = "FORGET " + oldDir + " TICKET " + IntegerToString((int)oldTicket);
   Print(g_lastAction);
}

void CheckFlipAndReverse()
{
   if(g_managed.state != ZP_STATE_MANAGED)
      return;

   if(!IsFlipAgainstManaged())
      return;

   // Final spec:
   // - If already partialed, old layer becomes forgotten.
   // - New opposite managed trade opens immediately.
   // - If not partialed, do not force close; SL should finish it first.
   if(g_managed.partialDone)
   {
      ZP_DIRECTION newDir = g_sar.direction;
      ForgetManagedPosition();
      OpenManagedTrade(newDir, "FLIP AFTER PARTIAL");
      return;
   }

   g_lastAction = "FLIP DETECTED: WAIT SL NON-PARTIAL";
}

//==================================================================
// PANEL
//==================================================================
void DrawPanel()
{
   if(!InpShowPanel)
   {
      Comment("");
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask - bid) / _Point;
   double profit = 0.0;

   if(SelectManagedPosition())
      profit = PositionGetDouble(POSITION_PROFIT);

   string txt = "";
   txt += "================================\n";
   txt += "ZEBRA PARABOLIC V6.00\n";
   txt += "SAR STOP-AND-REVERSE ENGINE\n";
   txt += "================================\n\n";

   txt += "Symbol        : " + _Symbol + "\n";
   txt += "Timeframe     : " + EnumToString(_Period) + "\n";
   txt += "Magic         : " + IntegerToString((int)InpMagicNumber) + "\n";
   txt += "Spread        : " + DoubleToString(spread, 1) + " points\n\n";

   txt += "SAR Step      : " + DoubleToString(InpSARStep, 3) + "\n";
   txt += "SAR Maximum   : " + DoubleToString(InpSARMaximum, 3) + "\n";
   txt += "SAR Current   : " + DoubleToString(g_sar.current, _Digits) + "\n";
   txt += "SAR Previous  : " + DoubleToString(g_sar.previous, _Digits) + "\n";
   txt += "SAR Direction : " + DirectionToString(g_sar.direction) + "\n\n";

   txt += "Managed State : " + StateToString(g_managed.state) + "\n";
   txt += "Managed Ticket: " + IntegerToString((int)g_managed.ticket) + "\n";
   txt += "Managed Type  : " + PositionTypeToString(g_managed.type) + "\n";
   txt += "Partial Done  : " + (g_managed.partialDone ? "YES" : "NO") + "\n";
   txt += "Initial Lot   : " + DoubleToString(g_managed.initialLot, VolumeDigits()) + "\n";
   txt += "Current Lot   : " + DoubleToString(g_managed.currentLot, VolumeDigits()) + "\n";
   txt += "Floating $    : " + DoubleToString(profit, 2) + "\n";
   txt += "Last SL       : " + DoubleToString(g_managed.lastSL, _Digits) + "\n\n";

   txt += "Target $      : " + DoubleToString(InpTargetMoney, 2) + "\n";
   txt += "Close Percent : " + DoubleToString(InpClosePercent, 2) + "%\n";
   txt += "My Positions  : " + IntegerToString(CountMyPositions()) + "\n";
   txt += "Forgotten     : " + IntegerToString(g_forgottenCount) + "\n\n";

   txt += "New Bar       : " + (g_isNewBar ? "YES" : "NO") + "\n";
   txt += "Bar Time      : " + TimeToString(g_lastBarTime, TIME_DATE | TIME_SECONDS) + "\n";
   txt += "Last Action   : " + g_lastAction + "\n";

   Comment(txt);
}

//==================================================================
// INIT / DEINIT / TICK
//==================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPts);

   ResetManagedTrade();

   g_sarHandle = iSAR(_Symbol, _Period, InpSARStep, InpSARMaximum);
   if(g_sarHandle == INVALID_HANDLE)
   {
      Print("ZP6 ERROR: failed to create iSAR handle");
      return INIT_FAILED;
   }

   ArraySetAsSeries(g_sarBuffer, true);

   if(InpShowSARDots)
      ChartIndicatorAdd(0, 0, g_sarHandle);

   g_lastAction = "V6.00 INIT OK";
   Print("ZEBRA PARABOLIC V6.00 initialized");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_sarHandle != INVALID_HANDLE)
      IndicatorRelease(g_sarHandle);

   Comment("");
   Print("ZEBRA PARABOLIC V6.00 deinitialized");
}

void OnTick()
{
   UpdateNewBar();

   if(!UpdateSAR())
   {
      g_lastAction = "SAR UPDATE FAILED";
      DrawPanel();
      return;
   }

   SyncManagedState();

   if(g_managed.state == ZP_STATE_NONE)
   {
      TryOpenNewCycle();
      DrawPanel();
      return;
   }

   // Order matters:
   // 1. partial first when target money is reached
   // 2. trailing follows current SAR
   // 3. if partialed and SAR flips, forget old and open opposite immediately
   CheckPartialProfit();
   ManageTrailingSAR();
   CheckFlipAndReverse();

   DrawPanel();
}
//+------------------------------------------------------------------+
