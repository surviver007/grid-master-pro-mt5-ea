//+------------------------------------------------------------------+
//|                                       GridMasterPro_v2.1.mq5     |
//|                                    Copyright 2026, wangxiaozhi.  |
//|                       https://www.mql5.com/en/users/wangxiaozhi  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, wangxiaozhi."
#property link      "https://www.mql5.com/en/users/wangxiaozhi"
#property version   "2.11"
#property strict
#property description "GridMaster Pro v2.1 — 双向ATR网格挂单交易系统，含资金管理和回撤保护。"

#include <Trade\Trade.mqh>

//--- 枚举定义
enum ENUM_GRID_MODE {
    GRID_NEUTRAL  = 0,  // 中性模式：下方做多 + 上方做空
    GRID_BULLISH  = 1,  // 看多模式：仅做多
    GRID_BEARISH  = 2,  // 看空模式：仅做空
};

enum ENUM_LOT_MODE {
    LOT_FIXED     = 0,  // 固定手数
    LOT_DYNAMIC   = 1,  // 动态手数（按余额百分比计算风险）
};

//--- 输入参数 — 网格设置
input ENUM_GRID_MODE GridMode        = GRID_NEUTRAL;   // 网格模式
input int            MaxOrders       = 5;              // 每侧最大订单数
input int            ATRPeriod       = 14;             // ATR 周期
input double         ATRMultiplier   = 1.5;            // ATR 乘数（计算网格间距）

//--- 输入参数 — 订单设置
input ENUM_LOT_MODE  LotMode         = LOT_FIXED;      // 手数模式
input double         LotSize         = 0.1;            // 固定手数
input double         RiskPercent     = 1.0;            // 每单风险百分比（动态模式）
input bool           UseTakeProfit   = true;           // 启用止盈
input double         DefaultTP       = 200.0;          // 止盈距离（点）
input bool           UseStopLoss     = true;           // 启用止损
input double         DefaultSL       = 1000.0;         // 止损距离（点）
input bool           UseTrailingStop = true;           // 启用移动止损
input double         TrailingPoints  = 100.0;          // 移动止损激活距离（点）
input double         TrailingStep    = 20.0;           // 移动止损最小步距（点）

//--- 输入参数 — 风控管理
input double         MaxDrawdownPct  = 5.0;            // 最大回撤百分比（触发暂停）
input bool           CloseOnDrawdown = true;           // 回撤超限是否平掉所有仓位
input int            RecoveryBars    = 20;             // 暂停后恢复所需K线数量

//--- 输入参数 — 过滤器与调试
input int            MaxSpreadPoints = 50;             // 允许交易的最大点差（点）
input int            MagicBase       = 47291;          // 基础魔术号
input bool           DebugMode       = false;          // 启用调试日志

//--- 全局变量
CTrade   trade;
int      magicNumber;
double   gridDistance;           // 网格间距（价格单位，非点数）
double   accountEquityStart;     // 基准净值 — 恢复后不重置
bool     gridPaused   = false;
datetime pauseBarTime;           // 暂停时的K线时间，用于计算恢复K线数
string   logFile;
datetime lastBarTime;
int      atrHandle;
int      symbolDigits;
double   symbolPoint;

//+------------------------------------------------------------------+
//| EA 初始化                                                        |
//+------------------------------------------------------------------+
int OnInit() {
    // 防冲突魔术号
    magicNumber = MagicBase + (int)(StringLen(_Symbol) * 1000) + (int)Period();
    trade.SetExpertMagicNumber(magicNumber);
    trade.SetDeviationInPoints(50);
    trade.SetTypeFilling(DetectFillType());

    symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    symbolPoint  = _Point;

    accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
    logFile     = "GridMasterPro_" + _Symbol + "_" + IntegerToString(Period()) + ".log";
    lastBarTime = 0;

    // 创建 ATR 指标句柄（标准 MQL5 方式）
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if (atrHandle == INVALID_HANDLE) {
        WriteLog("FAILED to create ATR indicator handle");
        return INIT_FAILED;
    }

    // 初始网格间距
    gridDistance = CalculateGridDistance();
    if (gridDistance <= 0) {
        WriteLog("WARNING: Initial ATR is zero, grid will activate on first valid bar");
    }

    WriteLog("GridMaster Pro v2.11 initialized | Magic: " + IntegerToString(magicNumber) +
             " | Symbol: " + _Symbol + " | Grid: " + EnumToString(GridMode));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 反初始化                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    CancelAllPendingOrders();
    if (atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    WriteLog("EA deinitialized. Reason: " + IntegerToString(reason) +
             " | Positions: " + IntegerToString(CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL)));
}

