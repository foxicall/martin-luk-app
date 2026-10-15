# 現行建置門禁：真實行情與計算正確，允許零推薦（2026-10-15）

使用者已明確選擇「驗證真實行情與計算正確即可建置，允許推薦為零」。本段取代下方歷史紀錄中「至少一檔推薦才建置」、「休市或零推薦必須阻擋 APK」的舊規則；沒有調低任何選股或風控條件。

現行流程為 Python 報告驗證器測試 → Flutter RS／策略／風控單元測試 → Mock 關閉的實際 HTTP 行情與指標驗證 → `scripts/validate_live_scan_evidence.py` 驗證 schema 2 報告 → 正式 APK。真實驗證在 15 秒工作期限內取得 `^GSPC`、`^TWII` 與必要五檔 NVDA、AAPL、TSLA、2330.TW、2603.TW，獨立核對 ADR、EMA 9／21／50、20／60 日 RS。HTTP／解析、必要股票缺漏、指標錯誤與逾時仍使工作流失敗；`candidates: []` 正常通過。不能用假資料、觀察股或降低 ADR／突破／停損門檻補足候選。

原策略仍要求新鮮正常交易時段 PDH／ORH 確認和實際停損；存在嚴格推薦時核對 1.5%～3% 停損、單筆 0.5% 風險、35%／25% 曝險與 3R／5R／10R 目標。即使實測沒有推薦，前置可重現單元測試也必須驗證風控與型態行為。

