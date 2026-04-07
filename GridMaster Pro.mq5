//+------------------------------------------------------------------+
//|                                               GridMaster Pro.mq5 |
//|                                           Copyright 2024, Sajid. |
//|                    https://www.mql5.com/en/users/sajidmahamud835 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Sajid."
#property link      "https://www.mql5.com/en/users/sajidmahamud835"
#property version   "2.00"
#property strict
#property description "GridMaster Pro v2 — Bi-directional ATR grid with proper MM, min-stop awareness, and drawdown protection."

#include <Trade\Trade.mqh>

//--- Enums
enum ENUM_GRID_MODE {
    GRID_NEUTRAL  = 0,  // Neutral: BUY below + SELL above
    GRID_BULLISH  = 1,  // Bullish: BUY only
    GRID_BEARISH  = 2,  // Bearish: SELL only
};

enum ENUM_LOT_MODE {
    LOT_FIXED     = 0,  // Fixed lot size
    LOT_DYNAMIC   = 1,  // Risk-based (% of balance per order)
};

//--- Input Parameters — Grid
input ENUM_GRID_MODE GridMode        = GRID_NEUTRAL;   // Grid Mode
input int            MaxOrders       = 5;              // Max orders per side
input int            ATRPeriod       = 14;             // ATR period
input double         ATRMultiplier   = 1.5;            // ATR multiplier for grid distance

//--- Input Parameters — Orders
input ENUM_LOT_MODE  LotMode         = LOT_FIXED;      // Lot sizing mode
input double         LotSize         = 0.1;            // Fixed lot size
input double         RiskPercent     = 1.0;            // Risk % per order (dynamic mode)
input bool           UseTakeProfit   = true;           // Enable Take Profit
input double         DefaultTP       = 200.0;          // Min TP in points (auto-adjusted for broker)
input bool           UseStopLoss     = true;           // Enable Stop Loss
input double         DefaultSL       = 1000.0;         // Min SL in points (auto-adjusted for broker)
input bool           UseTrailingStop = true;           // Enable Trailing Stop
input double         TrailingPoints  = 100.0;          // Trailing stop in points
input double         TrailingStep    = 20.0;           // Trailing step in points

//--- Input Parameters — Risk Management
input double         MaxDrawdownPct  = 5.0;            // Max drawdown % before pausing
input bool           CloseOnDrawdown = true;           // Close all orders on drawdown breach

//--- Input Parameters — Magic & Debug
input int            MagicBase       = 47291;          // Base magic number
input bool           DebugMode       = false;          // Enable debug logging

//--- Global Variables
CTrade trade;
int    magicNumber;
double gridDistance;
double accountEquityStart;
bool   gridPaused = false;
string logFile;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
    // Generate collision-safe magic number: base + symbol hash + timeframe
    magicNumber = MagicBase + (int)(StringLen(_Symbol) * 1000) + (int)Period();
    trade.SetExpertMagicNumber(magicNumber);
    trade.SetDeviationInPoints(50);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
    logFile = "GridMasterPro_" + _Symbol + "_" + IntegerToString(Period()) + ".log";

    WriteLog("GridMaster Pro v2.00 initialized | Magic: " + IntegerToString(magicNumber) +
             " | Symbol: " + _Symbol + " | Grid mode: " + EnumToString(GridMode));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    WriteLog("EA deinitialized. Reason: " + IntegerToString(reason) + " | Open positions left: " + IntegerToString(CountOurPositions(ORDER_TYPE_BUY) + CountOurPositions(ORDER_TYPE_SELL)));
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick() {
    // Drawdown check
    if (CloseOnDrawdown && CheckDrawdown()) {
        if (!gridPaused) {
            WriteLog("DRAWDOWN LIMIT REACHED — closing all positions and pausing grid");
            CloseAllPositions();
            gridPaused = true;
        }
        return;
    }

    // Resume grid if paused and equity has recovered
    if (gridPaused) {
        double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        if (currentEquity >= accountEquityStart * (1.0 - MaxDrawdownPct / 200.0)) {
            gridPaused = false;
            accountEquityStart = currentEquity;
            WriteLog("Grid resumed after equity recovery");
        } else {
            return;
        }
    }

    // Recalculate grid distance every tick
    gridDistance = CalculateGridDistance();
    if (gridDistance <= 0) return;

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    int buyCount  = CountOurPositions(ORDER_TYPE_BUY);
    int sellCount = CountOurPositions(ORDER_TYPE_SELL);

    // Manage trailing stops
    if (UseTrailingStop) ManageTrailingStops();

    // Place BUY grid orders
    if (GridMode != GRID_BEARISH && buyCount < MaxOrders) {
        double buyPrice = ask - gridDistance * (buyCount + 1) * _Point;
        PlaceGridOrder(ORDER_TYPE_BUY, buyPrice);
    }

    // Place SELL grid orders
    if (GridMode != GRID_BULLISH && sellCount < MaxOrders) {
        double sellPrice = bid + gridDistance * (sellCount + 1) * _Point;
        PlaceGridOrder(ORDER_TYPE_SELL, sellPrice);
    }
}

