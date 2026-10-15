# Martin Luk 動能策略 Android App

Flutter / Dart 手機 App，包含台股上市及美股 S&P 500 儀表板、個股部位計算、我的持股庫存、動態出場診斷、設定、本機定時提醒與 FastAPI 後端。將需求中的交易規則轉成明確的數值規則；價格以各市場原生幣別表示。

## 既有 Windows 專案與正式連網版

正式 App 預設 `USE_MOCK_DATA=false`，手機直接取得 Yahoo 行情、於本機計算 ADR／EMA／RS／突破，不需自架後端；前台 60 秒更新、背景停止、下拉強制刷新。失敗保留帶原始時間的真實快取，不載入假資料。Python 中繼與示範模式均為明確選配，詳見 [PRODUCTION_GUIDE.md](PRODUCTION_GUIDE.md)。

Actions 直接驗證 Checkout 原始碼，不再執行 SHA 補丁更新器。完整直接覆蓋內容見 [GITHUB_MANUAL_UPDATE.md](GITHUB_MANUAL_UPDATE.md)。

2026-10-15 起，建置門禁改為「真實行情取得與計算正確」，取代先前「至少一檔推薦才建置」的規則。推薦清單為空是正常評估結果，不會單獨阻擋 APK；實際 HTTP、解析、必要股票、指標驗算或期限錯誤仍會阻擋。選股與風控規則維持原設定，觀察股不會充當已確認推薦。

市場評估優先掃描最多 30 檔核心成員，每批 5 檔、批次間隔 150ms；逐批顯示進度並支援停止。行情及一般 HTTP 預設最長 8 秒；共用傳輸層明確指定時允許最多 10 秒；直連市場評估預算 9 秒、控制器全流程硬上限 10 秒，報價與持股刷新維持短期限及 `finally` 清理。Actions 先驗證報告驗證器及 Dart 的 RS／策略／風控單元測試，再以 Mock 關閉的實際 HTTP，在 15 秒工作期限內取得 `^GSPC`、`^TWII` 與 NVDA、AAPL、TSLA、2330.TW、2603.TW，獨立驗算 ADR／EMA／RS。schema 2 報告還必須通過 `scripts/validate_live_scan_evidence.py`，才允許編譯 APK；`candidates: []` 可以通過。詳見 [刷新修復與實測門禁](REFRESH_RECOVERY.md)。

將 ZIP 同名檔案合併覆蓋至既有 `C:\Users\a1258\projects\martin_luk_trading_app`，不需重建專案骨架。雙擊根目錄 `run_preview.bat` 開啟 `preview/standalone_preview.html`：完全離線的單檔 HTML 已包含雙市場資金、793 筆字典、搜尋、風控與持股操作。原根目錄 `standalone_preview.html` 保留相同內容。覆蓋步驟見 [WINDOWS_UPDATE_GUIDE.md](WINDOWS_UPDATE_GUIDE.md)。

指定的純數學風控函式已於 `lib/services/live_strategy_engine.dart` 提供：

```dart
import 'package:martin_luk_app/services/live_strategy_engine.dart';

final plan = calculatePositionSize(
  capital: 50000, entryPrice: 100, stopLossPrice: 98, isMegaCap: true,
); // shares=125, riskBudget=250, riskAmount=250
final exits = calculateExitTargets(100, 98);
// oneR=2; targets={3:106, 5:110, 10:120}
```

`calculatePositionSize` 嚴格驗證 1.5%～3% 停損距離，以精確十進位數學向下取整、限制 0.5% 風險及 35%／25% 倉位；不把試算價格冒充市場訊號。`calculateExitTargets` 固定使用原始 1R，可用於現有持股目標價。

## 台美股智慧搜尋

