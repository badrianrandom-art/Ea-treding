//+------------------------------------------------------------------+
//| GOLD BOT 1.0 - XAUUSD Pending Breakout + Trailing Stop           |
//| Demo-first EA. Review broker symbol specifications before use.   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "XAUUSD Buy Stop/Sell Stop breakout with OCO and trailing stop"

#include <Trade/Trade.mqh>
CTrade trade;

input ulong  InpMagicNumber        = 16112026;
input double InpRiskPercent        = 0.25;   // Approximate risk per position (% balance)
input double InpDailyLossLimit     = 1.00;   // Stop placing new orders at this daily equity loss (%)
input double InpPipPrice           = 0.10;   // User convention: 1 pip = 0.10 XAUUSD price
input double InpPendingDistancePips= 10.0;   // Buy Stop above Ask / Sell Stop below Bid
input double InpStopLossPips       = 20.0;   // Initial SL distance from pending entry
input double InpTrailingPips       = 20.0;   // Trailing distance from current market price
input double InpMaxSpreadPoints    = 0.0;    // 0 = disabled; set after checking Exness symbol specs
input int    InpDeviationPoints    = 30;
input bool   InpRequireGoldSymbol  = true;
input bool   InpDemoOnly           = true;   // Refuse to trade on real accounts

string dailyBalanceKey;
string dailyDateKey;

bool IsGoldSymbol()
{
   string s = _Symbol;
   StringToUpper(s);
   return (StringFind(s, "XAUUSD") >= 0);
}

string DateStamp()
{
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

void RefreshDailyBaseline()
{
   string today = DateStamp();
   if(!GlobalVariableCheck(dailyDateKey) || GlobalVariableGet(dailyDateKey) != StringToDouble(today))
   {
      GlobalVariableSet(dailyDateKey, StringToDouble(today));
      GlobalVariableSet(dailyBalanceKey, AccountInfoDouble(ACCOUNT_BALANCE));
   }
}

bool DailyLossLimitReached()
{
   RefreshDailyBaseline();
   double startBalance = GlobalVariableGet(dailyBalanceKey);
   if(startBalance <= 0.0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (startBalance - equity) / startBalance * 100.0;
   return (lossPct >= InpDailyLossLimit);
}

double PipDistance(const double pips)
{
   return pips * InpPipPrice;
}

double NormalizePrice(const double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tickSize > 0.0)
      return NormalizeDouble(MathRound(price / tickSize) * tickSize, digits);
   return NormalizeDouble(price, digits);
}

bool SpreadIsAcceptable()
{
   if(InpMaxSpreadPoints <= 0.0) return true;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   return ((tick.ask - tick.bid) / _Point <= InpMaxSpreadPoints);
}

bool HasOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

int CountOurPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         count++;
   }
   return count;
}

void DeleteOurPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
      {
         if(!trade.OrderDelete(ticket))
            Print("Failed deleting pending order #", ticket, ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
   }
}

int VolumeDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   for(int d = 0; d <= 8; d++)
      if(MathAbs(step - NormalizeDouble(step, d)) < 0.000000001) return d;
   return 2;
}

double NormalizeVolumeDown(double volume)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || volume < minVol) return 0.0;
   volume = MathMin(maxVol, MathFloor(volume / step) * step);
   if(volume < minVol) return 0.0;
   return NormalizeDouble(volume, VolumeDigits());
}

double CalculateLots(const ENUM_ORDER_TYPE calcType, const double entry, const double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double pnlOneLot = 0.0;
   if(!OrderCalcProfit(calcType, _Symbol, 1.0, entry, sl, pnlOneLot))
   {
      Print("OrderCalcProfit failed. Error=", GetLastError());
      return 0.0;
   }
   double lossOneLot = MathAbs(pnlOneLot);
   if(lossOneLot <= 0.0) return 0.0;
   return NormalizeVolumeDown(riskMoney / lossOneLot);
}

bool StopsDistanceIsValid(const double entry, const double sl)
{
   double minDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(MathAbs(entry - sl) + 0.00000001 < minDistance) return false;
   return true;
}

