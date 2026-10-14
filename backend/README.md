# Python / FastAPI 掃描 API

這個資料層提供明確的示範模式與公開資料掃描模式。離線 UI 由 Flutter 內建資料負責；真實 API 失敗時回傳錯誤，不會悄悄替換示範標的。

## 安裝與啟動

以下命令從 `martin_luk_app` 專案根目錄執行。建議 Python 3.11 或 3.12。

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r backend/requirements.txt
python -m uvicorn backend.api:app --host 0.0.0.0 --port 8000
```

Windows 啟用環境使用 `.venv\Scripts\activate`。Android 模擬器的 API 位址為 `http://10.0.2.2:8000`；實機使用同一區域網路中的電腦 IP，例如 `http://192.168.1.10:8000`，並讓防火牆允許 TCP 8000。正式部署使用 HTTPS 反向代理，避免把開發服務直接公開在網際網路。

```bash
curl http://127.0.0.1:8000/health
curl 'http://127.0.0.1:8000/v1/candidates?market=tw&demo=true'
curl 'http://127.0.0.1:8000/v1/candidates?market=us&adr_threshold=5&force_refresh=false'
```

Swagger 文件：`http://127.0.0.1:8000/docs`。伺服器不會建立或送出券商交易委託。

## API 合約

`GET /v1/candidates` 接受 `market=tw|us`、選用 `adr_threshold`、`force_refresh=true|false`、`demo=true|false`。省略 ADR 時台股使用 3.5%，美股使用 5.0%。`demo` 預設為 false。

```json
{
  "market": "us",
  "generated_at": "2026-10-13T12:45:00Z",
  "source": "yfinance/Yahoo Finance · public universe · exchange_calendars",
  "universe_count": 503,
  "stale": false,
  "warnings": [],
  "candidates": [
    {
      "symbol": "EXAMPLE",
      "name": "Example",
      "sector": "Technology",
      "market": "us",
      "adr_percent": 5.8,
      "rs_score": 98.0,
      "rs_rank": 2,
      "patterns": ["PDH突破", "均線收斂"],
      "entry_price": 100.0,
      "stop_price": 98.0,
      "is_large_liquid": false,
      "status": "confirmed",
      "data_timestamp": "2026-10-13T14:05:00Z",
      "signal_timestamp": "2026-10-13T14:03:00Z",
      "notes": ["僅為 JSON 格式說明，並非真實行情。"],
      "daily_closes": [97.0, 98.0, 100.0]
    }
  ]
}
```

價格、停損、帳戶本金使用市場原生幣別，台股為 TWD，美股為 USD。`rs_score` 是通過 ADR 與資料驗證門檻標的的相對強勢百分位，不是所有上市股票的完整百分位。空推薦陣列是正常成功結果。部分標的資料被排除或股票池回退舊快取時，`stale=true` 表示這次評估有缺漏；個股過期行情本身不會產生推薦。欄位 `generated_at` 與 K 棒時間互相獨立，命中快取也不會把舊時間改成現在。

## 股票池、指標與資料品質

- S&P 500 清單取自 Wikipedia `constituents` 表。指數組成不是依市值單純取前 500 名；同一公司多種股份類別可能使代碼數略超過 500。
- 台股取自 TWSE ISIN 官方上市清單，只保留四位數代碼且 CFI 類別 `ES` 的上市普通股，排除特別股、存託憑證與基金，再附加 `.TW`。
- 股票池 JSON 快取 24 小時；Yahoo 調整後日線快取 6 小時，分鐘線快取 5 分鐘；API JSON 回應快取 5 分鐘。磁碟寫入採同目錄暫存檔及原子替換。
- ADR 嚴格採 `SMA((High-Low)/Low,20)*100`；RS 使用對 `^GSPC` / `^TWII` 的 20、60 日超額報酬等權評分。ADR 不是 ATR。
- 均線收斂要求價格在 9/21/50 EMA 之上、均線跨度與 ATR 收縮；PDH 使用完整內包日或窄幅整理及收斂，ORH 使用完整首 1/5 分鐘 K 棒。`entry_price` / `trigger_price` 是實際 PDH / ORH 邊界，`confirmation_price` 另列已完成突破 K 棒的收盤價。觸發界線與確認價格不同，無法保證按界線成交。
- 台股沒有可依賴的 Yahoo 盤前競價成交量；08:30 評估僅能給待觀察名單。美股盤前量以累積盤前量除以平均日量為代理，不能當成同時段歷史相對量。
- Yahoo 是延遲公開行情快照；分鐘線供應、休市與請求限流都可能導致訊號不足。若基準指數只剩過期快取、所有股票資料過期、日曆不可用或當地休市，API 回 `503` 並附原因；不會用一般工作日替代交易所日曆。
- 首次完整股票池掃描可能需要數分鐘。建議提前執行下方 cache warmup。App 的 REST 等候上限為 30 秒；手機逾時後伺服器 worker thread 仍會完成掃描並寫入快取，稍後下拉更新可取得完成的結果。API 不會把冷啟動掃描假裝成即時結果。