推薦列與持股表單已加入 200ms 防抖自動完成，支援 `台積電`／`2330`／`TSMC`、`輝達`／`NVDA`、`特斯拉`、中英文全名與簡碼。下拉顯示最多 8 筆市場、代碼與名稱；選取後帶入標準代碼，依股票市場使用 USD／TWD 本金。共同 `stocks_master.json` 預先索引於記憶體，兩個 HTML 同步內嵌，離線搜尋不發送網路請求。只有元資料的股票會帶入持股表單，等待實際成本與行情，搜尋本身不建立策略訊號。

程式介面、排序分數、字典來源與更新方式見 [SEARCH_GUIDE.md](SEARCH_GUIDE.md)。

## 單檔預覽與一鍵成品

Settings 將「帳戶總資金（Capital）」依市場獨立保存；計算機自動使用標的所屬市場的設定，修改美股本金不影響台股，反之亦然。

| 市場 | 預設 Capital | 預設單筆 0.5% 風險預算 |
|---|---|---|
| 美股 | US$50,000 USD | US$250 USD |
| 台股 | NT$1,000,000 TWD | NT$5,000 TWD |

HTML 計算機內切換 TW／US 會選取新市場所屬股票並帶入該市場本金。Flutter 於儀表板切換市場再開啟個股計算機時，依個股市場讀取 Capital；畫面會明示幣別，不進行匯率換算。

解壓後用 Chrome／Safari／Edge 開啟根目錄的 `standalone_preview.html`，不需安裝套件、啟動伺服器或監聽通訊埠。內含 `NVDA`、`TSLA`、`2330.TW`、`2603.TW` 等真實股票識別；價格、ADR、RS、EMA 與訊號均為教學假資料。可切市場、調整本金、操作持股 CRUD 與手動行情診斷。

在目前工作區重新產出完整 ZIP、Base64 與 SHA256：

```bash
bash /workspace/martin_luk_app/scripts/package_trading_app.sh
ls -lh /workspace/martin_luk_trading_app.zip
```

成品為 `/workspace/martin_luk_trading_app.zip`。若聊天介面提供下載附件可直接儲存；若不能下載，讀取 `/workspace/martin_luk_trading_app.zip.b64` 分段複製並依 [終端匯出指南](TERMINAL_EXPORT_GUIDE.md) 還原，不要遺漏或重複編碼行。工作區路徑不是自己電腦可直接瀏覽的網址。包內保留 `.github/workflows/build_apk.yml`：將專案內容提交至 GitHub，Actions 自動執行驗證，通過真實行情與計算門禁後下載 `martin-luk-app-release` artifact（保留 7 天）。

## 手機 Web 預覽與雲端 APK

若遠端瀏覽器存取127.0.0.1逾時，請先看 [連線診斷與修復](PREVIEW_CONNECTION.md)。啟動腳本已預設 `0.0.0.0:8080`，並支援無SDK的 `--mock` 模式；外部瀏覽器需使用平台實際提供的埠轉送網址。

- **立即互動預覽**：用瀏覽器開啟 `preview/index.html`，不需要 Flutter、Android SDK、後端或網路。此入口是獨立 HTML 行為預覽，可操作市場切換、ADR、排序、分頁、個股風控、持股新增／編輯／刪除、手動行情診斷及設定；正式 Flutter 原始碼位於 `lib/`。
- **正式 Flutter Web**：已補齊 `web/`，執行 `python3 scripts/check_web.py` 檢查配置，再執行 `bash scripts/preview_web.sh --build`。瀏覽器在同機時開啟 `http://127.0.0.1:8080/phone_preview.html`；遠端請使用8080轉送URL加上 `/phone_preview.html`。桌面內框為390×844；這個方式只需要 Flutter SDK，不需要 Android SDK。詳見 [WEB_PREVIEW.md](WEB_PREVIEW.md)。
- **固定離線單檔**：複製 `standalone_preview.html` 到本機即可操作推薦、持股及部位計算；此版本完全不含 API／連接埠設定。
- **本機沒有 Flutter**：將專案提交至 GitHub 的 `main`／`master`／`fix/refresh-live-gate-20261014`，或使用 [build_apk.yml](.github/workflows/build_apk.yml) 的 **Run workflow**，通過真實行情與計算門禁後在雲端編譯 APK。APK 保留 7 天；操作步驟見 [README_HOW_TO_BUILD.md](README_HOW_TO_BUILD.md)。目前工作流只上傳實測紀錄與 APK。
- **ZIP 無法點擊下載**：執行 `bash scripts/export_upload.sh` 產生上傳包與 Base64，參閱 [TERMINAL_EXPORT_GUIDE.md](TERMINAL_EXPORT_GUIDE.md)。

