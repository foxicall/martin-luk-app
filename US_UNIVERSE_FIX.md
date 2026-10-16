# 美股股票池更新修正：1.3.1+5

適用於畫面顯示「股票池更新失敗（資料格式無效）」並退回內建 5,113 檔字典的情況。截圖中核心 30 檔仍已評估，不代表所有美股報價都失效。

## 本次修改

- 股票名錄是 `text/plain`。網路層新增每個服務的 Accept 設定；名錄使用純文字優先，行情 API 仍預設 JSON，瀏覽器 User-Agent、8 秒期限及五路上限保留。
- 新的 `us_stock_directory.dart` 支援 UTF-8／BOM、來源指定的 Latin-1／Windows-1252、UTF-16。未指定編碼時僅允許受限的單位元組復原，並標示不完整。
- 忽略合法空白與尾端空欄；少數錯行或重複代碼會隔離並揭露，不再丟掉整份名單。缺少表頭、完成標記、多數損毀、HTML 驗證頁及非名錄 JSON 仍拒絕。
- 官方來源失敗時，嘗試 Cperkin/CanadianStats 的公開名錄鏡像。每個來源的官方與鏡像共用同一個最多 8 秒的預算；手機核心掃描預設為共用 4 秒。不是失敗後再等另一個 8 秒。
- 鏡像必須有可解析的名錄日期，超過 7 天不採用；鏡像永遠標示為備援、不完整來源。它只包含股票身份，不含假報價、ADR 或買點。
- 具體錯誤與日誌包含 HTTP 狀態、Content-Type、位元組數、有限長度回應開頭及解析原因。舊版全部顯示「資料格式無效」無法分辨原因；本版保留原因。
- 名錄日期與取得時間分開。股票池快取改為 v3，直接掃描快取亦使用新命名空間，避免繼續顯示上次失敗提示；沒有清除持股或帳戶本金。
- 服務關閉後不允許晚到的部分名單覆寫共用快取。

## 可直接覆蓋的檔案

請把小型更新包所有檔案依原路徑上傳到原本含 `pubspec.yaml` 的根目錄；**不要只覆蓋 `stock_universe_service.dart`，它需要新增的解析器與更新的網路層**。

```text
lib/services/us_stock_directory.dart             新增解析器
lib/services/stock_universe_service.dart           正式／備援、日期、快取與錯誤
lib/services/network_request.dart                 可設定 Accept
lib/services/live_candidate_repository.dart       4 秒名錄預算與快取遷移
pubspec.yaml                                     1.3.1+5
.github/workflows/build_apk.yml                    新解析測試與真實名錄門禁
test/us_stock_directory_test.dart                 新增解析回歸測試
test/us_universe_fallback_test.dart               新增備援／逾時／關閉測試
test/us_universe_http_smoke_test.dart              新增真實連線測試
test/stock_universe_service_test.dart              v3 與相容測試
test/network_request_test.dart                    Accept 設定回歸
test/live_repositories_test.dart                  快取版本更新
test/core_market_pool_test.dart                   快取版本更新
```

包內其他清單、完整性驗證器與說明也一併覆蓋。前次 v2 的計時器測試修正完整保留；沒有跳過測試、減少原有斷言或降低 ADR／進出場門檻。

## GitHub 與手機操作

1. 解壓 `martin_luk_us_universe_fix_20261015.zip`，切換 `foxicall/martin-luk-app` 的 `fix/refresh-live-gate-20261014` 分支。
2. 選 Add file → Upload files，把包內檔案／資料夾原路徑覆蓋；保留隱藏的 `.github/`。GitHub 不會自動解壓上傳的 ZIP。
3. Commit changes，等這次提交的 Actions；不能只重跑舊提交。
4. 下載新 `martin-luk-app-release` artifact，安裝 **1.3.1+5**，在美股頁下拉強制刷新。舊 APK 不會因上傳原始碼自動更新。
5. 若官方來源被拒絕，頁面會明示已改用備援及名錄日期。若官方與備援皆失敗，保留真實快取／字典及具體錯誤，不改用假行情。

「核心 30 檔」仍是手機直接連線模式的限制，用來避免瞬間對數千檔發送行情請求。要逐頁評估全市場，請在設定選擇 Python API，填入你實際部署的雲端 HTTPS 根網址；本次沒有替你部署新服務或假設已存在網址。

## 驗證與已知限制

原先內建 10/14 名錄可以正常解析。另已透過唯讀 GitHub connector 取得 10/15 鏡像，並用現有 Python 嚴格解析器實際驗證 `3185 + 1930 = 5115` 檔。固定來源：

```text
https://github.com/Cperkin/CanadianStats/tree/c38d2eb3a2f8658952051b8fced9c37eca83f461/data/sources
File Creation Time: 1015202607:00（原檔未附時區）
```

這證明有實際可用的公開名錄，不是 Android 手機此次 HTTP 回應或新 Dart 測試成功的證明。僅靠原截圖無法判定實機遇到 HTML 拒絕頁、編碼或下載損毀中的哪一種；本版同時提供對應恢復路徑與具體診斷。

本環境沒有 Flutter SDK，實際嘗試單元測試命令回傳 `flutter: command not found`（127）。新測試、APK 建置及手機實機結果須由 Actions 與新版 APK 確認，未宣稱已成功。

```bash
flutter test test/us_stock_directory_test.dart test/us_universe_fallback_test.dart test/stock_universe_service_test.dart test/network_request_test.dart --dart-define=USE_MOCK_DATA=false
flutter test test/us_universe_http_smoke_test.dart --dart-define=RUN_LIVE_UNIVERSE_TEST=true --dart-define=USE_MOCK_DATA=false --timeout=30s
```

CI 在原 Yahoo 真實行情／指標門禁後，新增美股名錄真實 HTTP 驗證：不得使用內建字典或舊快取、至少 2,500 筆、確認 NVDA／AAPL／BRK-B、名錄日期小於 8 天、15 秒內完成，通過後才建置 APK。原選股門檻不變，零推薦仍可通過原行情健康門禁。
