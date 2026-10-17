# 最新修正：1.6.1+14 兩項行情測試資料

2026-10-17（台北時間）。已讀取 commit `d8d540795478de323374069188ed46b989304e32`、run `39010655225`／job `117332338081` 完整日誌：既有 Python、風控、台美股輪掃與背景群組通過；快取群組 74 過、2 失敗，真實行情門禁與 APK／原生測試未執行。

只修 `test/market_data_api_test.dart` 的指數 URI 解碼及 `test/market_data_cache_bounds_test.dart` 的快取報價時間；保留 96 筆斷言、未來報價拒絕，增加反例測試。正式 lib／Android／CI／字典／版本與失敗 commit 不變。本機 Flutter 命令退出 127，修正後尚待新提交 Actions。原因與完整覆蓋步驟見 [CACHE_TEST_FIX.md](CACHE_TEST_FIX.md)。

---

# 最新修正：1.6.1+14 長時間快取與啟動復原

已確認舊行情磁碟快取無總量上限、離線回填 RAM 無界及輪掃重複寫入。新增 96 筆／8 MiB 編碼內容限制、共享增量 LRU、寫入排隊與逾時隔離；30 檔正常頁日誌由 13 次降為 7 次，大檢查點驗證移到 compute。升級先由原生非同步串流整理精確 Yahoo 行情 key，保留所有持股、本金及輪掃資料，歷史桌面元件透過 alias 保留。

新增 10 項行情快取、3 項保存預算、4 項原生 XML 回歸測試。CI 保留真實行情／指標門禁與零推薦規則，原生測試通過才上傳 APK。舊版基線 commit `0c25530e886bd4c6bd6ed284232e6a672df10f21` 的 run `38910623652` 已成功，不能作為本次版本結果。

本環境缺 Flutter／Dart／Android／Kotlin SDK；本次實際 Flutter 測試退出 127（command not found）。已完成靜態審查，尚未實際編譯新版、覆蓋安裝或重現兩天後 OOM／ANR，不能宣稱實機已修復。請不要清除資料，待 GitHub 新提交 Actions 後同簽章覆蓋安裝。詳細見 [LONG_RUN_RECOVERY.md](LONG_RUN_RECOVERY.md)。

本次本機已執行並通過 25 項 Python 腳本回歸測試；YAML、15 段 Bash 語法、實際 CI 的 63 個檔案預檢與 Dart 本地 import 路徑通過。另比對 21 個策略、持股、畫面、字典與真實行情門禁檔案和遠端成功基線雜湊相同。這些不等於新增 Dart／Kotlin 測試通過。

---

# 最新修正：1.6.0+13 六項畫面測試

2026-10-16（台北時間）。已讀取run `38908151003`／commit `5f2c597e7c41281bb9f085da9ac34c872cc0ce69`／job `116997415235`完整日誌。風控78項、網路／輪掃195項、台股備援39項、背景生命週期48項均通過；新增US與畫面群54項通過、6項失敗。真實行情與APK未執行。

六項均為畫面測試定位／狀態：儲存、警語展開與重試tap座標超出800×600，US來源tile未展開，停止後舊文案斷言，以及未捲到懶載入空卡片。本次只改3個test檔，等待實際layout、確認hitTestable後真實tap；保留原儲存／快取／forceRefresh／報價新鮮度檢查，暫停與870剩餘則按正式狀態精確驗證。

版本仍為1.6.0+13，正式lib、Android、資料、pubspec與CI保持該失敗commit內容。沒有縮回美股30檔，也沒有略過測試或放寬門禁。指定Flutter命令因本機缺SDK退出127，修正後仍待新提交Actions。詳見 [US_UI_TEST_FIX.md](US_UI_TEST_FIX.md)。

---

# 1.6.0+13 手機美股完整名單輪掃交付紀錄

2026-10-16（台北時間）。美股正式直連移除固定核心30選取，改為與台股共用完整名單分批輪掃；每頁最多30、每批最多5，保留網路／全流程時限。US與TW檢查點、ADR與手動暫停分市場保存，US未完成輪跨NY日界續掃並支援DST，台股原schema/key相容。