`?preview=mock` 會在 Web 初次啟動明確選擇離線資料，即使瀏覽器原先保存 API 模式也能預覽。使用者之後仍可在設定頁切換 API；API 失敗會顯示錯誤。Flutter3.29 已移除舊 `--web-renderer` 參數，使用提供的腳本及預設 CanvasKit。

## 專案內容

```text
lib/
  main.dart                       Material 3、深色／淺色主題及底部導覽
  app_config.dart                 USE_MOCK_DATA、API_BASE_URL 建置預設
  app_controller.dart             資料來源、設定、分頁及過期请求隔離
  models/
    stock_candidate.dart          Null-safe 股票模型與嚴格 JSON 解析
    stock_item.dart               台美股搜尋元資料與標準代碼
    app_settings.dart             分市場門檻、本金與持久化設定
    portfolio_position.dart       持股、原始風險與已觀察最高 R
  services/
    stock_search_service.dart     單次載入離線索引、權重排序及容錯
    strategy_engine.dart          精確 0.5% 風險與曝險上限計算
    candidate_repository.dart     離線假資料與 REST API
    reminder_service.dart         Android 本機定時提醒與 DST
    exit_advisory_engine.dart      保本／均線出場及分批減碼診斷
    portfolio_repository.dart     持股保存與獨立行情更新
  screens/
    dashboard_screen.dart         TW／US、排序、分頁、下拉更新
    calculator_screen.dart        個股指標、淨值輸入、股數及 R 目標
    settings_screen.dart          資料模式、API、ADR、主題及通知權限
    portfolio_screen.dart         持股管理、R 進度與操作建議
  widgets/stock_search_field.dart  200ms 防抖與自動完成下拉
stocks_master.json                台美股共用股票字典
stock_search.js                   兩個 HTML 使用的同一離線檢索器
web/                              正式 Flutter Web、CanvasKit bootstrap、手機框架
preview/                          免SDK的獨立 HTML 互動預覽
android/                          Android / Gradle / Manifest / Kotlin
backend/                          FastAPI、股票池、快取、掃描、持股診斷
test/                             Dart 單元及 Widget 測試
scripts/                          建置準備腳本
.github/workflows/build_apk.yml    Push／手動觸發真實行情與計算驗證、APK產物
```

## 離線使用

正式 App 預設 `USE_MOCK_DATA=false`。要明確開啟 Flutter 示範，可在 Settings 開啟 Mock，或建置／執行帶入 `USE_MOCK_DATA=true`。示範每市場有 8 檔範例，所有價格、ADR、RS、型態及走勢為固定合成資料，畫面標示「OFFLINE MOCK／離線示範」。完全無 SDK 的 HTML 預覽始終是離線示範。

使用 Flutter 3.29.3、Dart 3.7，Android SDK Platform 36、Build Tools 36.0.0、JDK 17（或相容 Gradle 的 JDK），在專案根目錄執行：

```bash
flutter doctor -v
flutter pub get
python3 scripts/prepare_android.py
dart format lib test
flutter analyze
flutter test
flutter run --dart-define=USE_MOCK_DATA=true
```

設定頁也能於執行時切換模式。schema 1 舊設定首次遷移為正式直接連線，保留本金與偏好；schema 2 之後使用者明確保存的模式優先。`--dart-define` 提供新安裝預設；`?preview=mock` 明確開啟 Web 示範。重新安裝或清除 App 資料可恢復建置預設。

