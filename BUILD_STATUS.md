# 本次交付的驗證狀態

## 台美股智慧搜尋（2026-10-13）

新增共用股票字典 793 筆：US 509（公開 S&P 500 快照 503 筆證券與 6 檔主要個股補充）、TW 284 檔常見上市普通股。`stocks_master_sources.json` 記錄來源、資料快照、名稱補齊政策與範圍；台股為常見股整理，不宣稱是完整官方即時名單。

Flutter 與兩個 HTML 的推薦列／持股表單支援代碼、中英文名稱、別名、簡碼、200ms 防抖及最多 8 筆建議。JS 與 Dart 使用同一權重規則；HTML 已內嵌完整 JSON 與同一 JS 核心。選取更新標準代碼與市場，保持 USD／TWD 本金獨立；沒有行情的字典身分不建立策略訊號。修正手機 HTML 長按選項的失焦競態，選項保留至點擊完成。離線字型已重新涵蓋新增字典中文，沒有缺少 CJK 字形。

已執行並通過：搜尋核心／字典／嵌入一致性 119 項、手機 HTML UI 53 項、持股 UI／引擎 207 項、獨立 HTML 221 項、既有策略 84 項、Python／HTML 診斷一致性 72 情境，以及 55 個後端單元測試。HTML 互動以生產 JavaScript 加 DOM 替身驗證；未做實際手機觸控或浏览器畫面測試。

新增 15 個 Dart 服務、Widget 與整合測試；本機沒有 Flutter／Dart SDK，僅完成靜態檢閱，未執行 `flutter analyze`／`flutter test` 或 APK 編譯。既有 GitHub Actions 將執行新的字典同步檢查、搜尋檢查、Flutter 分析、測試及 APK 建置。

重跑本次搜尋檢查：

```bash
python3 scripts/sync_stock_search.py --check
node scripts/check_stock_search.cjs
node scripts/check_preview_ui.cjs
node scripts/check_portfolio_preview.cjs
node scripts/check_standalone_preview.cjs
```

## 分市場 Capital 設定與自動帶入

Flutter、手機 HTML 預覽與完全離線單檔現在明示兩個独立 Capital 帳戶：美股預設 US$50,000 USD，台股預設 NT$1,000,000 TWD。單筆 0.5% 預設風險分別為 US$250 USD／NT$5,000 TWD；計算機使用標的所屬市場的本金，修改及重新載入互不覆蓋。HTML 支援在計算機內切市場，Flutter 在儀表板切市場後開啟個股時帶入對應資金；小數本金保持原值。

本次檢查：173 項獨立 HTML、31 項手機預覽 UI、195 項持股操作及 84 項策略檢查通過。新增 5 項 Flutter Capital 測試；本機無 Flutter SDK，分析及 Widget 測試由 GitHub Actions 執行。

## 固定離線單檔與終端匯出

本次再補入 `2603.TW` 長榮示範推薦，獨立 HTML 的檢查更新為 **150 項通過**。新增一鍵 `scripts/package_trading_app.sh`，產出指定名稱的 `/workspace/martin_luk_trading_app.zip`，並同步輸出 Base64 與 SHA256。

新增 `standalone_preview.html`，內嵌 CSS、JavaScript 與 Mock，沒有 API 呼叫或外部檔案依賴。145 項生產引擎與 UI handler 檢查通過（DOM 替身，未執行實際瀏覽器截圖）。新增 ZIP／Base64 匯出與還原腳本，14 項編碼、SHA256、CRC、路徑與覆寫保護檢查通過。

Actions 現在支援 Push 到 `main`／`master` 自動觸發，另保留手動入口；獨立 HTML 檢查加入建置前驗證。Android SDK／簽章／套件配置已靜態核對。APK 編譯結果仍須由實際 GitHub Actions run 確認。

## 新增持股診斷

新增 Python `exit_engine.py`／`portfolio_tracker.py`、持股行情與單次分析 API、Flutter 持股管理與出場畫面，以及單檔 HTML 的庫存 CRUD 和手動行情測試。原始成本與初始停損固定決定 1R；已觀察最高 R 持續保存，達到 2R 啟用保本停損。硬停損與完成收盤的 EMA 跌破分開判斷，全數出場優先於強勢分批減碼。

最高 R／已上移停損依 Mock 或各 API 基底網址隔離；模式切換即撤銷舊請求覆寫結果的資格，避免離線實驗替真實行情啟用保本停損。持股基礎資料改變會清除歷史。同市場代碼唯一，前端自動分批更新超過 50 檔庫存；本機儲存失敗時顯示提示。

