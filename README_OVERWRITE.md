# Martin Luk App：真實行情健康門禁完整覆蓋包

日期：2026-10-15（台北）

使用者已選擇：驗證真實行情與計算正確即可建置，允許推薦為零。
本包為現有完整 Flutter 專案的覆蓋更新，不是 APK、不是全新專案。

## 覆蓋步驟

1. 先備份現有專案的同名檔案。
2. 解壓縮本 ZIP。將其中 .github/、lib/、test/、scripts/ 及 Markdown 文件
   合併到含 pubspec.yaml 的原專案根目錄，覆蓋同名檔案。
   Windows 專案範例：C:\Users\a1258\projects\martin_luk_trading_app
   本 ZIP 沒有額外一層專案資料夾；避免產生 lib/lib/ 或 test/test/。
3. 在 GitHub 切換 fix/refresh-live-gate-20261014 分支，提交所有對應檔案。
   一定要包含 .github/workflows/build_apk.yml、test/integration_scan_test.dart、
   lib/models/market_data.dart、lib/services/live_strategy_engine.dart，以及新增
   scripts/validate_live_scan_evidence.py、scripts/tests/test_live_scan_evidence.py。
   僅修改測試而保留舊工作流，仍可能被舊的非空候選檢查阻擋。
4. 提交會啟動 Actions；也可 Actions → Build Android APK with Verification Gate
   → Run workflow → 選擇該分支。
5. 通過後在 Artifacts 下載 martin-luk-app-release，解壓取得 app-release.apk。
   不論成功失敗，martin-luk-live-scan-evidence 保存驗證日誌，內含 JSON 報告。

## 新門禁

Python 驗證器測試 → Flutter RS／策略／風控單元測試 → 真實 HTTP 行情／指標測試
→ schema 2 報告驗證 → Release APK。

真實行情測試要求兩指數 ^GSPC／^TWII 及五檔 NVDA、AAPL、TSLA、2330.TW、2603.TW，
在 15 秒內完成實際日 K／報價取得與 ADR／EMA／RS 獨立驗算。
status=passed 且候選數為 0 合法，會顯示 no_qualified_entry。
必要行情缺漏、HTTP／解析或計算錯誤、Mock、過期快取、超時仍會阻止建置。
有候選時仍驗證原本的 ADR、EMA 收斂、正常時段突破、實際停損及 0.5% 風控。
沒有把觀察股轉成推薦，也沒有降低選股門檻。

## 本次已執行的驗證

- Python 行情報告驗證器：16 項單元測試通過。
- 工作流 YAML、Bash 語法、失敗傳遞與驗證順序：靜態檢查通過。
- 專案來源完整性、每檔位元組比對與 ZIP CRC／SHA256：通過。
- 本環境無 Flutter SDK；Flutter 命令為 exit 127。
- 新 Dart 真實行情門禁與 APK 尚待提交後在 GitHub Actions 實際驗證。

本包沒有補丁安裝器，不需要執行舊 apply_market_scan 腳本。
完整檔案清單及 SHA256 見 SOURCE_SHA256.json。
