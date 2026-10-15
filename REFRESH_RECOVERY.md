# 刷新修復與真實行情／計算建置門禁

2026-10-15 起，依使用者選擇改為「驗證真實行情與計算正確即可建置，允許推薦為零」。本規則取代先前的至少一檔推薦門禁；行情仍必須實際取得，不能使用假資料、過期快取或觀察股填入已確認推薦。沒有買點是有效的市場評估結果，不代表更新失敗。

## RS 共同比較端點與完整日 K

RS 改用相同的最新 61 個共同完整交易日計算 20／60 日報酬，任一側最多容許 1 個尾端交易日差，共同日期距任一抓取日不得超過 7 曆日；超過範圍、歷史不足或跨市場資料仍拒絕。評估明示 RS 截止日期與未納入尾端天數，股票日 K 落後大盤時只供觀察，不確認新進場。當供應商交易時段已滾至次日，當日 K 仍需通過收盤後 15 分鐘及收盤附近原始報價時間檢查；缺少時段資訊或尚未完成的當日 K 不納入。

`test/rs_alignment_test.dart` 與相應策略案例涵蓋共同端點、缺漏／過期拒絕和股票日 K 落後只能觀察；未調低 ADR、突破、停損、0.5% 風險或 35%／25% 曝險條件。請連同 `lib/models/market_data.dart`、`lib/services/live_strategy_engine.dart` 整份覆蓋；只換整合測試無法修正舊版 RS 例外。

## 刷新行為

Yahoo 的 HTTP 邏輯已直接內建於 `market_data_api.dart`，不用新增 `network_request.dart`；其所有實例共用最多 5 筆 FIFO 名額，8 秒期限涵蓋排隊、連線、標頭與完整本文。其他股票池／中繼服務仍使用既有 `network_request.dart` 的獨立名額池。逾時取消該筆請求並釋放名額，候選與持股行情不會各自累加成無限制並行。Yahoo 的 429 退避和一次重試共用同一期限。Timeout、Socket／Client 連線錯誤由行情與 Repository 捕獲；單一股票失敗不終止其他股票，無快取時顯示錯誤，有快取時保留原始時間並標記過期。

`app_controller.dart` 在通知 UI 前取得操作所有權，於 `finally` 釋放載入狀態與完成 Future。相同更新共用工作；多次下拉最多合併為一次強制更新，而且排隊與後續請求共用從第一次下拉起算的期限。切換市場／來源、逾時與 dispose 都撤銷舊工作；遲到結果不能覆寫新行情或上移持股停損。

| 層級 | 預設等待上限 |
|---|---:|
| Yahoo 與一般 HTTP（含完整本文） | 預設 8 秒；共用傳輸可明確指定至 10 秒 |
| 直連核心池市場評估 | 9 秒，包含結果快取預留時間 |
| 候選報價／單市場持股整批 | 6 秒 |
| Controller 市場評估全流程 | 硬上限 10 秒，可停止；排隊共用原始截止時間 |
| Controller 後端／報價／持股刷新 | 8 秒 |
| 本機字典、SharedPreferences 讀寫 | 2 秒，仍受上層剩餘期限限制 |
| 真實行情 CI 驗證 | 15 秒工作期限；測試命令另設 90 秒框架保險 |

市場評估先從目前股票池選出最多 30 檔核心成員，預設每批 5 檔（設定範圍 1～5），等待整批完成，再間隔 150ms 開始下一批。持股更新仍使用其獨立短期限。市場介面逐批顯示已掃描、成功評估、ADR 符合及失敗數，並可立即停止。單一股票失敗不影響其餘標的；未掃全市場不冒稱全市場 RS 排名。有效但零 ADR 的評估會保存空快照及時間；全部行情失敗保存診斷兜底快照，顯示「評估未完成」及本次嘗試時間；股票池尚未取得時為 0，沒有虛構價格。兜底不會作為成功快取，也不會阻止下一次完整掃描。逾時保留已驗證部分資料或原始時間的上次快照；成功但候選為空的快照保持有效，不會被兜底取代。

前景輪詢每 60 秒；最近成功掃描使用候選報價更新。首次沒有快取、上次失敗或距完整掃描已滿 15 分鐘，會重新嘗試有期限的掃描。背景停止輪詢，回到前景可再更新。網路失敗不會將 Mock 資料替代成真實行情。

