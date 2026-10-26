# 1.6.1+14 長時間輪掃穩定性補充

行情快取改為有界，升級開啟先原生非同步整理舊行情，持股與輪掃進度保留。完整台美股輪掃及明確手動啟動前景服務的方式不變；先同簽章覆蓋安裝，**不要清除資料**。詳見 [LONG_RUN_RECOVERY.md](LONG_RUN_RECOVERY.md)。本版尚待 GitHub Actions 與手機升級驗證。

---

# Android 背景持續輪掃

2026-10-16（台北時間），更新至版本 **1.6.0+13**。美股完整名單輪掃見 [MOBILE_US_SCAN.md](MOBILE_US_SCAN.md)。

## 手機怎麼使用

1. 完整更新 GitHub 專案，等新提交的 Actions 成功後，下載 `martin-luk-app-release`，解壓並安裝新 APK。單獨更新 Dart 檔不足以新增 Android 原生服務，必須重新建置。
2. 在設定關閉離線示範、選擇 **Yahoo Finance／手機直接連線**，儲存。
3. 回總覽選擇要更新的市場，再到設定的 **「背景持續更新（Android）」→「啟動背景更新」**。
4. 首次啟動允許 Android 通知。成功後通知列會出現「市場輪掃」常駐通知；可切到其他 App。
5. 通知可 **暫停／繼續／停止**，點通知可返回 App。設定頁與總覽也顯示服務狀態。

服務不會因安裝、開啟 App 或開機而自行啟動；每次完整結束後需重新手動啟動。通知未允許、通知頻道被封鎖或 Android 拒絕啟動時，設定頁會顯示原因並允許重試。

前台自動更新開關與背景服務分開。即使前台開關關閉，明確啟動的服務仍會更新；停止／暫停背景服務後，App 保持在前台時仍依原本前台開關執行。每日通知提醒只提醒開啟 App，不會偷偷啟動服務。

## 更新範圍

- **台股**：沿用目前取得的上市＋上櫃普通股名單逐頁輪掃，每頁最多 30 檔、每批最多 5 檔，批次間保留間隔；失敗跳過繼續，進度及本輪名單保存在手機。服務約每 60 秒推進一頁。
- **美股**：按當輪已取得的 NYSE／Nasdaq／NYSE American 可確認普通股完整名單逐頁輪掃，每頁最多30檔、每批最多5檔。未完成輪次忽略候選報價快取的15分鐘冷卻，繼續下一頁；通知顯示實際累積已嘗試／成功／剩餘。這是分時取得資料，不是全市場同一時刻的同步排名。
- **持股**：沿用既有報價與診斷更新，不會送出券商訂單。

掃描跟隨總覽目前選取的市場。切換行情來源、Mock 或 ADR 門檻時，會先停止服務，保存設定後需再次啟動。本版手機背景服務僅支援正式直接行情；Python API 保持原有前台工作狀態讀取方式。

3R／5R 顯示、帳戶 USD／TWD、0.5% 單筆風險、35%／25% 部位上限、原始停損證據與零推薦規則維持。跨頁候選保留各自原行情時間與原頁 RS，不能當成全市場同步排名。通知進度代表已嘗試／成功評估範圍，不代表每檔都取得新鮮報價。

## 一個掃描擁有者

Android `dataSync` 前景服務保留 **同一個 UI FlutterEngine、AppController 與 Repository**，沒有另開 isolate、第二套掃描器或另一份 SharedPreferences 寫入者。切換背景時，已啟用服務的控制器保留原有更新計時器與頁面；返回畫面不重建第二個輪掃流程。未啟用服務時，原本切背景暫停的行為保留。

通知透過 `martin_luk/background_scan` 平台通道回傳狀態與操作。一般狀態／控制等待最長 8 秒；首次啟動包含人為授權，Dart 最長等待 60 秒，原生分別限制授權 45 秒、返回前台 5 秒、實際服務啟動 7 秒。取消或逾時後，晚到的授權不會重新啟動服務。HTTP 8 秒與掃描全流程 10 秒的原有時限不變。

服務先成功 `startForeground()` 才回覆啟動成功。啟用時以有界續租的部分 WakeLock 協助執行，暫停／停止／系統結束時釋放。通知進度節流，單次通知失敗不會中斷行情計算。只有 Activity 與服務都不再使用引擎時，才延後釋放引擎，讓最後的取消與檢查點處理有完成機會。

原生服務不成為 Flutter plugin 的另一個 host，不對同一個 UI engine 呼叫 `attachToService()`，避免拆離現有 Activity 的插件連線。通道在第一次實際使用時才註冊，不使原本無 Flutter Binding 的純 Controller 測試失效。

## Android 限制

