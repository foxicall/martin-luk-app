Martin Luk App — RS 日期對齊完整覆蓋包（2026-10-15）

這是既有 Flutter 專案的六個完整原始碼檔案，非 APK、非完整新專案。

使用方式
1. 先備份既有專案的同名檔案。
2. 解壓縮 ZIP，將 lib/、test/ 合併到有 pubspec.yaml 的專案根目錄，覆蓋同名檔案。
   Windows 原專案範例：C:\Users\a1258\projects\martin_luk_trading_app
   不要把 lib/ 放到既有 lib/ 裡形成 lib/lib/。
3. 在 GitHub 切換 fix/refresh-live-gate-20261014，依相同相對路徑提交這六個檔案。
4. Actions → Build Android APK with Verification Gate → Run workflow，選該分支。
   真實推薦門禁通過後才會編譯並上傳 APK；工作流檔案本次不需更改。

修正內容
- Yahoo currentTradingPeriod 已切至隔日時，保守辨識當日已完成日 K。
- 股票/指數使用相同共同交易日端點計算 20/60 日 RS。
- 最多容許單側 1 個尾端交易日差異；共同資料距各自抓取日不得超過 7 曆日。
- 股票完整日 K 落後大盤時只供觀察，禁止確認新進場。
- 真實行情門禁日誌加入最後原始/完整交易日與 RS 對齊資訊。
- 回歸測試同步新政策；新增 test/rs_alignment_test.dart。

驗證指令（具備 Flutter SDK 的環境）
flutter test test/rs_alignment_test.dart test/live_strategy_engine_test.dart test/market_data_api_test.dart test/live_repositories_test.dart
flutter test test/integration_scan_test.dart --dart-define=RUN_LIVE_SCAN_TEST=true --dart-define=USE_MOCK_DATA=false --timeout=90s --reporter=expanded

驗證狀態
已驗證六個檔案與目前工作區來源逐位元組一致、ZIP CRC 與檔案雜湊。
此環境沒有 Flutter SDK，尚未驗證本次 Dart 測試、真實推薦或 APK 成功。
正式行情/真實聯網門禁沒有加入假行情；一般單元測試含固定 OHLC 與 MockClient。
ADR、EMA、突破、停損與 0.5% 風險門檻沒有放寬。
休市或沒有合格突破時，嚴格門禁仍會失敗並阻止 APK 建置。