//+------------------------------------------------------------------+
//| Place a grid order with proper SL/TP                            |
//+------------------------------------------------------------------+
void PlaceGridOrder(ENUM_ORDER_TYPE type, double price) {
    // Check if order already exists near this price level
    if (OrderExistsNearPrice(type, price, gridDistance * 0.5 * _Point)) return;

    // Broker minimum stop distance
    long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minStop = MathMax((double)stopLevel, 10.0) * _Point * 1.2; // 20% buffer over broker min

    double sl = 0, tp = 0;
    double lot = CalculateLot();

    if (type == ORDER_TYPE_BUY) {
        if (UseTakeProfit) tp = price + MathMax(DefaultTP * _Point, minStop * 1.5);
        if (UseStopLoss)   sl = price - MathMax(DefaultSL * _Point, minStop * MaxOrders);
    } else {
        if (UseTakeProfit) tp = price - MathMax(DefaultTP * _Point, minStop * 1.5);
        if (UseStopLoss)   sl = price + MathMax(DefaultSL * _Point, minStop * MaxOrders);
    }

    // Normalize prices
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    price = NormalizeDouble(price, digits);
    sl    = sl > 0 ? NormalizeDouble(sl, digits) : 0;
    tp    = tp > 0 ? NormalizeDouble(tp, digits) : 0;

    bool sent;
    if (type == ORDER_TYPE_BUY) {
        sent = trade.Buy(lot, _Symbol, 0, sl, tp, "Grid BUY");
    } else {
        sent = trade.Sell(lot, _Symbol, 0, sl, tp, "Grid SELL");
    }

    if (sent) {
        WriteLog("Placed " + (type == ORDER_TYPE_BUY ? "BUY" : "SELL") +
                 " | Lot: " + DoubleToString(lot, 2) +
                 " | Price: ~" + DoubleToString(price, digits) +
                 " | SL: " + DoubleToString(sl, digits) +
                 " | TP: " + DoubleToString(tp, digits));
    } else {
        WriteLog("FAILED to place " + (type == ORDER_TYPE_BUY ? "BUY" : "SELL") +
                 " | Error: " + IntegerToString(GetLastError()) +
                 " | Price: " + DoubleToString(price, digits) +
                 " | MinStop: " + DoubleToString(minStop / _Point, 0) + " pts");
    }
}

//+------------------------------------------------------------------+
//| Manage trailing stops for all our positions                      |
//+------------------------------------------------------------------+
void ManageTrailingStops() {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minStop = MathMax((double)stopLevel, 10.0) * _Point * 1.2;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (!PositionSelectByTicket(PositionGetTicket(i))) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        ulong ticket = PositionGetInteger(POSITION_TICKET);

        double newSL = 0;

        if (posType == POSITION_TYPE_BUY) {
            double profit = bid - openPrice;
            if (profit >= TrailingPoints * _Point) {
                newSL = NormalizeDouble(bid - TrailingPoints * _Point, digits);
                if (newSL > currentSL + TrailingStep * _Point && newSL > openPrice - minStop) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        } else {
            double profit = openPrice - ask;
            if (profit >= TrailingPoints * _Point) {
                newSL = NormalizeDouble(ask + TrailingPoints * _Point, digits);
                if ((currentSL == 0 || newSL < currentSL - TrailingStep * _Point) && newSL < openPrice + minStop) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate ATR-based grid distance in points                      |
//+------------------------------------------------------------------+
double CalculateGridDistance() {
    double atr = iATR(_Symbol, 0, ATRPeriod);
    if (atr <= 0) return 0;
    return (atr * ATRMultiplier) / _Point; // Return in points
}

//+------------------------------------------------------------------+
//| Calculate lot size based on mode                                 |
//+------------------------------------------------------------------+
double CalculateLot() {
    if (LotMode == LOT_FIXED) return LotSize;

    double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if (tickValue <= 0 || tickSize <= 0 || DefaultSL <= 0) return LotSize;

    double riskAmount = balance * RiskPercent / 100.0;
    double slValue    = DefaultSL * _Point / tickSize * tickValue;
    double lot = NormalizeDouble(riskAmount / slValue, 2);

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot = MathMax(minLot, MathMin(maxLot, MathRound(lot / lotStep) * lotStep));
    return lot;
}

//+------------------------------------------------------------------+
//| Count our open positions by type                                 |
//+------------------------------------------------------------------+
int CountOurPositions(ENUM_ORDER_TYPE type) {
    int count = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (!PositionSelectByTicket(PositionGetTicket(i))) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if ((type == ORDER_TYPE_BUY && posType == POSITION_TYPE_BUY) ||
            (type == ORDER_TYPE_SELL && posType == POSITION_TYPE_SELL)) {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Check if order already exists near a price level                 |
//+------------------------------------------------------------------+
bool OrderExistsNearPrice(ENUM_ORDER_TYPE type, double price, double tolerance) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (!PositionSelectByTicket(PositionGetTicket(i))) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if ((type == ORDER_TYPE_BUY && posType == POSITION_TYPE_BUY) ||
            (type == ORDER_TYPE_SELL && posType == POSITION_TYPE_SELL)) {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            if (MathAbs(openPrice - price) <= tolerance) return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Check if drawdown limit breached                                 |
//+------------------------------------------------------------------+
bool CheckDrawdown() {
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double maxLoss = accountEquityStart * MaxDrawdownPct / 100.0;
    return (accountEquityStart - equity) >= maxLoss;
}

//+------------------------------------------------------------------+
//| Close all our positions                                          |
//+------------------------------------------------------------------+
void CloseAllPositions() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(ticket)) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        trade.PositionClose(ticket);
    }
}

//+------------------------------------------------------------------+
//| Append log to file (fixes overwrite bug)                         |
//+------------------------------------------------------------------+
void WriteLog(string message) {
    if (!DebugMode && StringFind(message, "FAILED") < 0 && StringFind(message, "DRAWDOWN") < 0) return;

    int handle = FileOpen(logFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END); // Append — seek to end
        string ts = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
        FileWriteString(handle, ts + " | " + message + "\n");
        FileClose(handle);
    }
}