//+------------------------------------------------------------------+
//| EA Tick 函数                                                     |
//+------------------------------------------------------------------+
void OnTick() {
    // --- 前置条件检查 ---
    if (!IsMarketActive()) return;

    // --- 高水位更新：净值创新高时上调基准，确保回撤保护始终有效 ---
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if (currentEquity > accountEquityStart)
        accountEquityStart = currentEquity;

    // --- 回撤保护 ---
    if (CloseOnDrawdown && CheckDrawdown()) {
        if (!gridPaused) {
            WriteLog("DRAWDOWN LIMIT REACHED — closing all and pausing");
            CloseAllPositions();
            CancelAllPendingOrders();
            gridPaused = true;
            pauseBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
            WriteLog("Pause started, will resume after " + IntegerToString(RecoveryBars) + " bars");
        }
        return;
    }

    // --- 恢复检查（基准不重置） ---
    if (gridPaused) {
        if (CheckRecovery()) {
            gridPaused = false;
            WriteLog("Grid resumed after equity recovery");
        } else {
            return;
        }
    }

    // --- 仅在新K线时更新网格间距 ---
    bool newBar = IsNewBar();
    if (newBar) {
        double newDist = CalculateGridDistance();
        if (newDist > 0) gridDistance = newDist;
    }

    if (gridDistance <= 0) return;

    // --- 点差过滤 ---
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if (spread > MaxSpreadPoints) {
        if (newBar && DebugMode)
            WriteLog("Spread too high: " + IntegerToString((int)spread) + " pts, skipping");
        return;
    }

    // --- 移动止损管理 ---
    if (UseTrailingStop) ManageTrailingStops();

    // --- 网格挂单管理 ---
    ManageGridOrders();
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

    // 周末检查
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.day_of_week == 0 || dt.day_of_week == 6) return false;

    return true;
}