bool PlaceOcoPair()
{
   if(InpRequireGoldSymbol && !IsGoldSymbol()) return false;
   if(InpDemoOnly && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
   {
      Print("GOLD BOT safety lock: real account detected. DemoOnly is enabled.");
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(DailyLossLimitReached() || !SpreadIsAcceptable()) return false;
   if(HasOurPosition() || CountOurPendingOrders() > 0) return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;

   double pendingDistance = PipDistance(InpPendingDistancePips);
   double slDistance = PipDistance(InpStopLossPips);
   double buyEntry = NormalizePrice(tick.ask + pendingDistance);
   double sellEntry = NormalizePrice(tick.bid - pendingDistance);
   double buySL = NormalizePrice(buyEntry - slDistance);
   double sellSL = NormalizePrice(sellEntry + slDistance);

   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if((buyEntry - tick.ask) < minStop || (tick.bid - sellEntry) < minStop ||
      !StopsDistanceIsValid(buyEntry, buySL) || !StopsDistanceIsValid(sellEntry, sellSL))
   {
      Print("Pending order skipped: requested 10-pip entry/20-pip SL conflicts with broker minimum stop distance.");
      return false;
   }

   double buyLots = CalculateLots(ORDER_TYPE_BUY, buyEntry, buySL);
   double sellLots = CalculateLots(ORDER_TYPE_SELL, sellEntry, sellSL);
   if(buyLots <= 0.0 || sellLots <= 0.0)
   {
      Print("Pending pair skipped: calculated lot is below broker minimum or risk calculation failed.");
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool buySent = trade.BuyStop(buyLots, buyEntry, _Symbol, buySL, 0.0, ORDER_TIME_GTC, 0, "GOLD BOT BUY STOP");
   if(!buySent)
   {
      Print("Buy Stop failed. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }

   bool sellSent = trade.SellStop(sellLots, sellEntry, _Symbol, sellSL, 0.0, ORDER_TIME_GTC, 0, "GOLD BOT SELL STOP");
   if(!sellSent)
   {
      Print("Sell Stop failed; deleting Buy Stop to avoid one-sided setup. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      DeleteOurPendingOrders();
      return false;
   }

   Print("OCO pair placed. BuyStop=", buyEntry, " SellStop=", sellEntry,
         " SL distance=", InpStopLossPips, " pips. Lots buy/sell=", buyLots, "/", sellLots);
   return true;
}

void ManageOCOAndTrailing()
{
   // If either pending order becomes a live position, remove the opposite pending order.
   if(HasOurPosition())
      DeleteOurPendingOrders();

   double trailDistance = PipDistance(InpTrailingPips);
   double minModifyDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double freezeDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
   double requiredDistance = MathMax(minModifyDistance, freezeDistance);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double newSL = 0.0;

      if(type == POSITION_TYPE_BUY)
      {
         // Starts trailing immediately; SL never moves down.
         newSL = NormalizePrice(tick.bid - trailDistance);
         if((tick.bid - newSL) < requiredDistance) continue;
         if(currentSL == 0.0 || newSL > currentSL + _Point)
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
               Print("BUY trailing modification failed #", ticket, ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         // Starts trailing immediately; SL never moves up.
         newSL = NormalizePrice(tick.ask + trailDistance);
         if((newSL - tick.ask) < requiredDistance) continue;
         if(currentSL == 0.0 || newSL < currentSL - _Point)
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
               Print("SELL trailing modification failed #", ticket, ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }
   }
}

int OnInit()
{
   if(InpPipPrice <= 0.0 || InpPendingDistancePips <= 0.0 || InpStopLossPips <= 0.0 || InpTrailingPips <= 0.0 || InpRiskPercent <= 0.0)
   {
      Print("Invalid input: pip size, distances and risk must be positive.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRequireGoldSymbol && !IsGoldSymbol())
   {
      Print("Attach GOLD BOT to an XAUUSD chart. Broker suffixes are supported if symbol contains XAUUSD.");
      return INIT_FAILED;
   }
   if(InpDemoOnly && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
   {
      Print("GOLD BOT safety lock: this build is demo-only. Use an Exness demo account.");
      return INIT_FAILED;
   }

   dailyBalanceKey = StringFormat("GB10_BAL_%I64d_%I64u", AccountInfoInteger(ACCOUNT_LOGIN), InpMagicNumber);
   dailyDateKey = StringFormat("GB10_DAY_%I64d_%I64u", AccountInfoInteger(ACCOUNT_LOGIN), InpMagicNumber);
   RefreshDailyBaseline();
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   Print("GOLD BOT 1.10 initialized. Pending breakout + OCO + trailing. Demo only.");
   Print("Pip convention: 1 pip = ", InpPipPrice, " price units; pending=", InpPendingDistancePips,
         " pips; initial SL/trailing=", InpStopLossPips, "/", InpTrailingPips, " pips.");
   return INIT_SUCCEEDED;
}

// React to an entry deal as soon as the terminal reports it, then cancel the other side.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
      DeleteOurPendingOrders();
}

void OnTick()
{
   ManageOCOAndTrailing();

   // Do not leave dormant pending orders active after the daily loss guard is hit.
   if(DailyLossLimitReached())
   {
      DeleteOurPendingOrders();
      return;
   }

   if(HasOurPosition()) return;
   if(CountOurPendingOrders() == 0)
      PlaceOcoPair();
}
//+------------------------------------------------------------------+
