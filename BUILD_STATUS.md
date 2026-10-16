# 本次交付狀態：擴充股票池與逐頁輪掃

本文件取代先前混合多次交付的歷史狀態，避免把舊測試數、舊股票池或舊推薦門禁當成本版結果。

## 最新補充：GitHub 缺少推薦測試及畫面更新檔

已讀取 Actions run `38851512257`（commit `79ea8cc338504ca6eac5448cb91470b7002f0723`）完整日誌，確切錯誤為 `recommendation_trade_levels_test.dart: Does not exist`。該提交的檔案樹確認缺少此測試及推薦說明，且計算機與離線預覽仍為舊版。本次提供依該提交比對的完整補齊包，保留六項測試及所有斷言，不降低門禁；正式版本維持 1.4.2+9。

工作流增加標準函式庫的必要畫面／實際引用測試存在性檢查，缺檔時在安裝 SDK 前列出明確路徑並停止，不自動生成空測試或略過。補齊及覆蓋見 [RESTORE_RECOMMENDATION_FILES.md](RESTORE_RECOMMENDATION_FILES.md)。此環境無 Flutter，沒有修正後 Dart／APK 成功證據。

## 最新補充：1.4.2+9 名單縮減與第一頁重掃修正

已確認原始碼中的重設路徑：每頁重新載入名單，單一交易所失敗可用部分成分覆寫完整快取；輪掃比較名單完全一致才續掃，因此約 1979→894→1979 會重複第一頁。本版依交易所保存原始名單／日期，本輪固定股票代碼與公司資料，直到完成才載入下一輪名單。手動強制更新仍更新行情，不在未完成輪次重新載入成分。儀表板使用同一輪的名單與累積數，新增本頁範圍／下一頁起點。

加入 8 項交易所快取測試、1 項 1085 上市＋894 上櫃跨模組測試，輪掃測試共 18 項，並新增名單縮減時畫面總數穩定的元件測試。跨模組 fixture 要求 1979 名單固定、30→60→90 續掃、跨重啟不重複請求。此環境仍無 Flutter，尚不能宣稱這些 Dart 測試或新版 APK 通過；新測試納入 Actions，真實行情門禁保留。細節見 [TW_SCAN_STABILITY_FIX.md](TW_SCAN_STABILITY_FIX.md)。

## 最新補充：1.4.1+8 推薦進出場明細

Flutter 推薦卡片與詳情計算機新增假設買價、有效初始停損／來源／幅度、1R、3R／5R 價位與各賣原始股數 15%、剩餘 70% 日收盤跌破 9 EMA 追蹤。兩個目標使用既有精確十進位 `PositionPlan`，不變更行情、輪掃、風控或持股診斷引擎。缺失、快取或無效計畫保留待確認／待更新，不合成替代停損。三份離線 HTML 同步新增欄位與比例說明。

新增六項 Flutter 元件測試，驗證台／美幣別、R 價位、缺失／快取／寬停損及本金無效情境，已加入 CI。此環境沒有 Flutter，尚無這六項 Dart 測試或新版 APK 成功證據。實際離線 Node 檢查：獨立預覽 231、互動 UI 58、持股 208、搜尋 168 項通過；這些不是連網行情證據。覆蓋與使用見 [RECOMMENDATION_LEVELS.md](RECOMMENDATION_LEVELS.md)。

## 最新修正：逐檔進度測試與批次完成點

已讀取 Actions run `38839063038` 的完整日誌：指定離線 Dart 測試群為 189 通過、1 失敗。唯一失敗為舊測試要求進度事件恰好 `[5, 10, 12]`，與服務逐檔即時發送部分快照的行為不符。本次只修改 `test/live_repositories_test.dart` 的該項測試：驗證非遞減計數、批次完成點、計數關係與 observer 錯誤隔離，原有終態精確斷言保留。正式 App、輪掃與 CI 工作流未改動，版本仍為 1.4.0+7。

本環境執行修正後測試仍因缺少 Flutter 回傳 127；尚不能宣稱通過。該 run 的真實行情門禁與 APK 建置均未執行。覆蓋與驗證見 [BATCH_PROGRESS_TEST_FIX.md](BATCH_PROGRESS_TEST_FIX.md)。

## 最新補充：1.4.0+7 手機台股完整名單輪掃

台股直接連線使用完整已取得名單，每頁最多 30 檔、有界並行、持久化本輪進度與候選；既有 60 秒前台更新會繼續下一頁，手動暫停不會被下一個 tick 取消。切換背景停止前台請求；恢復後從最近成功保存進度繼續。各股行情時間與原頁 RS 標示保留，不宣稱全市場同步排名。美股手機核心池與 Python API 協定維持原有範圍。

已讀取 Actions run `38836270967`：118 通過、4 失敗。已修正 API 按鈕在畫面外卻被測試點擊，以及 390px 設定頁右側溢位；新測試會驗證實際 HTTP 啟動，原有斷言保留。此環境仍無 Flutter/Dart SDK，本次新增 Dart 測試必須由 Actions 實際執行，不沿用歷史成功數宣稱新版 APK 成功。使用與範圍見 [MOBILE_TW_SCAN.md](MOBILE_TW_SCAN.md)。

## 最新補充：1.3.2+6 掃描範圍與雲端設定

新增總覽範圍說明、收合來源提示、API 設定入口、設定頁連線測試與後端 `/v1/capabilities`。部署與使用方式見 [FULL_MARKET_SETUP.md](FULL_MARKET_SETUP.md)。手機直連仍為有界精選池；Python API 必須由使用者先建立實際服務，再設定 HTTPS 網址。名單總數不當作已評估數，成功連線不當作行情已驗證。

本次實際執行後端 101 項與維護腳本 25 項測試，全部通過；這些為離線測試，不是公開行情實測。工作流 YAML、各 Bash 步驟語法與兩個真實門禁的先後順序檢查亦通過。新增 Dart 測試已寫入 CI，現有真實行情與美股名錄門禁保留，零推薦仍合法。此環境沒有 Flutter SDK，Dart 測試命令回傳 127，不宣稱新版 Dart 測試或 APK 已通過；沒有代為部署雲端服務。下列舊測試結果屬先前版本紀錄。

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