已只讀核對 GitHub [run 38662579836](https://github.com/foxicall/martin-luk-app/actions/runs/38662579836)：台北 2026-10-15 08:55、約 2661ms，22 檔評估成功、7 檔仍受遠端舊 RS 日期判斷影響，確認推薦為零；當時台股未開盤、美股已收盤。該 run 不等於本次健康門禁已通過。覆蓋包需同時包含 `market_data.dart`、`live_strategy_engine.dart` 的 RS／完整日 K 修正，不能只改測試。

本次實際執行報告驗證器的 16 項 Python 單元測試全部通過；工作流 YAML、所有 run 區塊的 Bash 語法、門禁先於建置及失敗傳遞的靜態檢查通過。這些結果不代表 Dart 或真實行情測試已執行。

本地沒有 Flutter／Dart／Android SDK，Flutter 命令曾實際回傳 `command not found`（exit 127）。本次來源／Python 驗證不能當作 Flutter 測試、最新實測或 APK 已成功；實際結果以覆蓋後的 GitHub Actions 為準。未執行 Git、Push 或 GitHub 寫入。現行工作流只保留 `martin-luk-live-scan-evidence` 日誌（不論成敗）及 `martin-luk-app-release` APK（通過才產出），保留 7 天；沒有 Android setup action、補丁更新器、來源 ZIP 或 Web artifact。

以下為歷次交付紀錄。當中的舊門禁、產物名稱、SDK 安裝步驟與「最新」字樣只描述當時狀態，現行流程以上段和 `.github/workflows/build_apk.yml` 為準。

---

# 歷史紀錄：RS 共同比較端點與完整日 K 判定（2026-10-15）

實際 GitHub [run 38658658054](https://github.com/foxicall/martin-luk-app/actions/runs/38658658054) 已成功取得真實行情，但在股票與大盤最新完整交易日的同步檢查失敗；這不代表推薦門禁或 APK 已成功。目前證據未記錄雙方完整日期，不能斷言是哪個標的或 session metadata 時間造成差異。

RS 改用相同的最新 61 個共同完整交易日計算 20／60 日報酬，任一側最多容許 1 個尾端交易日差，共同日期距任一抓取日不得超過 7 曆日；超過範圍、歷史不足或跨市場資料仍拒絕。評估明示 RS 截止日期與未納入尾端天數，股票日 K 落後大盤時只供觀察，不確認新進場。當供應商交易時段已滾至次日，當日 K 仍需通過收盤後 15 分鐘及收盤附近原始報價時間檢查；缺少時段資訊或尚未完成的當日 K 不納入。

新增 `test/rs_alignment_test.dart` 與相應策略回歸案例；未調低 ADR、突破、停損、0.5% 風險或 35%／25% 曝險條件。本地實際嘗試 `flutter test test/rs_alignment_test.dart test/live_strategy_engine_test.dart test/market_data_api_test.dart`，回傳 `flutter: command not found`（exit 127）；本地沒有 Flutter／Dart，這次 Dart 測試未能執行，也尚未驗證成功產出真實推薦或 APK。以下保留先前紀錄，現行 RS 政策以本段及來源為準。

# 真實行情測試缺檔修復（2026-10-14）

已只讀取得 GitHub run 38569992723 的完整日誌，錯誤為 `Failed to load test/integration_scan_test.dart: Does not exist.`，該修復分支的檔案 GET 也回傳 404。工作區完整測試檔已在 main 第一行初始化 TestWidgetsFlutterBinding；現在緊接著初始化本機儲存測試替身，真實 HTTP 與策略門禁不變。CI 先檢查測試檔存在，避免缺檔被誤判成 Dart 編譯錯誤。GitHub 上仍需手動新增完整測試檔並提交；沒有執行 Git 或 GitHub 寫入。

來源／資產／匯入／YAML 靜態檢查通過。本機 Flutter 測試命令回傳 exit 127（Flutter 未安裝），尚未實際驗證真實行情或 APK 成功。

# 直接修復 NetworkRequest 與來源建置（2026-10-14）

`network_request.dart` 提供預設 8 秒、可指定最多 10 秒及儲存上限 5 秒常數；保留 http.Client 注入、瀏覽器 Headers、5 筆 FIFO 名額、完整本文逾時、中止與 close。一般服務使用 8 秒預設、股票池本機讀寫維持 2 秒。工作流不執行任何補丁更新器；真實推薦門禁仍須成功才建置 APK。已補空 headers／逾時設定測試；執行 Flutter 測試得到 exit 127（未安裝 Flutter）。

# 市場批次評估更新（2026-10-14）

直連模式優先掃描最多 30 檔真實股票池成員，每批 5 檔、間隔 150ms，逐批顯示已處理、成功、ADR、確認與失敗數。單檔錯誤隔離，停止與 finally 釋放刷新操作；市場掃描為 9 秒、控制器獨立硬逾時計時器上限 10 秒，HTTP 與報價短期限維持 8 秒。有效空快照與全部行情失敗分開處理。

已移除 Actions 對補丁更新器的執行依賴；直接覆蓋原始碼，建置只使用 Checkout 的版本。實際執行回歸命令回傳 `flutter: command not found`（127）；沒有宣稱 Dart 分析、Flutter 測試、真實行情或 APK 已成功。

以下保留先前各次修復紀錄；本段的市場掃描期限取代舊版 6／8 秒全掃描期限。

# 本次交付的驗證狀態

## MarketAPI 詳細日誌（2026-10-14 最新）

依最新要求，僅在行情服務加入 `debugPrint` 副作用，不修改 ADR、EMA、RS、停損、部位及出場計算。日誌包含載入／共用請求、每次 HTTP 請求開始、收到標頭時的狀態碼、非 200 本文前 200 個 Unicode 字元、驗證後價格／K 棒數、快取標記、逾時及其他例外的型別與階段。

使用 `String.fromCharCodes(...runes.take(200))`，沒有對 Dart String 呼叫不存在的 `take`；本文日誌最多解碼前 1024 bytes 並容許無效 UTF-8，避免日誌本身產生解析例外。狀態碼在完整本文下載之前印出，有助識別本文卡住。訊息在 Android Logcat 可用 `[MarketAPI]` 搜尋，並不自動顯示於 App 畫面。

此前已授權的 Headers、JSON／個股隔離與控制器修復保留；所有計算模組此次未修改。環境無 Flutter SDK，尚未執行 Dart 測試或實機日志；來源／打包檢查不代表 Android 已實測成功。沒有執行 Git、GitHub 寫入或重試授權。

## 行情 API 單檔依賴與 Null-safety 修復（2026-10-14 最新）

`market_data_api.dart` 改為直接持有原生 `http.Client`，移除 `network_request.dart` import 與所有 `NetworkRequest` 引用。8 秒／2 秒常數、完整本文逾時取消及跨行情實例的 5 筆 FIFO 名額全部位於同檔；使用 `http ^1.5.0` 的 `AbortableRequest`，不需要另外新增傳輸 helper 檔案。

重試抽成回傳 `Future<http.Response>` 的方法，每次回應明確宣告 `final http.Response`，不存在 `http.Response?` 的 `statusCode`／`headers` 存取。保留一次 429 重試、同一 8 秒總網路期限、真實快取與失敗後清理。新增本文掛起後取消／重試及跨兩行情實例的並行上限測試，行情 API 測試共 22 個。

此處只完成程式檢閱、依賴與交付完整性檢查；沒有 Flutter SDK，未執行 Dart analyzer、測試或 APK 編譯。依使用者指示沒有執行 Git、GitHub 寫入或追加授權。以下為先前交付紀錄。

## 刷新期限與真實推薦建置門禁（2026-10-14 最新）

新增共同 HTTP 層：8 秒期限包含完整本文、429 退避與重試，逾時取消請求；本機快取讀寫最多 2 秒。Controller 以操作所有權與 `finally` 釋放鎖，整體刷新及強制更新排隊共用 8 秒期限，阻止遲到回應／錯誤污染下一次更新。直接 Repository 預設 6 秒整批預算、每批 4 檔與批次間隔 100ms，發布真實部分覆蓋或原始時間的過期快取；逾時後可以重試。

`test/integration_scan_test.dart` 使用實際 Yahoo HTTP、兩市場大盤與股票字典，15 秒工作期限內必須產出至少一檔通過原策略、實際突破和 1.5%～3% 停損距離的確認推薦，驗證 0.5% 風險股數、35%／25% 倉位及 R 目標。API 錯誤、休市、行情過期或沒有標的會失敗。Actions 明確開啟這項測試，非零退出碼阻止 APK；診斷 JSON／日誌仍上傳。新 APK artifact 為 `martin-luk-app-release`，保留 7 天。

已新增 HTTP 取消、回應本文掛起、Socket 錯誤、429、SharedPreferences 掛起、整批期限、限流、排隊、來源切換、dispose、逾時重試與遲到回應等 Dart 回歸測試。靜態審查不等於測試成功：本機仍沒有 Flutter SDK，實際執行整合命令回傳 `flutter: command not found`（exit 127）；直接探測 NVDA、AAPL、TSLA、2330.TW、2603.TW 的 5 筆 Yahoo 請求全部因 `Operation not permitted` 失敗，沒有本次最新行情、成功推薦或 APK 成品。

詳細期限、指令與當前限制見 [REFRESH_RECOVERY.md](REFRESH_RECOVERY.md)。以下段落記錄先前交付狀態；新版產物名稱與門禁以本段及目前工作流為準。

## APK 編譯錯誤修復：Future<void> 與 SDK 36（2026-10-14）

`app_controller.dart` 兩個刷新排隊的 `.then<void>` 閉包改為 `async`，並 `await` 後續刷新。提前停止的 `return;` 現在位於明確的非同步 void 閉包中，避免同步閉包從其他回傳分支推導為需回傳值的型態。唯讀審查整份 controller 的回傳分支，沒有發現其他同類問題。

新增兩個 controller 退訂邊界測試：掃描／持股的強制刷新排隊期間 `dispose()`，兩個 Future 都應正常完成而且不能發送新的 HTTP 請求。controller 測試現在共 15 個。此處沒有 Flutter／Dart SDK，尚未實際執行 `flutter analyze` 或這些測試；不能宣稱 analyzer 零警告或 APK 已完成。

Android 改為 compileSdk 36、Build Tools 36.0.0，配合 AGP 8.9.1／Gradle 8.11.1；維持 Java 17、Kotlin 2.0.21、minSdk 21、targetSdk 34。Actions 及 SDK 安裝腳本同步安裝 API 36。版本配置、YAML 解析及 Shell 語法檢查通過；實際編譯由既有 Actions 的分析／測試／APK 步驟確認。

## 正式行情模組與既有 Windows 預覽更新（2026-10-14）

既有目錄保留，新增指定入口 `preview/standalone_preview.html`（與根目錄單檔相同）及 CRLF 格式 `run_preview.bat`。雙市場本金、793 筆字典、PDH／ORH 示範、嚴格 1.5%～3% 初始停損、R 目標與持股 CRUD 都完整內嵌；不需要後端或通訊埠。已建立 Windows 合併覆蓋指南，沒有直接存取或修改使用者電腦的 C 槽。

`live_strategy_engine.dart` 提供指定的純數學 `calculatePositionSize` 與 `calculateExitTargets`：BigInt 精確十進位、0.5% 風險、整股向下取整、35%／25% 曝險上限及固定 1R／3R／5R／10R。新增 10 個邊界及例外測試，沒有製造假突破訊號以繞過驗證。

正式 Flutter 預設關閉 Mock，新增直接行情 API／日與盤中 K 模型、本機指標、股票池、推薦及持股 Repository。前景 60 秒更新、完整掃描 15 分鐘、下拉強制刷新；失敗保留原始時間的真實快取。過期／倒序行情不能上移停損，推薦卡片、確認數量與計算機共同停止過期價格的買進建議；每張卡片顯示各自行情時間。設定、來源、舊庫存遷移與背景停止已有專門測試。

本機已實際執行並通過：搜尋／三份嵌入字典 150 項、獨立 HTML 221 項、既有策略 84 項、手機 UI 53 項、持股 UI 207 項、跨語言診斷 72 情境、Python 後端 55 個單元測試與 7 項 Web 配置。HTML 測試使用生產 JS／DOM 替身；不代表已做 Windows／手機實機瀏覽器或 APK 驗證。

新增的 Dart 測試共有 75 個一般測試與 1 個選擇性實際 HTTP 測試，均尚未在此執行：本機沒有 Flutter／Dart／Android SDK。實際 Yahoo HTTP 驗證尚未完成，沙箱一般執行回傳 `Operation not permitted`。不能宣稱已取得本次最新市價或已編譯 APK。

Actions 已改為 `USE_MOCK_DATA=false` 產出 `martin-luk-production-apk`；完整指令、逐檔修改說明與選擇性 HTTP 檢查見 `PRODUCTION_GUIDE.md`。新增檔案已納入 SHA256 交付清單，打包排除快取並保存完整原始碼及獨立預覽。

## 台美股智慧搜尋（2026-10-13）

新增共用股票字典 793 筆：US 509（公開 S&P 500 快照 503 筆證券與 6 檔主要個股補充）、TW 284 檔常見上市普通股。`stocks_master_sources.json` 記錄來源、資料快照、名稱補齊政策與範圍；台股為常見股整理，不宣稱是完整官方即時名單。

Flutter 與兩個 HTML 的推薦列／持股表單支援代碼、中英文名稱、別名、簡碼、200ms 防抖及最多 8 筆建議。JS 與 Dart 使用同一權重規則；HTML 已內嵌完整 JSON 與同一 JS 核心。選取更新標準代碼與市場，保持 USD／TWD 本金獨立；沒有行情的字典身分不建立策略訊號。修正手機 HTML 長按選項的失焦競態，選項保留至點擊完成。離線字型已重新涵蓋新增字典中文，沒有缺少 CJK 字形。

已執行並通過：搜尋核心／字典／嵌入一致性 119 項、手機 HTML UI 53 項、持股 UI／引擎 207 項、獨立 HTML 221 項、既有策略 84 項、Python／HTML 診斷一致性 72 情境，以及 55 個後端單元測試。HTML 互動以生產 JavaScript 加 DOM 替身驗證；未做實際手機觸控或浏览器畫面測試。

新增 15 個 Dart 服務、Widget 與整合測試；本機沒有 Flutter／Dart SDK，僅完成靜態檢閱，未執行 `flutter analyze`／`flutter test` 或 APK 編譯。既有 GitHub Actions 將執行新的字典同步檢查、搜尋檢查、Flutter 分析、測試及 APK 建置。

重跑本次搜尋檢查：

```bash
python3 scripts/sync_stock_search.py --check
node scripts/check_stock_search.cjs
node scripts/check_preview_ui.cjs
node scripts/check_portfolio_preview.cjs
node scripts/check_standalone_preview.cjs
```

## 分市場 Capital 設定與自動帶入

Flutter、手機 HTML 預覽與完全離線單檔現在明示兩個独立 Capital 帳戶：美股預設 US$50,000 USD，台股預設 NT$1,000,000 TWD。單筆 0.5% 預設風險分別為 US$250 USD／NT$5,000 TWD；計算機使用標的所屬市場的本金，修改及重新載入互不覆蓋。HTML 支援在計算機內切市場，Flutter 在儀表板切市場後開啟個股時帶入對應資金；小數本金保持原值。

本次檢查：173 項獨立 HTML、31 項手機預覽 UI、195 項持股操作及 84 項策略檢查通過。新增 5 項 Flutter Capital 測試；本機無 Flutter SDK，分析及 Widget 測試由 GitHub Actions 執行。

## 固定離線單檔與終端匯出

本次再補入 `2603.TW` 長榮示範推薦，獨立 HTML 的檢查更新為 **150 項通過**。新增一鍵 `scripts/package_trading_app.sh`，產出指定名稱的 `/workspace/martin_luk_trading_app.zip`，並同步輸出 Base64 與 SHA256。

新增 `standalone_preview.html`，內嵌 CSS、JavaScript 與 Mock，沒有 API 呼叫或外部檔案依賴。145 項生產引擎與 UI handler 檢查通過（DOM 替身，未執行實際瀏覽器截圖）。新增 ZIP／Base64 匯出與還原腳本，14 項編碼、SHA256、CRC、路徑與覆寫保護檢查通過。

Actions 現在支援 Push 到 `main`／`master` 自動觸發，另保留手動入口；獨立 HTML 檢查加入建置前驗證。Android SDK／簽章／套件配置已靜態核對。APK 編譯結果仍須由實際 GitHub Actions run 確認。

## 新增持股診斷

新增 Python `exit_engine.py`／`portfolio_tracker.py`、持股行情與單次分析 API、Flutter 持股管理與出場畫面，以及單檔 HTML 的庫存 CRUD 和手動行情測試。原始成本與初始停損固定決定 1R；已觀察最高 R 持續保存，達到 2R 啟用保本停損。硬停損與完成收盤的 EMA 跌破分開判斷，全數出場優先於強勢分批減碼。

最高 R／已上移停損依 Mock 或各 API 基底網址隔離；模式切換即撤銷舊請求覆寫結果的資格，避免離線實驗替真實行情啟用保本停損。持股基礎資料改變會清除歷史。同市場代碼唯一，前端自動分批更新超過 50 檔庫存；本機儲存失敗時顯示提示。

推薦停損規則已依這次需求調整：有效突破日低點的風險距離不超過 5% 時可採用；超過 5% 時，必須有實際 1／5 分鐘進場棒低點，且距離在 1.5%～3%。不再把所有停損強制限制為 1.5%～3%；沒有有效市場低點仍列觀察。PDH／ORH 突破水平與實際確認棒價格分開記錄。

本次重新執行的檢查全部通過：

| 檢查 | 通過數量 |
| --- | ---: |
| Python 後端、風控、持股與行情 API 單元測試 | 55 |
| 原有 HTML 策略／資料檢查 | 84 |
| 原有 HTML UI handler 檢查 | 12 |
| 新增持股引擎／CRUD／來源隔離／持久化操作檢查 | 195 |
| Python／HTML 出場診斷結果一致性情境 | 72 |
| 正式 Flutter Web 靜態配置檢查 | 7 |

重跑指令（需要 Python 後端測試相依套件與 Node.js）：

```bash
python3 -m unittest discover -s backend/tests -v
python3 scripts/check_preview.py
node scripts/check_preview_ui.cjs
node scripts/check_portfolio_preview.cjs
python3 scripts/check_portfolio_parity.py
python3 scripts/check_web.py
```

UI 檢查執行實際 JavaScript handler，使用 DOM 測試替身；不是實際瀏覽器畫面或截圖測試。Python／HTML 一致性檢查涵蓋固定 1R、保本、EMA、曝險、分批整股邊界及出場優先序。Yahoo 實際行情、Android 裝置與正式 Flutter 編譯仍未在此環境驗證。

## 編譯與上一版檢查紀錄

目前工作環境沒有完整 Flutter／Dart／Android SDK，因此本機尚未產出 APK，亦尚未執行 `flutter analyze` 或 `flutter test`。本次使用 GitHub Actions 編譯途徑，不下載本機 SDK。

本次依新需求改為 GitHub Actions 雲端建置，不再下載本機 Android SDK。工作流為 `.github/workflows/build_apk.yml`，已檢查必要步驟、APK產物路徑與14天保留期；正式建置結果需由 GitHub Actions run 確認。提供正式 Flutter Web 配置與390×844框架，以及免SDK互動 HTML 預覽。

雲端工作流已加入 `strategy-tests`：Python 3.12／Node 22 驗證後端、HTML 策略及持股互動，並執行 Python／HTML 診斷一致性檢查；通過後才進入 Flutter 分析、測試及 APK／Web 建置。

已完成：Flutter 原始碼、Android 建置配置、FastAPI 掃描介面、離線資料與測試原始碼；靜態介面檢查已核對 JSON、Null-Safety、頁面與控制器契約。

上一版 Python 的 **21 項 API／風控／快取測試全部通過**，雙市場後端 demo CLI 與 Python compileall 亦已通過。HTTP 合約測試使用 ASGI 與 inline worker 替身，避開沙箱的跨執行緒喚醒限制；正式 API 保留非阻塞 worker thread。尚未連線驗證外部金融網站。

待在具備工具與網路存取的環境執行：`flutter pub get`、`flutter analyze`、`flutter test`、`flutter build apk --release`，以及 Android 實機通知與實際行情驗證。

新增 Web 靜態配置檢查 **7項全部通過**；Shell 語法、workflow YAML解析及Android XML檢查通過。新增4項 Dart mock預覽模式測試，待雲端 `flutter test` 執行。已修正分頁數值型別與中文 HTTP 測試資料的 UTF-8 編碼。

免SDK HTML 預覽的 **79項策略／資料檢查、12項UI操作邏輯檢查全部通過**。UI操作測試執行真實JavaScript handler並使用DOM測試替身。Chromium 在此沙箱啟動時遇到 `setsockopt: Operation not permitted`，因此未完成瀏覽器畫面或截圖驗證。正式Flutter Web及APK仍需以雲端編譯結果確認。

上一版已打包334,820 bytes的本地中文字體與SIL OFL授權，確認全部Dart UI與Mock文字有字形；新增持股中文介面使用重新產生的字型子集。Flutter Web可使用本機CanvasKit與字體資源預覽。

預覽連線修復：啟動腳本改為 `0.0.0.0:8080`，新增 `--mock` / `--serve-built` 與 `/__health`，12項launcher及6項HTTP handler測試通過。实际執行沙箱仍以 `Operation not permitted` 拒絕socket，已將此限制與遠端埠轉送需求記錄於 `PREVIEW_CONNECTION.md`；未宣稱外部瀏覽器已連通。
