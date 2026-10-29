# Android 建置與簽署

固定 Flutter **3.47.7（stable）**，與 CI 相同。使用 AGP **8.11.1**、Gradle **8.14**、Kotlin **2.2.20**、Java **17**、compileSdk **36**、Build Tools **36.0.0**、targetSdk **34**、minSdk **23（Android 6.0）**，Core Library Desugaring 2.1.4。Wrapper 與來源一起提交，CI 不改寫版本；本機與 CI 都不略過依賴檢查。此次工具升級原因、官方相容依據及仍待新 Actions 的限制見 [ANDROID_TOOLCHAIN_FIX.md](ANDROID_TOOLCHAIN_FIX.md)。

## 準備工具

1. 安裝 Flutter SDK，將 `flutter/bin` 加到 `PATH`。
2. 以 Android Studio／SDK Manager 安裝 Android Platform 36、Build Tools 36.0.0、Command-line Tools；需要時安裝 NDK 27.0.12077973。
3. 設定 Android SDK 路徑，並接受 SDK 授權：

```bash
flutter config --android-sdk /你的/android-sdk
flutter doctor --android-licenses
flutter doctor -v
flutter pub get
```

`android/local.properties` 由 Flutter 依本機產生，不應將其他機器的路徑提交。`gradle-wrapper.jar` 為二進位工具，如專案初次解壓沒有該檔，先執行提供的 Android 準備腳本，從已安装的 Flutter 範本取得，保持自訂 Manifest 與 Gradle 設定。

```bash
python3 scripts/prepare_android.py
```

Windows 可以用 `python scripts/prepare_android.py`。Linux 亦可用 `bash scripts/install_toolchains.sh` 安裝官方 SDK；完成後依脚本提示 `source ../toolchains/activate.sh`。授權由 SDK Manager 顯示供確認；自動化環境可明確設定 `MARTIN_ACCEPT_ANDROID_LICENSES=1`。

## 測試與打包

```bash
dart format lib test
python3 scripts/prepare_android.py
flutter analyze
flutter test
flutter build apk --release --dart-define=USE_MOCK_DATA=false
```

ARM／x86 分 ABI：

```bash
flutter build apk --release --split-per-abi --dart-define=USE_MOCK_DATA=false
```

以上指令預設直接向 Yahoo Finance 取得台美股行情，在手機上計算指標，不需要自架 Python 後端。未指定旗標時 `USE_MOCK_DATA` 也預設為 `false`。無法連線時顯示失敗及重試提示；有上次正式行情快取時顯示其時間與快取狀態，不自動改載假資料。

已部署自己的 Python 後端時，在 App 設定選擇「後端 API」並輸入 HTTPS 網址；可於建置時提供網址初值：

```bash
flutter build apk --release \
  --dart-define=USE_MOCK_DATA=false \
  --dart-define=API_BASE_URL=https://你的掃描服務.example
```

輸出路徑 `build/app/outputs/flutter-apk/`。可安裝合併版：

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## 快速 Debug 簽署

```bash
flutter build apk --debug --dart-define=USE_MOCK_DATA=false
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Flutter／Android 建置工具自動產生並使用 Debug Keystore。可安裝 APK 需要簽署，因此「使用 Debug Keystore」是測試簽署，不是無簽名打包。專案 Release 在沒有 `android/key.properties` 時使用 Debug 簽署，方便側載測試；正式發布需配置自己的 Release Keystore。

需要保留離線展示版本時，明確使用 `--dart-define=USE_MOCK_DATA=true`，或於設定中開啟示範模式。GitHub 工作流不使用此旗標。目前版本代碼為 `1.6.1+14`，以相同金鑰簽署時可更新先前 APK；舊示範偏好會遷移到正式直連模式，帳戶本金與自行新增的持股保留。

## 正式 Release Keystore

在本機產生金鑰，密碼由 keytool 互動輸入，避免命令歷史保存：

```bash
keytool -genkeypair -v -keystore martin-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias martin-release
```

於 `android/key.properties` 填入本機簽署資訊：

```properties
storeFile=/本機路徑/martin-release.jks
storePassword=你的金鑰庫密碼
keyAlias=martin-release
keyPassword=你的金鑰密碼
```

該檔與私鑰已列入 `.gitignore`，不可與公開原始碼一起分享。Android 的同一 applicationId 更新需使用同一簽署金鑰；若簽章不符，先保留舊 App 與資料，使用原金鑰建置；不要直接解除安裝造成資料遺失。

## 網路與通知配置

- 主 Manifest 包含 `INTERNET`、`ACCESS_NETWORK_STATE`、`POST_NOTIFICATIONS` 與開機恢復排程權限／通知接收器。
- 依本次需求設定 `android:usesCleartextTraffic="true"`，允許自訂 HTTP 中繼；內建 Yahoo Finance 來源使用 HTTPS。
- 本機提醒使用 `inexactAllowWhileIdle`，不要求精確鬧鐘特殊權限。
- `ic_stat_momentum` 為通知圖示；本版本關閉 Release 資源縮減，保留通知所需圖示。

工具完整且已接受授權時，上述 Flutter 指令即可建立 APK。建置結果以 [BUILD_STATUS.md](BUILD_STATUS.md) 中的實際紀錄為準。
