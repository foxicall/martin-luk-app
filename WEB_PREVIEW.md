# Flutter Web 與手機預覽

`web/` 已提供 Flutter Web 入口、現代 `flutter_bootstrap.js`、manifest、本機 SVG 圖示與 390 × 844 手機包裝頁。預覽 App 不需要 Android SDK。實際 Flutter Web 仍需要既有 Flutter SDK；目前工作環境沒有 Flutter，所以本次只能在此執行靜態配置檢查，不能宣稱已編譯或啟動 Flutter UI。

## 不安裝 SDK 的立即預覽

遠端環境以以下指令監聽所有介面：

```bash
bash scripts/preview_web.sh --mock --host 0.0.0.0 --port 8080
```

在同機瀏覽器使用 `http://127.0.0.1:8080/`；遠端瀏覽器使用平台提供的8080埠轉送URL。若啟動出現 `Operation not permitted`，需處理平台的監聽權限。完整診斷見 [PREVIEW_CONNECTION.md](PREVIEW_CONNECTION.md)。

`preview/index.html` 是獨立 HTML 示範介面，提供市場切換、排序、設定及風控計算。它用於此環境立即檢視互動，不是 Flutter 編譯產物，也不能代替 `flutter analyze`、`flutter test` 或真機驗證。啟動方式及離線限制請見 `preview/README.md`。

## 檢查已提交的 Flutter Web 配置

```bash
cd /workspace/martin_luk_app
python3 scripts/check_web.py
python3 scripts/check_web.py --json
ls web/index.html web/flutter_bootstrap.js web/manifest.json web/phone_preview.html
```

此檢查使用 Python 標準函式庫，驗證 viewport、bootstrap 替換標記、manifest 和本機圖示，不安裝 SDK、不連線。

## 390 × 844 的完整 Flutter 預覽

在已安裝 Flutter 3.29.3 或更新穩定版的電腦中執行：

```bash
cd /path/to/martin_luk_app
flutter --version
flutter config --enable-web
flutter devices
bash scripts/preview_web.sh --build --port 8080
```

腳本預設綁定0.0.0.0。在同機瀏覽 `http://127.0.0.1:8080/phone_preview.html`；遠端使用平台8080轉送URL加上 `/phone_preview.html`。桌面 iframe 的 CSS viewport 固定為 390 × 844；螢幕寬度 ≤ 450px 時填滿螢幕。包裝頁內載入的是實際 Flutter Web 編譯產物。請以 Ctrl+C 停止伺服器。

包裝頁使用 `index.html?preview=mock`，可在這次預覽工作階段蓋過曾儲存的 API 模式。使用者仍可於設定頁明確切換至 API。初始 Mock 模式會使用前端資料，無需 Python 後端；Mock 資料是示範，不是即時行情或最新完整成分股。API 模式發生錯誤會顯示錯誤，不會把示範資料偽裝為即時結果。

腳本執行的關鍵指令如下：

```bash
flutter pub get
flutter build web --release --no-web-resources-cdn --pwa-strategy=none \
  --dart-define=USE_MOCK_DATA=true
python3 scripts/preview_server.py --host 0.0.0.0 --port 8080 --mode flutter --directory build/web
```

CanvasKit 與 `MartinPreviewSans` 中文字體由同一個本機伺服器供應；字體子集覆蓋前端文字與全部 Mock 股票名稱，離線示範不需後端或遠端中文字體。超出子集的新 API 名稱仍可能需要擴充字體。此配置沒有註冊 Service Worker，所以不能把網頁關閉後再次斷網開啟視為支援 PWA 離線快取。首次 `flutter pub get` 與 Flutter Web engine 準備也可能需要網路，SDK/相依套件已快取後才能避免下載。

## 開發模式與 Chrome

```bash
# 不需本機 Chrome，自行在瀏覽器開啟 http://127.0.0.1:8080/?preview=mock
bash scripts/preview_web.sh --dev --port 8080

# 有 Chrome 的電腦可由 Flutter 啟動瀏覽器
bash scripts/preview_web.sh --chrome --port 8080

# 等價的開發啟動指令
flutter run -d chrome --web-hostname 0.0.0.0 --web-port 8080 --dart-define=USE_MOCK_DATA=true \
  --web-browser-flag=--window-size=430,940
```

Chrome 外視窗大小包含工具列，`--window-size` 不等於 App viewport。使用 DevTools → Toggle device toolbar → Responsive，輸入 Width `390`、Height `844`。固定尺寸包裝頁請使用前述 `--build` 模式，避免依賴 Flutter 開發伺服器對額外 HTML 的路由行為。

Flutter 3.29 起已移除 `--web-renderer` 選項；不要使用舊版 `--web-renderer canvaskit` 指令。一般 Web build 預設使用 CanvasKit。若使用較舊版本，先確認 `flutter run --help`，本專案 Dart SDK 最低需求是 3.7。

## 互動驗證

1. 在美股與台股標籤間切換，確認資料來源標示「離線示範」。
2. 美股 ADR 預設 5.0%、台股預設 3.5%；排序切換 ADR、RS 與部位比例。
3. 查看候選卡片的均線收斂、PDH/ORH 或跳空型態，以及進場價、停損價、停損幅度。
4. 開啟部位計算機，修改帳戶淨值，確認風險預算 = 淨值 × 0.005、股數取整，實際倉位不超過 35%/25%。
5. 確認 3R、5R、10R 目標價隨進場與初始停損風險計算。
6. 設定頁切換深色模式及 ADR，回到清單確認立即生效；下拉更新應保留目前市場。

Web 版提醒功能應明確顯示平台能力；Android 本機通知不能視為已在瀏覽器實作推播。正式 API 模式在跨域連線前還需設定後端 CORS，HTTPS 網頁不可直接呼叫不受信任的 HTTP API。

## 不需要 Flutter 的驗證

```bash
python3 scripts/check_web.py
python3 scripts/check_preview.py
node scripts/check_preview_ui.cjs
```

後兩個指令分別驗證策略／資料，以及實際預覽 JavaScript 的 UI 操作邏輯（使用 DOM 測試替身）。它們不等於瀏覽器畫面或 Flutter Widget 測試；正式 `flutter analyze`、`flutter test` 與編譯由 GitHub Actions 執行。