Dashboard、設定與Android通知改顯示美股真實全輪進度、本頁及下一檔；舊30檔無coverage快照明示待初始化。跨頁RS及每卡原報價時間保留，過期卡片不產新買進股數。選股與風控門檻不變。

新增US repository／polling／scope測試，遷移舊核心池測試為完整輪掃契約，保留限流、期限、個股隔離及晚到回應守護。CI在真實行情門禁前執行新增群組；允許零推薦的規則保留。

已讀取GitHub基線run `38896664051`／commit `4f19e9b97c1894b629e1d0a2585f022654bd0105`：前版1.5.0+12全部測試、真實行情門禁、APK編譯與上傳成功。這不能作為本版US輪掃測試結果；本環境缺少Flutter／Dart／Android SDK，本版仍須新提交Actions與手機驗收。見 [MOBILE_US_SCAN.md](MOBILE_US_SCAN.md)。

本機已嘗試新版US與既有TW／生命週期群測試命令，因`flutter: command not found`退出127。已通過YAML解析、13段Bash語法、實際CI的53個必要檔案預檢與專案Dart import路徑檢查；另確認31個策略／HTTP／名單／真實行情門禁／既有生命週期／Android檔案與成功基線雜湊相同。新增與更新測試的必填fixture欄位及coverage整組有做語彙檢查，但這不等於Dart編譯。

---

# 1.5.0+12 生命週期測試歷史修正

2026-10-16（台北時間）。已讀取 run `38877234917`（commit `9b289d0dcd532a39dd6297147db6bdd15aee2b8d`）完整日誌。背景服務測試群44項通過、2項失敗：新fixture漏填必填stale；原前台測試直接從paused跳resumed，違反Flutter listener的轉換契約。

本次只修改兩個測試的完整內容，補齊stale與輪掃指紋、恢復hidden／inactive轉換及安全清理，保留原有全部斷言並新增快照有效性檢查。正式Dart／Kotlin／Manifest、pubspec與工作流均保持失敗commit內容，沒有放寬門禁。

該run先前風控群78項、網路／輪掃群195項、台股備援群39項均通過；真實行情門禁與APK未執行。修正後指定Flutter命令仍因本機缺SDK退出127；尚待新提交Actions。詳見 [BACKGROUND_LIFECYCLE_TEST_FIX.md](BACKGROUND_LIFECYCLE_TEST_FIX.md)。

---

# 1.5.0+12 Android 前景服務交付紀錄

2026-10-16（台北時間）。新增使用者明確啟動的dataSync服務、常駐通知與暫停／繼續／停止。Activity與服務沿用同一FlutterEngine／Controller，不另建掃描isolate或第二個檢查點寫入者。未啟用服務時，既有切背景暫停行為保留。

原生加入前景服務與WakeLock權限、通知圖示、引擎所有權及啟動授權／取消時限；Dart加入安全平台橋接、單一poll擁有者、設定及通知進度。Mock、Python API、不支援平台不允許啟動；台股完整已取得名單續掃、美股核心池範圍不變。前台開關與明確背景服務分開。

加入平台通道、無Binding建構、Controller、設定頁及主App生命週期測試，CI同時執行既有前台生命週期與庫存Controller測試。名單服務關閉例外修正及原有全部門禁保留，允許零推薦。

本機已通過：YAML解析、12段Bash語法檢查、實際工作流48個必要檔案預檢、340個專案Dart import路徑、Android Manifest／通知圖示XML、服務權限及通道名稱一致性。已嘗試上述Flutter測試命令，因`flutter: command not found`退出127；靜態檢查不能替代Dart或Kotlin編譯。

本環境沒有Flutter／Dart／Kotlin／Android SDK，尚不能宣稱新增測試、原生APK或鎖屏實機通過。需要新提交Actions編譯與手機驗收。Doze、廠商省電、強制停止及關機仍可能中止工作，不保證每60秒準點。操作、架構及驗證限制見 [ANDROID_BACKGROUND_SCAN.md](ANDROID_BACKGROUND_SCAN.md)。

---

以下為歷史交付及已讀取的GitHub結果；不當作本版新增服務的驗證結果。

# 最新修正：名單服務關閉例外契約（仍為1.4.4+11）

