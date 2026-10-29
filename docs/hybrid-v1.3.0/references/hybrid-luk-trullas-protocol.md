# hybrid-luk-trullas-protocol.md
---
name: hybrid-luk-trullas-screening-and-trading-protocol
description: 結合 Martin Luk 動能波段掃描與 David Trullás 多週期量價訂單流之高勝算選股與精準執行協定（Codex Agent 規範）
version: 1.0.0
author: System Operator
tags: [stock-screening, swing-trading, order-flow, footprint, volume-profile, risk-management, usic, codex-skill]
---

# Hybrid Luk-Trullás 量化選股與多週期訂單流交易協定 (SKILL.md)

本協定融合了兩位頂尖實盤冠軍的核心競爭力：
1. **Martin Luk（美國投資大賽 USIC 冠軍）**：專精於高動能股票池篩選（ADR > 5%）、三重掃描架構、緊密盤整突破、非對稱風報比（5:1 R:R）及固定 0.5% 資本風險模型。
2. **David Trullás（Robbins World Cup 期貨當沖多度冠軍）**：專精於「俄羅斯套娃（Matrioska）」多週期巢狀分析、大盤/板塊背景共振、成交量分佈（Volume Profile）、K 棒內部成交量集群（Volume Cluster / Footprint）、機構大單追蹤（Big Trades）及微觀級別極窄停損（Surgical Stop-Loss）。

---

## 模組一：總體市場背景與監管市場過濾 (Macro Context & Market Filters)

在啟動個股掃描之前，Codex Agent 必須先通過大環境安全審查，排除系統性風險：

```
[市場總體審查 (Macro Check)]
   ├── 1. 嚴格限定「中央監管市場 (Regulated Market)」
   │     • 標的必須為紐約證交所 (NYSE)、納斯達克 (Nasdaq) 或 CME 正式期貨/股票。
   │     • 嚴禁非監管場外衍生品 (OTC)、撮合商滑點平台或報價不透明之交易所。
   │
   ├── 2. 領頭指數與板塊共振 (Index & Sector Confluence)
   │     • 基準指數檢驗：納斯達克 100 (QQQ / NQ) 與標普 500 (SPY / ES) 日線維持多頭趨勢。
   │     • 權益曲線與市場情緒：
   │         - 避免於大盤出現極度狂熱情緒 (Extremo de Optimismo) 時大幅追高。
   │         - 監控巨頭支柱股 (Pillar Mega Caps: AAPL, MSFT, NVDA) 結構穩定度。
   │
   └── 3. 排除合約換月期異常 (Rollover / Noise Filter)
         • 若為期貨標的，換月週（週一至週三）成交量移轉期間，Big Trades 演算法失真，暫停微觀依賴。
```

---

## 模組二：Martin Luk 動能股票池過濾與三重掃描器 (Universe Filtering & Scanners)

### 2.1 硬性基礎過濾條件 (Hard Baseline Screener)
Codex 篩選腳本必須每日盤前對全市場美股運行以下量化篩選條件：

```python
# 基礎選股過濾條件 (Python / Pandas 邏輯規範)
def base_universe_screener(df):
    selected = df[
        (df['adr_20'] >= 5.0) &                    # 20日平均每日真實波幅 >= 5% (確保動能充足)
        (df['market_cap'] >= 100_000_000) &        # 市值 >= 1 億美元 (排除殭屍仙股)
        (df['dollar_volume_20'] >= 50_000_000) &   # 20日日均成交額 >= 5,000 萬美元 (確保充足流動性)
        (df['close'] > df['ema_21']) &             # 股價位於 21 EMA 之上
        (df['ema_9'] > df['ema_21']) &             # 均線多頭排列：9 EMA > 21 EMA
        (df['ema_21'] > df['ema_50'])              # 21 EMA > 50 EMA
    ]
    return selected
```

### 2.2 三重掃描器運作機制 (The Three-Scanner Engine)
1. **盤前掃描器 (Pre-Market Gap & Volume Scanner)**：
   * **條件**：盤前跳空幅長度 `Gap Up >= 4%`，且盤前成交量超越個股近期盤前平均。
   * **目標**：識別由財報催化劑、地緣題材或重大新聞引發的**片段轉折點（Episodic Pivot, EP）**。
2. **強勢股掃描器 (Potent Sector Movers Scanner)**：
   * **條件**：前一交易日漲幅前 3% 且成交量放大之個股。
   * **目標**：捕捉主流熱門板塊輪動（如 AI 基礎設施、國防防務科技、核能鈾礦、特定大宗商品）。
3. **領頭羊名單掃描器 (Leader / Relative Strength Scanner)**：
   * **條件**：1 個月與 3 個月相對強勢指標（RS Rating）排名前 5%。
   * **動態廣度信號**：若清單內處於 `9 > 21 > 50 EMA` 的個股數量持續擴張，代表市場環境具備高攻擊性；若持續縮減，則收縮倉位。

---

## 模組三：David Trullás 俄羅斯套娃多週期結構審查 (Matrioska Structural Filter)

