# 3R／5R 未顯示：價位與買進股數分開處理

2026-10-16（台北時間），版本 **1.4.4+11**。

## 為何畫面都是待更新

使用者截圖為 1727.TW，PDH 觸發參考價 NT$100，頁面同時標示「快取行情待更新」。原本詳情頁只有在「行情未過期、突破停損已確認、有效本金可以計算股數」時才建立 `PositionPlan`，停損、1R、3R、5R 也全部依賴它。任一條件缺少，就連原本已有的有效舊停損和目標價也被隱藏。

截圖無法證明原始資料究竟有沒有有效停損。另一種可能是它本來只是 ADR／動能觀察股：未確認正常交易時段的 PDH／ORH 突破或沒有有效實際低點，策略便不建立初始停損。只有觸發價 100，不能唯一決定 3R／5R。

```text
1R = 假設買進價 − 初始停損
3R目標 = 假設買進價 + 3 × 1R
5R目標 = 假設買進價 + 5 × 1R
```

**純假設範例**：買進價 100、停損 98，1R=2，3R=106、5R=110、10R=120。98 不是 1727.TW 的實際停損或推薦值。

## 這次變更

1. 抽出 `StrategyEngine.calculateTradeLevels(candidate)`，以原本相同的確認狀態、停損來源、低點證據及精確十進位計算價格，不要求帳戶本金。
2. 有效但已保留／過期的候選，在推薦卡片及詳情顯示「上次確認價位（待更新）」、確認時間、舊停損及 3R／5R；買進股數與建議部位仍停用。它不會變成當前新買點。
3. 本金為空、無效或不足時，不再抹去有效價位；股數計算仍會顯示輸入錯誤並清除先前部位結果。
4. 沒有實際停損時，顯示「缺少停損」及具體說明。停損／來源／型態未通過驗證時，仍不給自動目標；不反推 2% 停損，不由收盤價或缺失分鐘棒補造低點。
5. 詳情新增「手動試算 3R／5R」。買進價先帶入該股觸發價，**停損留白**。使用者自行輸入後顯示 1R、幅度與 3R／5R／10R；明確標為「假設價格試算」，不修改候選、不新增買進股數。無效輸入立即清除舊試算結果；不同股票／市場重設，USD／TWD 分開。超過 5% 僅保留數學試算並提示不代表策略進場合格。

0.5% 風險預算、35%／25% 部位上限、當日實際低點 ≤5%、替代分鐘 K 低點 1.5%～3% 的原有條件均保留。真正進場仍須最新行情與型態確認。分批比例仍為 3R 賣原始股數 15%、5R 再賣 15%、剩餘 70% 依日收盤跌破 9 EMA 追蹤。

## 可直接覆蓋的檔案

核心本次檔案：

```text
lib/services/strategy_engine.dart
lib/screens/calculator_screen.dart
lib/screens/dashboard_screen.dart
lib/widgets/manual_trade_levels.dart
test/trade_levels_test.dart
test/manual_trade_levels_test.dart
test/recommendation_trade_levels_test.dart
.github/workflows/build_apk.yml
pubspec.yaml
```

實際更新包另包含與 GitHub 基線不同／缺少的完整依賴、上一版官方 CSV 備援與指南、驗證器及逐檔清單，見 `UPDATE_FILES.txt`；不需要先依序安裝先前數個更新包。離線 HTML 原有示範試算保留，本次新增的手動面板位於 Flutter 詳情頁。

1. 解壓 `martin_luk_r_targets_updates_20261016.zip`。
2. 在 GitHub `foxicall/martin-luk-app` 切換 `fix/refresh-live-gate-20261014`，依原路徑上傳／合併覆蓋全部檔案，包含 `.github/`。不要只上傳 ZIP，不要多包一層專案目錄。
3. 確認版本為 **1.4.4+11**。等待最後一次提交的 Actions 成功後下載 `martin-luk-app-release`，解壓並安裝 APK。
4. 開啟候選詳情。有有效舊停損會顯示歷史參考目標；若顯示「缺少停損」，展開「手動試算 3R／5R」自行輸入假設價位，或回推薦頁更新實際行情。

不確定專案完整性時，使用 `martin_luk_r_targets_20261016.zip` 合併完整專案。保留 App 資料與台股輪掃進度，不必清除快取或重設掃描。

## 驗證

```bash
flutter test test/trade_levels_test.dart test/manual_trade_levels_test.dart test/recommendation_trade_levels_test.dart --dart-define=USE_MOCK_DATA=false --reporter=expanded
```

新增 11 項價格邏輯測試、8 項手動面板測試；推薦／詳情元件測試從 6 項擴充為 10 項。兩項舊斷言改為新的價位與股數分離語意：快取有價位但無部位，本金無效仍保留價位但無買進股數。缺少停損／寬停損的自動目標禁止斷言保留，另驗證手動試算無法填補自動停損或啟用買進。

上述固定 fixture 不是真實行情證據。既有真實行情／指標門禁保留，允許零推薦，通過後才編譯 APK。

工作流也執行既有 `test/strategy_engine_test.dart`，檢查重構後原有股數取整、風險／曝險上限、交易單位及十進位邊界。

本環境實際執行上述 Flutter 命令，因沒有 SDK 退出 127（`flutter: command not found`），尚無新增 Dart 測試或 1.4.4+11 APK 通過結果。靜態檔案／工作流／ZIP 完整性不等同編譯及手機實測；請以新提交的 Actions 為準。
