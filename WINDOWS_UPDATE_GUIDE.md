# 更新既有 Windows 專案

本工作區的既有專案在 `/workspace/martin_luk_app`；沒有連線到使用者電腦的 C 槽。本成品提供同名檔案供覆蓋至 `C:\Users\a1258\projects\martin_luk_trading_app`，不需要重新產生 Flutter／Android 專案骨架。

下載 `martin_luk_trading_app.zip`，將內容合併至既有專案根目錄、允許覆蓋同名檔案。ZIP 內是直接的 `lib/`、`preview/`、`test/`、`.github/` 等路徑，不需要再建立一層專案目錄；既有檔案不會因未出現在 ZIP 而被刪除。若已有自行修改的原始碼，先保留一份副本再合併。

PowerShell 指令（請依實際下載位置調整 ZIP 路徑）：

```powershell
$project = 'C:\Users\a1258\projects\martin_luk_trading_app'
$archive = "$env:USERPROFILE\Downloads\martin_luk_trading_app.zip"
Expand-Archive -LiteralPath $archive -DestinationPath $project -Force
& "$project\run_preview.bat"
```

也可直接雙擊專案根目錄的 `run_preview.bat`，或用瀏覽器開啟 `preview\standalone_preview.html`。批次檔使用 `%~dp0` 取得自身所在目錄，從其他工作目錄啟動、路徑含空格也能定位 HTML。沒有 Node、Python、Flutter 或 Android SDK 也能使用離線頁。

## 四個指定檔案

| 檔案 | 內容 |
|---|---|
| `preview/standalone_preview.html` | 全部 CSS／JS／字典內嵌，獨立 USD／TWD 本金、搜尋、推薦、風控試算及持股管理 |
| `lib/services/live_strategy_engine.dart` | 真實 K 線指標與純數學 `calculatePositionSize`／`calculateExitTargets` |
| `lib/services/stock_search_service.dart` | 本機字典一次載入、正規化、權重排序及有界容錯 |
| `run_preview.bat` | 用預設 HTML 瀏覽器開啟離線預覽 |

原始股票身分是真實代碼與名稱；離線頁的價格、ADR、EMA 及訊號都是明確標示的示範數值。預設美股資金 USD 50,000、台股 TWD 1,000,000，兩市場各自儲存；單筆風險分別是 USD 250／TWD 5,000。選擇只有字典身分的股票時，會帶入持股表單，請自行填寫成本、停損與示範行情。

離線推薦停損距離嚴格維持 1.5%～3%。`calculatePositionSize` 同樣拒絕範圍外的停損，不自動造出市場上不存在的停損價；實際股數以 0.5% 風險預算及 35%／25% 金額上限中較小者向下取整。`calculateExitTargets` 只依有效成本／初始停損計算固定 1R 與 3R／5R／10R，不需網路或股票訊號。

既有連網版 App 改用真實 Yahoo 行情，獨立 HTML 持續提供無伺服器示範。完整 Dart 引擎還引用真實 K 線模型，若從 ZIP 手動取檔，請一起合併 `lib/models/market_data.dart` 等相關檔案；直接合併完整 ZIP 可保留各模組相依性。

## 驗證

離線預覽不需執行任何建置。具備 Flutter 時，於既有專案根目錄執行：

```powershell
flutter pub get
flutter test test/live_risk_helpers_test.dart test/stock_search_service_test.dart
flutter analyze
```

預覽互動檢查（開發環境有 Node／Python 時）：

```powershell
python scripts/sync_stock_search.py --check
node scripts/check_stock_search.cjs
node scripts/check_standalone_preview.cjs
```

正式 APK 建置、行情測試與前景更新說明見 `PRODUCTION_GUIDE.md`；原始碼檔案的完整性與 ZIP 校驗見 `FILE_MANIFEST.json`、`TERMINAL_EXPORT_GUIDE.md`。