通過初篩的標的，必須嵌入 David Trullás 的「多週期巢狀框架」，確認大級別空間與重要關鍵價位：

```
[俄羅斯套娃架構 (Matrioska Timeframe Pipeline)]
   │
   ├── 1. 宏觀層 (Daily & 1-Hour Chart) ── 「不可妥協的視角 (Innegociable)」
   │     • 成交量分佈 (Volume Profile)：標註固定週期之 POC (Point of Control) 與價值區高低點 (VAH/VAL)。
   │     • 關鍵分水嶺：黃金分割比率 (Fibonacci 61.8% / 50% / 38.2%) 與 道氏理論 2/3 (66.6%) 反彈阻力區。
   │     • 結構判定：股價不可直接撞擊上方巨大的歷史未消化量價密集區（Muro / Cluster de Volumen）。
   │
   ├── 2. 波段結構層 (5-Minute Chart)
   │     • 觀察形態收斂：尋找窄幅內包日（Inside Day）、均線密集纏繞（EMA 9/21/50 Convergence）。
   │     • 支撐回測質量：拉回時成交量必須呈現顯著遞減（Volumen Decreciente）。
   │
   └── 3. 微觀執行層 (1-Minute, 30-Second & 5-Second Chart)
         • 用於精確下單（Cirujano / 外科手術式進場），在微結構衰竭轉折點進場，極致壓縮停損點。
```

---

## 模組四：量價微觀結構與訂單流驗證 (Volume & Order Flow Confirmation)

在觸發進場訊號的關鍵瞬間，Codex 必須依據 David Trullás 訂單流原則進行微觀確認，防止假突破與主力倒貨：

### 4.1 成交量不對稱性與衰竭驗證 (Volume Divergence / Asymmetry)
* **拉回做多法則**：若股價在測試支撐時連續創出微觀新低，但下方成交量呈現階梯式遞減（四次或以上連續萎縮），視為**賣盤力竭訊號（Agotamiento）**。
* **突破確認法則**：價格向上突破時，成交量必須呈現實質放大。若出現實體極長但內部成交極少之「空心 K 棒（Vela Hueca）」，嚴防假突破回補。

### 4.2 K 棒內部集群分佈 (Intra-bar Volume Cluster / Footprint)
* **推進位置檢驗**：觀察 K 棒內部最大成交價格（TIC de Mayor Negociación）：
  * **優良多頭推動**：最大成交集群位於 K 棒實體的**中下半部（Pompi / 後保險桿推進）**。
  * **多頭警訊 / 阻力形成**：若長紅棒的最大成交集群集中在**最上緣或長上影線（Cabeza / 窒息阻力）**，表明主力大量賣單（Ask 吸籌/倒貨），短線易回調。

### 4.3 機構大單與 Delta 驗證 (Big Trades & Delta Checks)
* **大單訊號（Big Trades / Bolitas de Navidad）**：在 5 分鐘圖上監控機構瞬間市價掃單。當大單在關鍵支撐密集湧現時，代表多頭防守確立。
* **Delta 陷阱過濾**：
  * 切勿盲目迷信「正 Delta 即做多」。
  * 若出現極大正 Delta（Ask 買盤狂熱）但股價無法創新高，代表遭遇限價被動大賣單吸收（Absorption），不得進場。

---

## 模組五：精準進場觸發協定 (Execution Entry Protocols)

結合 Luk 的價格形態突破與 Trullás 的訂單流確認，僅在符合下列三種特定條件時觸發進場：

```
                              ┌── 協定 A：PDH 前日高點均線密集突破 (Luk Base Breakout)
[Hybrid 觸發協定 (Triggers)] ──┼── 協定 B：開盤區間突破與跳空催化 (Episodic Pivot ORH Breakout)
                              └── 協定 C：回調均線與量能衰竭 V 轉 (EMA Pullback with Volume Exhaustion)
```

### 協定 A：前日高點均線密集突破 (PDH Breakout)
1. **日線條件**：標的出現窄幅盤整，9 EMA、21 EMA 與 50 EMA 高度糾結收斂。
2. **觸發點**：開盤跳空於前一日區間上緣，在 1 分鐘或 5 分鐘級別突破**前一日高點 (Prior Day High)**。
3. **Trullás 確認**：突破當下 Bid/Ask 比率健康，無嚴重空心撮合。
4. **停損錨定**：設定於突破日當日低點（Breakout Day Low）；若距進場點 > 3.5%，則下移至觸發該突破之 5 分鐘 K 棒低點。

### 協定 B：片段轉折點開盤區間突破 (ORH Episodic Pivot)
1. **背景條件**：盤前跳空 > 4% 且量能暴增（財報或突發實質利多）。
2. **觸發點**：開盤前 1–5 分鐘標記開盤區間高點（Opening Range High, ORH）與低點（ORL）。價格放量突破 ORH 瞬間進場。
3. **Trullás 確認**：5 分鐘圖上偵測到 Big Trades 機構買盤介入。
4. **停損錨定**：直接設定於開盤區間低點（ORL）。

