# 修正「5,118 檔名單，卻只評估 30 檔」與大量提示卡

**本文件為 1.3.2+6 的 Python 部署說明。新版 1.4.0+7 台股手機模式已改為完整名單分批續掃，請先看 [MOBILE_TW_SCAN.md](MOBILE_TW_SCAN.md)；不需要為台股手機輪掃先部署 API。下文的 30 檔手機限制只描述當時版本與目前美股模式。**

更新日期：2026-10-16（台北時間）。App 版本：1.3.2+6。

## 這次畫面代表什麼

手機已成功取得美股交易所名單與核心股票行情。名單總數不等於已掃描數：
手機直接連線目前只評估最多 30 檔，避免對公開行情端點一次送出數千筆請求。
這個上限不是網路故障。台股上市／上櫃與美股三大交易所的更大股票池，
由 Python API 以最多 60 檔一頁逐頁評估。

未知美股證券類別仍保守排除，原始排除原因與數量都保留。
本次不會放寬普通股分類、ADR、突破、停損或 0.5% 風險規則，
也不會將名單筆數當作全市場成功評估數。

## 已完成的程式修改

- 總覽明確區分名單總數、本次掃描池與成功評估數，提供前往 API 設定的入口。
- 一般資料來源說明改為推薦清單下方的單一可展開區塊；完整文字保留。
  更新失敗、過期快照、缺漏行情仍直接顯示。
- 設定頁新增「測試 API 連線」，等待有期限，畫面離開後不回寫狀態。
  測試會驗證服務身份、版本與實際掃描池上限；不是只接受任意 HTTP 200。
- Python 新增 `/v1/capabilities`，不需等市場資料商回應即可回報掃描設定。
  連線測試通過只代表 API 可用，行情可用性仍由後續真實掃描驗證。
- 保留上一版取消請求測試的明確回呼同步修正。

## 你目前尚未部署 API：請先完成這一步

APK 建置與 Python 部署是兩件事。GitHub Actions 產生 APK，不會自動建立雲端服務。
本次準備了完整原始碼與部署配置；沒有代為建立 Render 服務或產生正式網址。

### 1. 先覆蓋 GitHub 原始碼

解壓本次更新包，將檔案依原路徑覆蓋到：

```text
repository: foxicall/martin-luk-app
branch: fix/refresh-live-gate-20261014
```

根目錄必須已有 `Dockerfile`、`.dockerignore`、`render.yaml`、`backend/`。
更新包含這些部署入口，以及本次修改檔的完整內容。
若你的 repository 缺少其他原始碼，請改用完整專案包。
只上傳 ZIP 不會更新原始碼。既有 Actions 會驗證後建置新 APK。

### 2. 在 Render 建立公開 HTTPS 服務

1. 開啟 <https://dashboard.render.com/> 並登入你自己的帳號。
2. 選 **New → Web Service**，連接 `foxicall/martin-luk-app`。
3. 分支選 `fix/refresh-live-gate-20261014`；Runtime 選 **Docker**。
4. 若專案就在 repository 根目錄，Root Directory 留空，Dockerfile Path 填 `./Dockerfile`。
5. Health Check Path 填 `/health`，依當下平台提供的方案選擇；本專案範本為 Free。
6. Environment 至少核對下面四個值；其他設定完整表見 `CLOUD_API_GUIDE.md`。

| Key | Value | 用途 |
|---|---|---|
| `MARTIN_SCAN_POOL_LIMIT` | `0` | 不固定截取前 30 檔 |
| `MARTIN_SCAN_PAGE_SIZE` | `60` | 每次工作最多排定 60 檔 |
| `MARTIN_SCAN_PAGE_INTERVAL` | `60` | 尚有下一頁時的快照有效秒數 |
| `MARTIN_CACHE_DIR` | `/tmp/martin_luk` | 快取與輪掃進度 |

7. 建立服務，等狀態變成 **Live**，複製平台分配給你的公開 HTTPS 基底網址。

也可用 **New → Blueprint** 匯入根目錄的 `render.yaml`，但務必核對實際選取分支。
這份文件不提供虛構的可連線服務網址。不要把 Render Dashboard 管理頁網址填入 App。

### 3. 用瀏覽器確認服務

將以下 `你的服務名稱` 換成平台實際分配的服務名稱：

```text
https://你的服務名稱.onrender.com/health
https://你的服務名稱.onrender.com/v1/capabilities
```

`/health` 應回 JSON。`/v1/capabilities` 應包含：

```json
{
  "service": "martin-luk-market-api",
  "api_version": 1,
  "data_mode": "live",
  "markets": ["tw", "us"],
  "scan": {
    "pool_limit": 0,
    "scope": "full_universe",
    "page_size": 60,
    "page_interval_seconds": 60,
    "background_jobs": true,
    "continuation": "client_driven",
    "recommendations": "latest_page_only"
  },
  "requires_market_data_verification": true
}
```

如果回 404，通常是部署了舊版／選錯分支。若 `pool_limit` 是 30，
在 Render Environment 改成 0 再部署。平台休眠後，先開 `/health` 等待喚醒，
看到回應後再回 App 進行 8 秒上限的連線測試。

### 4. 安裝新 APK 並設定手機

1. 安裝 Actions 成功產生的 1.3.2+6 APK。
2. 「設定與提醒」→ 關閉離線示範 → 正式行情來源選 **Python API**。
3. 填公開 HTTPS **基底網址**，不要加 `/health`、`/docs`、`/v1/candidates`。
4. 按「測試 API 連線」，確認實際股票池上限是 0，然後儲存設定。
5. 回總覽，下拉更新；台股、美股分別查看本頁進度與本輪累積計數。

帳戶本金、持股資料與原有 ADR 門檻會保留，不需要清除 App 資料。

## 全股票池輪掃的實際範圍

每個背景工作只處理當頁，每約 3 秒查詢進度。App 在前台持續一般更新，
快照到期後才會驅動下一頁；下拉更新可以提早推進下一頁。
關閉 App 後不會自動啟動後續頁，Render Free 亦可能休眠。
因此這版提供的是**可遍歷取得名單的分頁輪掃**，不是已完成的全天候全市場掃描。

請分別查看「本輪已嘗試」、「成功評估」、「尚未嘗試」：
嘗試包含失敗，不能把 5,118 檔名單宣稱成 5,118 檔有效行情。
目前推薦與 RS 排名只反映當頁成功取得且交易日對齊的資料；
跨頁不是同一時間快照，不會直接拼接成全市場排名。

API 可以回傳零推薦；這是合法結果。公開行情商可能延遲或對雲端 IP 限流，
API 連線成功不保證每檔行情抓取成功。

## 驗證狀態

本次已實際執行後端 101 項、維護腳本 25 項測試，全部通過；為離線測試，
不是外部行情實測。工作流 YAML／Bash 語法與真實門禁順序檢查通過。
此環境沒有 Flutter/Dart SDK，新增 Dart 單元／元件測試交由 GitHub Actions 執行，
不宣稱本次 APK 已編譯成功或 Python 服務已部署。
