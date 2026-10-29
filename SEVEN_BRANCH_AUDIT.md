# 七分支盤點與整合報告

盤點時間：2026-10-29（Asia/Taipei）。還原分支 `backup-before-7branch-merge` 指向 `ea45161`；建立時工作目錄乾淨。

| 分支 | 盤點 SHA | 功能與處理 |
| --- | --- | --- |
| `codex/industry-classification-20261029` | `af6138770d6b8dd9c7b993acad2ac7d9bb92f69c` | 7,091 檔分類、來源與快取；已由 b97e313 合入，資料雜湊全部保留。 |
| `fix/pwa-rs-cloud-20261026` | `243d9ee3ce155d463c6f1630c6eb4ad2d34832cc` | PWA 20/60-session RS 與台股資料來源恢復；原已在主線與工作分支，無須重複提交。 |
| `fix/refresh-live-gate-20261014` | `0e8ad18900974065fa380e4fc96007ec24566faf` | 手機背景掃描、續掃、快取與行情門禁；2211869 合入。 |
| `fix/tpex-cloud-download-20261029` | `b9099b43d5e80ca1c8aa08598796eca632b24ea6` | TPEx 慢速下載與有界重試；原已納入，保留原始修復。 |
| `main` | `af44d37e88b25b031b1aadf38825fbc019d14971` | 主線；已包含 Hybrid 與修復 PR，最後合入以保留全部主線歷史。 |
| `momentum-scan-data` | `88268fe8f75c47582144642246c84829092cbb86` | 獨立根歷史的生成資料；8ec56f4 合入並移到 metadata_snapshots/cloud_scan，保留資料分支自動更新用途。 |
| `update/hybrid-v1.3.0-mobile` | `c2ff6938011564ce6c1d1056809952bda8552b4b` | Hybrid 1.3.0 策略、風控與測試修復；a5a5675 合入。 |

## 合併順序與衝突處理

先分類與快取、再掃描快照、再既有 RS/TPEx 修復（已是祖先）、手機掃描修復、Hybrid UI/業務邏輯，最後對齊最新 main 與 CI。每個需要實際合併的分支皆有 merge commit；已是祖先的分支不製造空合併。

refresh 分支在控制器、畫面、行情服務、股票池、測試、pubspec 及建置文件發生衝突。以最新 main 已完成跨分支協調的版本為基礎，重新套用分類啟動門禁、候選股分類及 UI。Hybrid 的 dashboard 與 live_strategy_engine 兩處衝突採同樣方式，保留最新主線型別、策略與修復。pubspec 保留 1.7.0+15 與所有主線依賴、字型及分類資源。沒有關閉任何 lint；分析器指出的 67 個既有問題使用 dart fix 修正。Flutter 3.29.3 的 SDK 相依已重新鎖定。

掃描資料保留原始 manifest、完整 runs 與 .momentum-generated 標記於獨立目錄；沒有把資料分支標記放到儲存庫根目錄。31 個 active pages 的 SHA256 與筆數通過，合計 7,572 筆。分類資料仍為 7,091 檔，兩種清單不同，不以快照筆數冒充分類覆蓋率。

## 驗證方式

Flutter 3.29.3 / Dart 3.7.2。此版本沒有 flutter test --offline；先 flutter pub get --offline，再 flutter test --no-pub。完整輸出保存在 test_logs/。

PWA 站點 https://martin-momentum-lab-20261021.brainysky.chatgpt.site/ 直接 HTTP 存取為 401；儲存庫無此主機部署設定，也無可用站點發布工具。推送 main 與 GitHub Actions 產物不等於此網址已更新。未建立其他 Pages 站點。

## 分支清理建議

可在確認遠端整合及線上驗收後，考慮清理分類分支、三個 fix 分支與 Hybrid 過渡分支。momentum-scan-data 為持續生成資料，不建議刪除；本機還原分支暫時保留。未刪除任何遠端分支。

## 最終門禁結果

- flutter analyze：No issues found，0 錯誤／警告／提示。
- flutter pub get --offline：成功。
- flutter test --no-pub：609 通過，0 失敗；3 個原有 opt-in 線上測試跳過。
- 雲端掃描器：21 通過，0 失敗。
- flutter build web --release --base-href /martin-luk-app/：成功。
- 額外根路徑 Web 成品：build/pwa-root；成功。
- 瀏覽器：390/900/1440px 成功載入分類；最終根路徑手機畫面確認顯示台積電的半導體業、晶圓代工與主題，無未捕捉 JS 錯誤。
- 啟動門禁及重試：4 項測試通過；資源讀取失敗不啟動 App，重試期間顯示載入中。
- 分類資源與 AssetManifest、Service Worker 的封裝內容一致。

完整最終日誌見 [docs/verification/20261029](docs/verification/20261029/)。本機根路徑可部署壓縮包為 /workspace/martin-luk-pwa-root.zip，SHA256 `adb9035a2b2f034b9b208aaeb861079b819764a919569c6b39b3eb0fd250d7cd`。