### 協定 C：均線支撐衰竭回調進場 (Confluence Dip Entry)
1. **背景條件**：強勢股沿 9 EMA / 21 EMA 上行，短線拉回測試 9 EMA、21 EMA 或 AVWAP。
2. **觸發點**：在 30 秒至 1 分鐘圖上出現量能顯著衰竭（成交量持續遞減）之微觀新低，隨後出現一根 V 型微型反轉陽線，突破前一根微觀 K 棒高點時進場。
3. **停損錨定**：精確放置於該衰竭微觀最低點下方 1 個 Tick（Surgical Stop）。

---

## 模組六：部位規模、幾何風控與出場框架 (Sizing, Risk & Exit Protocol)

### 6.1 固定資本風險部位計算 (Position Sizing Logic)
嚴格執行 Martin Luk 的 0.5% 單筆資本風險限制，利用極窄停損換取部位放大與非對稱 R 倍數：

$$\text{買入股數 (Shares)} = \frac{\text{總帳戶資產 (Total Equity)} \times 0.005}{\text{進場價格 (Entry Price)} - \text{停損價格 (Stop Price)}}$$

* **投資組合曝險上限**：
  * 大型高流動性個股最大曝險不得超過總權益的 **35%**。
  * 中小型高波幅個股（Small/Micro Caps）最大曝險不得超過 **25%–30%**（防範跳空風險）。

### 6.2 交易管理與衝浪出場策略 (Surfing & Exit Framework)

```
[進場成交]
   │
   ├── Step 1: 立即掛出系統硬停損單 (Hard Stop Order)，絕無例外。
   │
   ├── Step 2: 保本上移 (Break-Even Plus)
   │     • 當獲利達 +1.5R 至 +2R，或股價拉開 15-20 點時，立即將停損移至「進場價 + 覆蓋手續費水平」。
   │
   ├── Step 3: 強勢分批獲利 (Selling into Strength - Luk & Trullás 技巧)
   │     • 碰觸 David Trullás 標記之大週期黃金分割位 (61.8%) 或道氏 2/3 (66.6%) 阻力區。
   │     • 未實現獲利達到 3R 至 5R，或股價偏離 9 EMA 達 15% 以上。
   │     • 執行：分批獲利了結 10%–15%（或平倉大合約，保留微型 Micro 跑者/Pizza 合約）。
   │
   └── Step 4: 弱勢移動停損出場 (Trailing Stop into Weakness)
         • 主力移動停損線：日線有效跌破 9 EMA 即全數平倉。
         • 超強趨勢：若進場成本極具優勢且處於主升浪，防守底線放寬至 21 EMA。
```

---

## 模組七：Codex 自動化執行狀態機 (Agent State Machine)

```
   ┌────────────────────────────────────────────────────────┐
   │ 狀態 0: IDLE (盤前 30-45 分鐘)                          │
   │ • 運行大盤背景審查 (QQQ/SPY 趨勢 & 波動度檢查)            │
   │ • 運行三重掃描器：提取 ADR >= 5%、多頭排列之候選清單       │
   └───────────────────────────┬────────────────────────────┘
                               │
                               ▼
   ┌────────────────────────────────────────────────────────┐
   │ 狀態 1: STRUCTURAL ANALYSIS (套娃結構標記)             │
   │ • 在 1H / Daily 圖計算 Volume Profile (POC/VAH/VAL)    │
   │ • 繪製斐波那契 61.8% / 道氏 66.6% 阻力空間與大單集群    │
   │ • 排除上方直接緊鄰巨量阻力牆 (Cluster) 之標的           │
   └───────────────────────────┬────────────────────────────┘
                               │
                               ▼
   ┌────────────────────────────────────────────────────────┐
   │ 狀態 2: SIGNAL DETECTION (開盤動態監控)                │
   │ • 追蹤 PDH 突破、ORH 跳空突破或 EMA 拉回               │
   │ • 檢查微觀成交量不對稱性 (拉回量縮 / 突破放量)          │
   │ • 驗證 Footprint 集群推進方向 (無頂部阻滯 / 無空心阻礙) │
   └───────────────────────────┬────────────────────────────┘
                               │
                               ▼
   ┌────────────────────────────────────────────────────────┐
   │ 狀態 3: EXECUTION (精準開倉與硬風控掛單)               │
   │ • 計算股數 (Risk <= 0.5% Total Equity)                 │
   │ • 送出 OCO / 市價 / 限價突破單                          │
   │ • 成交後毫秒級自動掛出 Hard Stop                       │
   └───────────────────────────┬────────────────────────────┘
                               │
                               ▼
   ┌────────────────────────────────────────────────────────┐
   │ 狀態 4: POSITION SURFING (持倉監控與動態管理)           │
   │ • 獲利延伸 > 1.5R 立即推至 Break-Even                   │
   │ • 達阻力目標或 > 3R-5R 分批停利 10%-15%                │
   │ • 日線跌破 9 EMA 觸發 Trailing Stop 全數平倉           │
   │ • 更新個人權益曲線 (若處回撤期，下筆交易風險降至 0.25%)  │
   └────────────────────────────────────────────────────────┘
```
