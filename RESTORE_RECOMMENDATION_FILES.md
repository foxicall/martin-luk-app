# 補齊 GitHub 缺少的推薦測試與畫面檔案

2026-10-16（台北時間）。版本維持 **1.4.2+9**。

## 已確認的錯誤

已讀取 Actions run `38851512257` 的完整日誌：

```text
Failed to load ".../test/recommendation_trade_levels_test.dart": Does not exist.
```

再比對該提交 `79ea8cc338504ca6eac5448cb91470b7002f0723` 的檔案樹：

- 缺少 `test/recommendation_trade_levels_test.dart`；不是測試內的語法錯誤。
- `lib/screens/calculator_screen.dart` 與三份 HTML 仍為上一版內容，未齊備推薦買賣價位更新。
- `RECOMMENDATION_LEVELS.md` 與幾個隱藏的專案配置檔亦未上傳。
- 新台股輪掃測試已存在；無須刪除或跳過它們。

本包依該提交與目前完整來源比對，補回缺檔及不同版本檔案，另更新操作說明與 CI 預檢。
不再要求用數個先前更新 ZIP 推算版本先後，也不以空檔或假測試替代原有六項驗證。

## 覆蓋方式

1. 解壓 `martin_luk_restore_recommendation_files_20261016.zip`。
2. 在 GitHub 選分支 `fix/refresh-live-gate-20261014`，將包內檔案依原路徑合併覆蓋。
   不要只上傳 ZIP，不要多套一層資料夾。
3. 務必核對這些路徑：

```text
test/recommendation_trade_levels_test.dart
lib/screens/calculator_screen.dart
.github/workflows/build_apk.yml
```

測試檔請放進根目錄的 **test** 資料夾，不是 `lib/test/`，也不是 `tests/`。
GitHub 網頁若選 **Add file → Create new file**，檔名填完整 `test/recommendation_trade_levels_test.dart`，
將下載的同名檔完整內容貼入再提交。畫面檔也要一起更新，以符合測試的 3R／5R 欄位。
`.github`、`.dockerignore`、`.gitignore`、`.metadata` 為隱藏項目，完整補齊時請保留包內路徑。

4. 提交後看新提交的 Actions。只重新執行舊提交不會取得新檔。
5. 若不確定其他檔案是否完整，可使用 `martin_luk_restore_recommendation_full_20261016.zip` 合併覆蓋完整專案。

## 新 CI 檔案檢查

在 Flutter 安裝／測試前，用 Python 標準函式庫檢查核心畫面與工作流引用的測試檔是否存在、非空。
若缺少任一項，直接輸出精確 `::error file=...` 路徑並停止建置。
不要求修改個人檔案內容才能通過，亦不會自動補空測試或略過失敗。
原有離線／真實行情／零推薦規則與 APK 先後門禁皆保留。

## 驗證限制

本次可確認日誌與 GitHub 檔案缺漏、原始碼完整性、工作流 YAML／Bash／Python 檔案預檢及 ZIP 雜湊。
本環境仍沒有 Flutter SDK，尚不能宣稱六項元件測試或 APK 建置已成功；以新提交 Actions 為準。
