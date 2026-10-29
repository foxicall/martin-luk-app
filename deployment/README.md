# PWA 發布與線上驗證

目標為 `https://martin-momentum-lab-20261021.brainysky.chatgpt.site/`，使用根路徑 `/`。`render.yaml` 是 Python API 的設定，不是此站的 PWA 部署入口。儲存庫沒有 `web/CNAME` 或此站的主機發布設定。

目前正常 HEAD/GET 請求回傳 HTTP 403；先前請求曾回傳 401。這只能證明目前請求未取得網站存取權，不能識別其實際發布平台。DNS 解析的共享 CDN 位址也不提供發布權限。GitHub Pages API 回傳 404；列出 Actions secrets/variables 的 API 回傳 403，因此不能宣稱 GitHub 沒有部署憑證。未讀取任何 secret 值。

## 可執行流程

在專案根目錄執行，Flutter 使用既有安裝：

```sh
python3 scripts/pwa_release.py audit --network --report build/deployment-audit.json
flutter build web --release --base-href / --output build/pwa-root
python3 scripts/pwa_release.py package
python3 scripts/pwa_release.py deploy --report build/deployment-result.json
```

`package` 會產生 `build/pwa-release/martin-luk-pwa-root.zip`、`pwa-release.json` 與 `SHA256SUMS`。它驗證根路徑入口、7,091 筆分類、與來源一致的資源檔、AssetManifest 及 Service Worker。ZIP 使用固定檔案時間，無內容差異時可重現相同雜湊。`pwa-release.json` 放在 ZIP 根目錄，記錄來源 commit 與各檔案 SHA256。

本地重用 Web 產物時，必須先確認它來自目前 HEAD；來源 commit 標籤本身不是編譯證明。CI 會在同一個 checkout 先重新編譯再打包。此工具不把舊的 main.dart.js 推測為新版本。

## 實際發布目前受阻

`pwa-target.json` 的 `publisher` 明確為 `null`。`deploy` 因此以 exit code 2 和 `DEPLOY_BLOCKED` 結束，不發送任何上傳請求。不能從站點網址自動推導官方上傳 API，也不能用空白憑證或猜測端點代替授權。

確認站點所屬平台的官方部署方式並取得相應授權後，才可將 `publisher` 設為官方發布工具或受信任 adapter 的 argv 陣列。這是本機程序參數陣列，不是 shell 字串。不要把憑證寫進設定檔或命令列；由部署系統依該平台的規範提供憑證。此儲存庫不包含假定適用於 brainysky 的上傳實作。

Adapter 會取得以下環境變數：

| 變數 | 用途 |
| --- | --- |
| `PWA_RELEASE_ARCHIVE` | 已驗證的 ZIP 絕對路徑 |
| `PWA_RELEASE_MANIFEST` | 版本 manifest 絕對路徑 |
| `PWA_TARGET_URL` | 必須更新的原站網址 |
| `PWA_RELEASE_COMMIT` | 本次來源 commit |

Adapter 必須使用主機的正式發布流程，將 ZIP 內容部署至原站根目錄，成功時回傳 0。腳本最多等候 300 秒，不使用 shell，也不輸出 adapter 可能包含憑證的原始輸出。Adapter 成功回傳後仍必須通過線上驗證，才能得到 `status: verified`。

```sh
python3 scripts/pwa_release.py verify --report build/live-verification.json
```

線上驗證要求遠端 `pwa-release.json` 與本次 manifest 完全一致，並重新下載入口、main.dart.js、bootstrap、Service Worker 與分類資料，比對實際 SHA256。HTTP 401/403、錯誤版本、舊檔或跨 origin 重新導向皆會失敗，不會因 adapter 回傳 0 就宣稱發布成功。若站點需要身分驗證，須先取得其正式支援的驗證方式；本工具不會蒐集瀏覽器 cookies。

## GitHub Actions

`Verify Flutter and build PWA` 先執行 6 項 release 腳本測試，再執行原有 Flutter 門禁及 Web 編譯，額外提供 `martin-luk-pwa-release` 成品，含可部署 ZIP、版本 manifest、SHA256 及部署設定盤點。原有 `martin-luk-pwa` 成品保留。

目前沒有部署 job，因為平台與授權尚未確定。Actions 綠燈表示建置／打包成功，不能當作原站已更新的證據。接入正式 publisher 後，應將 `deploy` 與線上 `verify` 設為發布 job 的必要成功條件。

```sh
python3 -m unittest discover -s scripts/tests -p test_pwa_release.py -v
```
