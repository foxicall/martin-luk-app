# 1.4.0+7：逐檔進度測試修正

2026-10-16（台北時間）。適用已套用手機台股輪掃 1.4.0+7 的專案。
本次只改 `test/live_repositories_test.dart` 的一項測試，不修改 App 正式行情、策略、風控、台股輪掃或 CI 門禁。

## 確認的原因

已讀取 GitHub Actions run `38839063038`（commit `9c5146edddf92173b5c697eec08762af52a6dfc8`）的完整日誌。
離線 Dart 測試群為 189 通過、1 失敗，失敗位置為 `test/live_repositories_test.dart:640`：

```text
Expected: [5, 10, 12]
Actual: [1, 2, 3, 3, 4, 5, 5, ... 6, 7, 8, 9, 10, 10, ...]
```

原測試把「每批最多 5 檔」誤當成「只能在每批結束時發一次進度」。
現有實作在單檔日 K 已驗證時就發送部分快照，盤中資料或整批完成後也可更新，
所以進度含中間值及重複值。這讓其他股票較慢時，已取得的資料仍能先顯示。

## 修正後驗證

保留原測試名稱與最終精確斷言，將進度事件檢查改為：

- 依序包含完成點 5、10、12，允許中間值與重複通知。
- 第一批完成前必須已有可顯示的部分快照。
- 嘗試數、完成數不倒退，每次均滿足 `完成 = 成功 + 失敗`。
- `0 ≤ 完成 ≤ 嘗試 ≤ 池大小`，ADR 符合數不大於成功評估數。
- 故意拋錯的 observer 確實被執行；之後仍能到 10、12，並只發布一次結束狀態。
- 最終仍為嘗試／完成 12、成功 11、失敗 1、ADR 10、候選 10，缺失標的只有 AAPL。
- 用 `finally` 保證斷言失敗時也會關閉測試資源。

沒有刪除測試、跳過失敗、放寬 ADR 或改用假行情通過真實門禁。
這項測試本來就使用明確的單元測試 fixture，不是公開行情連線證據。

## GitHub 覆蓋方式

1. 解壓 `martin_luk_progress_test_fix_20261016.zip`，依包內路徑覆蓋分支 `fix/refresh-live-gate-20261014`。
2. 確認 `test/live_repositories_test.dart` 已更新；其餘四個檔案為說明及完整性清單。
3. 提交後查看新 Actions。版本仍為 1.4.0+7，因為本次沒有修改 App 正式功能。
4. 必須由新的 Actions 重新執行測試，再通過真實行情門禁才會建置 APK；重跑舊 commit 不會取得這項修正。

有 Flutter SDK 可先執行：

```bash
flutter test test/live_repositories_test.dart --plain-name 'batch progress counts failed symbols as completed and isolates observer errors' --dart-define=USE_MOCK_DATA=false --reporter=expanded
```

本環境實際執行上述命令回報 `flutter: command not found`（127），因此尚無修正後的 Dart 測試成功證據。
原 run 的真實行情門禁及 APK 建置均被跳過，不能以 189 個離線測試通過宣稱 APK 已成功。
