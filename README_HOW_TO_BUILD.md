# 下載、離線預覽與 GitHub 雲端 APK 建置

這份 ZIP 同時包含 **可直接開啟的 HTML 手機互動預覽** 與 **完整 Flutter／FastAPI 原始碼及 GitHub Actions 工作流**。HTML 預覽不需 SDK、Python、後端或網路；它是獨立的介面與策略運算示範，不是編譯後的 Flutter。ZIP 目前不包含已編譯 APK；APK 由以下雲端工作流產生。

2026-10-15 起，現行門禁改為驗證真實行情與計算正確，允許推薦清單為空；本規則取代先前「至少一檔推薦才建置」。ADR、突破、資料新鮮度、停損與風控條件維持原設定，不以觀察股或假資料補足推薦。

## 1. 從目前聊天介面下載 ZIP

1. 儲存助理回覆附上的完整覆蓋包；若介面提供附件下載，直接下載該附件。不能下載時，可複製交付的完整原始碼，或依下方 Base64 匯出方式還原。
2. 將內容合併至既有專案，例如 `C:\Users\a1258\projects\martin_luk_trading_app`，覆蓋同名檔案。ZIP 內直接是專案檔案，不需重新建立骨架。
3. 雙擊 `run_preview.bat`，或用 Chrome／Edge／Safari 開啟 `preview/standalone_preview.html`；見 `WINDOWS_UPDATE_GUIDE.md`。

無法下載時，可直接複製 `standalone_preview.html` 的完整內容存成同名檔案；此入口固定離線、不含任何 API 呼叫。完整原始碼 ZIP 另有 Base64 終端匯出／還原方式，詳見 [TERMINAL_EXPORT_GUIDE.md](TERMINAL_EXPORT_GUIDE.md)。

交付檔案的精確位置為 `/workspace/martin_luk_trading_app.zip`；這是供聊天介面下載的工作區檔案路徑，不是在自己電腦瀏覽器輸入的網址。若介面提供工作區檔案面板，也可找到同名檔案下載。

## 2. 零安裝離線手機預覽

`preview/index.html` 已內嵌樣式、JavaScript、Mock 資料與風控計算器；它不會要求連接 `127.0.0.1`。頁面開啟後，點上方「重設為離線示範」，即可清除瀏覽器先前保存的 API 模式設定並載入假資料。

可操作功能包含台股／美股切換、ADR 門檻、RS／ADR／部位排序、分頁、深色模式、個股詳情，以及輸入帳戶淨值後即時更新的 0.5% 風險股數與 3R／5R／10R 目標。台股 ADR 預設 3.5%，美股 5%；大型流動性股曝險上限 35%，其餘 25%。推薦明確標示 PDH／ORH 觸發價與初始停損：實際突破日低點的風險距離不超過 5% 時可使用；超過 5% 時，必須有實際 1／5 分鐘進場棒低點且距離在 1.5%～3%，否則維持觀察狀態。

新增「我的持股」分頁，可新增、編輯、刪除台股／美股持股；資料在可用時保存至 localStorage。每筆顯示成本、初始停損、目前追蹤停損、現價損益／R 倍數、帳戶曝險及具體目標價。離線模式可調整現價、已完成收盤價及 EMA，立即比較「持有」、「分批減碼」及「全數出場」建議。完整示例見 [PORTFOLIO_GUIDE.md](PORTFOLIO_GUIDE.md)：例如成本 100、初始停損 98 時，106 為 3R；已觀察達到 2R 之後，保本停損將上移至 100。

Mock 測試與每個 API 網址各自保留最高 R／保本停損，離線測價不會影響真實行情的出場條件。改變成本或初始停損等計算基礎會清除觀察歷史；本機儲存失敗時，頁面會提示資料可能無法在重新開啟後保留。

手機請先完整解壓 ZIP，再以支援本機 HTML 與 JavaScript 的**瀏覽器**開啟檔案。部分檔案管理器、郵件附件預覽及 iOS Quick Look 只顯示靜態內容，不執行 JavaScript；這種情況需要改用可開啟本機 HTML 的瀏覽器，或在電腦的 Chrome／Edge／Safari 預覽。網頁不能繞過作業系統對本機檔案的開啟限制。

所有示例行情、ADR、RS 與訊號都是固定假資料，不代表即時報價或全市場掃描。HTML 沒有 Android 背景通知功能；正式 Flutter App 與 Python 掃描後端在下方原始碼中。

## 3. 專案包含的兩組成品

```text
preview/index.html                 免環境、單檔離線互動預覽
standalone_preview.html             固定離線，完全不含網路呼叫的可複製版本
lib/                               Flutter 前端與 Dart 策略引擎
android/                           Android／Gradle／Manifest 配置
web/                               正式 Flutter Web 入口及手機框架
backend/                           FastAPI、股票池、快取、掃描、排程
backend/engine/exit_engine.py       強勢減碼、保本與 EMA 出場診斷
backend/engine/portfolio_tracker.py 持股資料與 JSON 保存
test/                              Dart 單元與 Widget 測試
.github/workflows/build_apk.yml     GitHub 真實行情／計算門禁與 APK 建置
scripts/validate_live_scan_evidence.py schema 2 實測報告驗證器
scripts/package_trading_app.sh     一鍵驗證、打包、大小與 SHA256
scripts/verify_deliverable.py      交付檔案完整性驗證
scripts/export_upload.sh           ZIP、SHA256、Base64 終端匯出
scripts/recover_upload.py          本機還原 Base64 並檢查 ZIP
README_HOW_TO_BUILD.md              本操作指南
PORTFOLIO_GUIDE.md                  持股操作、買賣點與出場規則
```

