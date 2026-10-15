# 完整覆蓋包、GitHub Actions 與 Android APK

本版交付完整 Flutter／FastAPI 專案，股票池改為台灣上市＋上櫃及 NYSE／Nasdaq／NYSE American 可確認普通股。後端採每頁 60 檔背景輪掃；既有 App 與既有 Render 服務都需要更新。範圍及限制見 [ALL_STOCKS_UPDATE.md](ALL_STOCKS_UPDATE.md)。本包沒有已在本環境成功編譯的 APK，也沒有代為部署的上線網址。

## 1. 解壓並覆蓋

下載 `martin_luk_all_stocks_20261015.zip`，完整解壓，再將包內專案內容合併至現有根目錄，例如 `C:\Users\a1258\projects\martin_luk_trading_app`。ZIP 是原始碼覆蓋包，不是 Android 安裝檔；不要改副檔名為 `.apk`。

根目錄應直接看到 `pubspec.yaml`、`lib/`、`backend/`、`android/`、`Dockerfile`、`render.yaml` 與隱藏 `.github/`。請保留自己的私密簽署設定，勿上傳 keystore、金鑰密碼或 `.env`。本次不要只複製某一段 Dart 或 Python：搜尋資產、代碼驗證、輪掃 DTO、UI 與後端合約必須一起更新。

## 2. 用 GitHub 網頁更新既有分支

不需要在受限制的本機終端機執行 Git。於 GitHub 開啟 repository，切換至 `fix/refresh-live-gate-20261014`，選 **Add file → Upload files**，把解壓後的專案內容上傳至原專案根目錄並提交。不要只上傳 ZIP，不要多包一層目錄；完整操作見 [GITHUB_MANUAL_UPDATE.md](GITHUB_MANUAL_UPDATE.md)。

確認 `.github/workflows/build_apk.yml` 仍存在。Windows 檔案選擇器若不顯示 `.github`，先啟用顯示隱藏項目，或直接在 GitHub 檢查原路徑並逐檔更新。既有 workflow 的目錄位置不能刪除。

## 3. 用 Actions 建置 APK

1. 提交至 `main`、`master` 或 `fix/refresh-live-gate-20261014`，會觸發 **Build Android APK with Verification Gate**。
2. 也可在 **Actions → 該工作流 → Run workflow** 手動選分支。GitHub 要求手動入口的 workflow 已存在於預設分支；看不到按鈕時，先確認預設分支及 repository 的 Actions 權限。
3. 工作流安裝 Java 17／Flutter stable，驗證 Python 後端、報告驗證器、Dart 策略／輪掃合約與指定真實 HTTP 行情計算，再編譯 Release APK。
4. 現行門禁要求必要真實行情與 ADR／EMA／RS 計算正確；`candidates: []` 可以通過。HTTP、解析、必要資料缺漏、錯誤數學或逾時仍會阻擋建置。它不是全市場所有股票均可下載的認證。
5. 成功後下載 `martin-luk-app-release` artifact，解壓取得 `app-release.apk`，保留 7 天。`martin-luk-live-scan-evidence` 保存驗證日誌，不論成功或失敗都可供診斷。

Android 手機開啟 APK 後，依系統提示允許目前的檔案管理器／瀏覽器安裝未知應用程式。APK 不能安裝到 iPhone。若出現簽章不一致，必須使用與舊版相同的簽署金鑰建置，或先自行備份庫存再移除舊版；解除安裝可能刪除本機資料。

未提供正式 keystore 時，專案可用 Debug Keystore 簽署 Release APK 供側載測試。Android APK 必須簽署，這不是「無簽名 APK」。正式發佈與持續更新請設定自己的固定簽署金鑰，詳見 [BUILD_ANDROID.md](BUILD_ANDROID.md)。

## 4. 本機 Flutter 建置

需 Flutter／Dart、JDK 17 及相容 Android SDK。Android 專案使用 minSdk 21、targetSdk 34、compileSdk 36；Gradle／AGP 的實際版本以專案及 workflow 為準。

```bash
flutter doctor -v
flutter pub get
python3 scripts/prepare_android.py
flutter analyze
flutter test
flutter build apk --release --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
flutter build apk --release --split-per-abi --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
```

輸出位於 `build/app/outputs/flutter-apk/`。除錯測試可執行：

```bash
flutter build apk --debug --dart-define=USE_MOCK_DATA=true
```

Debug APK 會由 Android 工具使用 Debug Keystore 簽署。`USE_MOCK_DATA=true` 僅用於明確離線示範，不能拿來通過真實行情門禁。

## 5. 更新 Render，並安裝新 APK

只重建 APK 不會更新雲端 Python。Render 服務必須部署同一分支的新版 `backend/`、`Dockerfile` 與 `render.yaml`，並確認舊服務 Environment 已改為：

```text
MARTIN_SCAN_POOL_LIMIT=0
MARTIN_SCAN_PAGE_SIZE=60
MARTIN_SCAN_PAGE_INTERVAL=60
MARTIN_SCAN_BATCH_SIZE=3
MARTIN_SCAN_BATCH_DELAY=0.15
MARTIN_PROVIDER_TIMEOUT=8
MARTIN_RESPONSE_TTL=300
```

舊服務若仍存 `MARTIN_SCAN_POOL_LIMIT=30`，會繼續限制選定池；單純覆蓋 `render.yaml` 不保證平台已更新保存的值。用 **Manual Deploy → Deploy latest commit** 部署新後端；新程式自動隔離舊範圍快取。完整流程見 [CLOUD_API_GUIDE.md](CLOUD_API_GUIDE.md)。

安裝新 APK 後，設定中關閉 Mock，選 **Python API・自訂中繼**，填入 Render 實際提供的 HTTPS 根網址。不要附加 `/v1`、`/health`；行動網路 5G 不能直接連一般 `192.168.x.x`、`localhost` 或 `10.0.2.2`。

背景工作回 `202` 時，下拉動作會結束，UI 每約 3 秒查詢進度。當頁完成後，前景 60 秒一般更新或手動強制更新推進下一頁；不會讓單次 HTTP 等待完整市場。App 不在前景時，不會自動持續輪掃全部股票。

## 6. 離線預覽與搜尋

`preview/standalone_preview.html`／`standalone_preview.html` 是可獨立開啟的 HTML 示範，不是編譯後 Flutter。Windows 可雙擊 `run_preview.bat`。需要會執行 JavaScript 的瀏覽器，郵件附件預覽／Quick Look 可能只顯示靜態內容。

預覽支援市場切換、搜尋、本金、風控與庫存互動；價格、指標及訊號為明確示範。搜尋元資料與完整字典來源見 [SEARCH_GUIDE.md](SEARCH_GUIDE.md)，字典筆數與擷取日期以 `stocks_master_sources.json` 為準，不把打包時間當成行情更新時間。

本次沒有代為觸發 Actions、部署 Render 或產生正式 APK；實際可用性以新的 Actions 執行紀錄與服務回應為準。驗證狀態見 [BUILD_STATUS.md](BUILD_STATUS.md)。
