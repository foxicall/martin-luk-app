# 修正背景服務生命週期測試

2026-10-16（台北時間）。App 版本維持 **1.5.0+12**；本次修正測試，不修改正式掃描器、Android 服務、控制器或策略門檻。

## 已確認原因

已讀取 GitHub [run 38877234917](https://github.com/foxicall/martin-luk-app/actions/runs/38877234917)（commit `9b289d0dcd532a39dd6297147db6bdd15aee2b8d`，job `116895559973`）完整日誌。

1. `background_scan_app_lifecycle_test.dart` 在建立 `CandidateSnapshot` 時漏填必填的 `stale`，所以尚未執行測試就編譯失敗。
2. 同一測試的輪掃統計還缺少固定且非空的 `universeFingerprint`；它是 `RollingScanCoverage` 契約的一部分。只修第一項仍會在執行時產生 `FormatException`，讓 Controller 顯示 fallback。
3. `production_lifecycle_test.dart` 直接模擬 `paused → resumed`。Flutter 的 `AppLifecycleListener` 會拒絕這個轉換，日誌中的實際錯誤是 `Invalid state transition from AppLifecycleState.paused to AppLifecycleState.resumed`。

## 完整覆蓋的核心檔案

```text
test/background_scan_app_lifecycle_test.dart
test/production_lifecycle_test.dart
```

新測試補齊 `stale: false` 與固定指紋，並新增初始快照非 fallback、已嘗試 30 檔、背景完成後累積進度與 fixture 一致的斷言。兩個測試都用 `paused → hidden → inactive → resumed` 恢復前台；新測試清理時先恢復 frame，再卸載畫面並保證 dispose。

所有原有斷言保留。沒有略過、刪除測試或接受任意錯誤，也沒有修改正式 Controller 以迎合不合法的測試狀態。正式生命週期由 Flutter 引擎產生合法轉換；不需新增正式 App 的狀態補丁。

## GitHub 更新

1. 下載 `martin_luk_background_lifecycle_fix_updates_20261016.zip` 並解壓。
2. 將上述兩個 Dart 檔依相同路徑覆蓋到 `fix/refresh-live-gate-20261014` 分支；其餘檔案為說明與完整性清單，也可一併覆蓋。不要只把 ZIP 上傳到專案。
3. 提交新的 commit，讓既有 Actions 重新執行測試。重跑原失敗 commit 不會帶入這次修正。
4. 原有背景服務與前台生命週期測試通過後，仍需真實行情與指標門禁通過，才會建置 APK。零推薦仍允許。

完整專案為 `martin_luk_background_lifecycle_fix_20261016.zip`。若已有前一次 1.5.0+12 背景服務專案，使用更新包即可；不需要重新套用上一版 ZIP。`UPDATE_FILES.txt` 列出所有可覆蓋檔案。

## 實際驗證狀態

上述失敗 run 中，風控／RS／推薦價位群 **78 項通過**、網路／Controller／輪掃群 **195 項通過**、台股官方備援／穩定性群 **39 項通過**。背景服務與生命週期群為 **44 項通過、2 項失敗**；其中一項是編譯載入失敗。真實行情門禁與 APK 步驟均未執行。

本機已嘗試：

```bash
flutter test test/background_scan_app_lifecycle_test.dart test/production_lifecycle_test.dart --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded
```

結果為退出 127（`flutter: command not found`）。本機沒有 Flutter SDK，不能宣稱修正後 Dart 測試或 APK 已成功。已檢查建構子／輪掃契約、原斷言保留、正式程式與工作流未變、來源／ZIP 逐檔雜湊；最終編譯結果仍須以新提交的 Actions 為準。

手動檢查時可沿用 [ANDROID_BACKGROUND_SCAN.md](ANDROID_BACKGROUND_SCAN.md) 的手機驗收步驟。省電、強制停止與關機限制維持不變。
