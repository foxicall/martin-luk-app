# 網路取消測試同步修正（2026-10-16）

## 實際失敗與原因

已唯讀檢查 GitHub Actions run `38827477760`、job `116738414224`：
該組 Dart 測試 97 項通過、1 項失敗，唯一失敗是
`test/network_request_test.dart` 的
`disposing aborts active work without closing an injected client`。
第 271 行原本的 `expect(aborted, isTrue)` 取得 `false`。

`NetworkRequest` 與測試用 Client 各自監聽同一個非同步取消訊號。
外層請求 Future 先以 `RequestAbortedException` 結束時，Client 的另一個
回呼不一定已執行完畢。因此，等待請求結果不等於等待 Client 確認收到取消。

## 修正

只調整測試的同步方式：新增 `abortObserved` Completer，在 Client 實際處理
取消回呼後完成；測試以最長 1 秒等待這個確認，再檢查既有 `aborted` 斷言。
同時限制測試啟動與取消結果的等待時間，並登記測試結束後的清理動作。

保留全部原有斷言：請求必須收到 `RequestAbortedException`、Client 必須收到
取消通知、外部注入的 Client 不可被 close、已關閉的包裝器不可再發出請求。
未移除或跳過測試，未修改 `lib/services/network_request.dart`、策略、行情或 CI 門禁。

## 覆蓋方式

解壓本次修正包，將下列完整檔案依原路徑上傳至 GitHub 分支
`fix/refresh-live-gate-20261014`，覆蓋同名檔案：

- `test/network_request_test.dart`
- `NETWORK_DISPOSE_TEST_FIX.md`（本說明）
- `FILE_MANIFEST.json`（更新後的來源檔案雜湊清單）

請上傳解壓後的檔案，不要只將 ZIP 放入 repository。
提交後由既有 GitHub Actions 執行驗證；只有通過原有真實行情門禁才會建置 APK。

## 驗證

有 Flutter SDK 的環境可執行：

```bash
flutter pub get
flutter test test/network_request_test.dart --reporter=expanded
```

本次工作環境沒有 Flutter/Dart SDK，無法實際重跑這個 Dart 測試，亦未宣稱
APK 建置成功。已確認本次僅修改指定測試的取消同步與清理，保留全部原有斷言，
並檢查交付 ZIP 的內容、CRC 與逐檔 SHA256。