//+------------------------------------------------------------------+
//| 新K线检测                                                        |
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
//| 基于ATR计算网格间距（价格单位），使用已完成的K线                 |
//+------------------------------------------------------------------+
double CalculateGridDistance() {
    if (atrHandle == INVALID_HANDLE) return 0;
    double atr[];
    ArraySetAsSeries(atr, true);
    // 读取K线索引1（上一根已完成的K线）以确保稳定性
    if (CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return 0;
    if (atr[0] <= 0) return 0;
    return atr[0] * ATRMultiplier;   // 返回价格单位，非点数
}

//+------------------------------------------------------------------+
//| 管理网格挂单 — 放置BuyLimit/SellLimit                           |
//+------------------------------------------------------------------+
void ManageGridOrders() {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double minDist = GetMinStopDistance();   // 距当前价格的最小距离

    // --- 做多侧 ---
    if (GridMode != GRID_BEARISH) {
        int buyPos  = CountPositions(POSITION_TYPE_BUY);
        int buyPend = CountPendingOrders(ORDER_TYPE_BUY_LIMIT);

        if (buyPos + buyPend < MaxOrders) {
            double nextLevel;
            double lowest = GetLowestBuyEntry();

            if (lowest > 0) {
                // 扩展网格：在最低现有入场价下方放置一个新级别
                nextLevel = lowest - gridDistance;
            } else {
                // 第一个做多级别：当前Ask价下方一个网格间距
                nextLevel = ask - gridDistance;
            }

            // BuyLimit 必须低于Ask价且保持至少minDist间距
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

    // --- 做空侧 ---
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

            // SellLimit 必须高于Bid价且保持至少minDist间距
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
//| 放置带止损/止盈的网格挂单                                       |
//+------------------------------------------------------------------+
void PlaceGridOrder(ENUM_ORDER_TYPE type, double price) {
    double minStop = GetMinStopDistance();
    double sl = 0, tp = 0;
    double lot = CalculateLot();

    if (type == ORDER_TYPE_BUY_LIMIT) {
        if (UseTakeProfit) tp = price + MathMax(DefaultTP * symbolPoint, minStop);
        if (UseStopLoss)   sl = price - MathMax(DefaultSL * symbolPoint, minStop * MaxOrders);
    } else { // SELL_LIMIT（卖出限价）
        if (UseTakeProfit) tp = price - MathMax(DefaultTP * symbolPoint, minStop);
        if (UseStopLoss)   sl = price + MathMax(DefaultSL * symbolPoint, minStop * MaxOrders);
    }

    // 标准化所有价格
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
//| 移动止损 — 仅向盈利方向移动止损以锁定利润                       |
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
                // 仅向上移动止损，且移动幅度至少为TrailingStep
                if (newSL > currentSL + TrailingStep * symbolPoint) {
                    // 确保止损价不低于开仓价（锁定利润）
                    if (newSL >= openPrice) {
                        trade.PositionModify(ticket, newSL, currentTP);
                    }
                }
            }
        } else { // 卖出仓位
            double profit = openPrice - ask;
            if (profit >= TrailingPoints * symbolPoint) {
                double newSL = NormalizeDouble(ask + TrailingPoints * symbolPoint, symbolDigits);
                // 仅向下移动止损，且移动幅度至少为TrailingStep
                if (currentSL == 0 || newSL < currentSL - TrailingStep * symbolPoint) {
                    // 确保止损价不高于开仓价（锁定利润）
                    if (newSL <= openPrice) {
                        trade.PositionModify(ticket, newSL, currentTP);
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 计算手数                                                         |
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

    // 向下取整到lotStep（永不向上取整，避免超出风险预算）
    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| 下单前保证金检查                                                 |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double price) {
    double margin;
    double lot = CalculateLot();
    // OrderCalcMargin需要市价单类型，而非挂单类型
    ENUM_ORDER_TYPE calcType = (type == ORDER_TYPE_BUY_LIMIT) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if (!OrderCalcMargin(calcType, _Symbol, lot, price, margin)) return false;
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    return margin <= freeMargin * 0.95;   // 保留5%缓冲
}

//+------------------------------------------------------------------+
//| 按仓位类型统计持仓数量                                           |
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
//| 按订单类型统计挂单数量                                           |
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
//| 获取最低做多入场价（持仓或挂单）                                 |
//+------------------------------------------------------------------+
double GetLowestBuyEntry() {
    double lowest = 0;

    // 扫描持仓
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
    // 扫描挂单
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
//| 获取最高做空入场价（持仓或挂单）                                 |
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
//| 检查指定价格附近是否存在持仓或挂单                               |
//+------------------------------------------------------------------+
bool OrderExistsNearPrice(double price, double tolerance) {
    // 检查持仓
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if (MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) <= tolerance)
            return true;
    }
    // 检查挂单
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
//| 经纪商最小止损距离（价格单位）                                   |
//+------------------------------------------------------------------+
double GetMinStopDistance() {
    long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    return MathMax((double)stopLevel, 10.0) * symbolPoint * 1.2;
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
//| 恢复检查 — 基于暂停后经过的K线数量                               |
//+------------------------------------------------------------------+
bool CheckRecovery() {
    if (RecoveryBars <= 0) return true;   // 0表示立即恢复
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    int barsPassed = Bars(_Symbol, PERIOD_CURRENT, pauseBarTime, currentBarTime);
    if (barsPassed >= RecoveryBars) {
        // 恢复后重置基准净值为当前余额，从新起点开始
        accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
        return true;
    }
    return false;
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
//| 取消所有挂单                                                     |
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
//| 日志记录 — 关键事件始终记录，调试模式记录所有信息                |
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
