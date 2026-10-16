# 本次最小覆蓋：名單服務關閉例外

版本仍為 **1.4.4+11**。這次核心只需覆蓋 `lib/services/stock_universe_service.dart` 的完整檔案，讓關閉後的JSON／CSV取消一致回傳StateError。兩個測試、工作流及所有門禁不改動。

下載 `martin_luk_universe_close_fix_updates_20261016.zip` 解壓後依路徑覆蓋，或使用單獨下載的完整Dart檔貼到上述GitHub路徑。分支為 `fix/refresh-live-gate-20261014`。必須提交新commit再看Actions；重跑舊提交不會帶入修正。

本包也包含本次指南及更新狀態／清單，核心修改及驗證限制見 [UNIVERSE_CLOSE_FIX.md](UNIVERSE_CLOSE_FIX.md)。不要刪除失敗測試或改為接受任意例外。下方為前次功能更新說明。

---

# GitHub 網頁覆蓋：1.4.4+11 目標價顯示修正

請使用 `martin_luk_r_targets_updates_20261016.zip`，解壓後依 `UPDATE_FILES.txt` 原路徑覆蓋 `fix/refresh-live-gate-20261014` 分支。此包包含目前 GitHub 基線缺少的上一版官方 CSV 備援，不需另外依序疊加舊更新包。完整專案為 `martin_luk_r_targets_20261016.zip`。

務必一併上傳 `lib/widgets/manual_trade_levels.dart`、兩項新測試檔、更新後推薦測試及 `.github/workflows/build_apk.yml`；版本為 **1.4.4+11**。不要只上傳 ZIP，保留相對路徑與隱藏目錄，不多套一層資料夾。

看最後一次提交的 Actions，真實行情門禁成功後才建置，完成後下載 `martin-luk-app-release` 安裝。有效的舊停損／R價位會標明歷史參考；缺少停損可展開手動試算，輸入不會變成自動買點。詳見 [R_TARGET_DISPLAY_FIX.md](R_TARGET_DISPLAY_FIX.md)。本環境沒有 Flutter，新增測試與APK尚待新提交驗證。

---

以下為歷史版本說明，以本頁上方的版本與更新包為準。

# GitHub 網頁覆蓋：1.4.3+10 官方台股名單備援

本次使用 `martin_luk_tw_official_csv_updates_20261016.zip`，依解壓後 `UPDATE_FILES.txt` 原路徑覆蓋。若不確定舊檔是否完整，改用 `martin_luk_tw_official_csv_20261016.zip` 合併完整專案。

1. 開啟 `foxicall/martin-luk-app`，切換 **fix/refresh-live-gate-20261014**。
2. **Add file → Upload files**：上傳解壓後檔案與資料夾，放在原有 `pubspec.yaml` 所在根目錄；不是上傳 ZIP，也不是多包一層目錄。
3. 保留 `.github/` 隱藏目錄。新版工作流、新 parser 與兩個新測試必須一起上傳，版本為 **1.4.3+10**。清單內其他不同步檔案也一併覆蓋。
4. 最後一次提交會觸發 Actions。必須看新提交結果；重跑舊提交不會使用新原始碼。手動 Run workflow 按鈕需工作流存在於預設分支。
5. 成功後下載 **martin-luk-app-release**，解壓並安裝 APK；**martin-luk-live-scan-evidence** 保存測試紀錄。
6. 關閉 Mock、選手機直接連線，開啟前台自動更新。不要清資料或重設輪掃；目前進度保留，下一輪需要載入名單時會使用新增的官方備援。

這張圖已確認下拉會從 30 增到 60 或更多，並非續掃卡住。新增 CSV 備援處理的是 TWSE 官方名單逾時；完整行為、日期政策與驗證限制見 [TW_OFFICIAL_CSV_FALLBACK.md](TW_OFFICIAL_CSV_FALLBACK.md)。

基線 1.4.2+9 已在 GitHub run `38852597488` 通過測試、真實行情門禁與 APK 建置；新增 1.4.3+10 仍須由本次新提交驗證，本機沒有 Flutter SDK。沒有代為 Push、部署 API 或跳過門禁。

---

以下為先前交付的歷史說明；以本頁上方版本與更新包為準。

# GitHub 網頁完整覆蓋：1.4.0+7 手機台股輪掃

若 Actions 顯示 `recommendation_trade_levels_test.dart: Does not exist`，使用 **`martin_luk_restore_recommendation_files_20261016.zip`** 一次補齊；此包依 GitHub 實際缺漏比對，包含測試與不同步的計算機／預覽更新。步驟見 [RESTORE_RECOMMENDATION_FILES.md](RESTORE_RECOMMENDATION_FILES.md)。版本仍為 1.4.2+9。