## API 模式

啟動後端：

```bash
python -m venv .venv
.venv/bin/python -m pip install -r backend/requirements.txt
.venv/bin/python -m uvicorn backend.api:app --host 0.0.0.0 --port 8000
```

Windows 使用 `.venv\Scripts\python.exe`。詳細來源、快取、排程與 API 範例請見 [backend/README.md](backend/README.md)。

- Android 模擬器 Debug：`http://10.0.2.2:8000`。
- 實機經 USB：`adb reverse tcp:8000 tcp:8000`，Debug App 設 `http://127.0.0.1:8000`。
- Release APK：使用具有有效 TLS 憑證的 **HTTPS** 後端 URL。正式 Manifest 禁止任意明文 HTTP；Debug 僅允許上述開發主機。

啟動 Debug API 模式：

```bash
flutter run \
  --dart-define=USE_MOCK_DATA=false \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

REST 契約：

```text
GET /health
GET /v1/candidates?market=tw&adr_threshold=3.5
GET /v1/candidates?market=us&adr_threshold=5.0
GET /v1/quotes
POST /v1/portfolio/analyze
```

回應含 `market, generated_at, source, universe_count, stale, warnings, candidates`。個股鍵為 `symbol, name, sector, market, adr_percent, rs_score, rs_rank, patterns, entry_price, stop_price, is_large_liquid, status, data_timestamp, signal_timestamp, notes, daily_closes`。日期必須附 ISO-8601 時區，未確認候選使用 `status=watchlist`、`stop_price=null`。

後端完整股票池掃描需要下載大量行情，可能超過後端模式的 8 秒刷新期限，建議以後端排程預熱快取。手機直連模式先掃描最多 30 檔核心成員，以 9 秒整批期限、10 秒 Controller 硬上限及可見進度避免向全市場突發請求；缺漏與全股票池數量分開顯示，RS 排名只涵蓋成功評估的核心股票。無效、缺失或過期來源會公開警告，API 失敗不會自動替換為假資料。Yahoo 公開資料的延遲及分鐘資料可用性依市場與供應端而異。

後端取 S&P 500 最新成分表及 TWSE 官方上市清單，普通股自動加 `.TW`，以 CFI 排除存託憑證、特別股及 ETF。台股盤前沒有美股式連續盤前成交資料，盤前依已完成日K提供觀察條件，開盤之後才確認跳空／ORH。S&P 500 成分股筆數可能超過 500。

## 風險與計算方式

台股預設淨值 NT$1,000,000，美股 US$50,000。ADR 預設台股 3.5%、美股 5%，可於設定頁調整。

```text
R（每股） = 進場價 − 實際停損價
風險預算 = 帳戶淨值 × 0.005
建議股數 = floor(min(風險預算 / R, 淨值 × 曝險上限 / 進場價))
曝險上限 = 大型流動性股票 35%，一般股票 25%
3R／5R／10R 目標 = 進場價 + 3／5／10 × R
```

財務運算使用 `BigInt` 有理數，避免浮點誤差增加一股。推薦清單分別顯示 **PDH／ORH 觸發價、確認棒價格、初始停損與每股 1R**。以實際突破日低點計算的停損距離大於 0 且不超過 **5%** 時可以採用；超過 5% 時，僅採用實際 1／5 分鐘進場 K 棒低點，且距離必須在 **1.5%～3%（含邊界）**。無法取得有效低點時保留觀察，不以百分比反推虛構停損。台股預設整股、可零股交易。輸入無效淨值時，畫面會清除先前計算結果。

3R 標記約 12% 分批減碼點，減碼整股比例需落在 10%～15%；無法在交易單位內表示時顯示說明。5R／10R 為參考目標，不代表保證達成。0.5% 是按停損价計算的名目風險，實際成交滑價、費用、跳空或無法成交的停損可能增加損失。

## 我的持股與動態出場

「我的持股」可新增、編輯或刪除股票代碼、成本、股數及初始停損，同市場的相同代碼不重複新增。Flutter 使用 SharedPreferences、離線 HTML 使用 localStorage 保存持股；寫入失敗會提示，當次頁面仍可操作。持股診斷使用固定的初始 `1R = 成本 − 初始停損`，顯示現價、浮動損益、部位市值、帳戶曝險、9／21／50 EMA、目前追蹤停損及 1／2／3／5／10R 目標。

已觀察最高獲利達到 2R 時，保本停損上移至成本；此狀態保存於持股，重新開啟後仍有效。觸及硬停損／保本停損，或已完成收盤跌破所選 EMA，優先建議全數出場。預設追蹤 9 EMA；主升段且曾觀察達到 3R 才可改用 21／50 EMA。盤中價格低於均線本身不等於收盤確認跌破。

Mock 與每個 API 基底網址分別保存最高 R／追蹤停損；離線測價不會啟用真實行情的保本停損。切換來源先清除舊行情，再依該來源保存的觀察與新報價評估；首次使用的來源從未觀察狀態開始，遲到的舊請求不會覆蓋結果。修改成本或初始停損等基礎資料會清除既有觀察歷史。

沒有出場條件時，達到 3／5／10R、單筆市值超過帳戶 35%，或 9 EMA 正乖離超過設定門檻（預設 20%，可調 15%～20%），建議分批減碼 10%～15%。一般股票超過 25% 另列曝險警示。台股淨值以 TWD、美股以 USD 評估，未合併不同幣別或進行匯率換算。

API 模式從 `/v1/quotes` 更新持股行情，不依賴該股票是否進入推薦清單；App 與 HTML 可自動分批更新超過 50 檔庫存。Yahoo 公開行情可能延遲，畫面保留來源與時間，連線失敗會顯示錯誤。Mock 模式可手動調整現價、已完成收盤價和 EMA，立即觀察操作建議變化。系統產出建議，不送出交易委託。示例操作與完整規則見 [PORTFOLIO_GUIDE.md](PORTFOLIO_GUIDE.md)。

## 定時提醒

在設定頁啟用通知，Android 13 以上會請求 `POST_NOTIFICATIONS` 權限。使用系統非精確排程，不需要 `SCHEDULE_EXACT_ALARM` 特殊授權。

| 市場 | 市場所在地時間 |
| --- | --- |
| 台股 | 週一至週五，台北 08:30／14:00 |
| 美股 | 週一至週五，美東 08:45／16:30，隨夏令時間調整 |

提醒使用每個市場的 IANA 時區，共 20 個每週重複通知；Android 電池限制可能延後送達。本機提醒是「開啟 App 更新評估」的通知，完整交易日與休市判斷由 Python 後端負責。本機週一至週五提醒仍可能出現在交易所休市日。App 在背景不會持續抓取全市場資料，也未配置遠端 FCM 推播。

## Android APK 建置

請見 [BUILD_ANDROID.md](BUILD_ANDROID.md)，包含 Gradle 配置、Release／分 ABI／Debug 指令及簽署方式。

```bash
flutter build apk --release --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
flutter build apk --release --split-per-abi --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
flutter build apk --debug --dart-define=USE_MOCK_DATA=false
```

Release 合併 APK 路徑：`build/app/outputs/flutter-apk/app-release.apk`；分 ABI 為同目錄的 `app-arm64-v8a-release.apk` 等檔案。Android 可安裝 APK 必須簽署；Debug Keystore 可以快速測試，不是無簽名 APK。

## 驗證狀態

程式碼附有模型、JSON、風控、request race、設定／畫面與提醒排程測試。建置／執行的實際結果記錄在 [BUILD_STATUS.md](BUILD_STATUS.md)；僅寫好測試不等於已通過。實際行情及裝置通知需要在可連線環境與 Android 裝置進一步驗證。
