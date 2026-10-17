# 1.6.1+14：長時間輪掃快取與無法啟動修正

本次處理「使用兩天後卡死、無法開啟」。程式中確實存在行情快取無界累積及大量重複存檔；沒有手機 crash／ANR 紀錄，尚不能斷言此次一定是 OOM，也尚未完成兩天實機穩定性驗證。

## 先保留手機資料

1. 到 Android「設定 → 應用程式 → Martin Luk 動能觀察 → 強制停止」。**不要解除安裝、不要按清除資料或清除儲存空間**，這會丟失持股及設定。
2. 在 GitHub 的 `fix/refresh-live-gate-20261014` 分支完整覆蓋更新包內的檔案，提交新 commit。版本應為 `1.6.1+14`，不能只重跑舊提交。
3. 等 Actions 的測試、真實行情門禁、Release 建置與原生 XML 測試均成功，下載 `martin-luk-app-release`，解壓後覆蓋安裝 APK。必須使用與已安裝版本相同的簽章；若顯示簽章不符，先保留舊 App，不能用解除安裝當作修復。
4. 第一次開啟會先顯示原生「正在整理舊行情快取」畫面。請保留足夠手機儲存空間並稍候；整理在工作執行緒執行，完成後才建立 Flutter 引擎。
5. 開啟後核對持股、台美股獨立本金與已保存輪掃進度，再開始更新。舊的原始 Yahoo 行情需要重新抓取，不能把這次清理時間當成行情時間。

如果整理失敗，畫面提供「重試安全整理」，不會自動開啟 Flutter 讀入舊巨量行情，也不會直接清空偏好設定。如果新版仍無法開啟，需提供卡在哪個畫面及 Android crash／ANR 紀錄；不應再次盲目清除資料。

## 實際修正

- 舊行情磁碟快取沒有總筆數限制。5118 檔美股與台股完整輪掃逐漸保存數千份原始圖表 JSON；原生 SharedPreferences 啟動會整批載入。
- 舊 `_readCache` 的離線回填沒有 RAM 上限，舊儲存只移除一筆，也無法將已超量的記憶體降回限制。
- 新版 RAM 與磁碟行情各限制 **96 筆、8 MiB 編碼內容**，單筆上限 **512 KiB**、保留 **7 日**，讀寫共用 LRU。這是編碼內容預算，並非精確的 VM heap 上限。超大的有效即時回應仍可運算，但不寫入行情快取。
- 磁碟只在首次建立索引時稽核既有行情，後續使用共享增量索引，不在每筆成功報價時重解碼所有 K 線。存檔待處理上限 8；平台寫入逾時後隔離該寫入器，行情成功不依賴快取必須成功。已發送的原生寫入無法由 Dart 強制取消，但不再持續排入後續寫入。
- 關閉 API 時釋放 RAM，晚到 HTTP／初始化結果不能回填快取或改寫狀態。
- 30 檔正常掃描頁的完整進度日誌寫入由 **13 次降為 7 次**；相同 ADR 門檻不重寫，重複存檔共用已驗證的不可變檢查點。超過 256 KiB 的還原驗證使用 `compute`，在 Android 背景 isolate 執行。
- 中斷／關閉時保留已完成的批次進度；中斷當下尚未完整提交的一批最多 5 檔可能重掃，不會跳過未嘗試股票。

原生升級整理只移除 SharedPreferences 最上層 key 以 `flutter.market-data-yahoo-v1:` 或 `market-data-yahoo-v1:` 開頭的可重建行情。持股、成本與停損、本金、設定、輪掃檢查點及其他未知 key 均保留。沒有 `clear()`，不呼叫 SharedPreferences 整批讀入後再清除。

XML 使用串流轉寫與 AtomicFile；完成寫入後驗證大小及 SHA256，成功才寫入不可備份的完成標記。解析或提交前錯誤會走 AtomicFile 復原；不能保證手機儲存硬體故障或提交後錯誤仍可恢復原始位元組。原生測試驗證保留欄位的值與型別，而非僅驗證 key 存在。

歷史桌面元件 `.MainActivity` 保留為 launcher alias，經 `CacheRecoveryActivity → FlutterHostActivity` 開啟主畫面；通知也經過復原入口。整理在使用者切到背景後完成時，不會擅自開啟 Flutter；返回前台才開啟。

## 保留的功能

美股及台股仍使用實際取得完整名單、每頁最多 30／每批最多 5 的續掃。沒有退回固定核心 30 檔，無須為此修正部署 Python API。0.5% 單筆風險、實際低點停損、部位上限、原始行情時間與資料新鮮度規則不變；持股及雙市場本金不重設。

## 驗證與限制

新增 `test/market_data_cache_bounds_test.dart` 十項：150 檔循環、離線大量回填、容量與 LRU、精確命名空間、共享索引、關閉後晚到結果及掛起平台寫入。

新增 `test/mobile_scan_storage_budget_test.dart` 三項：5118 檔檢查點保存次數、第二批中斷續掃，以及相同計數下更新真實停損仍會存檔。

新增 `android/app/src/test/kotlin/com/martinluk/martin_luk_app/LegacyQuoteCacheXmlTest.kt` 四項：保留值與型別／未知欄位、2 MiB 行情捨棄、壞 XML 拒絕，以及重複執行保留資料。

Actions 先跑固定測試與真實行情／ADR／EMA／RS 門禁（仍允許零推薦），再建置 Release APK，最後跑 `:app:testReleaseUnitTest`。原生測試通過才上傳 APK，測試紀錄不論成敗均保存。原生測試放在建置之後，讓 Flutter 先準備本專案所需的 Gradle Wrapper。

```bash
flutter test test/market_data_cache_bounds_test.dart test/mobile_scan_storage_budget_test.dart test/market_data_api_test.dart test/market_transport_regression_test.dart test/refresh_recovery_test.dart --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded
flutter build apk --release --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
cd android
bash ./gradlew :app:testReleaseUnitTest --no-daemon --console=plain
```

已讀取遠端基線 commit `0c25530e886bd4c6bd6ed284232e6a672df10f21`、Actions run `38910623652`：舊版 1.6.0+13 的測試、真實行情門禁及 APK 成功。**這不代表本次 1.6.1 已通過。** 本環境缺少 Flutter／Dart／Android／Kotlin SDK，實際嘗試上述 Flutter 測試得到 `flutter: command not found`、退出碼 127。本機通過 25 項 Python 腳本測試、YAML／15 段 Bash 語法、CI 63 檔預檢及專案 Dart import 路徑檢查；另核對 21 個策略、持股與行情門禁等受保護檔案與成功基線一致。這些不能代替新增 Dart／Kotlin 測試或實機驗證，新版結果以新 commit 的 Actions 與覆蓋安裝驗收為準。

更新包是完整可覆蓋原始碼，不包含已編譯 APK：`martin_luk_long_run_recovery_updates_20261016.zip`；完整專案為 `martin_luk_long_run_recovery_20261016.zip`。請一併更新 Kotlin、Manifest、Gradle、Dart、測試及 workflow，不能只更新行情 API。
