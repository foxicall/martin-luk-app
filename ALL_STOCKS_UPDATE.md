# 全市場擴充覆蓋指南

本次完整包為 `martin_luk_all_stocks_20261015.zip`。範圍由「台股上市＋美股 S&P 500」改為「台灣上市＋上櫃普通股，以及 Nasdaq／NYSE／NYSE American 可確認普通股」。Python API 每次處理有界的一頁，App 顯示本頁及本輪累積覆蓋，不再把固定核心池稱為全市場。

## 更新後的三種範圍

| 用途 | 新範圍與限制 |
|---|---|
| Python 連網股票池 | 台股 TWSE ISIN 上市／上櫃 CFI `ES` 普通股；美股 NasdaqTrader 兩名錄保守名稱分類，未知類型排除並披露 |
| Flutter 直接連線 | 可載入擴充元資料，但價格評估仍限最多 30 檔核心或指定個股；台股官方發行公司 JSON 未逐筆 CFI 核證 |
| 離線搜尋 | 7,091 筆隨包身分快照，US 5,113、TW 1,978；不同日期來源，不保證當日完整成員 |

台灣上市代碼加 `.TW`，上櫃加 `.TWO`；美股股份類別使用 Yahoo 的 `-` 格式。普通股範圍排除 ADR／ADS、特別股、ETF、基金、權證、單位等；美股名錄沒有完整 CFI，保守規則仍可能漏收普通股，不能稱百分之百官方分類認證。來源與所有限制見 [stocks_master_sources.json](stocks_master_sources.json)、[metadata_snapshots/SOURCES.json](metadata_snapshots/SOURCES.json) 及 [SEARCH_GUIDE.md](SEARCH_GUIDE.md)。

## 1. 完整覆蓋 GitHub 分支

備份現有專案，解壓 ZIP，在 GitHub 網頁切換到 **`fix/refresh-live-gate-20261014`**，使用 Add file → Upload files 上傳解壓後的專案內容。根目錄必須直接有 `pubspec.yaml`、`lib/`、`backend/`、`android/`、`Dockerfile`、`render.yaml`，不要只放 ZIP 或多一層資料夾。

保留隱藏 `.github/` 與 `.dockerignore`，同時更新字典、來源快照、三份 HTML、Dart 模型／UI、Python 與測試。不要把私人 `.env`、keystore、密碼、快取或 build 目錄提交。詳見 [GITHUB_MANUAL_UPDATE.md](GITHUB_MANUAL_UPDATE.md)。

## 2. Render 舊服務必須改環境變數

在服務 Environment 將原來的 `MARTIN_SCAN_POOL_LIMIT=30` 改成 **`0`**，另確認：

```text
MARTIN_SCAN_PAGE_SIZE=60
MARTIN_SCAN_PAGE_INTERVAL=60
MARTIN_SCAN_BATCH_SIZE=3
MARTIN_SCAN_BATCH_DELAY=0.15
MARTIN_PROVIDER_TIMEOUT=8
MARTIN_PROVIDER_RETRIES=1
MARTIN_FETCH_WORKERS=4
MARTIN_SCAN_TIMEOUT=180
MARTIN_SCAN_FAILURE_COOLDOWN=30
MARTIN_RESPONSE_TTL=300
```

`0` 是「不截斷選定股票池」，不是無限制並行下載。平台舊環境值可能覆蓋新程式預設，必須在已存在的服務內實際核對。保存後確認分支與提交，選 Manual Deploy → Deploy latest commit。沒有服務時依 [CLOUD_API_GUIDE.md](CLOUD_API_GUIDE.md) 建立；這份包沒有替你建立服務或提供真實上線網址。

## 3. 理解背景輪掃

首次以 `/v1/candidates?market=tw&background=true`（美股用 `market=us`）取得 `202`，不等待全池。App 每約 3 秒查同一工作；工作成功後取得 `200` 當頁快照，空候選合法；失敗會有終止狀態與原因。有舊快照時保留原始時間並標示 stale，不變成現在的新行情。

每工作一頁最多 60 檔，每批 3 檔、150ms 間隔，HTTP 期限 8 秒。當頁完成且尚有剩餘時，回應快取期限為 `min(300,60)` 秒；App 在前景每 60 秒一般更新可推進下一頁，或手動強制更新立即請求下一頁。進行中的同市場工作共用，反覆輪詢不另開工作。整輪完成後使用 300 秒一般期限，再開始下一輪。

**這不是無人連續全池排程。** App 背景停止前景更新，伺服器也不會只因完成一頁便自動排完所有剩餘頁。需要其他固定頻率請明確配置伺服器排程；每次排程仍是一頁評估。

## 4. 正確閱讀覆蓋與排行

| 欄位 | 解讀 |
|---|---|
| `universe_count` | 本次分類後取得的市場名單總數 |
| `scan_page_start`／`scan_page_size` | 本頁起點（0 起）／排定檔數 |
| `evaluated_count` | 本頁成功驗證數 |
| `coverage_total_count` | 這輪選定池總數；預設池上限 0，不截斷名單 |
| `coverage_scanned_count` | 累積已嘗試，**含失敗** |
| `coverage_evaluated_count` | 累積成功驗證 |
| `coverage_remaining_count` | 尚未嘗試 |
| `coverage_round` | 這是第幾輪 |

全部已嘗試不保證全部成功，失敗數與來源警告仍須查看。RS 百分位和候選清單只比較當頁有效標的，不混合多頁、多日期為全市場同步排行榜。美股仍對 `^GSPC` 做相對動能；台灣上市與上櫃共用 `^TWII` 加權指數，不是櫃買指數或每交易所獨立排行。

## 5. 快取與斷點

輪掃游標位於 `MARTIN_CACHE_DIR/scan_coverage/<market>_<thresholdhex>.json`。市場與 ADR 門檻分開，名單指紋改變會重建對應進度。完整嘗試名單後才開始下一輪；失敗嘗試不計為成功。

新版名單與 `responses_expanded_v2` 回應隔離舊版只含上市／S&P 500 的快取；新 Flutter 亦使用新版股票池鍵。無需為了清市場快取刪除所有 App 私人庫存。Render 免費服務 `/tmp/martin_luk` 不承諾永久保存，重新部署／休眠重啟可能重置游標與行情快取。

## 6. 重建及安裝新 APK

更新 Actions workflow，等待指定真實行情與計算門禁通過後下載 `martin-luk-app-release` artifact。現行門禁允許推薦為零，不以假行情、觀察股或放寬條件補數；它不認證所有市場股票當天均已下載。

安裝新版 APK，在設定關閉 Mock、選 Python API，保存實際 HTTPS 根網址，不附加 `/v1` 或 `/health`。5G 不使用一般家中 `192.168.x.x`、localhost 或模擬器位址。先看 `/health`，再看台股／美股背景回應，最後看 App 本頁與累積覆蓋。

本環境沒有 Flutter SDK，尚未實際編譯新 APK、部署 Render、取得網址或完成手機驗證。完整建置及狀態見 [README_HOW_TO_BUILD.md](README_HOW_TO_BUILD.md) 與 [BUILD_STATUS.md](BUILD_STATUS.md)。
