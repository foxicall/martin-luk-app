# Python API：擴充股票池與有界背景輪掃

Python API 掃描台灣上市＋上櫃普通股，以及 Nasdaq／NYSE／NYSE American 可確認普通股。Flutter 全市場輪掃請使用 `background=true`；同步端點保留給工具與相容用戶端，不應讓手機等待整個市場。正式資料失敗不切換假行情。

## 啟動

在專案根目錄使用 Python 3.11／3.12：

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r backend/requirements.txt
python -m uvicorn backend.api:app --host 0.0.0.0 --port 8000 --workers 1
```

Windows 啟用環境使用 `.venv\Scripts\activate`。Swagger 在 `http://127.0.0.1:8000/docs`。單一 worker 讓輪詢共用同一背景工作登記；不能直接改多 workers／多實例而不加入共用佇列與儲存。

```bash
curl http://127.0.0.1:8000/health
curl -i 'http://127.0.0.1:8000/v1/candidates?market=tw&background=true'
curl -i 'http://127.0.0.1:8000/v1/candidates?market=us&background=true'
```

`/health` 只表示服務程序可達，不證明金融來源或掃描成功。手機使用 5G 需實際部署的 HTTPS 根網址，詳見 [雲端指南](../CLOUD_API_GUIDE.md)；一般區網 IP 只供同網段／VPN 開發。

## 股票池來源與分類

- 台灣：`https://isin.twse.com.tw/isin/C_public.jsp?strMode=2` 上市、`strMode=4` 上櫃。保留四位數代碼及 CFI `ES` 普通股；分別附 `.TW`／`.TWO`，排除特別股、存託憑證與 ETF 等非普通股。
- 美國：`https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt` 與 `otherlisted.txt`，後者只採 NYSE／NYSE American，另納入 Nasdaq 名錄。排除測試證券、ETF、ADR／ADS、特別股、基金、權證、權利與單位等。
- NasdaqTrader 名錄沒有完整 CFI。普通股分類採保守證券名稱規則；無法確認者排除並記錄數量，可能遺漏普通股，不能宣稱百分之百官方普通股分類。來源失敗、重複代碼、未知類型及分類方式均在元資料／警告揭露。
- `universe_count` 是實際取得並通過目前規則的名單數，不是交易所所有證券總數。`universe_is_complete` 是來源／選定池範圍資訊，不表示這輪的全部行情已成功掃描，也不補足美股缺少的官方分類證據。

Flutter 直接連線另使用 TWSE／TPEx 官方**發行公司 JSON**，未逐筆取得 CFI；不能把該模式等同 Python ISIN CFI 篩選。直接連線仍是最多 30 檔核心評估或指定個股，後端模式才支援本節的逐頁輪掃。

## 背景 API 合約

`GET /v1/candidates` 接受 `market=tw|us`、`adr_threshold`、`force_refresh`、`demo`、`background`。ADR 預設台股 3.5%、美股 5.0%，`demo=false`。明確傳 `demo=true` 才使用標示為虛構展示的固定資料。

`background=true` 回傳 envelope：

```text
{
  market,
  scan: {job_id, status, stage, completed_count, total_count,
         evaluated_count, adr_match_count, failed_count, error, ...},
  snapshot: null 或已完成當頁的快照,
  retry_after_seconds
}
```

首次沒有快照且工作進行中回 `202`，App 約每 3 秒查詢。已有快照回 `200`，工作可能同時是 `running`／`failed`；快照以 `stale=true` 明示仍是舊結果並保留原始時間。工作失敗且沒有快照時回 `503`，查看 `scan.error`。`queued`、`running`、`completed`、`failed` 都有明確生命週期；背景工作期限 180 秒，失敗冷卻 30 秒。進行中的同市場工作被共用，不因重複輪詢重新啟動。

快照保留 `generated_at, source, universe_count, stale, warnings, candidates`，並提供：

| 欄位 | 範圍／語意 |
|---|---|
| `scan_pool_size`、`scan_page_size` | 本頁排定檔數，通常最多 60；尾頁可較少 |
| `scan_page_start` | 本頁從 0 起的累積位置 |
| `evaluated_count`、`adr_match_count`、`missing_symbols` | 本頁成功驗證、通過 ADR、未成功標的 |
| `coverage_total_count` | 本輪選定池總數 |
| `coverage_scanned_count` | 本輪已嘗試，**含失敗** |
| `coverage_evaluated_count` | 本輪成功驗證行情及必要指標 |
| `coverage_remaining_count` | 本輪尚未嘗試 |
| `coverage_round`、`universe_fingerprint` | 輪次與選定名單識別 |
| `universe_as_of`、`scan_completed_at` | 股票池時間與當頁完成時間，和個股 K 棒時間分開 |

`coverage_scanned_count + coverage_remaining_count = coverage_total_count`，且成功數不得大於已嘗試數。嘗試失敗仍計入本輪進度；下一輪才重新嘗試，不會把失敗當作已有有效行情。零候選是成功且合法的結果。

個股 JSON 含 `symbol, name, sector, market, adr_percent, rs_score, rs_rank, patterns, entry_price, stop_price, status, data_timestamp, signal_timestamp, notes, daily_closes`，另有觸發／確認價及實際停損來源。`watchlist` 的停損為 `null`。時間均為含時區 ISO-8601；日 K 日期附有其語意說明，不冒充最新報價時間。

