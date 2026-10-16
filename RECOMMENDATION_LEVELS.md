# 1.4.1+8：推薦股票進出場價位

2026-10-16（台北時間）。本版將使用者圖片中的資訊加入 Flutter 推薦卡片、個股計算機及離線預覽。
行情、台股完整名單輪掃與 0.5% 風控規則沿用既有版本。

## 每張推薦卡片

- 代碼、名稱、產業、ADR、RS、型態與行情時間。
- 假設買價／PDH 或 ORH 觸發界線，和最新可用市價分開。
- 初始硬停損參考、實際低點來源、停損幅度、每股 1R。
- **3R 賣價：賣原始股數 15%。**
- **5R 賣價：再賣原始股數 15%。**
- **剩餘 70%：日收盤跌破 9 EMA 時追蹤出場。**

詳情頁另保留 10R 觀察價與獨立台／美帳戶本金、建議股數及曝險。
兩次 15% 都以原始買進股數為分母，並非第二次賣剩餘股數的 15%。
百分比為分批計畫；實際整股／整張交易需依數量調整，App 不會自動送出或記帳賣單。
既有持股診斷仍有自身的 10%–15% 強勢減碼與停損規則，本版是推薦進場前的計畫呈現。
初始／保本停損先觸發時，應先依停損處理，不需等待達到獲利目標。

## 計算方式

```text
每股 1R = 假設買價 - 初始硬停損
停損幅度% = 1R / 假設買價 × 100
3R = 假設買價 + 3 × 1R
5R = 假設買價 + 5 × 1R
```

純數學範例（不是最新行情）：假設買價 NT$74.70、停損 NT$73.50，
1R 為 NT$1.20、停損約 1.61%、3R 為 NT$78.30、5R 為 NT$80.70。
幣別依該股票市場為 TWD 或 USD，不換算或混用本金。

觸發界線不保證可成交，目標價格也未代為轉成交易所委託跳動單位。
圖片中日線參考停損若超過 5%，不會直接視為可下單建議；仍須取得有效的實際進場分鐘 K 停損。
未確認突破、缺少停損、風控不符或本金不足時，目標價標示「待確認」。
快取／舊行情需更新時標示「待更新」，不利用快照整體更新時間把舊卡片當成新買點。

## 覆蓋及重建

1. 已套用 1.4.0+7 手機台股輪掃包：解壓 `martin_luk_recommendation_levels_updates_20261016.zip`，
   依路徑覆蓋 GitHub 分支 `fix/refresh-live-gate-20261014`，不要只上傳 ZIP。
   本更新包同時包含上一項 `live_repositories_test.dart` 逐檔進度修正。
2. 版本不確定時使用完整專案 `martin_luk_recommendation_levels_20261016.zip` 合併覆蓋。
3. 確認 `pubspec.yaml` 為 **1.4.1+8**。等本次提交的 Actions 通過，下載新版 APK 安裝。
4. 若只想先看畫面，可下載 `standalone_preview.html` 後以瀏覽器開啟；該頁全為明確標示的離線示範資料。

本次沒有替使用者 Push、觸發 GitHub Actions 或部署 API。
台股手機直接輪掃不需要 Python API，美股手機核心池仍保持原有範圍。

## 驗證

本環境可執行並已通過離線 Node 檢查：

```bash
node scripts/check_standalone_preview.cjs
node scripts/check_preview_ui.cjs
node scripts/check_portfolio_preview.cjs
node scripts/check_stock_search.cjs
```

有 Flutter SDK 的環境再執行：

```bash
flutter pub get
flutter test test/recommendation_trade_levels_test.dart test/dashboard_scope_test.dart test/production_ui_test.dart --dart-define=USE_MOCK_DATA=false --reporter=expanded
```

新增六個元件測試已加入 Actions，原有真實行情門禁保留，零推薦合法。
本環境缺少 Flutter SDK，因此不能宣稱 Dart 測試或新版 APK 已成功。