這個功能可在切換其他 App 後繼續更新，但 **不能保證鎖屏後每 60 秒準點執行**。Doze、廠商省電、網路中斷及系統資源管理仍可能延後或停止工作，前景服務及 WakeLock 也不能繞過所有限制。背景網路與喚醒會增加耗電，使用者可隨時從通知停止。

強制停止 App、系統殺掉整個程序、關機或重開機後不保證繼續；本版使用 `START_NOT_STICKY`，不在背景自行冷啟動引擎。下次開啟會從最後成功保存的檢查點續掃；中斷當下尚未保存的頁面可能重新嘗試。若需要手機關機後仍運作，需另行部署獨立雲端排程。

Android 設定維持 minSdk 21、targetSdk 34、compileSdk 36，加入 `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`WAKE_LOCK` 權限及非匯出的 `dataSync` 服務。通知權限使用既有 `POST_NOTIFICATIONS`。服務不能在畫面不可見時偷偷啟動；開機接收器仍只恢復既有提醒。

官方依據：[FlutterEngine](https://api.flutter.dev/javadoc/io/flutter/embedding/engine/FlutterEngine.html)、[AppLifecycleState](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)、[Android 前景服務啟動](https://developer.android.com/develop/background-work/services/fgs/launch)、[省電模式](https://developer.android.com/training/monitoring-device-state/doze-standby)。若未來升級 targetSdk 到 35 以上，需注意 [Android 15 dataSync 累計時限](https://developer.android.com/develop/background-work/services/fgs/timeout)；目前 compileSdk 36 不會自動把 targetSdk 34 變成 35。

## 完整覆蓋與 CI

最新完整覆蓋包為 `martin_luk_mobile_us_updates_20261016.zip`，解壓後依 `UPDATE_FILES.txt` 原路徑覆蓋 `fix/refresh-live-gate-20261014` 分支。不確定既有檔案是否完整時，使用 `martin_luk_mobile_us_20261016.zip` 合併完整專案。不要只上傳 ZIP，不要多包一層目錄，保留 `.github/`、原生 Kotlin 檔及 drawable 圖示。

主要新增檔案：

```text
lib/services/background_scan_service.dart
android/app/src/main/kotlin/com/martinluk/martin_luk_app/ScanServiceBridge.kt
android/app/src/main/kotlin/com/martinluk/martin_luk_app/ScanForegroundService.kt
android/app/src/main/res/drawable/ic_stat_scan.xml
test/background_scan_uninitialized_test.dart
test/background_scan_service_test.dart
test/background_scan_controller_test.dart
test/background_scan_settings_test.dart
test/background_scan_app_lifecycle_test.dart
```

修改控制器、MainActivity、Manifest、總覽與設定頁，並保留上次名單服務關閉時轉為 `StateError` 的修正。沒有新增第三方 Flutter 背景套件，也不需要部署 Python API。

CI 在原有離線及真實行情門禁前執行：

```bash
flutter test test/background_scan_uninitialized_test.dart test/background_scan_service_test.dart test/background_scan_controller_test.dart test/background_scan_settings_test.dart test/background_scan_app_lifecycle_test.dart test/production_lifecycle_test.dart test/portfolio_controller_test.dart --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded
```

涵蓋權限拒絕與重試、控制等待／晚到回應／dispose、無 Binding 建構、單一擁有者、原本未啟用時暫停、通知操作、設定切換、背景及畫面生命週期。固定 fixture 不是實際行情證據；真實行情／指標門禁仍允許零推薦，通過後才建置 APK，沒有刪除失敗測試或繞過門禁。

本環境沒有 Flutter／Dart／Android SDK，無法宣稱新增測試或原生 APK 已編譯成功。靜態 XML、依賴路徑、工作流與 ZIP 完整性檢查也不能代替手機實測。請以新提交的 Actions 為編譯依據，安裝後依下列步驟驗證。

## 手機驗收

1. 不啟動服務時切背景：更新暫停，回前台可續掃，保留舊行為。
2. 啟動並允許通知後按 Home，等約 1～2 分鐘，查看通知與回到 App 的累積數；再測鎖屏。省電導致延後時，記錄實際狀況，不把它當成已取得新報價。
3. 通知按暫停，在 App 背景時確認不推進；按繼續後推進。返回前台不應再建立第二批掃描。
4. 按停止後通知消失；回到設定顯示未啟動，服務不自行重啟。前台自動更新依其獨立開關運作。
5. 拒絕通知、關閉通知頻道或網路中斷時，應顯示可重試的狀態，不永久轉圈。
6. 活動重建、系統停止／程序結束後再開啟，確認從最後已保存進度恢復；要背景續掃時重新手動啟動服務。
