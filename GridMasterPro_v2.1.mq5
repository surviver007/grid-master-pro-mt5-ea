//+------------------------------------------------------------------+
//|                                        GridMasterPro_v2.1.mq5     |
//|                                           Copyright 2026, wangxiaozhi.  |
//|                    https://www.mql5.com/en/users/wangxiaozhi  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, wangxiaozhi."
#property link      "https://www.mql5.com/en/users/wangxiaozhi"
#property version   "2.10"
#property strict
#property description "GridMaster Pro v2.1 — Fixed bi-directional ATR grid with pending orders, proper MM, and drawdown protection."

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
input double         DefaultTP       = 200.0;          // TP distance in points
input bool           UseStopLoss     = true;           // Enable Stop Loss
input double         DefaultSL       = 1000.0;         // SL distance in points
input bool           UseTrailingStop = true;           // Enable Trailing Stop
input double         TrailingPoints  = 100.0;          // Trailing activation in points
input double         TrailingStep    = 20.0;           // Min trailing move in points

//--- Input Parameters — Risk Management
input double         MaxDrawdownPct  = 5.0;            // Max drawdown % before pausing
input bool           CloseOnDrawdown = true;           // Close all on drawdown breach

//--- Input Parameters — Filters & Debug
input int            MaxSpreadPoints = 50;             // Max spread (points) to allow trading
input int            MagicBase       = 47291;          // Base magic number
input bool           DebugMode       = false;          // Enable debug logging

//--- Global Variables
CTrade   trade;
int      magicNumber;
double   gridDistance;           // Grid spacing in price units (not points)
double   accountEquityStart;     // Baseline equity — never reset after recovery
bool     gridPaused   = false;
string   logFile;
datetime lastBarTime;
int      atrHandle;
int      symbolDigits;
double   symbolPoint;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
    // Collision-safe magic number
    magicNumber = MagicBase + (int)(StringLen(_Symbol) * 1000) + (int)Period();
    trade.SetExpertMagicNumber(magicNumber);
    trade.SetDeviationInPoints(50);
    trade.SetTypeFilling(DetectFillType());

    symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    symbolPoint  = _Point;

    accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
    logFile     = "GridMasterPro_" + _Symbol + "_" + IntegerToString(Period()) + ".log";
    lastBarTime = 0;

    // Create ATR indicator handle (proper MQL5 way)
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if (atrHandle == INVALID_HANDLE) {
        WriteLog("FAILED to create ATR indicator handle");
        return INIT_FAILED;
    }

    // Initial grid distance
    gridDistance = CalculateGridDistance();
    if (gridDistance <= 0) {
        WriteLog("WARNING: Initial ATR is zero, grid will activate on first valid bar");
    }

    WriteLog("GridMaster Pro v2.10 initialized | Magic: " + IntegerToString(magicNumber) +
             " | Symbol: " + _Symbol + " | Grid: " + EnumToString(GridMode));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    CancelAllPendingOrders();
    if (atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    WriteLog("EA deinitialized. Reason: " + IntegerToString(reason) +
             " | Positions: " + IntegerToString(CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL)));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // --- Precondition checks ---
    if (!IsMarketActive()) return;

    // --- Drawdown protection ---
    if (CloseOnDrawdown && CheckDrawdown()) {
        if (!gridPaused) {
            WriteLog("DRAWDOWN LIMIT REACHED — closing all and pausing");
            CloseAllPositions();
            CancelAllPendingOrders();
            gridPaused = true;
        }
        return;
    }

    // --- Recovery check (baseline NOT reset) ---
    if (gridPaused) {
        if (CheckRecovery()) {
            gridPaused = false;
            WriteLog("Grid resumed after equity recovery");
        } else {
            return;
        }
    }

    // --- Update grid distance on new bar only ---
    bool newBar = IsNewBar();
    if (newBar) {
        double newDist = CalculateGridDistance();
        if (newDist > 0) gridDistance = newDist;
    }

    if (gridDistance <= 0) return;

    // --- Spread filter ---
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if (spread > MaxSpreadPoints) {
        if (newBar && DebugMode)
            WriteLog("Spread too high: " + IntegerToString((int)spread) + " pts, skipping");
        return;
    }

    // --- Trailing stop management ---
    if (UseTrailingStop) ManageTrailingStops();

    // --- Grid pending order management ---
    ManageGridOrders();
}