2026-10-16（台北時間）。已讀取 GitHub run `38862604909` 完整日誌：3R／5R及風控群78項通過，網路／控制器／輪掃群195項通過，台股官方備援群37項通過、2項失敗。兩項都預期關閉服務回傳StateError，實際卻收到已取消HTTP的RequestAbortedException。

本次只修核心 `StockUniverseService._load` 的共用錯誤邊界：若服務已關閉，以原stack回傳StateError；一般HTTP錯誤及快取退避不變。兩項測試、全部斷言、NetworkRequest、工作流與pubspec均保持失敗commit原樣，已比對雜湊。

本機指定測試因缺少Flutter退出127，修正後仍需新提交Actions驗證。上述run的真實行情與APK步驟均未執行。詳見 [UNIVERSE_CLOSE_FIX.md](UNIVERSE_CLOSE_FIX.md)。下方為之前交付紀錄，舊版「尚未執行Dart」不代表上面已取得的CI結果。

---

# 最新交付狀態：1.4.4+11 目標價與股數分開計算

2026-10-16（台北時間）。確認原始碼會因快取或無效本金令 `PositionPlan` 為 null，而一起隱藏停損與3R／5R；截圖不足以判定1727.TW原始資料有沒有停損。

本次拆出純價格 `TradeLevels`，保持原有實際停損驗證；快取顯示帶時間的舊參考目標，買進股數仍停用。缺少停損會明確說明。新增獨立手動假設試算，停損預設空白，不修改候選或部位。

新增價格邏輯11項、手動元件8項測試，推薦元件由6項擴充為10項；工作流一併加入，原有真實行情與零推薦門禁保留。核心選股與0.5%／曝險上限不放寬。上一版CSV備援與台股進度保留。

已嘗試 Flutter 指定測試命令，退出127（未安裝SDK），不能宣稱新版Dart測試或APK已成功。已確認的1.4.2+9 GitHub成功結果僅為基線。這次仍需新提交Actions驗證。詳細操作及限制見 [R_TARGET_DISPLAY_FIX.md](R_TARGET_DISPLAY_FIX.md)。

---

以下為歷史交付紀錄；以本頁上方狀態為準。

# 最新交付狀態：1.4.3+10 官方台股 CSV 備援

2026-10-16（台北時間）。使用者已確認手機下拉會增加到 60 或更多，因此分批續掃正常；截圖中的 TWSE 名單逾時才是本次修正範圍。

- 新增官方 TWSE／TPEx CSV 備援與純 Dart 解析器。每交易所 JSON 與 CSV 共用既有網路期限，成功 JSON 不另發 CSV。
- 嚴格驗證出表日期、編碼、CSV 結構、普通股排除與 `.TW`／`.TWO`。依官方目錄月／日頻率分別採 45／7 日 CSV 保存政策，既有 JSON／舊快取 30 天限制保留；來源日期與下載時間分列。
- 依交易所保存來源與期限，保留本輪固定名單及輪掃進度。原有選股、報價、風控、零推薦門禁與前台排程不變。
- 新增 parser／備援測試並加入 CI；工作流檔案存在性預檢要求新增測試一併提交。

**已確認的 GitHub 基線結果：** run [38852597488](https://github.com/foxicall/martin-luk-app/actions/runs/38852597488)、commit `13e4cb1560b9f3a30bd2b720f173622c970aad25` 為 success，1.4.2+9 的台股續掃測試、真實行情門禁、Release APK 編譯及上傳均完成。先前「缺少推薦測試」已由該提交補齊；下方歷史紀錄保留供查閱。

**本版限制：** 新增 CSV 版本尚未由 GitHub 執行；本環境 Flutter 命令退出 127，沒有 Dart／APK 成功結果。直接讀 CSV 的沙箱請求被阻止，只確認官方政府目錄及 CSV 端點，不宣稱原始 CSV 或手機連通性已通過。原始碼、YAML／Bash、完整清單與 ZIP 檢查不等同實機成功。

使用及可直接覆蓋檔案見 [TW_OFFICIAL_CSV_FALLBACK.md](TW_OFFICIAL_CSV_FALLBACK.md) 與 `UPDATE_FILES.txt`。

---

以下為歷史交付紀錄；舊版限制及測試數不當成本次執行結果。

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
