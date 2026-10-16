# 本次交付狀態：擴充股票池與逐頁輪掃

本文件取代先前混合多次交付的歷史狀態，避免把舊測試數、舊股票池或舊推薦門禁當成本版結果。

## 最新補充：美股股票池格式與備援

版本為 1.3.1+5，新增美股文字名錄解析器、每服務 Accept、具體 HTTP／格式診斷、共用期限的有日期備援、v3 名錄快取與關閉後的寫入防護。新解析、備援與真實名錄測試均已加入建置流程；細節與覆蓋清單見 [US_UNIVERSE_FIX.md](US_UNIVERSE_FIX.md)。

已用現有 Python parser 驗證 10/15 公開鏡像共 5,115 檔；這不是 Android 或新 Dart 測試成功的證明。本環境仍沒有 Flutter SDK，新測試命令回傳 127，須由新的 Actions 結果確認。前次 v2 計時器測試修正保留。

## 最新補充 v2：在 Widget callback 返回前清理計時器

已讀取 Actions run `38690946473` 的完整日誌：v1 剩餘兩個失敗均為 pending timer invariant，而非行為斷言。v2 將兩個 auto-refresh 測試以 `try/finally` 在 callback 返回前 `dispose()`，移除同測試的重複 teardown，保留 14 個測試、原有斷言及前次零秒計時器修正。新增清理後的 timer／waiting／loading 檢查。詳見 [POLLING_TEST_FIX.md](POLLING_TEST_FIX.md)。

本機仍缺少 Flutter SDK；Docker socket 亦受沙箱限制，不能執行 Flutter 測試。已確認原始碼保留斷言與單次清理，但 v2 的成功結果仍須由新 Actions 執行確認，不能沿用上次的 62 passed / 2 failed 結果宣稱通過。

## 前次補充：背景輪詢測試時鐘

`test/backend_scan_controller_test.dart` 已在前景啟動點明確呼叫 `pump(Duration.zero)`，修正零秒計時器未執行造成的請求次數錯誤。全部 14 個測試與原有斷言保留；詳見 [POLLING_TEST_FIX.md](POLLING_TEST_FIX.md)。本次沒有修改控制器或工作流，沒有跳過門禁。

本機執行該 Flutter 測試命令因缺少 SDK 回傳 127；修正後的 Flutter 成功結果須由新的 GitHub Actions 執行確認。下列 Python／JavaScript 數字是本次股票池版本既有的檢查紀錄，不能代替此次 Dart 測試結果。

## 已提供的內容

- 台灣上市 `.TW`／上櫃 `.TWO` 及 Nasdaq／NYSE／NYSE American 可確認普通股的來源解析、排除及來源警告。
- Python 選定池預設不截斷（`MARTIN_SCAN_POOL_LIMIT=0`），有界背景工作每頁 60 檔、每批 3 檔、150ms 間隔、8 秒提供商 HTTP 期限。
- 持久化輪掃游標、按市場／ADR／名單指紋隔離的累積嘗試及成功數。仍有 remaining 時，一般前景更新每 60 秒可推進；整輪完成後回 300 秒一般快取期限。
- Flutter 代碼、來源、輪掃計數與 UI、離線搜尋字典及 HTML 同步資產、GitHub Actions／Docker／Render 設定與更新指南。

快照與進度只代表實際已取得及評估的範圍。`coverage_scanned_count` 包含失敗；`coverage_evaluated_count` 才是成功驗證。當頁推薦及 RS 不合併不同日期為全市場同步排行。服務不會在沒有後續請求時自行連續掃完全部頁面。

## 可以確認的元資料證據

隨包字典有 7,091 筆身分（US 5,113；TW 1,978：上市 1,085、上櫃 893），不是當日完整普通股核證。美股以缺少 CFI 的 NasdaqTrader 名錄做保守名稱分類，排除 150 筆未知類型；台灣身分來自不同日期來源，1,941 筆匹配舊 CFI，37 筆未匹配該舊資料。來源時間、固定來源識別、雜湊及限制完整記錄於 [stocks_master_sources.json](stocks_master_sources.json) 與 [metadata_snapshots/SOURCES.json](metadata_snapshots/SOURCES.json)。

來源鏡像 commit／字典打包時間不等於每筆身分的最新時間。這些檔案沒有用作當日價格、ADR、RS 或買點證據。

## 本次實際執行的檢查

- Python 後端：`python3 -m unittest discover -s backend/tests -v`，97 項通過。
- 門禁報告與字典維護：`python3 -m unittest discover -s scripts/tests -v`，25 項通過。
- JavaScript 搜尋 168 項、獨立預覽 222 項、庫存預覽 208 項、介面事件 53 項通過；另有 72 組 Python／HTML 庫存邏輯一致性檢查通過。
- 三份 HTML 的字典與搜尋程式完全一致；Web 靜態配置、工作流 YAML、允許的 Actions 清單與 Bash 語法通過檢查。

上述 Python／JavaScript 是固定 fixture、真實掛牌身分快照及離線互動檢查，**不是最新行情連線成功的證據**。沒有把 fixture 寫入正式行情門禁報告。

## 未完成、不能宣稱已完成的項目

本環境沒有 Flutter／Dart／Android SDK，因此沒有執行本次 Flutter analyzer、Widget／Dart 測試或 APK 編譯。原始碼與測試配置存在不等於編譯成功；請以新提交的 GitHub Actions 結果確認。

沒有代為部署 Render、取得公開上線網址、安裝手機實測或完成全市場當日行情抓取。Docker／Render 設定已提供，但不能當作容器已建置、來源已連線或服務已上線的證據。Python／JavaScript／靜態檢查結果以本次實際執行紀錄與交付回覆為準，不沿用舊版的測試項數。

## 現行 CI 門禁

CI 驗證指定必要真實行情及 ADR／EMA／RS 數學，**零推薦合法**。HTTP／解析／必要資料缺漏、指標錯誤及逾時仍阻擋 APK；不以假資料、觀察股或降低門檻補足候選。必要標的測試通過不代表所有上市股票均成功掃描。

工作流通過才產出 `martin-luk-app-release`；`martin-luk-live-scan-evidence` 保存實測日誌，保留 7 天。此份交付不包含已經在本環境成功編譯的 APK。

## 下一步驗證

1. 完整覆蓋 GitHub `fix/refresh-live-gate-20261014` 分支，保留 `.github/`，等待新的 Actions 結果。
2. Render 更新同一提交；舊服務環境變數池上限 `30` 改 `0`，頁大小／頁間隔均設 `60`，重新部署。
3. 依序檢查 `/health`、背景候選回應、來源警告、本頁及累積覆蓋數，再安裝新 APK 測試手機。

操作分別見 [ALL_STOCKS_UPDATE.md](ALL_STOCKS_UPDATE.md)、[CLOUD_API_GUIDE.md](CLOUD_API_GUIDE.md) 與 [README_HOW_TO_BUILD.md](README_HOW_TO_BUILD.md)。