## 停損與部位政策

Python 與 App 預設用突破當時已知的當日低點；距離大於零且不超過 5% 時保留該真實低點。當距離超過 5% 時，必須用真實 1/5 分鐘進場 K 棒低點，且緊密停損距離須在 1.5%～3%。缺少適用低點時降為 `watchlist`、`stop_price=null`，保留具體原因，絕不合成低點以通過門檻。推薦 JSON 同時提供 `day_low`、`entry_bar_low`、`stop_source` 及 `risk_per_share`（1R）。

Flutter 依使用者淨值再計算 0.5% 名目風險與向下取整股數。大型與流動性身份未確認時，保守使用 25% 上限。伺服器只有在 `LARGE_LIQUID_SYMBOLS` 指定已查核的大型股，且近 20 日成交值中位數至少達 USD 50M 或 TWD 1B 時，才標註可用 35% 上限。例如：

```bash
export LARGE_LIQUID_SYMBOLS='AAPL,MSFT,2330.TW'
```

名目停損風險不含手續費、滑價與跳空，且不是實際損失保證。這套規則是可配置的策略改編，沒有聲稱取得 Martin Luk 的官方或獨家實作。

## 選用排程與預先掃描

匯入或啟動 API 不會自動建立排程。需要定期掃描時，顯式執行下列命令；排程使用 `exchange-calendars` 的 NYSE / TWSE 交易日與開收盤資料，涵蓋美國夏令時間、假日與提早收盤。

```bash
# 立即執行並寫入與 API 共用的 JSON 回應快取。
python -m backend.scheduler --market all
# 只在美東 08:45 / 16:30、台北 08:30 / 14:00 後 10 分鐘窗口執行。
python -m backend.scheduler --market all --scheduled
# 持續每 30 秒檢查交易所排程；同一交易日與階段完成後不重複掃描。
python -m backend.scheduler --market all --loop
# 全離線 API / CLI 格式示範，不寫入真實掃描快取。
python -m backend.scheduler --market all --demo
```

Linux cron 可每分鐘檢查一次，由 Python 日曆決定該執行的市場與時間，無需依賴 cron 支援 `CRON_TZ`：

```cron
* * * * * cd /absolute/path/martin_luk_app && /absolute/path/martin_luk_app/.venv/bin/python -m backend.scheduler --market all --scheduled >> scan.log 2>&1
```

Windows Task Scheduler 設每分鐘重複執行 `python.exe -m backend.scheduler --market all --scheduled`，將 Start in 設為專案根目錄。排程和 API 必須共用同一個 `MARTIN_CACHE_DIR`。避免啟動多個排程程序；同一 API process 使用市場鎖避免重複下載，跨程序請以 cron 鎖或作業排程器的禁止重疊設定保護。不要用多個 Uvicorn workers 同時冷啟動掃描。

## 設定與驗證

環境變數：`MARTIN_CACHE_DIR`、`MARTIN_RESPONSE_TTL`（300 秒）、`MARTIN_PROVIDER_TIMEOUT`（20 秒）、`MARTIN_PROVIDER_RETRIES`（2）、`MARTIN_FETCH_WORKERS`（4）、`MARTIN_RESULT_LIMIT`（50）。瀏覽器 Flutter Web 如需 CORS，明確設定 `MARTIN_CORS_ORIGINS=http://localhost:5173`；原生 Android 不需要 CORS。

```bash
python -m pip install -r backend/requirements-dev.txt
python -m unittest discover -s backend/tests -v
```

API 測試不連線至金融網站，覆蓋 JSON 合約、ADR 包含邊界、503 故障、日曆休市、快取隔離及真實停損範圍。HTTP 合約測試使用 ASGI transport 與 inline worker 替身，以便在限制跨執行緒喚醒描述符的 sandbox 執行；production 仍用 `asyncio.to_thread`。真實資料源可用性與當日推薦數量取決於資料供應商，測試通過不代表已確認所有股票的線上分鐘行情。

## 持股報價與診斷 API

`GET /v1/quotes?market=us&symbols=NVDA,AMD&demo=true` 回傳以下格式。`demo=false`（預設）只抓取指定持股，不重掃整個股票池。台股代碼使用 `2330.TW`，美股使用 Yahoo 的 `BRK-B` 格式。一次最多 50 個不同代碼。

```json
{
  "market": "us",
  "generated_at": "2026-10-13T06:00:00Z",
  "source": "mock / fictitious portfolio demonstration",
  "quotes": [{
    "symbol": "NVDA", "name": "NVIDIA (demo)", "market": "us",
    "current_price": 159.0, "ema9": 155.0, "ema21": 150.0, "ema50": 140.0,
    "last_close": 158.0, "close_confirmed": true,
    "quote_timestamp": "2026-10-13T06:00:00Z",
    "close_timestamp": "2026-10-12T20:00:00Z",
    "source": "mock / fictitious portfolio demonstration", "is_large_liquid": true
  }],
  "errors": {}
}
```

