# 修正名單服務關閉時的取消例外

2026-10-16（台北時間）。App 版本維持 **1.4.4+11**。

## 已確認原因

已讀取 GitHub [run 38862604909](https://github.com/foxicall/martin-luk-app/actions/runs/38862604909)，commit `042af225e8450c8ccc5719aa97032042ed278faf`、job `116848135142` 的完整日誌。兩項錯誤都是：

```text
Expected: throws <Instance of 'StateError'>
Which: threw RequestAbortedException: ClientException: Request aborted by abortTrigger
```

一項發生於 TWSE JSON，另一項發生於官方 CSV。HTTP 取消有運作，但前次備援修改在 `_closed` 時直接重新拋出底層 `RequestAbortedException`，違反 `StockUniverseService` 關閉後回傳 `StateError` 的契約。這不是資料格式或 Yahoo 限流造成的測試失敗。

## 本次核心只修一個檔案

完整覆蓋：

```text
lib/services/stock_universe_service.dart
```

在 `_load()` 最外層的網路／快取錯誤邊界改為：

```dart
} catch (error, stack) {
  if (_closed) {
    Error.throwWithStackTrace(StateError('股票池服務已關閉。'), stack);
  }
  // 下方原有 HTTP 錯誤、快取與字典退避不變。
```

這個邊界處理的是 `_inFlight` 中共用的 `_load` Future，因此第一個及後續共用請求的呼叫者都會得到同一關閉契約。只在最外面的 `load()` 呼叫者做轉換會漏掉直接沿用 pending Future 的共用呼叫，這次不採該方式。

保留取消、原始 stack、晚到回應禁止解析／寫入，以及 `finally` 清除進行中工作。一般網路錯誤在未關閉時仍走原有容錯。`NetworkRequest` 的 HTTP 取消行為不改動。

兩個失敗測試、斷言、工作流、版本與 `NetworkRequest` 均與失敗 commit 相同，已比對 Git blob 雜湊；沒有改成接受任何例外，沒有跳過測試或降低門禁。3R／5R、台股輪掃及官方 CSV 日期規則保留。

## GitHub 覆蓋

1. 若下載單獨 Dart 檔，在 `fix/refresh-live-gate-20261014` 分支開啟 `lib/services/stock_universe_service.dart`，用下載檔完整內容覆蓋並提交。
2. 若下載 `martin_luk_universe_close_fix_updates_20261016.zip`，先解壓，依原路徑合併覆蓋。包內 `UPDATE_FILES.txt` 列出完整清單；除核心 Dart 外，包含本次說明、最新狀態、完整性清單及 GitHub 仍缺少的隱藏配置檔。
3. 不要只上傳 ZIP，不要多套一層目錄。必須讓新提交觸發 Actions；重跑舊 commit 不會帶入修正。
4. 兩項名單關閉測試通過後，仍須真實行情／指標門禁通過，才會建置 APK。

## 驗證狀態

該失敗 run 中，包含 3R／5R、手動試算及風控的測試群 **78 項通過**；接下來的網路／控制器／輪掃群 **195 項通過**。台股 CSV／穩定性／續掃群為 **37 項通過、2 項失敗**，就是本次兩個例外型態錯誤。真實行情門禁及 APK 未執行。

本機已嘗試：

```bash
flutter test test/tw_official_fallback_test.dart test/tw_universe_stability_test.dart --dart-define=USE_MOCK_DATA=false --reporter=expanded
```

因未安裝 Flutter SDK，退出 127（`flutter: command not found`）。本次只確認完整日誌、最小原始碼修改、原測試及配置未被放寬、ZIP／來源完整性；修正後是否通過仍須以新提交的 Actions 結果為準。
