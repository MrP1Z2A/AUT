# GoldMTF EA – Gold trading bot for MetaTrader 4

An Expert Advisor (EA) for **XAUUSD / GOLD** that uses two timeframes:

| Timeframe | Job | Rule |
|-----------|-----|------|
| **M15** | Trend direction | EMA 50 vs EMA 200, price on the right side of EMA 200, ADX ≥ 20 |
| **M5**  | Entry timing   | EMA 9 crosses EMA 21 **in the M15 trend direction**, RSI confirms (50–70 for buys, 30–50 for sells) |

Each trade risks **5% of the account** (you can change this). The lot size is calculated from the stop-loss distance, so a stop-loss hit loses about 5%.

## Exits
- **Stop loss** = 1.5 × ATR(14) on M15. The distance adapts to gold's volatility.
- **Take profit** = 2 × the stop distance (risk:reward 1:2)
- **Break-even**: at +1R the stop moves to entry + 0.1R
- **Trailing stop**: from +1.5R, the stop trails at 1 × ATR(M15)

## Safety filters
- Only **1 trade at a time** (`MaxOpenTrades`)
- **Daily loss limit**: after a 10% loss in a day, no new trades until the next day
- **Max spread**: no new trades if the spread is over $0.60
- **Trading hours**: 07:00–20:00 server time, and no new trades after 18:00 on Friday
- If the account is too small to trade the minimum lot within 5% risk, the trade is **skipped**. The EA never rounds the lot size up.

## Installation
1. In MT4: **File → Open Data Folder**, then open `MQL4/Experts/`.
2. Copy `MQL4/Experts/GoldMTF_EA.mq4` into that folder.
3. Open **MetaEditor** (F4), open the file, and press **Compile** (F7). It should report 0 errors.
4. In MT4, open a **XAUUSD chart**. Your broker may call it `GOLD`, `XAUUSD.m`, etc. Any chart timeframe works because the EA reads M5 and M15 itself. M5 is recommended.
5. Drag **GoldMTF_EA** from the Navigator onto the chart. Tick **Allow live trading** and turn on **AutoTrading**.
6. The info panel in the top-left corner shows the trend, risk amount and status.

> Open the M5 and M15 charts of the symbol once so MT4 downloads their history.

## Position size example (standard gold contract: 100 oz per lot, $1 move = $100 per lot)
| Balance | 5% risk | SL distance | Lot size |
|---------|---------|-------------|----------|
| $1,000  | $50     | $10.00      | 0.05     |
| $5,000  | $250    | $8.00       | 0.31     |
| $200    | $10     | $12.00      | skipped (below 0.01 minimum) |

## Settings you will most likely change
| Input | Default | Notes |
|-------|---------|-------|
| `RiskPercent` | 5.0 | % of balance risked per trade |
| `MaxSpreadPrice` | 0.60 | In dollars. Raise it for wide-spread brokers |
| `StartHour` / `EndHour` | 7 / 20 | **Broker server time** (shown in Market Watch) |
| `ECNMode` | false | Set to true if orders fail with error 130 on an ECN account |
| `CommissionPerLot` | 0 | Your round-turn commission, so it counts toward the risk |
| `MagicNumber` | 515151 | Use a different number on each chart |

## ⚠️ Risk warning
**5% risk per trade is aggressive.** Ten losses in a row, which is normal in trading, take about **40% of the account**. Most professional traders risk 0.5–2%.
No strategy is guaranteed to make money. Before trading real money:
1. **Backtest** in the Strategy Tester (Ctrl+R): symbol XAUUSD, model *Every tick*, chart period M5, with at least 6–12 months of data.
2. **Run it on a demo account** for several weeks.
3. Then start live with lower risk, for example 1–2%.
