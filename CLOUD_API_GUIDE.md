# Render 雲端 API：全市場逐頁掃描與手機 5G

**尚未部署服務請先依 [FULL_MARKET_SETUP.md](FULL_MARKET_SETUP.md) 操作。** 新版提供 `/v1/capabilities` 與 App 的「測試 API 連線」，可確認你部署的分支與掃描上限。API 可達不等於行情已驗證，仍需實際觸發掃描。以下完整說明保留所有輪掃與主機限制。

本版以單一 Python API 服務支援台灣上市＋上櫃、美股 Nasdaq／NYSE／NYSE American 可確認普通股。手機使用短 HTTP 請求讀取背景工作與當頁快照，不等待整池。這份交付沒有代為建立 Render 服務、部署、付費或產生實際網址。

## 1. 先更新 GitHub 原始碼

將 `martin_luk_all_stocks_20261015.zip` 解壓後，透過 GitHub 網頁完整覆蓋到 `fix/refresh-live-gate-20261014` 分支的專案根目錄。不要只上傳 ZIP，不要多一層專案資料夾。保留 `.github/workflows/build_apk.yml`，同時更新隱藏的 `.dockerignore`；細節見 [GITHUB_MANUAL_UPDATE.md](GITHUB_MANUAL_UPDATE.md)。

根目錄應有 `Dockerfile`、`render.yaml`、`backend/`、`lib/`、`android/`、`pubspec.yaml`。Docker 只複製 Python `backend/`，不需要 Flutter／Android SDK。前端輪掃欄位及股票代碼也已改變，**必須重建及安裝新版 APK**，不能只更新伺服器。

## 2. 已有 Render 服務：更新環境變數並重部署

開啟既有服務，確認部署分支為 `fix/refresh-live-gate-20261014`、Dockerfile 是此專案根目錄的 `./Dockerfile`。在 **Environment** 核對：

| Key | Value |
|---|---|
| `MARTIN_CACHE_DIR` | `/tmp/martin_luk` |
| `MARTIN_SCAN_POOL_LIMIT` | `0` |
| `MARTIN_SCAN_PAGE_SIZE` | `60` |
| `MARTIN_SCAN_PAGE_INTERVAL` | `60` |
| `MARTIN_SCAN_BATCH_SIZE` | `3` |
| `MARTIN_SCAN_BATCH_DELAY` | `0.15` |
| `MARTIN_PROVIDER_TIMEOUT` | `8` |
| `MARTIN_PROVIDER_RETRIES` | `1` |
| `MARTIN_FETCH_WORKERS` | `4` |
| `MARTIN_SCAN_TIMEOUT` | `180` |
| `MARTIN_SCAN_FAILURE_COOLDOWN` | `30` |
| `MARTIN_RESPONSE_TTL` | `300` |

舊服務最容易殘留 `MARTIN_SCAN_POOL_LIMIT=30`：一定改為 `0`。`0` 表示選定池不再限制檔數，**不是一次 HTTP 下載整個市場**。環境變數可能被平台或手動設定保留，原始碼中的新預設不一定覆蓋它。

保存後執行 **Manual Deploy → Deploy latest commit**。若服務以 Blueprint 管理，亦確認同步的新 `render.yaml` 與服務 Environment 一致。新版本會隔離舊上市／S&P 500 名單及回應快取，無需為了更新清除 App 私人持股。輪掃進度寫在快取目錄，Render 暫存磁碟重啟或部署後可能重新開始。

只保留一個 Uvicorn worker／一個服務實例。進行中的工作登記在程序內，直接增加 workers 可能讓不同輪詢讀到不同工作；多實例須另做共用工作佇列與儲存。

## 3. 沒有服務：建立 Docker Web Service

