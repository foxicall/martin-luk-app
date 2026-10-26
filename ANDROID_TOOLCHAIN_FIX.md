# 1.6.1+14：Android 工具版本一致性修正

2026-10-17（台北時間）。本次修正 Android／CI 配置，App 版本維持 `1.6.1+14`，交易策略與行情程式不變。

## 這次並非 APK 編譯步驟失敗

已讀取 commit `8e18bc91838eb799329006a0230d83a36447a4dc`，Actions run `39011383757`／job `117334467798` 完整日誌：

- 所有固定 Dart 測試通過，上一輪行情快取群組共 77 項也通過。
- 真實 TW／US 行情、ADR／EMA／RS 門禁通過，推薦 0 檔，符合允許零推薦的規則。
- 美股名單實測取得 5120 檔可確認普通股，來源缺漏／保守排除提示保留；並非全市場分類認證。
- Release APK 已編譯成功，日誌顯示 61.4 MB。
- 接著直接執行 `gradlew :app:testReleaseUnitTest` 時，Flutter 重新檢查版本，因 AGP 8.9.1 低於 8.11.1 而在設定階段失敗。原生 XML 測試尚未開始，APK 上傳也被正確阻擋。

先前 `flutter build` 使用的 `--android-skip-build-dependency-validation` 只對那次 Gradle 呼叫生效，不能讓下一個獨立 Gradle 指令自動略過檢查。只把同一略過參數塞到原生測試不能解決相容問題。

## 本次對齊版本

| 項目 | 本次配置 |
|---|---|
| Flutter | 3.47.7、stable channel，固定為上述 CI 實際使用版本 |
| Java | Temurin 17 |
| Android Gradle Plugin | 8.11.1 |
| Gradle Wrapper | 8.14 |
| Kotlin Gradle Plugin | 2.2.20 |
| compileSdk／targetSdk | 36／34，維持原設定 |
| minSdk | **23（Android 6.0 以上）** |

已核對 [Flutter 3.47.7 的依賴檢查原始碼](https://github.com/flutter/flutter/blob/3.47.7/packages/flutter_tools/gradle/src/main/kotlin/DependencyVersionChecker.kt)。只升 AGP 還會遇到舊 Kotlin 2.0.21 的最低版本檢查；只移除略過參數又不調整 minSdk 21，組裝 APK 時仍會失敗。

此組合也符合 [AGP 8.11 的相容要求](https://developer.android.com/build/releases/agp-8-11-0-release-notes)及 [Kotlin Gradle 相容表](https://kotlinlang.org/docs/gradle-configure-project.html)。未來棄用警告可能仍出現，與本次硬性最低版本錯誤不同；本次不升級至 Gradle 9／AGP 9。

**最低支援版本由 Android 5.x 提高至 Android 6.0。** 這是固定使用的 Flutter 版本要求；Android 5.x 不再可安裝本版。較新 Android 手機的持股、設定及輪掃格式不變。

## 必須一併覆蓋的核心檔案

```text
android/settings.gradle
android/gradle/wrapper/gradle-wrapper.properties
android/app/build.gradle
.github/workflows/build_apk.yml
```

`scripts/verify_deliverable.py` 同步檢查上述版本與 minSdk，`scripts/prepare_android.py` 只更新缺少 SDK 時的版本提示。CI 不再臨時用 sed 改寫 Wrapper，而是驗證已提交的 8.14；Flutter 固定 3.47.7，避免 stable 浮動再改變門檻。APK 與原生測試都不使用略過版本檢查。

所有原有測試、真實行情門禁、原生 XML 保留資料測試及兩項產物上傳保留。只有原生測試成功後才上傳 APK，日誌不論成敗均上傳。沒有加入 `setup-android`、`sdkmanager` 或舊 Python 補丁依賴。

## GitHub 覆蓋與驗證

下載 `martin_luk_android_toolchain_fix_updates_20261017.zip`，依 `UPDATE_FILES.txt` 將完整檔案覆蓋到 `fix/refresh-live-gate-20261014` 分支。特別注意隱藏 `.github` 路徑；不是只改錯誤訊息指向的 `android/app/build.gradle` 第 5 行。

提交新 commit，再看 Actions。不能重跑舊 commit 期待載入新版配置。新工作流應走完版本檢查、全部測試、真實行情、APK 建置及原生測試，才下載 `martin-luk-app-release`。原生測試若仍失敗，保留完整例外；不能刪除該步或先上傳 APK。

```bash
flutter --version
flutter pub get
python3 scripts/prepare_android.py
flutter build apk --release --dart-define=USE_MOCK_DATA=false
cd android
bash ./gradlew :app:testReleaseUnitTest --no-daemon --console=plain
```

本機已通過 25 項 Python 腳本測試、YAML／15 段 Bash 語法與實際 CI 63 檔預檢；核對 140 個 Dart／測試／後端／資料與門禁檔案、18 個 Android 原生來源及資源和上述 commit 相同。實際嘗試新的 Flutter 建置命令退出 127（command not found）。此環境仍缺 Flutter／Android SDK，新配置尚未本機編譯或實機驗證；前述成功日誌屬更新前 commit，不能當作本次版本配置已通過的證據。新結果以本次提交的 Actions 為準。

本次未改 applicationId 或簽署規則。覆蓋安裝仍必須使用與舊 App 相同的金鑰；CI 預設 Debug Keystore 不保證跨次執行相同。若手機顯示簽章不符，保留舊 App，不要解除安裝或清除資料。長時間卡死的原有修正及第一次啟動整理見 [LONG_RUN_RECOVERY.md](LONG_RUN_RECOVERY.md)。

更新包與完整包 `martin_luk_android_toolchain_fix_20261017.zip` 均存於指定 Google Drive `Martin_Luk_App` 資料夾。
