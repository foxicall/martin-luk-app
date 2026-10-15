# GitHub 網頁完整覆蓋：全市場輪掃版本

本次原始碼位於完整覆蓋包 `martin_luk_all_stocks_20261015.zip`。更新台灣上市＋上櫃與美股三交易所名單、Flutter 搜尋／代碼、Python 背景逐頁掃描及部署設定。請使用 GitHub 網頁上傳，不需要本機 Git 指令或額外的補丁安裝器。

如果你已套用上一份 `martin_luk_cloud_api_20261015.zip`，可改下載 **`martin_luk_all_stocks_updates_20261015.zip`**，只上傳本次新增／修改的完整檔案（少於 100 個檔案）。具體清單見 `UPDATE_FILES.txt`。這不是補丁腳本；每個同名檔案都整份覆蓋。若原專案版本不確定，使用完整專案包，避免漏掉既有依賴。

## 1. 選對分支與根目錄

開啟 `foxicall/martin-luk-app`，切換到 **`fix/refresh-live-gate-20261014`**。記下這次更新提交，後續 Actions 與 Render 都要使用同一版。

解壓完整 ZIP。將包內檔案上傳到原本含 `pubspec.yaml` 的專案根目錄；不要只上傳 ZIP，不要多套 `martin_luk_app/` 或其他新資料夾。既有 Windows 專案可先備份，再合併同名檔案。

## 2. 上傳整個專案內容

選 **Add file → Upload files**，拖入解壓後的專案檔案與資料夾。至少核對：

```text
.github/workflows/build_apk.yml
Dockerfile
.dockerignore
render.yaml
pubspec.yaml
lib/
android/
backend/
test/
scripts/
stocks_master.json
stocks_master_sources.json
stock_search.js
metadata_snapshots/
preview/
standalone_preview.html
ALL_STOCKS_UPDATE.md
```

包內其他原始碼、圖片、字型、授權及文件也一起保留。GitHub 網頁若遇到檔數限制，可在同一分支分批上傳，最後一次全部完成後再驗證／部署。每次提交可能觸發 Actions；前幾批未齊時失敗不代表最終完整版本不可建置。

`.github` 和 `.dockerignore` 是隱藏項目，容易漏掉。保留 `.github` 的原路徑，確認 workflow 已更新；不要刪除整個目錄或另建不帶點的 `github`。不要上傳 `.git/`、`build/`、`.dart_tool/`、`.venv/`、快取、個人 `.env`、keystore 或私鑰。

這份指南不再內嵌舊版數千行程式碼，避免手動複製出與 ZIP 不一致的舊股票池／API 合約。直接使用包內對應檔案完整內容。

## 3. 檢查提交中的關鍵值

在 GitHub 網頁逐一確認：

- `backend/engine/listed_universe.py` 及 `backend/engine/data_loader.py` 支援台股上市／上櫃和兩份 NasdaqTrader 名錄。
- `backend/scan_jobs.py` 包含持久化輪掃游標；`backend/api.py` 回傳本頁與累積 coverage 欄位。
- `Dockerfile`、`render.yaml` 使用 `MARTIN_SCAN_POOL_LIMIT=0`、`MARTIN_SCAN_PAGE_SIZE=60`、`MARTIN_SCAN_PAGE_INTERVAL=60`。
- Flutter 模型／來源／UI 與新版 background envelope、`.TWO` 代碼一致；字典及三份 HTML 已同步。
- `.github/workflows/build_apk.yml` 仍有真實行情與數學門禁，允許 `candidates: []`，不是要求至少一檔推薦。

本版不是放寬 ADR／突破／風控條件。美股名錄缺 CFI 時保守排除未知證券，台灣離線字典有不同日期身分來源，不宣稱當日完整核證；來源與限制見 `stocks_master_sources.json`、`metadata_snapshots/SOURCES.json`。

## 4. 重建 APK

在 **Actions → Build Android APK with Verification Gate** 查看完整提交的執行結果；必要時 **Run workflow** 選正確分支。手動入口需 workflow 存在於預設分支。工作流先驗證指定真實行情與計算，零推薦合法；通過後才產出 `martin-luk-app-release` APK artifact。實測日誌是 `martin-luk-live-scan-evidence`，兩者保留 7 天。

下載 APK 安裝到手機。新輪掃欄位與上櫃代碼需要新版 App，不能以舊 APK 只接新後端假設全部相容。簽署與本機建置見 [README_HOW_TO_BUILD.md](README_HOW_TO_BUILD.md)。

## 5. 同步更新 Render

在 Render 確認來源分支與這次提交。舊服務 Environment 的 `MARTIN_SCAN_POOL_LIMIT=30` **必須改為 `0`**，另填頁數 `60`、頁間隔 `60`；部署檔更新不保證平台手動保存的舊值已被覆寫。儲存後 **Manual Deploy → Deploy latest commit**。

新程式隔離舊範圍快取；Render 暫存磁碟重建後，輪掃進度可能從第一頁重新開始。每工作一頁，剩餘標的由前景 60 秒更新／手動 force 推進，不是無人連續全池服務。當頁 RS 與推薦不能稱為跨日期全市場排行。

先檢查公開服務 `/health`，再檢查台股／美股 `/v1/candidates?...&background=true`，最後在新 App 選 Python API、保存實際 HTTPS 根網址。完整步驟見 [CLOUD_API_GUIDE.md](CLOUD_API_GUIDE.md)。

本次提供可覆蓋檔案與操作指南，沒有代為提交 GitHub、觸發 Actions、部署 Render 或取得正式網址。實際建置與部署結果以你的執行紀錄為準。
