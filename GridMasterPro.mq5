//+------------------------------------------------------------------+
//|                                              GridMasterPro.mq5   |
//|                                    Copyright 2026, wangxiaozhi.  |
//|                                           https://www.mql5.com   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, wangxiaozhi."
#property link      "https://www.mql5.com"
#property version   "3.0"
#property strict
#property description "布林带突破 + 动态间距加仓策略（含冷却期）"

#include <Trade\Trade.mqh>

//--- 布林带设置
input int            BB_Period        = 20;             // 布林带周期
input double         BB_Deviation     = 2.0;            // 布林带标准差倍数

//--- 交易设置
input double         InitialLot       = 0.01;           // 初始手数
input double         FirstTP_ATR      = 1.0;            // 首单止盈ATR倍数
input int            FlatAddCount     = 3;              // 前N笔等量加仓（之后启用斐波那契）
input int            MaxPositions     = 50;             // 单方向最大持仓数
input double         ATRAddMultiplier = 2.0;            // 加仓间距基础ATR倍数
input double         ATRStepIncrement = 0.5;            // 加仓间距递增（每多一笔增加ATR倍数）
input int            CooldownBars     = 20;             // 回撤恢复后冷却K线数
input int            ATRPeriod        = 5;              // ATR周期

//--- 出场设置
input double         ProfitTargetPercent = 0.3;         // 整体盈利目标（余额%）

//--- 风控管理
input double         MaxDrawdownPct   = 30.0;           // 最大回撤百分比
input int            MaxSpreadPoints  = 50;             // 最大点差（点）
input bool           AllowBuy         = true;           // 允许做多
input bool           AllowSell        = false;           // 允许做空
input int            MagicBase        = 47291;          // 魔术号
input bool           DebugMode        = false;          // 调试模式

//--- 全局变量
CTrade   trade;
int      magicNumber;
double   accountEquityStart;
string   logFile;
int      bbHandle;
int      atrHandle;
int      symbolDigits;
double   symbolPoint;
datetime cooldownUntil;

