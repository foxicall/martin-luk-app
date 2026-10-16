# 修正美股輪掃畫面測試的六項失敗

2026-10-16（台北時間），App版本維持 **1.6.0+13**。本次只修測試定位與狀態斷言，正式美股完整名單輪掃、Android服務、策略與建置門禁不變。

## 已讀取的實際日誌

GitHub [run 38908151003](https://github.com/foxicall/martin-luk-app/actions/runs/38908151003)，commit `5f2c597e7c41281bb9f085da9ac34c872cc0ce69`，job `116997415235`。

先前風控／推薦群78項、網路／控制器／輪掃群195項、台股官方備援群39項、背景服務／生命週期群48項均通過。新增的美股輪掃及畫面群為 **54項通過、6項失敗**。真實行情門禁及APK步驟尚未執行。

## 原因與修正

| 失敗測試 | 日誌或原始碼確認的原因 | 修正 |
|---|---|---|
| 冷掃描顯示進度與停止操作 | 手動停止會進入「台股輪掃已暫停」，原斷言仍期待一般失敗文案；空卡片亦在後方sliver | 驗證明確暫停、載入鎖釋放、進度結束、重試及舊請求晚到隔離，捲動至暫停卡片 |
| 成功但零候選的分頁 | 正確空清單卡片在長總覽下方，sliver尚未建立 | 捲至卡片後驗證本輪30／900、剩餘870、原時間戳、無spinner／重試，不把當頁零候選當成全市場零買點 |
| US新頁保留前一日報價 | 測試捲到整個ExpansionTile，沒有確認可點擊標題與展開結果 | 以tile內的標題定位，完成捲動與layout後確認hitTestable再真實點擊；保留舊報價／訊號時間及禁止新部位斷言 |
| 設定直接行情成功儲存 | tap中心`(409,1876)`在`800×600`測試畫面外，未真的按到儲存 | 定位真正FilledButton，捲動／置中／pump，要求hitTestable後點擊並保留原成功與設定斷言 |
| 快取部分掃描的原始警語 | 展開標題tap中心`(396,666.2)`在畫面外，警語仍折疊 | 捲至真正標題並等待layout，再點擊及驗證原警語 |
| 斷線後強制重試 | tap中心`(120.1,773)`在畫面外，實際請求數仍為1 | 捲至真正TextButton並等待layout，驗證真實tap後請求增加一次且forceRefresh仍為true |

本次沒有透過直接呼叫按鈕callback來繞過互動，沒有關閉hit-test警告、刪除失敗測試或改成接受任意結果。原本獨立檢查RefreshIndicator callback的測試保持不變。FilledButton／TextButton以`is`辨識，可涵蓋`.icon`建立的子類別。

## 完整可覆蓋檔案

核心三個檔案：

```text
test/market_scan_progress_test.dart
test/mobile_us_scope_test.dart
test/production_ui_test.dart
```

下載 `martin_luk_ui_test_fix_updates_20261016.zip` 並解壓，依相同路徑覆蓋GitHub分支 `fix/refresh-live-gate-20261014`。包內其他檔案為本次指南、最新狀態、逐檔清單與GitHub仍缺少的隱藏配置。不要只把ZIP上傳到專案，也不要多套一層目錄。

完整專案為 `martin_luk_ui_test_fix_20261016.zip`。已套用1.6.0+13時，使用更新包即可，不需依序重套所有舊版本。

必須提交新commit觸發Actions，重跑原失敗commit不會帶入修正。工作流仍先跑固定與真實行情／指標門禁，允許零推薦；通過後才建置APK。美股手機完整名單的操作見 [MOBILE_US_SCAN.md](MOBILE_US_SCAN.md)。

## 驗證限制

本機已嘗試：

```bash
flutter test test/market_scan_progress_test.dart test/mobile_us_scope_test.dart test/production_ui_test.dart --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded
```

因缺少Flutter SDK退出127（`flutter: command not found`）。已核對完整日誌、正式原始碼／版本／工作流未改、原測試斷言與新狀態契約、來源／ZIP完整性；這不能替代修正後的Flutter測試或APK編譯。請以新提交的Actions結果為準。