真實報價使用最新已完成分鐘 K 棒的收盤價；盤中沒有 15 分鐘內的完整分鐘報價時，該股票回傳明確錯誤，保留既有庫存但不產生新的操作建議。非盤中可回退最近已完成日線收盤，`source` 會標註 `completed daily close only`，時間保留交易所收盤時刻，不會偽裝即時價格。EMA9/21/50 僅從交易所日曆確認的完整日 K 計算，未完成日 K 被排除；Yahoo 延遲行情仍不是交易所即時報價。未知代碼不生成任意 mock 數字。

`POST /v1/portfolio/analyze` 接收一個市場的帳戶淨值與庫存，回傳 `diagnostics`、`updated_positions`、`errors`。客戶端應保存 `updated_positions` 的已觀察最高 R 與浮動硬停損；API 本身不替不同使用者保存私有庫存。

```bash
curl -X POST http://127.0.0.1:8000/v1/portfolio/analyze \
  -H 'Content-Type: application/json' \
  -d '{"market":"us","account_equity":50000,"demo":true,"euphoria_percent":20,"positions":[{"id":"my-nvda","symbol":"NVDA","market":"us","entry_price":150,"shares":100,"initial_stop":147,"peak_r":0,"trailing_stop":147,"trailing_ema":9,"main_uptrend":false}]}'
```

每筆診斷包含 `current_r`、`peak_r`、`unrealized_pnl`、`position_value`、`exposure_pct`、`exposure_cap_pct`、`over_exposure`、`health`、`trailing_stop`、`effective_trailing_ema`、`targets`（1/2/3/5/10R 價格）、`action`（`hold` / `trim` / `exit`）、`action_label`、`reason_codes`、可執行的 `trim_shares` 與行情時間來源。所有股數為「股」，帳戶本金與行情價格必須同幣別；USD 與 TWD 分開診斷。同市場同股票只允許一筆合併庫存，需以加權成本與合計股數輸入，避免拆成多筆而繞過部位上限。

規則優先順序：

1. 現價小於或等於浮動硬停損，建議全數平倉。硬停損為原始停損、先前硬停損、已觀察至少 2R 後成本價三者最高；只能上移。`1R = entry_price - initial_stop` 永遠不因浮動停損改變。
2. 已確認完整收盤嚴格低於追蹤 EMA，建議全數平倉。盤中跌破 EMA 僅影響健康度。預設追蹤 9EMA；須使用者明確開啟 `main_uptrend=true` 且已觀察至少 3R，才採用設定的 21 或 50EMA。EMA 收盤規則與盤中硬停損分開，避免把盤中觸碰 EMA 誤當收盤出場。
3. 目前獲利至少 3R（標示最高達到的 3/5/10R）、部位市值嚴格超過帳戶 35%、或價格對 9EMA 正乖離嚴格超過 `euphoria_percent`（15～20%，預設 20%），建議分批 10%～15%。採向下取整 15% 股數，只有實際整股比例仍達 10% 才提供股數；例如僅 1 股時有訊號但無可執行減碼股數。
4. 大型／高流動性股票超過 35%、其餘超過 25% 另顯示曝險警示。中小型股票超過 25% 並不自行冒充強勢止盈訊號。低於 50EMA 優先評為 `severely_weak`，否則站上 9EMA 為 `strong`、9與21間為 `consolidating`、低於21為 `weak`。

最高 R 只由實際診斷報價逐次累積；匯入庫存不推測過去曾達 2R。持股資料只供建議，App 與 API 都不自動送出賣單，重複出現建議也不自動減少使用者庫存。

## Python 持股 JSON 資料庫

`backend/engine/exit_engine.py` 是純計算引擎，`portfolio_tracker.py` 提供型別化庫存、JSON 原子寫入與 CRUD。示例從專案根目錄執行：

```python
from backend.engine.exit_engine import Position
from backend.engine.portfolio_tracker import PortfolioTracker, demo_quote

tracker = PortfolioTracker(".cache/my_portfolio.json")
tracker.add(Position("nvda-1", "NVDA", "us", 150.0, 100, 147.0))
diagnoses, errors = tracker.diagnose({"NVDA": demo_quote("NVDA", "us")}, 50_000.0, "us")
for diagnosis in diagnoses:
    print(diagnosis.to_dict())
```

重啟後 `peak_r` 與硬停損保留。編輯名稱、股數、EMA 設定不清除觀察紀錄；若刻意修正代碼、成本或初始停損，代表新交易基礎，會將最高 R 重設零、硬停損重設新初始停損。損毀庫存檔會明確拒絕讀取，不會靜默改成空庫存並覆蓋。庫存鎖只保護同程序；多程序／多使用者正式部署應另採資料庫與身分驗證。`MARTIN_CORS_ORIGINS` 設定的 Web 來源可呼叫 GET 和 POST。