//+------------------------------------------------------------------+
//| EA 初始化                                                        |
//+------------------------------------------------------------------+
int OnInit() {
    // 防冲突魔术号
    int symbolHash = 0;
    for (int i = 0; i < (int)StringLen(_Symbol); i++)
        symbolHash = (symbolHash * 31 + (int)StringGetCharacter(_Symbol, i)) & 0x7FFF;
    magicNumber = MagicBase + symbolHash + (int)Period();
    trade.SetExpertMagicNumber(magicNumber);
    trade.SetDeviationInPoints(50);
    trade.SetTypeFilling(DetectFillType());

    symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    symbolPoint  = _Point;

    accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
    logFile     = "GridMasterPro_" + _Symbol + "_" + IntegerToString(Period()) + ".log";

    // 创建布林带指标句柄
    bbHandle = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
    if (bbHandle == INVALID_HANDLE) {
        WriteLog("FAILED to create BB indicator handle");
        return INIT_FAILED;
    }

    // 创建 ATR 指标句柄
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if (atrHandle == INVALID_HANDLE) {
        WriteLog("FAILED to create ATR indicator handle");
        return INIT_FAILED;
    }

    WriteLog("GridMaster Pro v3.0 initialized | Magic: " + IntegerToString(magicNumber) +
             " | Symbol: " + _Symbol + " | Strategy: BB Breakout + Dynamic Grid + Cooldown");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 反初始化                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    if (bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
    if (atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    WriteLog("EA deinitialized. Reason: " + IntegerToString(reason) +
             " | Positions: " + IntegerToString(CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL)));
}

//+------------------------------------------------------------------+
//| EA Tick 函数                                                     |
//+------------------------------------------------------------------+
void OnTick() {
    if (!IsMarketActive()) return;

    // --- 高水位更新 ---
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if (currentEquity > accountEquityStart)
        accountEquityStart = currentEquity;

    // --- 回撤保护 ---
    if (CheckDrawdown()) {
        WriteLog("DRAWDOWN LIMIT REACHED — closing all positions");
        CloseAllPositions();
        accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
        cooldownUntil = iTime(_Symbol, PERIOD_CURRENT, 0) + CooldownBars * PeriodSeconds(PERIOD_CURRENT);
        WriteLog("Drawdown recovery — equity baseline reset to " + DoubleToString(accountEquityStart, 2) +
                 " | Cooldown until: " + TimeToString(cooldownUntil));
        return;
    }

    // --- 点差过滤 ---
    if ((long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;

    // --- 读取布林带和ATR ---
    double bbUpper[], bbLower[], atrVal[];
    ArraySetAsSeries(bbUpper, true);
    ArraySetAsSeries(bbLower, true);
    ArraySetAsSeries(atrVal, true);

    if (CopyBuffer(bbHandle, 1, 0, 1, bbUpper) <= 0) return;   // 上轨 = buffer 1
    if (CopyBuffer(bbHandle, 2, 0, 1, bbLower) <= 0) return;   // 下轨 = buffer 2
    if (CopyBuffer(atrHandle, 0, 0, 1, atrVal) <= 0) return;

    double upperBB  = bbUpper[0];
    double lowerBB  = bbLower[0];
    double atr      = atrVal[0];
    double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // --- 1. 整体盈利目标平仓（多笔持仓时） ---
    CheckBasketExit(POSITION_TYPE_BUY);
    CheckBasketExit(POSITION_TYPE_SELL);

    // --- 2. 单笔止盈检查（仅1笔持仓时，基于ATR倍数） ---
    CheckSingleTP(POSITION_TYPE_BUY, atr);
    CheckSingleTP(POSITION_TYPE_SELL, atr);

    // --- 3. 冷却期检查 ---
    bool inCooldown = (cooldownUntil > 0 && iTime(_Symbol, PERIOD_CURRENT, 0) < cooldownUntil);

    // --- 4. 布林带突破入场 ---
    int buyCount  = CountPositions(POSITION_TYPE_BUY);
    int sellCount = CountPositions(POSITION_TYPE_SELL);

    // 做多：Ask突破布林带上轨，且当前无多头持仓
    if (!inCooldown && AllowBuy && ask > upperBB && buyCount == 0) {
        double lot = NormalizeLot(InitialLot);
        if (CheckMargin(ORDER_TYPE_BUY, ask, lot)) {
            if (trade.Buy(lot, _Symbol, ask, 0, 0, "BB BUY #1")) {
                WriteLog("BB BREAKOUT BUY #1 | Price: " + DoubleToString(ask, symbolDigits) +
                         " | BB Upper: " + DoubleToString(upperBB, symbolDigits) +
                         " | Lot: " + DoubleToString(lot, 2));
            }
        }
    }

    // 做空：Bid跌破布林带下轨，且当前无空头持仓
    if (!inCooldown && AllowSell && bid < lowerBB && sellCount == 0) {
        double lot = NormalizeLot(InitialLot);
        if (CheckMargin(ORDER_TYPE_SELL, bid, lot)) {
            if (trade.Sell(lot, _Symbol, bid, 0, 0, "BB SELL #1")) {
                WriteLog("BB BREAKOUT SELL #1 | Price: " + DoubleToString(bid, symbolDigits) +
                         " | BB Lower: " + DoubleToString(lowerBB, symbolDigits) +
                         " | Lot: " + DoubleToString(lot, 2));
            }
        }
    }

    // --- 5. 马丁格尔加仓（动态间距） ---
    if (atr > 0) {
        if (AllowBuy)  CheckMartingale(POSITION_TYPE_BUY, ask, atr);
        if (AllowSell) CheckMartingale(POSITION_TYPE_SELL, bid, atr);
    }
}

//+------------------------------------------------------------------+
//| 单笔止盈：仅1笔持仓且盈利达到ATR倍数时平仓                       |
//+------------------------------------------------------------------+
void CheckSingleTP(ENUM_POSITION_TYPE dir, double atr) {
    if (CountPositions(dir) != 1) return;
    if (atr <= 0) return;

    double tpDistance = atr * FirstTP_ATR;

    if (dir == POSITION_TYPE_BUY) {
        double entryPrice = GetExtremeEntryPrice(dir);
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if (bid - entryPrice >= tpDistance) {
            double profit = GetTotalProfit(dir);
            ClosePositionsByType(dir);
            WriteLog("Single BUY TP hit | Entry: " + DoubleToString(entryPrice, symbolDigits) +
                     " | Exit: " + DoubleToString(bid, symbolDigits) +
                     " | Profit: " + DoubleToString(profit, 2));
        }
    } else {
        double entryPrice = GetExtremeEntryPrice(dir);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        if (entryPrice - ask >= tpDistance) {
            double profit = GetTotalProfit(dir);
            ClosePositionsByType(dir);
            WriteLog("Single SELL TP hit | Entry: " + DoubleToString(entryPrice, symbolDigits) +
                     " | Exit: " + DoubleToString(ask, symbolDigits) +
                     " | Profit: " + DoubleToString(profit, 2));
        }
    }
}

//+------------------------------------------------------------------+
//| 整体盈利目标：多笔持仓时，总盈利达到余额的ProfitTargetPercent    |
//+------------------------------------------------------------------+
void CheckBasketExit(ENUM_POSITION_TYPE dir) {
    if (CountPositions(dir) <= 1) return;

    double totalProfit = GetTotalProfit(dir);
    double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
    double target      = balance * ProfitTargetPercent / 100.0;

    if (totalProfit >= target) {
        string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        int posCount = CountPositions(dir);
        ClosePositionsByType(dir);
        WriteLog("BASKET EXIT " + dirStr +
                 " | Positions: " + IntegerToString(posCount) +
                 " | Profit: " + DoubleToString(totalProfit, 2) +
                 " | Target: " + DoubleToString(target, 2));
    }
}

//+------------------------------------------------------------------+
//| 马丁格尔加仓：亏损时在动态ATR距离处按倍数加仓                    |
//+------------------------------------------------------------------+
void CheckMartingale(ENUM_POSITION_TYPE dir, double currentPrice, double atr) {
    int count = CountPositions(dir);
    if (count <= 0 || count >= MaxPositions) return;

    // 只在整体亏损时加仓
    if (GetTotalProfit(dir) >= 0) return;

    // 获取最远入场价（做多取最低价，做空取最高价）
    double extremePrice = GetExtremeEntryPrice(dir);
    if (extremePrice <= 0) return;

    // 动态间距：持仓越多，间距越大
    double currentMultiplier = ATRAddMultiplier + (count - 1) * ATRStepIncrement;
    double addDistance = atr * currentMultiplier;
    bool shouldAdd = false;

    if (dir == POSITION_TYPE_BUY)
        shouldAdd = (currentPrice <= extremePrice - addDistance);
    else
        shouldAdd = (currentPrice >= extremePrice + addDistance);

    if (!shouldAdd) return;

    // 加仓手数计算：前 FlatAddCount 笔等量，之后斐波那契递增
    double newLot;
    if (count < FlatAddCount) {
        // 等量加仓：保持初始手数
        newLot = NormalizeLot(InitialLot);
    } else {
        // 斐波那契加仓：取最远两笔的手数之和
        double lot1, lot2;
        GetTwoExtremeLots(dir, lot1, lot2);
        newLot = NormalizeLot(lot1 + lot2);
    }

    ENUM_ORDER_TYPE orderType = (dir == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if (!CheckMargin(orderType, currentPrice, newLot)) {
        if (DebugMode) WriteLog("Insufficient margin for martingale add");
        return;
    }

    string comment = ((dir == POSITION_TYPE_BUY) ? "BB BUY ADD #" : "BB SELL ADD #") +
                     IntegerToString(count + 1);

    bool sent = false;
    if (dir == POSITION_TYPE_BUY)
        sent = trade.Buy(newLot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), 0, 0, comment);
    else
        sent = trade.Sell(newLot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), 0, 0, comment);

    if (sent) {
        string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        string addMode = (count < FlatAddCount) ? "FLAT" : "FIB";
        WriteLog(addMode + " ADD " + dirStr + " #" + IntegerToString(count + 1) +
                 " | Price: " + DoubleToString(currentPrice, symbolDigits) +
                 " | Lot: " + DoubleToString(newLot, 2) +
                 " | ATR x" + DoubleToString(currentMultiplier, 1) +
                 " | Distance: " + DoubleToString(addDistance, symbolDigits) +
                 " | Total positions: " + IntegerToString(count + 1));
    }
}

//+------------------------------------------------------------------+
//| 检测经纪商支持的成交类型                                          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillType() {
    long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if ((fillMode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if ((fillMode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| 检查市场是否活跃且允许交易                                       |
//+------------------------------------------------------------------+
bool IsMarketActive() {
    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
    if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

    long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (tradeMode != SYMBOL_TRADE_MODE_FULL) return false;

    // 周末检查（加密货币等品种跳过）
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.day_of_week == 0 || dt.day_of_week == 6) {
        string sym = _Symbol;
        if (StringFind(sym, "BTC") < 0 && StringFind(sym, "ETH") < 0 &&
            StringFind(sym, "XRP") < 0 && StringFind(sym, "LTC") < 0 &&
            StringFind(sym, "SOL") < 0 && StringFind(sym, "DOGE") < 0)
            return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| 标准化手数                                                       |
//+------------------------------------------------------------------+
double NormalizeLot(double lot) {
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| 保证金检查                                                       |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double price, double lot) {
    double margin;
    if (!OrderCalcMargin(type, _Symbol, lot, price, margin)) return false;
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    return margin <= freeMargin * 0.95;
}

//+------------------------------------------------------------------+
//| 按方向统计持仓数量                                               |
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
//| 获取最远入场价（做多=最低价，做空=最高价）                       |
//+------------------------------------------------------------------+
double GetExtremeEntryPrice(ENUM_POSITION_TYPE posType) {
    double result = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        double p = PositionGetDouble(POSITION_PRICE_OPEN);
        if (posType == POSITION_TYPE_BUY) {
            if (result == 0 || p < result) result = p;
        } else {
            if (result == 0 || p > result) result = p;
        }
    }
    return result;
}

//+------------------------------------------------------------------+
//| 获取最远入场价的持仓手数                                         |
//+------------------------------------------------------------------+
double GetExtremeEntryLot(ENUM_POSITION_TYPE posType) {
    double extremePrice = 0;
    double extremeLot   = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        double p   = PositionGetDouble(POSITION_PRICE_OPEN);
        double lot = PositionGetDouble(POSITION_VOLUME);

        if (posType == POSITION_TYPE_BUY) {
            if (extremePrice == 0 || p < extremePrice) {
                extremePrice = p;
                extremeLot   = lot;
            }
        } else {
            if (extremePrice == 0 || p > extremePrice) {
                extremePrice = p;
                extremeLot   = lot;
            }
        }
    }
    return extremeLot;
}

//+------------------------------------------------------------------+
//| 获取最远的两笔持仓手数（用于斐波那契加仓）                       |
//+------------------------------------------------------------------+
void GetTwoExtremeLots(ENUM_POSITION_TYPE posType, double &lot1, double &lot2) {
    lot1 = 0;
    lot2 = 0;
    double price1 = 0, price2 = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        double p   = PositionGetDouble(POSITION_PRICE_OPEN);
        double lot = PositionGetDouble(POSITION_VOLUME);

        if (posType == POSITION_TYPE_BUY) {
            // 做多：找价格最低的两笔
            if (price1 == 0 || p < price1) {
                price2 = price1; lot2 = lot1;
                price1 = p;      lot1 = lot;
            } else if (price2 == 0 || p < price2) {
                price2 = p;      lot2 = lot;
            }
        } else {
            // 做空：找价格最高的两笔
            if (price1 == 0 || p > price1) {
                price2 = price1; lot2 = lot1;
                price1 = p;      lot1 = lot;
            } else if (price2 == 0 || p > price2) {
                price2 = p;      lot2 = lot;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 获取某方向所有持仓的总浮盈（含手续费）                           |
//+------------------------------------------------------------------+
double GetTotalProfit(ENUM_POSITION_TYPE posType) {
    double total = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;
        total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
    }
    return total;
}

//+------------------------------------------------------------------+
//| 按方向平掉所有持仓                                               |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_POSITION_TYPE posType) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            trade.PositionClose(ticket);
    }
}

//+------------------------------------------------------------------+
//| 平掉所有持仓                                                     |
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
//| 回撤检查                                                         |
//+------------------------------------------------------------------+
bool CheckDrawdown() {
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double maxLoss = accountEquityStart * MaxDrawdownPct / 100.0;
    return (accountEquityStart - equity) >= maxLoss;
}

//+------------------------------------------------------------------+
//| 日志记录                                                         |
//+------------------------------------------------------------------+
void WriteLog(string message) {
    bool isImportant =
        StringFind(message, "FAILED") >= 0 ||
        StringFind(message, "DRAWDOWN") >= 0 ||
        StringFind(message, "BREAKOUT") >= 0 ||
        StringFind(message, "MARTINGALE") >= 0 ||
        StringFind(message, "BASKET") >= 0 ||
        StringFind(message, "Single") >= 0 ||
        StringFind(message, "closed") >= 0 ||
        StringFind(message, "initialized") >= 0 ||
        StringFind(message, "deinitialized") >= 0 ||
        StringFind(message, "resumed") >= 0 ||
        StringFind(message, "WARNING") >= 0 ||
        StringFind(message, "recovery") >= 0;

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