//+------------------------------------------------------------------+
//| Detect broker-supported fill type                                |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillType() {
    long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if ((fillMode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if ((fillMode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Check if market is active and trading is allowed                 |
//+------------------------------------------------------------------+
bool IsMarketActive() {
    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
    if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

    long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (tradeMode != SYMBOL_TRADE_MODE_FULL) return false;

    // Weekend check
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.day_of_week == 0 || dt.day_of_week == 6) return false;

    return true;
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar() {
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if (currentBarTime != lastBarTime) {
        lastBarTime = currentBarTime;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| ATR-based grid distance (in price units) using completed bar     |
//+------------------------------------------------------------------+
double CalculateGridDistance() {
    if (atrHandle == INVALID_HANDLE) return 0;
    double atr[];
    ArraySetAsSeries(atr, true);
    // Read bar index 1 (last completed bar) for stability
    if (CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return 0;
    if (atr[0] <= 0) return 0;
    return atr[0] * ATRMultiplier;   // Price units, not points
}

//+------------------------------------------------------------------+
//| Manage pending grid orders — place BuyLimit/SellLimit            |
//+------------------------------------------------------------------+
void ManageGridOrders() {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double minDist = GetMinStopDistance();   // Min distance from current price

    // --- BUY side ---
    if (GridMode != GRID_BEARISH) {
        int buyPos  = CountPositions(POSITION_TYPE_BUY);
        int buyPend = CountPendingOrders(ORDER_TYPE_BUY_LIMIT);

        if (buyPos + buyPend < MaxOrders) {
            double nextLevel;
            double lowest = GetLowestBuyEntry();

            if (lowest > 0) {
                // Expand grid: place one level below the lowest existing entry
                nextLevel = lowest - gridDistance;
            } else {
                // First BUY level: one grid distance below current Ask
                nextLevel = ask - gridDistance;
            }

            // BuyLimit must be below Ask with at least minDist gap
            if (nextLevel > 0 && nextLevel <= ask - minDist) {
                if (!OrderExistsNearPrice(nextLevel, gridDistance * 0.3)) {
                    if (CheckMargin(ORDER_TYPE_BUY, nextLevel)) {
                        PlaceGridOrder(ORDER_TYPE_BUY_LIMIT, nextLevel);
                    } else if (DebugMode) {
                        WriteLog("Insufficient margin for BUY LIMIT at " + DoubleToString(nextLevel, symbolDigits));
                    }
                }
            }
        }
    }

    // --- SELL side ---
    if (GridMode != GRID_BULLISH) {
        int sellPos  = CountPositions(POSITION_TYPE_SELL);
        int sellPend = CountPendingOrders(ORDER_TYPE_SELL_LIMIT);

        if (sellPos + sellPend < MaxOrders) {
            double nextLevel;
            double highest = GetHighestSellEntry();

            if (highest > 0) {
                nextLevel = highest + gridDistance;
            } else {
                nextLevel = bid + gridDistance;
            }

            // SellLimit must be above Bid with at least minDist gap
            if (nextLevel > 0 && nextLevel >= bid + minDist) {
                if (!OrderExistsNearPrice(nextLevel, gridDistance * 0.3)) {
                    if (CheckMargin(ORDER_TYPE_SELL, nextLevel)) {
                        PlaceGridOrder(ORDER_TYPE_SELL_LIMIT, nextLevel);
                    } else if (DebugMode) {
                        WriteLog("Insufficient margin for SELL LIMIT at " + DoubleToString(nextLevel, symbolDigits));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Place a pending grid order with SL/TP                           |
//+------------------------------------------------------------------+
void PlaceGridOrder(ENUM_ORDER_TYPE type, double price) {
    double minStop = GetMinStopDistance();
    double sl = 0, tp = 0;
    double lot = CalculateLot();

    if (type == ORDER_TYPE_BUY_LIMIT) {
        if (UseTakeProfit) tp = price + MathMax(DefaultTP * symbolPoint, minStop);
        if (UseStopLoss)   sl = price - MathMax(DefaultSL * symbolPoint, minStop * MaxOrders);
    } else { // SELL_LIMIT
        if (UseTakeProfit) tp = price - MathMax(DefaultTP * symbolPoint, minStop);
        if (UseStopLoss)   sl = price + MathMax(DefaultSL * symbolPoint, minStop * MaxOrders);
    }

    // Normalize all prices
    price = NormalizeDouble(price, symbolDigits);
    sl    = sl > 0 ? NormalizeDouble(sl, symbolDigits) : 0;
    tp    = tp > 0 ? NormalizeDouble(tp, symbolDigits) : 0;

    bool sent;
    if (type == ORDER_TYPE_BUY_LIMIT) {
        sent = trade.BuyLimit(lot, price, _Symbol, sl, tp, 0, "Grid BUY");
    } else {
        sent = trade.SellLimit(lot, price, _Symbol, sl, tp, 0, "Grid SELL");
    }

    string dir = (type == ORDER_TYPE_BUY_LIMIT) ? "BUY LIMIT" : "SELL LIMIT";
    if (sent) {
        WriteLog("Placed " + dir +
                 " | Lot: " + DoubleToString(lot, 2) +
                 " | Price: " + DoubleToString(price, symbolDigits) +
                 " | SL: " + DoubleToString(sl, symbolDigits) +
                 " | TP: " + DoubleToString(tp, symbolDigits));
    } else {
        WriteLog("FAILED " + dir +
                 " | Error: " + IntegerToString(GetLastError()) +
                 " | Price: " + DoubleToString(price, symbolDigits));
    }
}

//+------------------------------------------------------------------+
//| Trailing stop — only moves SL to lock in profit                  |
//+------------------------------------------------------------------+
void ManageTrailingStops() {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;

        ENUM_POSITION_TYPE posType   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentTP = PositionGetDouble(POSITION_TP);

        if (posType == POSITION_TYPE_BUY) {
            double profit = bid - openPrice;
            if (profit >= TrailingPoints * symbolPoint) {
                double newSL = NormalizeDouble(bid - TrailingPoints * symbolPoint, symbolDigits);
                // Only move SL upward, and only by at least TrailingStep
                if (newSL > currentSL + TrailingStep * symbolPoint) {
                    // Ensure SL is at or above open price (lock in profit)
                    if (newSL >= openPrice) {
                        trade.PositionModify(ticket, newSL, currentTP);
                    }
                }
            }
        } else { // SELL
            double profit = openPrice - ask;
            if (profit >= TrailingPoints * symbolPoint) {
                double newSL = NormalizeDouble(ask + TrailingPoints * symbolPoint, symbolDigits);
                // Only move SL downward, and only by at least TrailingStep
                if (currentSL == 0 || newSL < currentSL - TrailingStep * symbolPoint) {
                    // Ensure SL is at or below open price (lock in profit)
                    if (newSL <= openPrice) {
                        trade.PositionModify(ticket, newSL, currentTP);
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size                                               |
//+------------------------------------------------------------------+
double CalculateLot() {
    if (LotMode == LOT_FIXED) return LotSize;

    double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if (tickValue <= 0 || tickSize <= 0 || DefaultSL <= 0) return LotSize;

    double riskAmount = balance * RiskPercent / 100.0;
    double slTicks    = DefaultSL * symbolPoint / tickSize;
    double slValue    = slTicks * tickValue;
    if (slValue <= 0) return LotSize;

    double lot = riskAmount / slValue;

    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    // Round down to lotStep (never round up — would exceed risk budget)
    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Margin check before placing order                                |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double price) {
    double margin;
    double lot = CalculateLot();
    // OrderCalcMargin needs market order type, not pending
    ENUM_ORDER_TYPE calcType = (type == ORDER_TYPE_BUY_LIMIT) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if (!OrderCalcMargin(calcType, _Symbol, lot, price, margin)) return false;
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    return margin <= freeMargin * 0.95;   // Keep 5% buffer
}

//+------------------------------------------------------------------+
//| Count open positions by position type                            |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE posType) {
    int count = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Count pending orders by order type                               |
//+------------------------------------------------------------------+
int CountPendingOrders(ENUM_ORDER_TYPE orderType) {
    int count = 0;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == orderType)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Get lowest BUY entry price (position or pending)                 |
//+------------------------------------------------------------------+
double GetLowestBuyEntry() {
    double lowest = 0;

    // Scan open positions
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            double p = PositionGetDouble(POSITION_PRICE_OPEN);
            if (lowest == 0 || p < lowest) lowest = p;
        }
    }
    // Scan pending orders
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT) {
            double p = OrderGetDouble(ORDER_PRICE_OPEN);
            if (lowest == 0 || p < lowest) lowest = p;
        }
    }
    return lowest;
}

//+------------------------------------------------------------------+
//| Get highest SELL entry price (position or pending)               |
//+------------------------------------------------------------------+
double GetHighestSellEntry() {
    double highest = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
            double p = PositionGetDouble(POSITION_PRICE_OPEN);
            if (p > highest) highest = p;
        }
    }
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_LIMIT) {
            double p = OrderGetDouble(ORDER_PRICE_OPEN);
            if (p > highest) highest = p;
        }
    }
    return highest;
}

//+------------------------------------------------------------------+
//| Check if position or pending order exists near a price           |
//+------------------------------------------------------------------+
bool OrderExistsNearPrice(double price, double tolerance) {
    // Check open positions
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if (MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) <= tolerance)
            return true;
    }
    // Check pending orders
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        if (MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) <= tolerance)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Broker minimum stop distance in price units                      |
//+------------------------------------------------------------------+
double GetMinStopDistance() {
    long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    return MathMax((double)stopLevel, 10.0) * symbolPoint * 1.2;
}

//+------------------------------------------------------------------+
//| Drawdown check                                                   |
//+------------------------------------------------------------------+
bool CheckDrawdown() {
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double maxLoss = accountEquityStart * MaxDrawdownPct / 100.0;
    return (accountEquityStart - equity) >= maxLoss;
}

//+------------------------------------------------------------------+
//| Recovery check — baseline is NOT reset                           |
//+------------------------------------------------------------------+
bool CheckRecovery() {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    // Resume when equity recovers to at least halfway back to baseline
    return equity >= accountEquityStart * (1.0 - MaxDrawdownPct / 200.0);
}

//+------------------------------------------------------------------+
//| Close all our positions                                          |
//+------------------------------------------------------------------+
void CloseAllPositions() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        trade.PositionClose(ticket);
    }
}

//+------------------------------------------------------------------+
//| Cancel all our pending orders                                    |
//+------------------------------------------------------------------+
void CancelAllPendingOrders() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        trade.OrderDelete(ticket);
    }
}

//+------------------------------------------------------------------+
//| Logging — key events always logged, debug mode logs everything   |
//+------------------------------------------------------------------+
void WriteLog(string message) {
    bool isImportant =
        StringFind(message, "FAILED") >= 0 ||
        StringFind(message, "DRAWDOWN") >= 0 ||
        StringFind(message, "Placed") >= 0 ||
        StringFind(message, "closed") >= 0 ||
        StringFind(message, "initialized") >= 0 ||
        StringFind(message, "deinitialized") >= 0 ||
        StringFind(message, "resumed") >= 0 ||
        StringFind(message, "WARNING") >= 0;

    if (!DebugMode && !isImportant) return;

    int handle = FileOpen(logFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        string ts = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
        FileWriteString(handle, ts + " | " + message + "\n");
        FileClose(handle);
    }
}
//+------------------------------------------------------------------+