## 真實行情與計算門禁

在有 Flutter 與正常網路的環境執行：

```bash
flutter pub get
python3 -m unittest discover -s scripts/tests -p 'test_live_scan_evidence.py' -v
flutter test test/rs_alignment_test.dart test/live_strategy_engine_test.dart test/live_risk_helpers_test.dart --dart-define=USE_MOCK_DATA=false --reporter=expanded
flutter test test/integration_scan_test.dart --dart-define=RUN_LIVE_SCAN_TEST=true --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded
python3 scripts/validate_live_scan_evidence.py build/live-scan-evidence.json
```

CI 先執行 Python 報告驗證器測試與 Flutter RS／策略／風控單元測試，再執行真實 HTTP 整合測試，最後獨立驗證 schema 2 報告；任何一步非零退出碼都阻止 APK。一般測試中的整合檔預設跳過外部行情，Actions 明確傳入 `RUN_LIVE_SCAN_TEST=true`、`USE_MOCK_DATA=false`。HTTP 是實際 client、強制刷新且空快取；只有本機 preferences 使用測試替身。

整合測試在 15 秒工作期限內取得 `^GSPC`、`^TWII` 及必要五檔 NVDA、AAPL、TSLA、2330.TW、2603.TW，檢查完整日 K、實際報價與來源，獨立重算 ADR、9／21／50 EMA 與同日期 20／60 日 RS。單純 HTTP 200 不足以證明計算正常。必要標的缺漏、HTTP／解析錯誤、指標不符、無有效歷史或逾時，仍必須失敗。

`candidates: []` 是有效結果，休市、盤前盤後或股票池沒有確認突破不會單獨使健康門禁失敗。原策略仍只將通過 ADR、EMA 收斂、新鮮正常交易時段 PDH／ORH 突破及實際有效停損的股票列為確認推薦；不能以觀察名單替代。存在推薦時，仍驗證嚴格 1.5%～3% 停損範圍、USD 50,000／TWD 1,000,000 獨立本金、0.5% 風險、35%／25% 曝險，以及 3R／5R／10R 目標。即使零推薦，前置單元測試仍會驗證這些計算與型態的正反向情境。

Actions 不執行補丁更新器，直接使用已提交的原始碼。順序為 Python 報告驗證器測試 → Flutter RS／策略／風控單元測試 → 真實行情與計算驗證 → schema 2 報告驗證 → Release APK → 上傳。沒有 `continue-on-error` 或失敗後仍建置的例外。只保留兩種產物：

- `martin-luk-live-scan-evidence`：`**/test_logs/verification.log`，`if: always()`，成功或失敗都保存診斷，保留 7 天；JSON 證據會寫入日誌。
- `martin-luk-app-release`：僅門禁通過後才生成 `app-release.apk`，保留 7 天。

## 回歸測試

```bash
flutter test test/market_scan_timeout_test.dart test/live_repositories_test.dart test/market_scan_progress_test.dart test/candidate_repository_test.dart test/refresh_recovery_test.dart
```

覆蓋卡住的 HTTP 連線與本文、Socket 錯誤、429 等待、儲存掛起、整批期限、部分結果、限流、強制刷新合併、來源切換、dispose、逾時後重試，以及遲到回應不能污染新結果。

## 此工作區實際驗證狀態

已只讀核對 GitHub [run 38662579836](https://github.com/foxicall/martin-luk-app/actions/runs/38662579836)：台北 2026-10-15 08:55，約 2661ms，22 檔評估成功、7 檔仍因遠端舊版 RS 日期檢查失敗，沒有確認推薦。當時台股尚未開盤、美股已收盤，零推薦本身符合市場狀態。該次執行尚未使用本次健康門禁與全部 RS 修正，不能宣稱新流程已通過。

本地 Flutter／Dart／Android SDK 未安裝，實際嘗試 Flutter 命令回傳 `flutter: command not found`（exit 127）；直接網路探測亦曾因 `Operation not permitted` 失敗。來源與 Python 檢查不等於 Dart、最新真實行情測試或 APK 成功。本交付是可覆蓋原始碼；完成覆蓋並提交後，以新 Actions run 確認健康門禁與 APK 結果。
