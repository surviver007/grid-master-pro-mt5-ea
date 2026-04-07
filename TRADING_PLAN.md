# GridMaster Pro — Trading Plan v2.0

## Strategy Overview

**Type:** Bi-directional Grid (BUY + SELL simultaneously)  
**Best Market:** Ranging/sideways markets with periodic trends  
**Risk Level:** Medium-High (requires proper MM)

---

## Grid Architecture

```
Price
  |
  |  +--[SELL 5]-- TP
  |  +--[SELL 4]--
  |  +--[SELL 3]--
  |  +--[SELL 2]--
  |  +--[SELL 1]-- ← Upper band
  |
  |  ===== PRICE NOW =====
  |
  |  +--[BUY 1]-- ← Lower band
  |  +--[BUY 2]--
  |  +--[BUY 3]--
  |  +--[BUY 4]--
  |  +--[BUY 5]-- TP
  |
```

### Grid Modes
1. **Neutral Grid** — BUY below price + SELL above price (best for ranging)
2. **Bullish Grid** — BUY-only grid (trend following up)
3. **Bearish Grid** — SELL-only grid (trend following down)

---

## Entry Logic

### Grid Distance (Dynamic via ATR)
```
gridDistance = ATR(14) × ATRMultiplier
```
- ATR adapts to volatility automatically
- Low volatility → smaller grid → more precise entries
- High volatility → larger grid → avoids whipsaws

### Order Placement
- Place N orders above AND below current price at equal intervals
- Each order has its own TP = gridDistance (close at next level)
- Each order has SL = N × gridDistance (total grid width)

---

## Take Profit Logic

### Per-Order TP
```
BUY order TP  = openPrice + gridDistance
SELL order TP = openPrice - gridDistance
```

### Grid-Level TP (basket close)
When total floating profit ≥ GridProfitTarget:
- Close ALL orders (BUY + SELL basket)
- Reset grid from current price

---

## Stop Loss Logic

### Individual Order SL
```
BUY SL  = lowestGridLevel - SLBuffer
SELL SL = highestGridLevel + SLBuffer
```

### Trailing Stop (optional)
- Activates when profit ≥ TrailingActivation points
- Locks in profit at price - TrailingStep

### Max Drawdown Protection
- If account equity drops below MaxDrawdownPercent → close all + pause
- Resume only on next candle open

---

## Position Sizing (Money Management)

### Fixed Lot
```
LotSize = input
```

### Dynamic Lot (Risk-Based)
```
LotSize = (AccountBalance × RiskPercent) / (gridDistance × contractSize)
```
Ensures each order risks max X% of account.

### Martingale Mode (optional, caution)
```
nextLot = prevLot × MartingaleMultiplier
```
Increases lot on each grid level — amplifies both profit and loss.

---

## Minimum Stop Distance Fix

```mql5
double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
sl = MathMax(sl, openPrice - MathMax(minStop * 2, DefaultSL * _Point));
tp = MathMax(tp, openPrice + MathMax(minStop * 2, DefaultTP * _Point));
```

---

## Key Improvements in v2.0

| Issue | v1.04 | v2.0 |
|-------|-------|------|
| Order direction | BUY only | BUY + SELL |
| ordersCount sync | Never decrements | Counts live positions |
| Stop distance | Fixed points (breaks on BTC) | Dynamic min-stop aware |
| TP calculation | From lastPrice (wrong) | From openPrice (correct) |
| Log mode | Overwrites every write | Appends properly |
| Magic number | Hash collision risk | Symbol+TimeFrame based |
| SymbolInfoInteger | Wrong signature | Correct usage |
| OnDeinit | Missing | Cleans up state |
| Grid direction | One-sided only | Bi-directional |
| Risk management | None | MaxDrawdown% guard |

---

## Recommended Settings

### BTCUSD (Crypto)
```
LotSize          = 0.01
MaxOrders        = 5
ATRPeriod        = 14
ATRMultiplier    = 2.0
DefaultTP        = 1000   (= $10 for BTC)
DefaultSL        = 5000   (= $50 for BTC)
GridMode         = Neutral
MaxDrawdown      = 5.0%
```

### EURUSD (Forex)
```
LotSize          = 0.1
MaxOrders        = 8
ATRPeriod        = 14
ATRMultiplier    = 1.5
DefaultTP        = 200    (= 20 pips)
DefaultSL        = 1000   (= 100 pips)
GridMode         = Neutral
MaxDrawdown      = 3.0%
```

### XAUUSD (Gold)
```
LotSize          = 0.05
MaxOrders        = 6
ATRPeriod        = 14
ATRMultiplier    = 1.8
DefaultTP        = 500    (= $5)
DefaultSL        = 3000   (= $30)
GridMode         = Neutral
MaxDrawdown      = 4.0%
```
