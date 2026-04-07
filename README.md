<div align="center">

# 🤖 GridMaster Pro — Algorithmic Grid Trading System

[![MQL5](https://img.shields.io/badge/MQL5-MetaTrader_5-green?style=for-the-badge)](https://www.metatrader5.com/en)
[![Version](https://img.shields.io/badge/Version-2.0.0-blue?style=for-the-badge)](https://github.com/sajidmahamud835/grid-master-pro-mt5-ea/releases)
[![Strategy](https://img.shields.io/badge/Strategy-Bi--directional_Grid-orange?style=for-the-badge)](https://en.wikipedia.org/wiki/Grid_trading)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)
[![Stars](https://img.shields.io/github/stars/sajidmahamud835/grid-master-pro-mt5-ea?style=for-the-badge)](https://github.com/sajidmahamud835/grid-master-pro-mt5-ea/stargazers)

**A robust MetaTrader 5 Expert Advisor implementing a bi-directional ATR-based grid trading strategy with dynamic lot sizing, drawdown protection, and broker-aware stop management.**

*⚡ ATR-Adaptive · 🛡️ Drawdown Protected · 📊 Bi-directional · 🤖 Fully Automated*

[Report Bug](https://github.com/sajidmahamud835/grid-master-pro-mt5-ea/issues) · [Request Feature](https://github.com/sajidmahamud835/grid-master-pro-mt5-ea/issues) · [Trading Plan](TRADING_PLAN.md)

</div>

---

## 📖 About The Project

**GridMaster Pro** is a quantitative trading EA that exploits market volatility in ranging markets. Unlike trend-following systems that rely on prediction, it uses a grid execution model to capture profit from mean-reversion movements.

### ✨ Key Design Principles

1. **Bi-directional** — Places BUY orders below AND SELL orders above the current price simultaneously (Neutral mode), or can run one-sided in trending markets.
2. **ATR-Adaptive** — Grid spacing dynamically adjusts to market volatility using ATR, preventing over-trading in low-volatility and under-trading in high-volatility conditions.
3. **Broker-Aware** — Reads `SYMBOL_TRADE_STOPS_LEVEL` and enforces proper minimum stop distances, preventing the "Invalid stops" error common on crypto and exotic pairs.
4. **Risk-Managed** — Built-in drawdown circuit breaker auto-pauses and closes all positions when equity drops beyond a configurable threshold.

---

## ⚙️ Parameters

### Grid Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `GridMode` | NEUTRAL | NEUTRAL (both), BULLISH (buy only), BEARISH (sell only) |
| `MaxOrders` | 5 | Max open positions per side |
| `ATRPeriod` | 14 | ATR lookback period |
| `ATRMultiplier` | 1.5 | Grid spacing = ATR × multiplier |

### Order Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `LotMode` | FIXED | FIXED or DYNAMIC (risk % per order) |
| `LotSize` | 0.1 | Fixed lot (ignored in dynamic mode) |
| `RiskPercent` | 1.0 | % of balance risked per order (dynamic mode) |
| `DefaultTP` | 200 | Minimum TP in points (auto-raised to broker minimum) |
| `DefaultSL` | 1000 | Minimum SL in points (auto-raised to broker minimum) |
| `UseTrailingStop` | true | Enable trailing stop |
| `TrailingPoints` | 100 | Trailing activation distance in points |
| `TrailingStep` | 20 | Trailing step (minimum move before update) |

### Risk Management
| Parameter | Default | Description |
|-----------|---------|-------------|
| `MaxDrawdownPct` | 5.0 | Max equity drawdown % before pause |
| `CloseOnDrawdown` | true | Close all positions on drawdown breach |

---

## 🚀 Features

### ✅ Implemented (v2.0)

- [x] **Bi-directional Grid** — BUY + SELL simultaneously in NEUTRAL mode
- [x] **Dynamic Grid Distance** — ATR-based spacing adapts to volatility
- [x] **Broker-Aware Stops** — Reads broker minimum stop level, auto-adjusts TP/SL
- [x] **Dynamic Lot Sizing** — Risk-based lot calculation (% of balance)
- [x] **Drawdown Protection** — Circuit breaker pauses grid on equity loss
- [x] **Trailing Stop** — Proper directional trailing with configurable step
- [x] **Live Position Count** — Uses `PositionSelectByTicket()` + magic filter (no stale counters)
- [x] **Collision-Safe Magic Number** — Symbol + timeframe based, prevents EA cross-interference
- [x] **Append Logging** — Log file appends properly (no data loss on each tick)
- [x] **OnDeinit Cleanup** — Graceful deinitialization with position count report

### 📋 Recommended Settings by Instrument

| Instrument | LotSize | MaxOrders | ATRMult | DefaultTP | DefaultSL | MaxDrawdown |
|------------|---------|-----------|---------|-----------|-----------|-------------|
| BTCUSD | 0.01 | 5 | 2.0 | 1000 | 5000 | 5% |
| EURUSD | 0.1 | 8 | 1.5 | 200 | 1000 | 3% |
| XAUUSD | 0.05 | 6 | 1.8 | 500 | 3000 | 4% |
| GBPUSD | 0.1 | 6 | 1.6 | 200 | 1200 | 3% |

---

## 📥 Getting Started

### Installation

1. **Download** — Get `GridMaster Pro.mq5` from this repository
2. **Deploy** — Copy to `MetaTrader 5 / MQL5 / Experts /`
3. **Compile** — Open MetaEditor (F4), compile (F7), check for 0 errors
4. **Attach** — Drag onto chart (EURUSD H1 recommended for testing)
5. **Enable** — Turn on "Algo Trading" in the toolbar

### ⚠️ Risk Warning

> Grid strategies can sustain **large drawdowns during strong trending markets** when orders stack against the trend. Always:
> - Set `MaxDrawdownPct` to limit losses (recommended: 3-5%)
> - Test on demo account for at least 2 weeks before going live
> - Never risk more than you can afford to lose

---

## 📋 Changelog

### v2.0.0 — 2026-04-07 *(Current)*
#### 🔴 Critical Bug Fixes
- **Fixed: "Position doesn't exist" error** — `PositionSelect(_Symbol)` replaced with `PositionSelectByTicket()` + magic number filter. Old code was attempting to modify positions with ticket `#0` (invalid).
- **Fixed: "Invalid stops" on BTCUSD/crypto** — `DefaultTP = 100` points was below broker minimum stop distance for BTC. Now reads `SYMBOL_TRADE_STOPS_LEVEL` and enforces `MathMax(userTP, brokerMin × 1.5)` on every order.
- **Fixed: `ordersCount` stale counter** — Old code incremented but never decremented, permanently stopping order placement after MaxOrders. Replaced with live `CountOurPositions()` calculated on each tick.
- **Fixed: `SymbolInfoInteger` wrong usage** — Was passing `tradeAllowed` as reference (compile error on some compilers). Fixed to proper `long x = SymbolInfoInteger(...)` usage.
- **Fixed: Log file overwrites** — `FILE_WRITE` was truncating the log on every write. Fixed with `FILE_READ | FILE_WRITE` + `FileSeek(SEEK_END)` to append.

#### ✨ New Features
- **Bi-directional grid** — Three modes: NEUTRAL (BUY+SELL), BULLISH (BUY only), BEARISH (SELL only)
- **Dynamic lot sizing** — Risk-based mode: `lot = (balance × riskPct) / (SL × tickValue)`
- **Drawdown circuit breaker** — Auto-closes all positions and pauses grid when equity falls below threshold
- **Improved trailing stop** — Separate BUY/SELL logic with `TrailingStep` minimum move
- **Collision-safe magic number** — `MagicBase + symbolLen×1000 + timeframe`, prevents interference with other EAs
- **OnDeinit handler** — Logs position count on EA removal

#### 🔄 Refactoring
- Replaced manual `OrderSend` with `CTrade` library for cleaner, more reliable execution
- Removed `GenerateMagicNumber()` string-parsing hack
- `CalculateLot()` now handles both FIXED and DYNAMIC modes
- `OrderExistsNearPrice()` prevents duplicate orders at the same grid level

---

### v1.04 — 2024 *(Previous)*
- Initial release with BUY-only grid
- ATR-based dynamic grid distance
- Basic retry mechanism for order placement
- File logging (overwrites — bug)
- `ordersCount` counter (stale — bug)

---

## 🗺️ Future Roadmap

### v2.1 — Order Management
- [ ] **Basket close** — Close all BUY + SELL positions when combined floating profit ≥ target
- [ ] **Partial close** — Close oldest/worst position when new grid level is hit
- [ ] **Break-even stop** — Move SL to open price after first TP hit

### v2.2 — Trend Filter
- [ ] **Moving average trend filter** — Only place BUY orders when price > MA200, SELL when below
- [ ] **RSI filter** — Only place orders when RSI is not overbought/oversold
- [ ] **Session filter** — Restrict trading to London/NY sessions for forex pairs

### v2.3 — Advanced Risk
- [ ] **Martingale mode** — Optional lot multiplier per grid level (configurable, off by default)
- [ ] **Equity lock** — Don't open new orders when floating loss exceeds threshold
- [ ] **Correlation guard** — Prevent opening grid on correlated pairs simultaneously

### v2.4 — Analytics & Alerts
- [ ] **WhatsApp/Telegram alerts** — Notify on order placed, TP hit, drawdown breach
- [ ] **Dashboard panel** — On-chart display of grid levels, P&L, position count
- [ ] **Backtesting reports** — 5-year reports on EURUSD, BTCUSD, XAUUSD

### v3.0 — AI-Enhanced (MarketSync Integration)
- [ ] **ML regime detection** — Classify market as trending/ranging, auto-select grid mode
- [ ] **GPT-based parameter optimizer** — Suggest ATR multiplier based on recent volatility history
- [ ] **Integration with [MarketSync-EA](https://github.com/sajidmahamud835/MarketSync-EA)** — AI decides WHEN to deploy the grid

---

## 🔗 Related Projects

| Project | Description |
|---------|-------------|
| [MarketSync-EA](https://github.com/sajidmahamud835/MarketSync-EA) | AI-powered evolution — uses ML to decide when/where to place the grid |
| [Slippage Tracker](https://github.com/sajidmahamud835/slippage-tracker-client) | Monitor broker execution quality for your grid orders |
| [WhatsApp Bot](https://github.com/sajidmahamud835/whatsapp-bot) | Trade alerts via WhatsApp |

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---

<div align="center">

**[Sajid Mahamud](https://www.mql5.com/en/users/sajidmahamud835)**

*MQL5 Developer · Quantitative Researcher · AI Trading Systems*

[🌐 Portfolio](https://sajidmahamud835.github.io/) · [📊 MQL5 Profile](https://www.mql5.com/en/users/sajidmahamud835) · [⭐ Star this repo](https://github.com/sajidmahamud835/grid-master-pro-mt5-ea)

</div>
