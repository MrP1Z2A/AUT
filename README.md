# MTF trading bots for MetaTrader 4 – XAUUSD (gold) and EURUSD

Two Expert Advisors (EAs) using the same strategy:

| File | Market | Magic number |
|------|--------|--------------|
| `MQL4/Experts/XAUUSD_MTF_EA.mq4` | **Gold (XAUUSD / GOLD)** | 515151 |
| `MQL4/Experts/EURUSD_MTF_EA.mq4` | **EURUSD** | 616161 |

Both use two timeframes:

| Timeframe | Job | Rule |
|-----------|-----|------|
| **M15** | Trend direction | EMA 50 vs EMA 200, price on the right side of EMA 200, ADX ≥ 20 |
| **M5**  | Entry timing   | EMA 9 crosses EMA 21 **in the M15 trend direction**, RSI confirms (50–70 for buys, 30–50 for sells) |

Each trade risks **5% of the account** (you can change this). The lot size is calculated from the stop-loss distance, so a stop-loss hit loses about 5%.

## Gold vs EURUSD differences
| Setting | XAUUSD bot | EURUSD bot |
|---------|-----------|------------|
| Max spread | `MaxSpreadPrice` = $0.60 | `MaxSpreadPips` = 2 pips |
| Minimum stop loss | `MinStopPrice` = $3.00 | `MinStopPips` = 8 pips |
| Small-account option | `AllowMinLotOverRisk` (see below) | not needed |

### ⚠️ Gold and small accounts
One standard gold lot is 100 oz, so a $1 move = **$100 per lot** (0.01 lot = $1 per $1 move).
A typical gold stop is $5–15, so the minimum 0.01 lot risks **$5–15 per trade**.
With 5% risk you need about **$200–300 or more** in the account, otherwise the bot **skips** trades.

| Balance | 5% risk | SL distance | Lot size |
|---------|---------|-------------|----------|
| $1,000  | $50     | $10.00      | 0.05     |
| $5,000  | $250    | $8.00       | 0.31     |
| $150    | $7.50   | $10.00      | skipped (0.01 lot would risk $10 = 6.7%) |

To trade small accounts anyway, set `AllowMinLotOverRisk = true`. The bot then uses 0.01 lot as long as that risks no more than `MaxRiskAtMinLot` (10%).

## Exits
- **Stop loss** = 1.5 × ATR(14) on M15, with a minimum ($3 on gold, 8 pips on EURUSD). The distance adapts to volatility.
- **Take profit** = 2 × the stop distance (risk:reward 1:2)
- **Break-even**: at +1R the stop moves to entry + 0.1R
- **Trailing stop**: from +1.5R, the stop trails at 1 × ATR(M15)

## Safety filters
- Only **1 trade at a time** (`MaxOpenTrades`)
- **Daily loss limit**: after a 10% loss in a day, no new trades until the next day
- **Max spread**: no new trades if the spread is too wide
- **Trading hours**: 07:00–20:00 server time, and no new trades after 18:00 on Friday
- If the account is too small to trade the minimum lot within 5% risk, the trade is **skipped**. The EA never rounds the lot size up.

## Installation
1. In MT4: **File → Open Data Folder**, then open `MQL4/Experts/`.
2. Copy `XAUUSD_MTF_EA.mq4` (and/or `EURUSD_MTF_EA.mq4`) into that folder.
3. Open **MetaEditor** (F4), open the file, and press **Compile** (F7). It should report 0 errors.
4. In MT4, open a **XAUUSD chart** (or EURUSD for the EURUSD bot). Your broker may call it `GOLD`, `XAUUSD.m`, etc. Any chart timeframe works because the EA reads M5 and M15 itself. M5 is recommended.
5. Drag **XAUUSD_MTF_EA** (or **EURUSD_MTF_EA**) from the Navigator onto the chart. Tick **Allow live trading** and turn on **AutoTrading**.
6. The info panel in the top-left corner shows the trend, risk amount and status.

> Open the M5 and M15 charts of the symbol once so MT4 downloads their history.

## Settings you will most likely change
| Input | Default | Notes |
|-------|---------|-------|
| `RiskPercent` | 5.0 | % of balance risked per trade |
| `MaxSpreadPrice` / `MaxSpreadPips` | $0.60 / 2.0 | Raise it for wide-spread brokers |
| `MinStopPrice` / `MinStopPips` | $3 / 8.0 | Smallest stop loss allowed |
| `AllowMinLotOverRisk` | false | Gold only: lets small accounts trade 0.01 lot |
| `StartHour` / `EndHour` | 7 / 20 | **Broker server time** (shown in Market Watch) |
| `ECNMode` | false | Set to true if orders fail with error 130 on an ECN account |
| `CommissionPerLot` | 0 | Your round-turn commission, so it counts toward the risk |
| `MagicNumber` | 515151 / 616161 | Use a different number on each chart |

## ⚠️ Risk warning
**5% risk per trade is aggressive.** Running both bots at once can put **10%** at risk at the same time. Ten losses in a row, which is normal in trading, take about **40% of the account**. Most professional traders risk 0.5–2%.
No strategy is guaranteed to make money. Before trading real money:
1. **Backtest** in the Strategy Tester (Ctrl+R): symbol XAUUSD or EURUSD, model *Every tick*, chart period M5, with at least 6–12 months of data.
2. **Run it on a demo account** for several weeks.
3. Then start live with lower risk, for example 1–2%.
