# Aurora Bridge Setup Guide

Auto-execute trades from Aurora X directly into MetaTrader 5.

---

## What You Need

- A Windows PC or VPS (running 24/7 recommended)
- MetaTrader 5 installed and logged into your broker
- An Aurora X account with an active strategy

---

## Step 1: Create a Strategy

1. Go to **Aurora X** → **Strategy Builder**
2. Pick a pair and timeframe (e.g. EURUSD H4)
3. Configure your filters, SL, and TP settings
4. Run a backtest to verify performance
5. Go to the **Notifications** tab → **Save as Alert**
6. On your saved alert, toggle **Auto-Trade ON**
7. Set your risk settings (lot size, SL method, target accounts)

Your strategy is now live and will generate signals when conditions are met.

---

## Step 2: Get Your API Key

1. In Aurora X → **Strategy Builder** → **Trader** tab
2. Scroll to **MT5 Bridge Agent** section
3. Click **Generate API Key**
4. Copy the key (starts with `bridge_`) — keep it safe

---

## Step 3: Download & Install the Bridge Agent

1. In the same **MT5 Bridge Agent** section, click **Download**
2. Unzip `AuroraBridge.zip` on your Windows PC/VPS
3. You'll see:
   - `AuroraBridge.exe` — the bridge agent
   - `AuroraX_Copier.ex5` — the MT5 Expert Advisor

---

## Step 4: Set Up MT5

1. Open **MetaTrader 5**
2. Copy `AuroraX_Copier.ex5` into your MT5's `MQL5\Experts\` folder
   - Usually at: `C:\Users\YourName\AppData\Roaming\MetaQuotes\Terminal\[ID]\MQL5\Experts\`
   - Or the agent auto-installs it for you in the next step
3. In MT5, open **Navigator** (Ctrl+N) → **Expert Advisors**
4. Drag **AuroraX_Copier** onto any chart
5. Click **OK** (make sure "Allow Algo Trading" is enabled in MT5 settings)

---

## Step 5: Start the Bridge Agent

Open PowerShell or Command Prompt, navigate to where you unzipped, and run:

```
.\AuroraBridge.exe --token YOUR_API_KEY_HERE
```

Replace `YOUR_API_KEY_HERE` with the key you copied in Step 2.

You should see:

```
Aurora Bridge Agent v1.4
API: https://...
Token saved!
MT5 path auto-detected: ...
Listening for signals...
```

The agent is now connected. Leave it running.

---

## That's It

When your strategy conditions are met:

1. Aurora X generates a signal
2. Bridge Agent receives it instantly via live stream
3. The EA in MT5 reads the signal and places the trade
4. SL and TP are calculated automatically from your strategy settings

---

## FAQ

**Do I need to keep the agent running?**
Yes. The agent must be running for signals to reach MT5. Use a VPS if you want 24/7 execution.

**Can I run multiple strategies?**
Yes. All your active auto-trade strategies send signals through the same bridge agent.

**What if the agent disconnects?**
It auto-reconnects. Any missed signals are picked up when it reconnects.

**How do I stop it?**
Press `Ctrl+C` in the terminal, or close the window.

**How do I update my API key?**
Delete the saved config and run again with a new key:
```
del %USERPROFILE%\.aurora-bridge\config.json
del %USERPROFILE%\.aurora-bridge\token.enc
.\AuroraBridge.exe --token NEW_KEY_HERE
```

**Can I change the risk/SL/TP?**
Yes — update your strategy in Aurora X. The new settings apply to the next signal. You can also override risk % directly on the EA by changing its input parameters in MT5.
