# 真實行情連網版

2026-10-15 起，APK 門禁驗證真實行情取得與計算正確，推薦數可以為零。本規則取代先前「至少一檔嚴格推薦才建置」；選股條件、盤中確認與風控門檻未放寬，觀察股不會當作確認推薦。

App 預設 `USE_MOCK_DATA=false`，直接使用 HTTPS Yahoo chart API，不需要自架 Python 後端。設定頁可明確選擇「Yahoo 直接連線」、「Python 中繼」或開啟示範模式；HTTP 失敗不會自動載入假行情。既有 schema 1 設定第一次更新會遷移為連網模式，保留 USD／TWD 本金、ADR 與其他偏好；使用者之後自行選擇的模式持續保存。

新安裝的連網版沒有自動建立持股。舊版已保存的庫存保留；以 `demo-` 建立的示範資料會顯示來源提示，請使用者核對／刪除，不直接當成已確認的真實持股。最高 R／上移停損按 Mock、直接行情或各 Python API 網址分開保存。

## 行情與本機運算

- `lib/models/market_data.dart`：真實 OHLCV、供應商報價時間、下載時間、交易所時區、正常交易時段與快取來源。
- `lib/services/market_data_api.dart`：Yahoo `/v8/finance/chart/{symbol}`，`6mo`／`1d` 日 K、`5d`／`5m` 或 `1m` 盤中 K。支援 `.TW`、`^TWII`、`^GSPC`；直接使用原生 `http.Client`，逾時、取消、5 筆名額、有限 429 退避及真實快取皆在同檔，不依賴 `network_request.dart`。保留 `http: ^1.5.0` 以支援請求取消。
- `lib/services/live_strategy_engine.dart`：ADR 20、EMA 9／21／50、對齊 61 個共同完整交易日的 RS、PDH／ORH、實際低點停損，以及純數學風控／R 目標函式。
- `lib/services/stock_universe_service.dart`：公開 S&P 500 CSV、TWSE OpenAPI 普通股清單與字典快取。無法取得新名單時，內建快照會明示日期與不完整範圍；台股內建的是 284 檔常見股，不冒稱上市全股票。
- `lib/services/live_candidate_repository.dart`：批量掃描及百分位排名、有限併發、掃描結果快取。
- `lib/services/live_portfolio_repository.dart`：持股最新報價與完成日 K 的 EMA，快取不建立新的最高 R／上移停損。

既有 Dart 修改檔案：

| 路徑 | 修改 |
|---|---|
| `lib/app_config.dart` | 正式模式預設與直接來源 |
| `lib/models/app_settings.dart` | 來源／自動更新選項與 schema 2 遷移 |
| `lib/app_controller.dart` | 真實 Repository、快取、刷新排隊及來源隔離 |
| `lib/main.dart` | 前景／背景生命週期通知 |
| `lib/models/stock_candidate.dart` | 真實 EMA、市價與欄位驗證 |
| `lib/models/portfolio_position.dart` | 行情快取／過期／下載時間欄位 |
| `lib/services/candidate_repository.dart` | 強制刷新／只更新報價及快照覆蓋資訊 |
| `lib/services/portfolio_repository.dart` | 強制刷新介面 |
| `lib/services/exit_advisory_engine.dart` | 過期資料僅顯示診斷，凍結新的觀察狀態 |
| `lib/screens/settings_screen.dart` | 直接／中繼與明確示範選擇 |
| `lib/screens/dashboard_screen.dart` | 真實來源、快取／部分結果、逐股時間、刷新及重試 |
| `lib/screens/portfolio_screen.dart` | 持股刷新、快取與舊示範來源提示 |
| `lib/screens/calculator_screen.dart` | 真實 EMA／市價，過期資料禁止新部位建議 |

`lib/services/stock_search_service.dart` 保留已完成的一次載入離線檢索，無需為每次搜尋連線；詳細介面見 `SEARCH_GUIDE.md`。新增及調整的測試都位於既有 `test/`，Mock 相關測試明確使用 schema 2 示範 fixture，不更改正式版預設。

ADR 為 `SMA((High-Low)/Low,20)*100`。日 EMA 使用已完成日 K；目前日 K 至正常收盤後 15 分鐘且供應商報價時間已接近收盤才作為完成資料。RS 使用股票與大盤共同交易日，20／60 交易日報酬差綜合後，在本次成功評估的股票池內計算百分位；覆蓋不足會顯示成功數、缺資料名單，沒有預設虛構分數。

ORH 使用正常交易時段實際第一根完成 5 分鐘 K；盤前／盤後資料不形成開盤區間。PDH 使用前一個完整日高點、內包／窄幅與 EMA 收斂。缺少開盤棒、連續分鐘棒、有效停損或資料過期時保留觀察狀態。策略不因找不到 1.5%～3% 的市場低點而自行補出停損。

純數學 `calculatePositionSize` 供此次指定的嚴格 1.5%～3% 試算使用。正式市場掃描延續已定義的當日實際低點規則：當日低點距離 ≤5% 可採用；超過 5% 才改用實際進場棒低點，而且必須在 1.5%～3%。兩條規則用途會明示，避免把實際低點更改成方便顯示的百分比。

## 更新與快取

推薦與持股清單都可下拉強制刷新。前景每 60 秒更新，切到背景停止；未完成的輪詢不重疊，下拉刷新會在需要時接續執行。完整掃描以 15 分鐘為間隔，每分鐘行情更新最多追蹤前 20 個候選及現有持股；不會每分鐘重新下載整個股票池。

