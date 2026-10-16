# 在 GitHub 雲端產生連網 APK 與 Flutter Web

工作流為 `.github/workflows/build_apk.yml`，推送至 `main`／`master` 自動執行，也支援手動 **Run workflow**。使用 GitHub 的 `ubuntu-latest`、Temurin Java17、Flutter stable 3.29.3，安裝 Android Platform 36、Build Tools 36.0.0 與 NDK 27.0.12077973；專案固定 AGP 8.9.1／Gradle 8.11.1，滿足 `shared_preferences_android` 的 compileSdk 36 要求。後端／HTML、Dart 分析與一般測試通過後，**還必須實際聯網產出至少一檔符合策略的確認推薦**才編譯 APK。APK 與實測證據保留 7 天，Web 保留 14 天。

## 提交專案

請將 **`martin_luk_app` 目錄內的內容**放在 GitHub repository 根目錄，讓 repository 根目錄具有 `pubspec.yaml` 與 `.github/workflows/build_apk.yml`。工作流優先定位根目錄，也能定位 `martin_luk_app/pubspec.yaml`；GitHub 的工作流檔案仍必須位於 repository 根目錄的 `.github/workflows/`。

以新空白 repository 為例，在 App 根目錄執行下列指令；將 URL 換成自己的 repository：

```bash
git init
git add .
git commit -m "Add connected market data and production Android build"
git branch -M main
git remote add origin https://github.com/你的帳號/你的儲存庫.git
git push -u origin main
```

已有 repository 時，依既有分支及 remote 提交。私鑰、`android/key.properties`、本機設定與建置快取已由 `.gitignore` 排除。此交付只新增工作流檔案，尚未替您推送 repository 或觸發遠端建置。

## 一鍵建置與手機安裝

1. 讓工作流檔案位於 repository 預設分支，開啟 GitHub **Actions** 頁面；首次使用依頁面提示啟用 Actions。
2. 左側選 **Build Production APK and Web**，按 **Run workflow**，選擇分支，再按綠色 **Run workflow**。Actions 政策需允許檔案使用的 checkout、setup-java、flutter-action、setup-android 及 upload-artifact 動作。
3. 等待該次 run 完成。若真實行情門禁失敗，下載 `martin-luk-live-scan-evidence` 查看 JSON／日誌；API 限流、逾時、休市或沒有符合策略的股票都會阻止編譯。一般分析／測試失敗也會阻止建置。
4. 只有門禁通過的 run 才會有 **Artifacts → `martin-luk-app-release`**。GitHub 下載的是 ZIP，先解壓縮，取得 `app-release.apk`；7 天內下載。
5. 將 APK 傳到 Android 手機，允許實際用於開啟 APK 的檔案管理器／瀏覽器「安裝未知應用程式」，再點 APK 安裝。也可用 USB：

```bash
adb install -r app-release.apk
```

工作流明確以正式旗標建置：

```bash
flutter build apk --release --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
```

建置之前必須成功執行：

```bash
flutter test test/integration_scan_test.dart --dart-define=RUN_LIVE_SCAN_TEST=true --timeout=60s
```

策略不保證每次有標的，美台正常交易時段也不重疊。建議選其中一個市場正常交易時段執行，失敗時依證據重試；不以示範資料、調低門檻或硬編碼推薦通過。驗證範圍與刷新期限見 [REFRESH_RECOVERY.md](REFRESH_RECOVERY.md)。

新安裝與舊示範設定升級後皆以直連行情為預設，台美股資料在手機端計算 ADR、EMA 與相對強勢，無需輸入後端網址。無網路時僅顯示前次正式行情快取與資料時間，首次尚無快取會顯示重試提示。獨立 HTML 示範檔及 `?preview=mock` 仍是明確選取的離線預覽。

本專案沒有正式 Release Keystore 時使用 Debug Keystore 簽署 **Release 模式** APK，適用側載測試。Android 可安裝 APK 必須有簽名，正式上架需改用自有金鑰，詳見 [BUILD_ANDROID.md](BUILD_ANDROID.md)。若另一台機器先前安裝的 APK 使用不同 Debug 金鑰，可能需解除安裝舊版再安裝。

## 下载正式 Flutter Web 產物

同一 run 也會上傳 `martin-luk-production-web`，以 `USE_MOCK_DATA=false` 編譯，CanvasKit與本地中文字體隨產物打包。下載並解壓後，在包含 `index.html` 的目錄啟動靜態伺服器：

```bash
python3 -m http.server 8080 --bind 127.0.0.1
```

開啟 `http://127.0.0.1:8080/` 為正式連網介面。公開行情端點可能不允許瀏覽器跨來源請求；遇到 CORS 阻擋時，在設定選用已部署、允許此 Web 網域的後端 API。Android 原生 HTTP 連線不受瀏覽器 CORS 規則影響。

`http://127.0.0.1:8080/phone_preview.html` 的390×844包裝框仍明確開啟 `?preview=mock`，可離線檢查完整介面；也可直接開啟 `http://127.0.0.1:8080/?preview=mock`。編譯後的 Flutter Web 請經 HTTP 伺服器載入，不能直接雙擊 `index.html` 以 `file://` 執行。

## GitHub 可用性與驗證範圍

此流程在 GitHub runner 安裝 SDK，可避開本機 Android SDK 下載限制。本機未安裝 Flutter，而且這次實際 Yahoo 探測被沙箱阻擋，沒有成功聯網證據。工作流結構、原始碼與包驗證不能代替實測；Flutter 分析、測試及 APK 的成功狀態以實際 Actions run 為準。沒有成功 run 時，尚不存在可下載的雲端 APK。請於產物期限內下載。