## 輪掃、快取與排行

預設選定池不限檔數（`MARTIN_SCAN_POOL_LIMIT=0`），每工作只掃一頁 60 檔，每批 3 檔、間隔至少 150ms、提供商 HTTP 8 秒。最前面的頁面可優先安排核心成員，但後續游標會推進其他成員，不再永遠只掃同一批核心股。

游標儲存於 `MARTIN_CACHE_DIR/scan_coverage/<market>_<thresholdhex>.json`，依市場與 ADR 門檻分開，內容包含名單指紋、輪次、已嘗試及成功標的。指紋變更／不相容快取會重建進度；完整嘗試選定池後開始下一輪。寫入採原子替換，異常中斷可能重試已做的工作，不把未記錄的嘗試冒充完成。

仍有 remaining 時，回應快取期限是 `min(MARTIN_RESPONSE_TTL, MARTIN_SCAN_PAGE_INTERVAL)`，預設 60 秒；一般前景更新於期限後啟動下一頁，手動 `force_refresh=true` 可立即推進但仍共用進行中的工作。整輪完成後使用 300 秒一般期限。**不是伺服器無人持續全池執行器**：完成一頁不自動排完後續所有頁面，須有下一次一般更新、明確強制更新或自行配置的排程請求。

候選與 RS 百分位只代表**當頁有效標的**，不合併多頁、不同日期的結果為全市場排行。RS 使用 20／60 日對 `^GSPC`／`^TWII` 的相對動能；台灣上市及上櫃都共用加權指數 `^TWII`，不是各交易所獨立基準。

股票池快取 24 小時、日 K 6 小時、分鐘線 5 分鐘。新版名單／`responses_expanded_v2` 回應隔離舊範圍快取，原始行情時間不因讀快取更新。Render 的 `/tmp/martin_luk` 不保證重啟後持久保存；沒有付費永久磁碟。

## 設定

| 環境變數 | 本版預設 |
|---|---|
| `MARTIN_SCAN_POOL_LIMIT` | `0`，不截斷選定池；舊服務的 `30` 必須自行改掉 |
| `MARTIN_SCAN_PAGE_SIZE` | `60` |
| `MARTIN_SCAN_PAGE_INTERVAL` | `60` 秒 |
| `MARTIN_SCAN_BATCH_SIZE` | `3` |
| `MARTIN_SCAN_BATCH_DELAY` | `0.15` 秒 |
| `MARTIN_PROVIDER_TIMEOUT`／`MARTIN_PROVIDER_RETRIES` | `8` 秒／`1` |
| `MARTIN_FETCH_WORKERS` | `4`，單批仍受批次大小限制 |
| `MARTIN_SCAN_TIMEOUT`／`MARTIN_SCAN_FAILURE_COOLDOWN` | `180`／`30` 秒 |
| `MARTIN_RESPONSE_TTL` | `300` 秒；未完成輪次另受頁間隔限制 |
| `MARTIN_RESULT_LIMIT` | `50`，當頁輸出候選上限，不是全市場股票池上限 |

需要 Web CORS 時明確配置 `MARTIN_CORS_ORIGINS`；原生 Android 不需要 CORS。保留 TLS 憑證驗證，不以停用驗證解決資料源錯誤。

## 策略、風控及持股 API

ADR 採 `SMA((High-Low)/Low,20)*100`，不是 ATR。進場需有完整資料、相對動能及 PDH／ORH／收斂證據，台股盤前僅能先列觀察，不能製造美股式連續盤前量。

停損預設突破當時已知的當日低點，距離須大於零且不超過 5%；超過 5% 才可改用實際進場 K 棒低點且距離須在 1.5%～3%。不符合時只列觀察。風險預算固定 0.5%，股數向下取整，已核實大型流動性股票上限 35%，其餘 25%。名目風險不含滑價、費用與跳空損失。系統不送單。

`GET /v1/quotes?market=tw&symbols=2330.TW,6488.TWO` 只更新指定持股，一次最多 50 個不同代碼；`POST /v1/portfolio/analyze` 依固定原始 1R、保本停損、EMA 收盤及強勢分批規則回傳診斷。盤中缺新鮮分鐘報價不產生新出場建議；非盤中只用已完成日線時明示來源。私人持股由使用者端保存，API 不建立跨用戶庫存。詳見 [PORTFOLIO_GUIDE.md](../PORTFOLIO_GUIDE.md)。

## 明確啟用的排程及驗證

```bash
python -m backend.scheduler --market all
python -m backend.scheduler --market all --scheduled
python -m backend.scheduler --market all --loop
python -m backend.scheduler --market all --demo
python -m pip install -r backend/requirements-dev.txt
python -m unittest discover -s backend/tests -v
```

排程採交易所日曆，美東 08:45／16:30、台北 08:30／14:00；匯入 API 不會自動建立排程。每次執行仍是本版有界頁面評估，不能把一天兩次的頁面工作說成全市場已同時評估。自行部署排程時避免多程序重疊，保持相同快取目錄。

單元測試以可注入資料源驗證解析、分類、輪掃游標、快取、背景狀態與風控；測試不等於已成功下載全市場當日行情。真正供應商可能延遲、拒絕雲端 IP 或回 429；請保留來源、時間、警告與失敗狀態，不回退假推薦。
