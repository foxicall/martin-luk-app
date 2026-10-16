# 背景輪詢測試修正 v2（2026-10-15）

本次需覆蓋的程式檔案只有 `test/backend_scan_controller_test.dart`，是完整檔案，無需補丁腳本。`lib/app_controller.dart` 和 `.github/workflows/build_apk.yml` 維持原內容，沒有跳過測試、放寬斷言或移除建置門禁。

## v2：實際 Actions 日誌確認的剩餘兩個失敗

已唯讀取得 GitHub Actions run `38690946473`、job `116276488335` 的完整日誌：
https://github.com/foxicall/martin-luk-app/actions/runs/38690946473

v1 的零秒計時器修正後，該次執行是 **62 passed / 2 failed**。剩餘兩個失敗都不是 `expect` 行為斷言錯誤，而是 Flutter 在測試結束時回報：

```text
A Timer is still pending even after the widget tree was disposed.
```

- `server failure stops polling and manual retry recovers`：留下 60 秒週期計時器。
- `stop only stops this client and a manual pull can resume`：留下 60 秒週期、3 秒狀態查詢、180 秒等待上限計時器。

Flutter 在 `testWidgets` callback 返回後、package 的 `addTearDown` 執行前，就會檢查 pending timers。v2 保留原本全部行為斷言，將這兩個測試的主體包在 `try/finally`，在 callback 返回前清理控制器：

```dart
try {
  // 原有初始化、停止／失敗及恢復斷言，全部保留。
} finally {
  controller.dispose();
}
```

移除這兩個測試原有的 `addTearDown(controller.dispose)`，避免重複釋放；清理後再驗證 auto-refresh、status timer、waiting 與 loading 全部為 false。其他測試及控制器沒有變動。

**上面的 62/2 是已觀察到的 v1 CI 結果，不是 v2 通過的證明。v2 仍須由新的 Actions 執行確認。**

## 保留 v1 的零秒計時器修正

Flutter 的 `AutomatedTestWidgetsFlutterBinding.pump` 僅在傳入非 null 的 `duration` 時呼叫 fake clock 的 `elapse(duration)`。單純 `tester.pump()` 只清理 microtasks，不會執行 `Timer(Duration.zero)`。

控制器在 `setForeground(true)` 後以零秒計時器啟動第一次狀態請求，舊測試未執行該計時器，故只有初始化的 1 次請求，而斷言預期 2 次。dispose 案例也因此在沒有請求訂閱 `delayed.future` 時呼叫 `completeError`，產生測試結束後的未處理例外。

修正版在 12 處前景切換後明確使用：

```dart
controller.setForeground(true);
await tester.pump(Duration.zero);
```

保留全部 14 個測試及原本的斷言；另確認三秒輪詢在 2999ms 尚不發生，下一個 1ms 才發生。dispose 案例先確認第二次請求已啟動，再檢查清除計時器、停止 loading、不再通知 listener，及消化晚到錯誤；未在測試端加入 `catchError` 掩蓋錯誤。guarded teardown 可在前置斷言失敗時清除控制器。

Flutter 原始碼參考：
https://github.com/flutter/flutter/blob/stable/packages/flutter_test/lib/src/binding.dart

## 在 GitHub 套用

1. 解壓 `martin_luk_polling_test_fix_v2_20261015.zip`。
2. 切換 `foxicall/martin-luk-app` 的 `fix/refresh-live-gate-20261014` 分支。
3. 在原專案根目錄上傳包內 `test/backend_scan_controller_test.dart`，保留 `test/` 路徑，整份覆蓋同名檔；本說明檔可一併上傳。
4. Commit changes，查看此次提交觸發的 Actions。不要直接上傳 ZIP，GitHub 不會自動解壓。

若原始碼版本不確定，可使用同次提供的完整專案 `martin_luk_all_stocks_polling_fix_v2_20261015.zip`。

## 驗證與限制

已比對上一份完整成品：14 個測試名稱與全部原有 `expect` 行均保留；12 個前景啟動點皆明確推進零秒計時器；控制器與工作流逐位元組不變。檔案內容另經獨立程式碼審查。

本機實際嘗試以下命令，因缺少 Flutter SDK 回傳 `flutter: command not found`（exit 127）。**尚未在此環境執行成功，須由 GitHub Actions 確認結果**：

```bash
flutter test test/backend_scan_controller_test.dart --dart-define=USE_MOCK_DATA=false --reporter=expanded
```

工作流原有的離線測試與真實行情／指標門禁仍依序執行；零推薦合法，但網路或必要資料驗證失敗仍會阻擋 APK。
