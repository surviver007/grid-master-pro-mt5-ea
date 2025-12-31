<div align="center">

# 📉 GridMaster Pro — Algorithmic Grid Trading System

[![MQL5](https://img.shields.io/badge/MQL5-MetaTrader_5-green?style=for-the-badge&logo=metatrader-5)](https://www.metatrader5.com/en)
[![Strategy](https://img.shields.io/badge/Strategy-Grid_Trading-blue?style=for-the-badge)](https://en.wikipedia.org/wiki/Grid_trading)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

**A highly robust MetaTrader 5 Expert Advisor (EA) implementing a deterministic grid trading strategy with advanced error handling and execution optimization.**

*📊 Efficient • 🛡️ Resilient • ⚡ Automated*

[Report Bug](https://github.com/sajidmahamud835/grid-master-pro-mt5-ea/issues) · [Request Feature](https://github.com/sajidmahamud835/grid-master-pro-mt5-ea/issues)

</div>

---

## 🔬 About The Project

**GridMaster Pro** is a quantitative trading tool designed to exploit market volatility in ranging markets. Unlike trend-following systems that rely on prediction, this project utilizes a grid execution model to capture profit from mean-reversion movements.

From a research perspective, this EA serves as a baseline for measuring **Order Execution Quality** and **Strategy Robustness**. It implements rigid capital allocation rules and studies the impact of market noise on static grid intervals.

### 🎯 Key Design Principles
1.  **Deterministic Execution**: Removes emotional bias by adhering to strict mathematical entry/exit rules.
2.  **Resilience**: Built-in "Retry Mechanism" to handle broker requotes and server busy errors during high-volatility events.
3.  **Capital Efficiency**: Optimized for calculating maximum drawdown potential based on input parameters.

---

## ⚙️ Algorithms & Inputs

The core logic revolves around placing buy limits below the current price (or buy stops above) at fixed intervals.

| Parameter | Type | Description |
|-----------|------|-------------|
| `LotSize` | `double` | Fixed volume for each grid order. |
| `GridDistance` | `double` | The gap (in points) between subsequent orders (Noise Filter). |
| `MaxOrders` | `int` | Hard cap on open positions to control leverage exposure. |

```mql5
// Example Configuration
input double LotSize = 0.1;
input double GridDistance = 50; 
input int MaxOrders = 10; 
```

---

## ✨ Features

### 🟢 Implemented Capabilities

- [x] **Auto-Execution**: Autonomous order placement without user intervention.
- [x] **Error Handling**: Graceful recovery from `TRADE_RETCODE_CONNECTION` and timeout errors.
- [x] **Visual Debugging**: Comments on chart indicating system status and next grid levels.
- [x] **MQL5 Native**: Compiled to highly efficient bytecode for millisecond-level execution.

### 🗓️ Research & Development Plan (Todo)

- [ ] **Dynamic Grids**: Implement Average True Range (ATR) based grid spacing to adapt to changing volatility.
- [ ] **Hedging Module**: Add "Sell" grid logic to create a full hedged mesh functionality.
- [ ] **Martingale Option**: (Experimental) Add variable lot sizing (1.0x, 1.5x, 2.0x) for aggressive recovery.
- [ ] **Backtesting Reports**: Publish 5-year backtests on EURUSD and GBPUSD pairs.

---

## 🚀 Getting Started

### Installation

1.  **Download**: Get the latest `GridMasterPro.mq5` from the repository.
2.  **Deploy**: Move the file to your MetaTrader 5 Data Folder: `.../MQL5/Experts/`.
3.  **Compile**: Open MetaEditor (F4), open the file, and click "Compile".
4.  **Activate**:
    -   Open MT5 Terminal.
    -   Drag "GridMasterPro" onto a chart (e.g., EURUSD H1).
    -   Enable "Algo Trading" in the toolbar.

### ⚠️ Risk Warning

Trading Forex and CFDs carries a high level of risk and may not be suitable for all investors. The high degree of leverage can work against you as well as for you. **Grid strategies, in particular, can sustain large drawdowns during strong unidirectional trends.**

*Always test on a Demo account before deploying real capital.*

---

## 🤝 Related Projects

Explore other components of the research portfolio:

1.  **[MarketSync-EA](../MarketSync-EA)** - The "Smart" evolution of this project, using AI to determine when to deploy the grid.
2.  **[Slippage Tracker Client](../slippage-tracker-client)** - A tool to monitor if your broker is executing your grid orders fairly.
3.  **[WhatsApp Bot](../whatsapp-bot)** - Integration for sending trade alerts directly to your phone.

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---

<div align="center">

**[Sajid Mahamud](https://www.mql5.com/en/users/sajidmahamud835)**

*MQL5 Developer • Quantitative Researcher*

</div>