推薦停損規則已依這次需求調整：有效突破日低點的風險距離不超過 5% 時可採用；超過 5% 時，必須有實際 1／5 分鐘進場棒低點，且距離在 1.5%～3%。不再把所有停損強制限制為 1.5%～3%；沒有有效市場低點仍列觀察。PDH／ORH 突破水平與實際確認棒價格分開記錄。

本次重新執行的檢查全部通過：

| 檢查 | 通過數量 |
| --- | ---: |
| Python 後端、風控、持股與行情 API 單元測試 | 55 |
| 原有 HTML 策略／資料檢查 | 84 |
| 原有 HTML UI handler 檢查 | 12 |
| 新增持股引擎／CRUD／來源隔離／持久化操作檢查 | 195 |
| Python／HTML 出場診斷結果一致性情境 | 72 |
| 正式 Flutter Web 靜態配置檢查 | 7 |

重跑指令（需要 Python 後端測試相依套件與 Node.js）：

```bash
python3 -m unittest discover -s backend/tests -v
python3 scripts/check_preview.py
node scripts/check_preview_ui.cjs
node scripts/check_portfolio_preview.cjs
python3 scripts/check_portfolio_parity.py
python3 scripts/check_web.py
```

UI 檢查執行實際 JavaScript handler，使用 DOM 測試替身；不是實際瀏覽器畫面或截圖測試。Python／HTML 一致性檢查涵蓋固定 1R、保本、EMA、曝險、分批整股邊界及出場優先序。Yahoo 實際行情、Android 裝置與正式 Flutter 編譯仍未在此環境驗證。

## 編譯與上一版檢查紀錄

目前工作環境沒有完整 Flutter／Dart／Android SDK，因此本機尚未產出 APK，亦尚未執行 `flutter analyze` 或 `flutter test`。本次使用 GitHub Actions 編譯途徑，不下載本機 SDK。

本次依新需求改為 GitHub Actions 雲端建置，不再下載本機 Android SDK。工作流為 `.github/workflows/build_apk.yml`，已檢查必要步驟、APK產物路徑與14天保留期；正式建置結果需由 GitHub Actions run 確認。提供正式 Flutter Web 配置與390×844框架，以及免SDK互動 HTML 預覽。

雲端工作流已加入 `strategy-tests`：Python 3.12／Node 22 驗證後端、HTML 策略及持股互動，並執行 Python／HTML 診斷一致性檢查；通過後才進入 Flutter 分析、測試及 APK／Web 建置。

已完成：Flutter 原始碼、Android 建置配置、FastAPI 掃描介面、離線資料與測試原始碼；靜態介面檢查已核對 JSON、Null-Safety、頁面與控制器契約。

上一版 Python 的 **21 項 API／風控／快取測試全部通過**，雙市場後端 demo CLI 與 Python compileall 亦已通過。HTTP 合約測試使用 ASGI 與 inline worker 替身，避開沙箱的跨執行緒喚醒限制；正式 API 保留非阻塞 worker thread。尚未連線驗證外部金融網站。

待在具備工具與網路存取的環境執行：`flutter pub get`、`flutter analyze`、`flutter test`、`flutter build apk --release`，以及 Android 實機通知與實際行情驗證。

新增 Web 靜態配置檢查 **7項全部通過**；Shell 語法、workflow YAML解析及Android XML檢查通過。新增4項 Dart mock預覽模式測試，待雲端 `flutter test` 執行。已修正分頁數值型別與中文 HTTP 測試資料的 UTF-8 編碼。

免SDK HTML 預覽的 **79項策略／資料檢查、12項UI操作邏輯檢查全部通過**。UI操作測試執行真實JavaScript handler並使用DOM測試替身。Chromium 在此沙箱啟動時遇到 `setsockopt: Operation not permitted`，因此未完成瀏覽器畫面或截圖驗證。正式Flutter Web及APK仍需以雲端編譯結果確認。

上一版已打包334,820 bytes的本地中文字體與SIL OFL授權，確認全部Dart UI與Mock文字有字形；新增持股中文介面使用重新產生的字型子集。Flutter Web可使用本機CanvasKit與字體資源預覽。

預覽連線修復：啟動腳本改為 `0.0.0.0:8080`，新增 `--mock` / `--serve-built` 與 `/__health`，12項launcher及6項HTTP handler測試通過。实际執行沙箱仍以 `Operation not permitted` 拒絕socket，已將此限制與遠端埠轉送需求記錄於 `PREVIEW_CONNECTION.md`；未宣稱外部瀏覽器已連通。