在 [Render Dashboard](https://dashboard.render.com/) 使用 **New → Blueprint**，選 `foxicall/martin-luk-app`、分支 `fix/refresh-live-gate-20261014`、根目錄 `render.yaml`。先確認方案與平台當下條件，再建立。提供的設定選 Free，沒有付費磁碟。

若介面無法選 Blueprint 分支，使用 **New → Web Service**，選相同 repository／分支、Runtime **Docker**、Dockerfile Path `./Dockerfile`、Health Check `/health`，並填入上表環境變數。若專案在 repository 子目錄，將服務 Root Directory 指向含 `Dockerfile`、`backend/` 的那一層。

等待日誌顯示 Uvicorn 監聽且服務 Live，再複製 Render 提供的公開 HTTPS 根網址。例如 `https://你的服務名稱.onrender.com` 只是格式示例，並不是本次已建立網址。

## 4. 依序驗證服務、輪掃與資料來源

將以下根網址換成自己實際的服務：

```text
https://你的服務名稱.onrender.com/health
https://你的服務名稱.onrender.com/docs
https://你的服務名稱.onrender.com/v1/candidates?market=tw&background=true
https://你的服務名稱.onrender.com/v1/candidates?market=us&background=true
```

`/health` 成功只代表程序可達。第一次沒有快照時，候選端點回 `202`，envelope 為 `{market, scan, snapshot, retry_after_seconds}`。`scan.status` 從 queued／running 進到 completed 或 failed，`snapshot` 在當頁完成後才有結果。每約 3 秒讀同一網址即可查看進度，不要每次輪詢都加 `force_refresh=true`。

已有快照時回 `200`；若正在更新或更新失敗，會保留原始快照時間並標示 `stale=true`。只有失敗且無快照時回 `503`。空的 `snapshot.candidates` 是合法成功，不代表部署失敗，也不應用假數據補足。

本版每個工作排定最多 60 檔，每批 3 檔、至少間隔 150ms，HTTP 提供商期限 8 秒，工作期限 180 秒。工作完成後請檢查：

| 欄位 | 應如何理解 |
|---|---|
| `universe_count` | 分類後實際取得的名單總數，不預先寫死 |
| `scan_page_start`／`scan_page_size` | 本頁位置／排定檔數 |
| `evaluated_count`／`missing_symbols` | 本頁成功驗證／失敗或缺漏 |
| `coverage_total_count` | 本輪選定池總數；若小於 universe_count，檢查舊池上限 |
| `coverage_scanned_count` | 已嘗試累積數，**包含失敗** |
| `coverage_evaluated_count` | 成功驗證累積數 |
| `coverage_remaining_count` | 尚未嘗試數 |
| `coverage_round` | 輪次 |

仍有 remaining 時，快照期限為 `min(300,60)` 秒。App 前景每 60 秒的一般更新可啟動下一頁，或手動強制更新直接推進；進行中的同市場工作仍會共用。整輪完成後再依 300 秒快取開始下一輪。沒有下一次請求就不會自動連續掃完所有頁，App 關閉或退到背景也不會持續驅動輪掃。

游標位於 `/tmp/martin_luk/scan_coverage/<market>_<thresholdhex>.json`，按市場／ADR 與名單指紋區分。名單改變會重建對應進度；免費服務的暫存磁碟不是永久資料庫。當頁 RS 與候選只反映該頁有效股票，不是多日期合併的全市場排名。

## 5. 安裝新 APK 與設定手機

1. 等待 GitHub Actions 依 [建置指南](README_HOW_TO_BUILD.md) 通過並產出 APK，安裝新版。
2. 開啟「設定與提醒」，關閉離線示範，正式來源選 **Python API・自訂中繼**。
3. 基底網址只填 Render 的公開 HTTPS 根網址，不加 `/health`、`/docs`、`/v1` 或 `/v1/candidates`。
4. 儲存後回總覽，台股與美股分別下拉更新。檢查本頁與累積覆蓋數，不把累積嘗試當成累積成功。

手機使用 5G 時，一般 `127.0.0.1`、`localhost`、`10.0.2.2` 與 `192.168.x.x` 不是可達的雲端網址。不要填 Render 管理頁面的 Dashboard 網址。

## 6. 範圍與故障辨識

台灣名單使用 TWSE ISIN 上市／上櫃 CFI 普通股篩選，代碼為 `.TW`／`.TWO`。美股 NasdaqTrader 沒有完整 CFI，採保守名稱分類，ADR／特別股／ETF 等及未知類型被排除並披露；不是百分之百官方分類認證。台灣上市與上櫃的 RS 目前共用 `^TWII`，不是櫃買指數。

Flutter 直接連線可載入擴充元資料，但價格評估仍限最多 30 檔核心或指定個股；台股直連官方發行公司 JSON 也未逐筆 CFI 核證。要逐頁推進整個已取得池，必須選 Python API。

Render 免費服務休眠後可能超過 App 單次 8 秒 HTTP 期限。先用瀏覽器開 `/health` 等待喚醒，再回 App 重試。若服務可達而掃描失敗，看 Render Logs、`scan.error`、單檔缺漏及來源警告；公開資料商仍可能對雲端 IP 回 403／429，部署成功不保證金融資料可用。

本包未觸發部署、未取得正式網址、未在此環境驗證新 APK。現行 CI 只要求指定真實行情及數學正確，零推薦合法，不代表當日全市場都已成功掃描。
