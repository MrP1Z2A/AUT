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

## ⚡ XAUUSD Scalper (`MQL4/Experts/XAUUSD_Scalper_EA.mq4`, magic 717171)
A separate fast bot for gold. It doesn't wait for candles: it watches **every price tick**.

| What | How |
|------|-----|
| **Go LONG** | Gold jumps **up** by at least 0.6 × ATR(M1) (and at least $1.00) within **10 seconds**, and price is still near the top |
| **Go SHORT** | Gold drops **down** the same way, and price is still near the bottom |
| **Take profit** | Closes **as soon as the trade is +$2.00 in profit** (`TakeProfitMoney`). A broker-side TP sits at the same level |
| **Profit lock** | At +$1.00 the stop moves to lock in **+$0.50** (`LockProfitMoney`), then trails to keep 50% of the profit (`TrailLockPct`). A pullback closes the trade at a small profit instead of 0.00 |
| **Stop loss** | Always set: 2 × ATR(M1), at least $2. Skips the trade if the stop would be wider than $8 |
| **Time limit** | Closes any trade after 10 minutes, win or lose |
| **Multiple trades** | Up to **4 at once: 2 LONG + 2 SHORT** can be open together. Each closes at its own +$2. Same-direction entries are at least 15 s apart, and the combined stop-loss risk of all open trades is capped at **15%** of balance (`MaxTotalRiskPercent`) |
| **Safety** | 30 s cooldown per direction after a close, pauses 30 min after 3 losses in a row, max 40 trades a day, stops for the day at −10%, max spread $0.40 |

The live panel shows the size of the current surge against the size needed, the open trade's P/L against the target, and today's trades, wins and P/L.

⚠️ **The maths of tiny targets:** each win is about **$2**, but a stop loss costs about **$3–8**. The bot needs to win roughly **3 out of 4 trades** just to break even, and the spread takes a big bite out of every $2 win. Run it on **demo** for at least a week and check the "Today" line before using real money.
Backtest results for tick scalpers are unreliable in MT4, because the tester generates fake ticks inside each M1 candle. A demo account is the real test.

## Long and short
Both bots trade **both directions**:
- **Long (BUY)** when the M15 trend is **UP** and EMA 9 crosses **above** EMA 21 on M5.
- **Short (SELL)** when the M15 trend is **DOWN** and EMA 9 crosses **below** EMA 21 on M5.

On the gold bot, `TradeDirection` can limit it to longs only or shorts only.

## Gold vs EURUSD differences
| Setting | XAUUSD bot | EURUSD bot |
|---------|-----------|------------|
| Max spread | `MaxSpreadPrice` = $0.60 | `MaxSpreadPips` = 2 pips |
| Minimum stop loss | `MinStopPrice` = $3.00 | `MinStopPips` = 8 pips |
| Small-account option | `AllowMinLotOverRisk` (see below) | not needed |
| Direction choice | `TradeDirection`: long + short (default), long only, short only | always long + short |

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

## Watching the bots in real time (both bots, v1.10)
**Live panel on the chart.** It updates every second:
- A green ✔ or red ✘ for each trade condition: M15 trend, M5 EMA cross, RSI, spread, trading hours, daily loss limit and trade slots. A trade opens when all 7 are green on a new M5 candle.
- The open trade with its live P/L, the size of the next trade, a countdown to the next M5 check, and the last event.

**Push notifications to your phone** (`PushNotifications` = true). You get an alert when the bot starts, opens a trade, moves the stop to break-even, closes a trade (with profit or loss), hits the daily limit, or an order fails. To set it up:
1. Install the **MetaTrader 4** app on your phone. Go to **Settings → Messages** and copy your **MetaQuotes ID**.
2. In desktop MT4, go to **Tools → Options → Notifications**. Tick **Enable Push Notifications**, paste the ID, and click **Test**.
3. You can also log into the same account in the phone app to watch trades live. The bot itself keeps running on the PC.

**Watch it trade history quickly.** In the Strategy Tester (Ctrl+R), tick **Visual mode** and press Start. Trades appear on the chart as it replays past prices.

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
