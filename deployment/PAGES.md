# 正式 PWA：GitHub Pages

正式目標網址：**https://foxicall.github.io/martin-luk-app/**。此處使用 `/martin-luk-app/`，原站與根路徑 ZIP 仍保留為獨立目標，不共用錯誤的 base href。

## 自動發布

`.github/workflows/deploy-pages.yml` 在每次 main 推送或手動執行時運作；非 main 的手動執行不會發布。

1. 執行 release/Webhook 工具測試、Flutter 靜態分析與完整測試。
2. 編譯 `/martin-luk-app/` Web，核對分類與資源封裝，將版本 manifest 放入網站根目錄。
3. 使用 `actions/upload-pages-artifact@v3` 上傳 `build/web`。
4. 在 `github-pages` 環境使用 `actions/deploy-pages@v4` 發布。
5. 下載版本 manifest，重新取得線上的 manifest、入口、main.dart.js、bootstrap、Service Worker 與分類資料，比對 commit 與檔案 SHA256。

只有部署及線上驗證成功，deploy job 才會綠燈。授權為 `contents: read`、`pages: write`、`id-token: write`；只有建置及 Webhook job 則降為 `contents: read`。工作流使用官方 Actions token 發布，不使用原站的憑證。

## 首次啟用：目前的外部限制

目前整合憑證向官方 API `POST /repos/foxicall/martin-luk-app/pages` 送出 `build_type: workflow` 時，被 GitHub 以 HTTP 403 `Resource not accessible by integration` 拒絕。儲存庫的 admin 權限顯示為 true，不代表這個 GitHub App token 具備 Pages／Administration 的 API 權限。

若未能透過 API 啟用，儲存庫管理員需到以下頁面將 **Build and deployment → Source 設為 GitHub Actions**：

https://github.com/foxicall/martin-luk-app/settings/pages

啟用後，在 Actions 的 **Deploy PWA to GitHub Pages** 工作流重新執行失敗工作或 Run workflow（main）。不需要再修改 App 或重新授權原站。不可把建立工作流或成功建置宣稱為 Pages 已上線；必須以 deploy job 及實際網址為準。

## 原站 Webhook：預設關閉

目前原站為 `https://martin-momentum-lab-20261021.brainysky.chatgpt.site/`，不會在每次 push 自動收到請求。未設定任何 Webhook secret 值，也沒有發送通知。

取得正式 Webhook 入口後，可在 GitHub Actions secrets 設定：

- `ORIGINAL_PWA_WEBHOOK_URL`：HTTPS Webhook URL，不含查詢 token 或內嵌帳密。
- `ORIGINAL_PWA_WEBHOOK_SECRET`：雙方共用的簽章金鑰；使用高熵隨機值，不寫入程式碼或命令列。

手動 Run workflow 時選擇 `notify_original: true`，才會在 Pages 發布且線上驗證成功後發送一次 POST。缺少設定會明確失敗；不自動重試，也不跟隨重新導向。

JSON payload 包含 `event: pwa.pages.deployed`、`commit`、`repository`、`pages_url` 與 `run_url`。簽章規約：

```text
X-PWA-Timestamp: Unix 秒數
X-PWA-Signature: sha256=<HMAC-SHA256(secret, timestamp + "." + 原始 JSON body)>
Idempotency-Key: commit SHA
```

接收端需以原始 request body 驗證簽章、限制 timestamp 時差，並以 commit 去重。200–299 只表示通知送達，**不代表原站已部署**。接收端若要更新原站，仍須使用其正式授權的部署流程，並取得根路徑版本；Pages 的子路徑 ZIP 不能直接當成原站根路徑版本。

根路徑的 `Verify Flutter and build PWA` 工作流與 `martin-luk-pwa-release` 成品仍保留。其既有 `deployment/pwa-target.json` 屬於原站；Pages 設定獨立位於 `deployment/pages-target.json`。

## 本地驗證

```sh
python3 -m unittest discover -s scripts/tests -p 'test_pwa_*.py' -v
flutter build web --release --base-href /martin-luk-app/ --no-pub
python3 scripts/pwa_release.py package --config deployment/pages-target.json --web-dir build/web --out-dir build/pages-release
```
