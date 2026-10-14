# 在 GitHub 雲端產生 APK 與正式 Flutter Web 預覽

工作流為 `.github/workflows/build_apk.yml`，推送至 `main`／`master` 自動執行，也支援手動 **Run workflow**。使用 GitHub 的 `ubuntu-latest`、Temurin Java17、Flutter stable 3.29.3；後端及離線 HTML 檢查通過後，執行 `flutter pub get`、`flutter analyze`、`flutter test` 再編譯 APK。兩種產物均保留14天。

## 提交專案

請將 **`martin_luk_app` 目錄內的內容**放在 GitHub repository 根目錄，讓 repository 根目錄具有 `pubspec.yaml` 與 `.github/workflows/build_apk.yml`。工作流以根目錄執行，將整個 App 再包一層子目錄時需相應修改工作路徑。

以新空白 repository 為例，在 App 根目錄執行下列指令；將 URL 換成自己的 repository：

```bash
git init
git add .
git commit -m "Add Flutter preview and Android cloud build"
git branch -M main
git remote add origin https://github.com/你的帳號/你的儲存庫.git
git push -u origin main
```

已有 repository 時，依既有分支及 remote 提交。私鑰、`android/key.properties`、本機設定與建置快取已由 `.gitignore` 排除。此交付只新增工作流檔案，尚未替您推送 repository 或觸發遠端建置。

## 一鍵建置與手機安裝

1. 讓工作流檔案位於 repository 預設分支，開啟 GitHub **Actions** 頁面；首次使用依頁面提示啟用 Actions。
2. 左側選 **Build APK and Web Preview**，按 **Run workflow**，選擇分支，再按綠色 **Run workflow**。Actions 政策需允許檔案使用的 checkout、setup-java、flutter-action、setup-android 及 upload-artifact 動作。
3. 等待該次 run 完成。若分析或測試失敗，開啟紅色步驟查看錯誤並修正，工作流不會跳過失敗的測試。
4. 開啟 run 的摘要，下方 **Artifacts** 下載 `martin-luk-release-apk`。GitHub 下載的是 ZIP，先解壓縮，取得 `app-release.apk`。
5. 將 APK 傳到 Android 手機，允許實際用於開啟 APK 的檔案管理器／瀏覽器「安裝未知應用程式」，再點 APK 安裝。也可用 USB：

```bash
adb install -r app-release.apk
```

預設以 `USE_MOCK_DATA=true` 建置，可直接離線預覽。本專案沒有正式 Release Keystore 時使用 Debug Keystore 簽署 **Release 模式** APK，適用側載測試。Android 可安裝 APK 必須有簽名，正式上架需改用自有金鑰，詳見 [BUILD_ANDROID.md](BUILD_ANDROID.md)。若另一台機器先前安裝的 APK 使用不同 Debug 金鑰，可能需解除安裝舊版再安裝。

## 下载正式 Flutter Web 產物

同一 run 也會上傳 `martin-luk-flutter-web-preview`，由 `flutter build web` 編譯，CanvasKit與本地中文字體隨產物打包。下載並解壓後，在包含 `index.html` 的目錄啟動靜態伺服器：

```bash
python3 -m http.server 8080 --bind 127.0.0.1
```

開啟 `http://127.0.0.1:8080/phone_preview.html`，即可用390×844框架預覽真正 Flutter Web；直接開啟 `http://127.0.0.1:8080/?preview=mock` 可查看響應式全尺寸介面。編譯後的 Flutter Web 請經 HTTP 伺服器載入，不能直接雙擊 `index.html` 以 `file://` 執行。

## GitHub 可用性與驗證範圍

此流程在 GitHub runner 安裝 SDK，可避開本機 Android SDK 下載限制。本機目前只驗證工作流結構、預覽靜態配置及免SDK預覽；Flutter 分析、測試及 APK 的成功狀態，以實際 Actions run 為準。沒有成功 run 時，尚不存在可下載的雲端 APK。Artifacts 14天後過期；若需要長期保存，請於期限內下載。