市場評估先選最多 30 檔目前股票池成員，每批 5 檔、間隔 150ms，逐批顯示成功、失敗與 ADR 數，並支援停止。Yahoo 行情共用最多 5 筆 HTTP 名額。直連市場評估 Repository 預算 9 秒、Controller 獨立截止計時器硬上限 10 秒；候選報價與持股整批仍為 6 秒，控制器的後端、報價與持股刷新為 8 秒。每筆 HTTP 也最多 8 秒（含名額排隊、完整本文與 429 退避），本機讀寫最多 2 秒且受剩餘期限約束。`finally` 釋放狀態與 Future，逾時撤銷舊操作；重試使用新操作，不接受遲到結果。

免費公開 API 可能限流，期限內未完成會產出明示的部分結果，不能保證一次涵蓋全市場。日 K／指數快取 15 分鐘，盤中資料快取 30 秒；掃描與持股摘要也保存於 SharedPreferences。更新失敗顯示原始時間、快取提示與重試，不將下載時間替代成最新成交時間，也不利用過期或倒序行情上移停損。完整診斷、回歸命令與門禁條件見 [REFRESH_RECOVERY.md](REFRESH_RECOVERY.md)。

畫面時間以 `YYYY-MM-DD HH:mm:ss`、台北 UTC+08 顯示；計算正常交易時段仍使用交易所 IANA 時區，處理美東夏令時間。Yahoo 公開行情可能延遲，成功 HTTP 並不代表交易所即時報價。Flutter Web 的直接跨域請求可能受 CORS 限制，可使用既有 Python 中繼；Android 原生 HTTPS 不受瀏覽器 CORS 限制。

## 驗證與建置

一般單元／Widget 測試使用明確 HTTP fixture，不依賴 Yahoo 可用性；另外的 Actions 真實行情門禁必須實際聯網通過：

```bash
flutter pub get
python3 -m unittest discover -s scripts/tests -p 'test_live_scan_evidence.py' -v
flutter test test/rs_alignment_test.dart test/live_strategy_engine_test.dart test/live_risk_helpers_test.dart --dart-define=USE_MOCK_DATA=false --reporter=expanded
flutter test test/integration_scan_test.dart --dart-define=RUN_LIVE_SCAN_TEST=true --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded
python3 scripts/validate_live_scan_evidence.py build/live-scan-evidence.json
```

`integration_scan_test.dart` 使用實際 HTTP、空快取與關閉 Mock，在 15 秒工作期限內取得 `^GSPC`、`^TWII` 及 NVDA、AAPL、TSLA、2330.TW、2603.TW 的必要資料，獨立重算 ADR／EMA／RS 並核對。必要標的缺漏、HTTP／解析錯誤、指標不符或逾時仍會失敗。報告採 schema 2，必須再通過 `scripts/validate_live_scan_evidence.py` 才可編譯 APK；只有 HTTP 200 不足以通過。

推薦 `candidates: []` 表示本次沒有符合所有買進條件的標的，健康門禁可正常通過。休市、盤前盤後或沒有突破時，保留此空結果；有合格訊號時，仍檢查原 ADR、EMA 收斂、新鮮正常交易時段 PDH／ORH 確認、實際停損、0.5% 風險、35%／25% 曝險及 R 目標。風控與型態的正反向行為由前面的可重現單元測試覆蓋，不能靠放寬門檻或偽造訊號通過。另可執行下列較小的傳輸檢查，但它不取代完整健康門禁：

```bash
flutter test test/live_http_smoke_test.dart --dart-define=RUN_LIVE_HTTP_TEST=true --dart-define=USE_MOCK_DATA=false
```

測試使用實際 `http.Client`、強制刷新、空快取，且暫時解除 Flutter 測試框架的 HTTP 400 替身；TLS 憑證驗證維持啟用。遇到限流／DNS／端點異動會失敗並顯示錯誤，不能拿 fixture 或快取代替此項連網成功證據。

```bash
flutter build apk --release --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
```

GitHub Actions **Build Android APK with Verification Gate** 僅在上述單元測試、真實行情／計算測試與 schema 2 報告驗證全部通過後建置連網版，成功後下載 `martin-luk-app-release`，保留 7 天。`martin-luk-live-scan-evidence` 保存 `test_logs/verification.log`，失敗時也保留診斷；JSON 證據會寫入日誌。現行工作流只上傳這兩項產物。Manifest 有 INTERNET、ACCESS_NETWORK_STATE、`usesCleartextTraffic=true`；Yahoo 仍使用 HTTPS。目前簽章是既有快速測試用 debug keystore，商店發布需配置自有 release signing。`android-skip-build-dependency-validation` 是依需求加入的旗標，不取代驗證步驟。

本受限工作區沒有 Flutter／Dart／Android SDK，本地執行 Flutter 命令回傳 `command not found`（exit 127），沒有完成實際 APK 編譯或這次 Dart 測試。已只讀核對 GitHub [run 38662579836](https://github.com/foxicall/martin-luk-app/actions/runs/38662579836)：台北 2026-10-15 08:55、約 2661ms，22 檔評估成功、7 檔仍受遠端舊 RS 日期判斷影響，推薦為零。當時台股未開盤、美股已收盤；這份舊版失敗紀錄不能當作本次新健康門禁或 APK 已通過的證據。請完整覆蓋 `market_data.dart` 與 `live_strategy_engine.dart` 的 RS 修正，再以新的 Actions 結果確認。

`preview/standalone_preview.html` 與 `run_preview.bat` 仍提供完全離線示範，詳見 `WINDOWS_UPDATE_GUIDE.md`。