最新 **1.4.2+9** 請使用 `martin_luk_tw_scan_stable_updates_20261016.zip` 或完整包 `martin_luk_tw_scan_stable_20261016.zip`，依 [TW_SCAN_STABILITY_FIX.md](TW_SCAN_STABILITY_FIX.md) 操作。本版修正 894／1979 名單切換造成第一頁重掃，保留推薦價位與前次測試修正。

最新 **1.4.1+8** 請使用 `martin_luk_recommendation_levels_updates_20261016.zip` 或完整包 `martin_luk_recommendation_levels_20261016.zip`。本次新增推薦進出場明細，並包含上一項逐檔進度測試修正；操作見 [RECOMMENDATION_LEVELS.md](RECOMMENDATION_LEVELS.md)。以下是 1.4.0+7 輪掃交付的原有說明。

本版不需要本機 Git 指令或補丁安裝器。台股手機直接連線即可分頁輪掃上市／上櫃名單；美股手機模式仍是最多 30 檔核心池。細節見 [MOBILE_TW_SCAN.md](MOBILE_TW_SCAN.md)。

## 1. 選擇更新包

- 已套用上一份 `martin_luk_full_market_setup_20261016.zip`（1.3.2+6）：解壓 `martin_luk_mobile_tw_updates_20261016.zip`，其中每個檔案都是完整可覆蓋內容，清單見 `UPDATE_FILES.txt`。
- 不確定既有版本：解壓完整專案 `martin_luk_mobile_tw_20261016.zip`，合併覆蓋專案全部內容，避免遺漏既有依賴。

不要只把 ZIP 上傳到 repository，也不要把原始碼多包一層新目錄。Windows 本機專案可先備份，再合併同名檔案。

## 2. 上傳到正確分支

開啟 `foxicall/martin-luk-app`，切換 **`fix/refresh-live-gate-20261014`**。使用 **Add file → Upload files**，將解壓後檔案及資料夾放在原有 `pubspec.yaml` 所在根目錄，保留包內路徑。

本次務必一併更新：

```text
.github/workflows/build_apk.yml
pubspec.yaml
lib/app_controller.dart
lib/screens/dashboard_screen.dart
lib/screens/settings_screen.dart
lib/services/candidate_repository.dart
lib/services/live_candidate_repository.dart
lib/services/mobile_scan_checkpoint.dart
test/backend_setup_settings_test.dart
test/dashboard_scope_test.dart
test/live_repositories_test.dart
test/mobile_tw_polling_test.dart
test/mobile_tw_rolling_repository_test.dart
scripts/verify_deliverable.py
```

更新包內其他文件及完整性清單也一起上傳。`.github` 是隱藏目錄，請確認 workflow 沒有漏掉。不要上傳 `.git/`、`build/`、`.dart_tool/`、個人 `.env`、keystore 或私鑰。

如果必須分批提交，等全部檔案上傳完成後，以最後一次提交的 Actions 結果為準。

## 3. 重建與安裝 APK

確認 `pubspec.yaml` 為 `version: 1.4.0+7`。在 **Actions → Build Android APK with Verification Gate** 查看這次提交；若可使用 **Run workflow**，選正確分支執行（手動入口需 workflow 存在於預設分支）。

工作流保留原有真實行情／計算門禁，允許零推薦；新增輪掃、取消及續掃測試必須通過，才會編譯正式 APK。完成後下載 `martin-luk-app-release` artifact，解壓安裝 APK。`martin-luk-live-scan-evidence` 保存測試日誌，兩種產物保留 7 天。

本環境沒有 Flutter SDK，尚無本次 Dart 測試或 APK 成功證據；以該提交的 Actions 日誌為準，不以單元測試假資料當成實際行情成功。

## 4. 手機開始台股輪掃

1. 設定關閉離線示範，來源選 **Yahoo Finance・手機直接連線**，保存設定。
2. 開啟前台自動更新，切換台股並下拉一次。
3. 每次最多 30 檔、每批最多 5 檔；前台每 60 秒推進下一頁，單檔失敗跳過。
4. 查看本輪已嘗試、成功及剩餘數。「暫停台股輪掃」會保持暫停；「繼續」或手動下拉可恢復。

進度與累積候選保存在手機；切到背景會停止請求，返回後續掃。較舊卡片保留原始行情時間，RS 為原掃描頁的排名。公開端點仍可能限流或失敗，不能保證每檔取得成功；不會改用示範價格。

## 5. 可選 Python API

只掃台股不需部署服務。若使用 Python API 或要美股完整名單輪掃，另依 [CLOUD_API_GUIDE.md](CLOUD_API_GUIDE.md) 配置並實際部署 HTTPS API；上傳 ZIP 或安裝 APK 不會自動建立伺服器。後端原有逐頁協定保留，本次未代為部署或產生正式網址。
