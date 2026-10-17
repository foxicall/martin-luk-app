# 1.6.1+14：行情快取兩項測試資料修正

2026-10-17（台北時間）。版本維持 `1.6.1+14`。核心只需覆蓋兩個完整檔案：

```text
test/market_data_api_test.dart
test/market_data_cache_bounds_test.dart
```

## 已讀取的失敗紀錄

GitHub commit `d8d540795478de323374069188ed46b989304e32`，Actions run `39010655225`／job `117332338081`。

Python 後端 101 項、腳本 25 項、風控 78 項、網路與輪掃 195 項、台股備援 39 項、背景生命週期 48 項、美股輪掃與畫面 60 項通過。行情快取群組 74 項通過、2 項失敗。真實行情門禁、APK 編譯及原生復原測試尚未執行，不能視為已產出新版 APK。

## 精確原因與修改

1. `Benchmarks and class-share IDs are normalized for Yahoo`：測試以 `request.url.path.endsWith('^TWII')` 判定台股；URI 路徑中的 `^` 經編碼成 `%5E`，測試卻回傳美股 `^GSPC` 資料。正式解析器正確拒絕。改用解碼後的 `pathSegments.last` 建立測試回應及驗證請求代碼；增加真正經過 HTTP 模組的 `brk.b → BRK-B` 請求，核對指數／類股代碼與 USD／TWD，保留錯誤市場拒絕斷言。
2. `disk reads and offline fallback obey the same memory eviction budget`：120 筆測試快取的抓取時間為 `now − 120…1 秒`，但報價時間全部固定 `now`。清理後保留 96 筆，其中 36 筆報價晚於原抓取時間超過一分鐘，被正式驗證拒絕，因此實際只成功 60 筆。改讓每筆測試報價時間等於該筆原抓取時間，並驗證時間未被改寫。**保留預期 96，沒有改成 60。**

另新增一項反例：刻意放入報價晚於抓取時間兩分鐘的快取；離線更新必須失敗，且該錯誤快取會被移除。行情快取測試現在共 11 項，避免為了通過測試而放寬時間校驗。

正式 `lib/`、Android、工作流、版本、股票字典、策略風控與真實行情門禁均保持失敗 commit 的內容。前版有界快取、原生升級整理及持股／本金／進度保留仍生效於原始碼；沒有跳過失敗測試或降低選股門檻。

## GitHub 網頁覆蓋

下載 `martin_luk_cache_test_fix_updates_20261017.zip`，解壓後依原路徑覆蓋 `fix/refresh-live-gate-20261014` 分支，尤其上述兩個 test 檔。包內其他檔案是更新指南、完整性清單及 GitHub 尚缺的隱藏專案配置，可一併覆蓋。完整專案為 `martin_luk_cache_test_fix_20261017.zip`。

提交新 commit 再看 Actions，不能重跑原失敗 commit。全部測試、真實行情計算門禁、APK 建置及原生測試成功後才下載 APK。安裝仍依 [LONG_RUN_RECOVERY.md](LONG_RUN_RECOVERY.md)：相同簽章覆蓋安裝，不解除安裝或清除 App 資料。

## 驗證限制

```bash
flutter test test/market_data_api_test.dart test/market_data_cache_bounds_test.dart test/mobile_scan_storage_budget_test.dart --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded
```

本環境實際嘗試上述命令，得到 `flutter: command not found`、退出碼 127。無 Flutter／Dart／Android SDK，修正後的 Dart 測試、APK 與手機啟動仍待新提交的 Actions 與實機確認。本機通過 25 項 Python 腳本回歸、YAML／Bash 語法、CI 63 檔預檢及 Dart import 路徑檢查；核對 79 個正式行情、Android、策略、字典與門禁檔案和失敗 commit 雜湊相同。這些及 ZIP 完整性檢查不能代替編譯或實際行情驗證。