`backend/README.md` 包含資料來源、REST 合約、排程、風險政策及限制。正式 Flutter Web 與 HTML 模擬預覽是兩個不同入口；詳見 `WEB_PREVIEW.md` 與 `preview/README.md`。

## 4. 不用本機 Android SDK，在 GitHub 產出 APK

1. 建立 GitHub repository。將**解壓後的專案內容**放在 repository 根目錄：根目錄應直接有 `pubspec.yaml`、`lib/`、`android/` 與 `.github/`。不要只上傳 ZIP，也不要多套一層專案資料夾。
2. 確認隱藏目錄 `.github` 一起提交。提交至 `main`、`master` 或 `fix/refresh-live-gate-20261014` 時自動執行建置。
3. 若要重新建置，可開啟 **Actions → Build Android APK with Verification Gate → Run workflow**，選分支後再次按 **Run workflow**；手動入口要求工作流先存在於預設分支。若 Actions 被 repository 或組織政策停用，先在 GitHub 設定允許工作流執行。
4. 等待 `verify-and-build` 完成。工作流使用 Java 17 與 Flutter stable，先執行 Python 報告驗證器測試及 Flutter RS／策略／風控單元測試，再以 `RUN_LIVE_SCAN_TEST=true`、`USE_MOCK_DATA=false` 實際連網驗證：15 秒工作期限內取得兩指數與 NVDA、AAPL、TSLA、2330.TW、2603.TW，獨立驗算 ADR、EMA 與 RS。`scripts/validate_live_scan_evidence.py` 驗證 schema 2 報告通過後才建置 APK。推薦 `[]`、休市或當下沒有買點不會單獨阻止建置；必要行情取得、解析、指標不符或逾時仍會阻止，詳見 `REFRESH_RECOVERY.md`。
5. 通過門禁後在 **Artifacts** 點 `martin-luk-app-release` 下載，解壓取得 `app-release.apk`；保留 **7 天**。`martin-luk-live-scan-evidence` 保存 `test_logs/verification.log`，成功或失敗都保留 7 天；實測 JSON 亦會寫入日誌供診斷。
6. 把 APK 傳到 Android 手機，點擊安裝；依手機提示允許該檔案管理器或瀏覽器「安裝未知應用程式」。這是 Android APK，不能安裝到 iPhone。

沒有設定正式簽署金鑰時，專案使用 Debug Keystore 簽署 Release APK 供側載測試。Android APK 必須簽署，此方式不是無簽名 APK。公開發布或穩定更新版本前，請依 `BUILD_ANDROID.md` 設定自己的簽署金鑰；不要把私鑰或密碼提交到 GitHub。

這份交付沒有在 GitHub 上代為觸發建置。工作流的分析、測試及編譯結果，以實際 Actions 執行紀錄為準；本機未具備完整 Flutter／Android SDK，不能把配置檢查視為已編譯成功。

現行 APK 工作流只上傳實測紀錄與 APK，不產出 Flutter Web artifact。若自行執行 `flutter build web`，真正編譯後的 Flutter Web 仍需透過 HTTP 提供檔案，不能當成單檔 HTML 直接雙擊；有 Python 的電腦可在 `build/web` 目錄執行：

```bash
python3 -m http.server 8080 --bind 127.0.0.1
```

再於同一台電腦開啟 `http://127.0.0.1:8080/phone_preview.html`。此選用步驟不是第 2 節離線 HTML 預覽的必要條件。

## 5. 選用：啟動 Python 後端

在專案根目錄、Python 3.11／3.12 環境執行：

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r backend/requirements.txt
python -m uvicorn backend.api:app --host 0.0.0.0 --port 8000
```

Windows 的環境啟用指令是 `.venv\Scripts\activate`。API 文件位於同機 `http://127.0.0.1:8000/docs`，離線格式示範可呼叫 `/v1/candidates?market=tw&demo=true`。持股行情與分析使用 `/v1/quotes` 及 `/v1/portfolio/analyze`；行情以來源時間區分盤中價格與已完成收盤，不假設 Yahoo 為逐筆即時報價。實際行情掃描需要網路；首次全股票池掃描可能較久。手機的 `127.0.0.1` 指向手機自己，連接電腦後端需使用可達的電腦 IP／轉送網址；Release App 的後端應使用 HTTPS。完整部署與排程步驟請見 `backend/README.md`。

## 6. 一鍵重新驗證與打包

此步驟需要 Bash、Python 3 與 `zip`，只用於重新製作交付 ZIP；一般使用者直接下載並開啟 HTML 即可。

```bash
cd /workspace/martin_luk_app
bash scripts/package_trading_app.sh
```

腳本先驗證必要檔案並產生 `FILE_MANIFEST.json`，再從專案根目錄執行 `zip -r`，產生 `/workspace/martin_luk_trading_app.zip` 與相鄰的 `.zip.sha256` 驗證檔，最後檢查 ZIP 內容、CRC 與來源一致性，並輸出檔案大小及 SHA256。包內保留 `.github`，排除 `.git/`、`build/`、`.dart_tool/`、虛擬環境、資料快取、`__pycache__/` 及私密簽署設定等非交付項目。

單獨執行完整性檢查：

```bash
python3 scripts/verify_deliverable.py
python3 scripts/verify_deliverable.py --archive /workspace/martin_luk_trading_app.zip
```

也可手動查看大小與雜湊：

```bash
ls -lh /workspace/martin_luk_trading_app.zip
sha256sum /workspace/martin_luk_trading_app.zip
```

下載後可與助理回覆或 `.sha256` 的值比對。Windows PowerShell 使用 `Get-FileHash .\martin_luk_trading_app.zip -Algorithm SHA256`；macOS 使用 `shasum -a 256 martin_luk_trading_app.zip`。
